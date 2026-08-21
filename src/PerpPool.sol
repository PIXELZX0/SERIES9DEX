// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {FeeSplit} from "./libraries/FeeSplit.sol";
import {ISpotPool} from "./interfaces/ISpotPool.sol";
import {PerpParams} from "./interfaces/IPerpPool.sol";

/// @notice Perpetual futures pool (DEX.md §5.2), GMX-style: a single-sided
/// quote-token LP vault is the counterparty to every position. Mark price is
/// a TWAP read from the linked spot pool's cumulative-price oracle. Funding
/// accrues from the heavier side to the LP vault (compensation for
/// directional exposure). Fee policy mirrors spot: creator-chosen lpFeeRate
/// on notional, 0.1% of it to the protocol.
///
/// Accounting invariant: quote balance == totalLiquidity + sum of position
/// margins + protocolFeesQuote (all realized flows move between these three
/// buckets; unrealized PnL only affects LP share pricing).
///
/// Rebasing tokens are unsupported by policy. Fee-on-transfer quote tokens
/// are credited by balance delta on deposit; payouts are plain transfers.
///
/// LP shares are a plain non-transferable ledger (`sharesOf`/`totalShares`) —
/// there is no fungible LP token. Transferable ownership of a vault position
/// is the ERC-721 minted by `DexPositionManager`, which custodies the shares.
contract PerpPool is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct Position {
        uint256 sizeBase;
        uint256 marginQuote;
        uint256 entryNotional; // sum of size * entry mark / 1e18
        uint256 entryFundingX18; // cumulative funding index snapshot
    }

    uint256 public constant MIN_TWAP_WINDOW = 300;
    uint256 internal constant BPS = 1e4;

    address public immutable registry;
    address public immutable treasury;
    address public immutable spotPool;
    address public immutable baseToken;
    address public immutable quoteToken;
    bool public immutable baseIsToken0;
    uint32 public immutable lpFeeRatePpm;
    bytes32 public immutable pairId;
    uint32 public immutable maxLeverageX;
    uint32 public immutable maintenanceMarginBps;
    uint32 public immutable liquidationFeeBps;
    uint32 public immutable maxUtilizationBps;
    uint64 public immutable fundingCoeffPpmPerHour;

    mapping(address => mapping(bool => Position)) public positions; // trader => isLong => position

    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    uint256 public totalLiquidity; // LP-owned quote (realized)
    uint256 public protocolFeesQuote;
    uint256 public longSizeBase;
    uint256 public longOpenNotional;
    uint256 public shortSizeBase;
    uint256 public shortOpenNotional;
    uint256 public cumFundingLongX18; // quote per base unit, X18, monotone
    uint256 public cumFundingShortX18;
    uint64 public lastFundingTime;

    uint256 public twapCumCheckpoint;
    uint64 public twapTsCheckpoint;
    uint256 public cachedMarkX18;

    error ZeroAmount();
    error ZeroAddress();
    error MarkNotReady();
    error NoPosition();
    error LeverageTooHigh();
    error UtilizationExceeded();
    error InsufficientLiquidity();
    error InsufficientShares();
    error NotLiquidatable();
    error BelowMaintenance();
    error SlippageExceeded();
    error ReduceTooLarge();

    event MarkUpdated(uint256 markX18);
    event FundingAccrued(bool longPays, uint256 deltaX18);
    event LiquidityAdded(address indexed provider, address indexed to, uint256 quoteIn, uint256 shares);
    event LiquidityRemoved(address indexed provider, address indexed to, uint256 quoteOut, uint256 shares);
    event PositionIncreased(
        address indexed trader, bool indexed isLong, uint256 sizeBase, uint256 marginAdded, uint256 markX18, uint256 fee
    );
    event PositionDecreased(
        address indexed trader, bool indexed isLong, uint256 sizeBase, uint256 payout, uint256 markX18, uint256 fee
    );
    event MarginAdded(address indexed trader, bool indexed isLong, uint256 amount);
    event MarginRemoved(address indexed trader, bool indexed isLong, uint256 amount);
    event Liquidated(
        address indexed trader,
        bool indexed isLong,
        address indexed liquidator,
        uint256 sizeBase,
        uint256 markX18,
        uint256 reward
    );
    event ProtocolFeesCollected(uint256 amount);

    constructor(
        address registry_,
        address treasury_,
        address spotPool_,
        address baseToken_,
        address quoteToken_,
        uint32 lpFeeRatePpm_,
        bytes32 pairId_,
        PerpParams memory params
    ) {
        registry = registry_;
        treasury = treasury_;
        spotPool = spotPool_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        baseIsToken0 = ISpotPool(spotPool_).token0() == baseToken_;
        lpFeeRatePpm = lpFeeRatePpm_;
        pairId = pairId_;
        maxLeverageX = params.maxLeverageX;
        maintenanceMarginBps = params.maintenanceMarginBps;
        liquidationFeeBps = params.liquidationFeeBps;
        maxUtilizationBps = params.maxUtilizationBps;
        fundingCoeffPpmPerHour = params.fundingCoeffPpmPerHour;
        lastFundingTime = uint64(block.timestamp);
    }

    // ------------------------------------------------------------- oracle

    /// @notice Roll the TWAP checkpoint when the window has elapsed; returns
    /// the current mark (0 until the first full window after seeding).
    function pokeMark() public returns (uint256) {
        (uint256 r0, uint256 r1, uint64 poolTs) = ISpotPool(spotPool).getReserves();
        if (r0 == 0 || r1 == 0) return cachedMarkX18; // pool not seeded yet
        uint256 cum =
            baseIsToken0 ? ISpotPool(spotPool).price0CumulativeLast() : ISpotPool(spotPool).price1CumulativeLast();
        uint256 live = baseIsToken0 ? r1 * 1e18 / r0 : r0 * 1e18 / r1;
        unchecked {
            cum += live * (block.timestamp - poolTs); // virtual accrual for stale pools
        }
        if (twapTsCheckpoint == 0) {
            twapCumCheckpoint = cum;
            twapTsCheckpoint = uint64(block.timestamp);
            return cachedMarkX18;
        }
        uint256 elapsed = block.timestamp - twapTsCheckpoint;
        if (elapsed >= MIN_TWAP_WINDOW) {
            unchecked {
                cachedMarkX18 = (cum - twapCumCheckpoint) / elapsed;
            }
            twapCumCheckpoint = cum;
            twapTsCheckpoint = uint64(block.timestamp);
            emit MarkUpdated(cachedMarkX18);
        }
        return cachedMarkX18;
    }

    function _requireMark() internal returns (uint256 mark) {
        mark = pokeMark();
        if (mark == 0) revert MarkNotReady();
    }

    // ------------------------------------------------------------- funding

    /// @notice Lazily accrue imbalance funding since the last touch. The
    /// heavier side pays the LP vault; the lighter side pays nothing.
    // ponytail: one-sided funding to LP; long<->short transfer if peg quality matters
    function updateFunding() public {
        uint256 dt = block.timestamp - lastFundingTime;
        if (dt == 0) return;
        uint256 mark = cachedMarkX18;
        uint256 totalOI = longSizeBase + shortSizeBase;
        if (mark > 0 && totalOI > 0 && longSizeBase != shortSizeBase) {
            bool longPays = longSizeBase > shortSizeBase;
            uint256 imbalanceX18 =
                (longPays ? longSizeBase - shortSizeBase : shortSizeBase - longSizeBase) * 1e18 / totalOI;
            // quote per base (X18) accrued over dt
            uint256 deltaX18 = Math.mulDiv(uint256(fundingCoeffPpmPerHour) * imbalanceX18 / 1e6, mark * dt / 3600, 1e18);
            if (deltaX18 > 0) {
                if (longPays) cumFundingLongX18 += deltaX18;
                else cumFundingShortX18 += deltaX18;
                emit FundingAccrued(longPays, deltaX18);
            }
        }
        lastFundingTime = uint64(block.timestamp);
    }

    // ------------------------------------------------------------------ LP

    function lpEquity() public view returns (uint256) {
        int256 equity = totalLiquidity.toInt256() - _globalUnrealizedPnl(cachedMarkX18);
        return equity <= 0 ? 0 : uint256(equity);
    }

    function addLiquidity(uint256 quoteIn, uint256 minShares, address to)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (to == address(0)) revert ZeroAddress();
        pokeMark();
        updateFunding();
        uint256 credited = _pull(quoteIn);
        uint256 supply = totalShares;
        if (supply == 0) {
            shares = credited;
        } else {
            uint256 equity = lpEquity();
            if (equity == 0) revert InsufficientLiquidity(); // vault wiped; new LPs must not mint against zero
            shares = Math.mulDiv(credited, supply, equity);
        }
        if (shares == 0 || shares < minShares) revert SlippageExceeded();
        totalLiquidity += credited;
        _mintShares(to, shares);
        emit LiquidityAdded(msg.sender, to, credited, shares);
    }

    function removeLiquidity(uint256 shares, uint256 minQuoteOut, address to)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (to == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroAmount();
        if (shares > sharesOf[msg.sender]) revert InsufficientShares();
        pokeMark();
        updateFunding();
        uint256 mark = cachedMarkX18;
        if ((longSizeBase > 0 || shortSizeBase > 0) && mark == 0) revert MarkNotReady();

        uint256 equity = lpEquity();
        quoteOut = Math.mulDiv(shares, equity, totalShares);
        if (quoteOut < minQuoteOut) revert SlippageExceeded();
        // Unrealized trader losses back LP equity on paper only; cash out is
        // capped by realized liquidity.
        if (quoteOut > totalLiquidity) revert InsufficientLiquidity();

        uint256 remainingEquity = equity - quoteOut;
        _checkUtilization(mark, remainingEquity, 0, true);
        _checkUtilization(mark, remainingEquity, 0, false);

        _burnShares(msg.sender, shares);
        totalLiquidity -= quoteOut;
        IERC20(quoteToken).safeTransfer(to, quoteOut);
        emit LiquidityRemoved(msg.sender, to, quoteOut, shares);
    }

    // ------------------------------------------------------------ positions

    function openPosition(bool isLong, uint256 marginQuote, uint256 sizeBase) external nonReentrant {
        if (sizeBase == 0) revert ZeroAmount();
        uint256 mark = _requireMark();
        updateFunding();

        Position storage pos = positions[msg.sender][isLong];
        _settleFunding(pos, isLong);

        uint256 credited = _pull(marginQuote);
        pos.marginQuote += credited;

        uint256 notionalDelta = Math.mulDiv(sizeBase, mark, 1e18);
        if (notionalDelta == 0) revert ZeroAmount();
        (uint256 totalFee, uint256 protocolFee, uint256 lpFee) = FeeSplit.split(notionalDelta, lpFeeRatePpm);
        if (pos.marginQuote < totalFee) revert LeverageTooHigh();
        pos.marginQuote -= totalFee;
        protocolFeesQuote += protocolFee;
        totalLiquidity += lpFee;

        pos.sizeBase += sizeBase;
        pos.entryNotional += notionalDelta;

        uint256 notionalAtMark = Math.mulDiv(pos.sizeBase, mark, 1e18);
        if (notionalAtMark > pos.marginQuote * maxLeverageX) revert LeverageTooHigh();

        if (isLong) {
            longSizeBase += sizeBase;
            longOpenNotional += notionalDelta;
        } else {
            shortSizeBase += sizeBase;
            shortOpenNotional += notionalDelta;
        }
        _checkUtilization(mark, lpEquity(), 0, isLong);
        emit PositionIncreased(msg.sender, isLong, sizeBase, credited, mark, totalFee);
    }

    function decreasePosition(bool isLong, uint256 sizeBaseReduce) external nonReentrant {
        if (sizeBaseReduce == 0) revert ZeroAmount();
        uint256 mark = _requireMark();
        updateFunding();

        Position storage pos = positions[msg.sender][isLong];
        if (pos.sizeBase == 0) revert NoPosition();
        if (sizeBaseReduce > pos.sizeBase) revert ReduceTooLarge();
        _settleFunding(pos, isLong);

        uint256 notionalPortion = Math.mulDiv(pos.entryNotional, sizeBaseReduce, pos.sizeBase);
        uint256 marginPortion = Math.mulDiv(pos.marginQuote, sizeBaseReduce, pos.sizeBase);
        uint256 closeNotional = Math.mulDiv(sizeBaseReduce, mark, 1e18);

        int256 pnl = isLong
            ? closeNotional.toInt256() - notionalPortion.toInt256()
            : notionalPortion.toInt256() - closeNotional.toInt256();

        uint256 payout = _settleAgainstVault(marginPortion, pnl);
        // Close fee comes out of the trader's claim (capped by it) and is
        // split like every other fee: 0.1% protocol, rest to LPs.
        (uint256 totalFee,,) = FeeSplit.split(closeNotional, lpFeeRatePpm);
        totalFee = Math.min(totalFee, payout);
        payout -= totalFee;
        uint256 protocolFee = totalFee / 1000;
        protocolFeesQuote += protocolFee;
        totalLiquidity += totalFee - protocolFee;

        pos.sizeBase -= sizeBaseReduce;
        pos.entryNotional -= notionalPortion;
        pos.marginQuote -= marginPortion;
        if (isLong) {
            longSizeBase -= sizeBaseReduce;
            longOpenNotional -= notionalPortion;
        } else {
            shortSizeBase -= sizeBaseReduce;
            shortOpenNotional -= notionalPortion;
        }
        if (pos.sizeBase == 0) {
            // Return any residual margin along with the payout.
            payout += pos.marginQuote;
            delete positions[msg.sender][isLong];
        } else {
            // Remaining position must stay above maintenance.
            if (_belowMaintenance(pos, isLong, mark)) revert BelowMaintenance();
        }
        if (payout > 0) IERC20(quoteToken).safeTransfer(msg.sender, payout);
        emit PositionDecreased(msg.sender, isLong, sizeBaseReduce, payout, mark, totalFee);
    }

    function addMargin(bool isLong, uint256 quoteIn) external nonReentrant {
        Position storage pos = positions[msg.sender][isLong];
        if (pos.sizeBase == 0) revert NoPosition();
        pokeMark();
        updateFunding();
        _settleFunding(pos, isLong);
        uint256 credited = _pull(quoteIn);
        pos.marginQuote += credited;
        emit MarginAdded(msg.sender, isLong, credited);
    }

    function removeMargin(bool isLong, uint256 quoteOut) external nonReentrant {
        uint256 mark = _requireMark();
        updateFunding();
        Position storage pos = positions[msg.sender][isLong];
        if (pos.sizeBase == 0) revert NoPosition();
        _settleFunding(pos, isLong);
        if (quoteOut > pos.marginQuote) revert ReduceTooLarge();
        pos.marginQuote -= quoteOut;
        uint256 notionalAtMark = Math.mulDiv(pos.sizeBase, mark, 1e18);
        if (notionalAtMark > pos.marginQuote * maxLeverageX) revert LeverageTooHigh();
        if (_belowMaintenance(pos, isLong, mark)) revert BelowMaintenance();
        IERC20(quoteToken).safeTransfer(msg.sender, quoteOut);
        emit MarginRemoved(msg.sender, isLong, quoteOut);
    }

    function liquidate(address trader, bool isLong) external nonReentrant {
        uint256 mark = _requireMark();
        updateFunding();
        Position storage pos = positions[trader][isLong];
        if (pos.sizeBase == 0) revert NoPosition();
        _settleFunding(pos, isLong);
        if (!_belowMaintenance(pos, isLong, mark)) revert NotLiquidatable();

        uint256 size = pos.sizeBase;
        uint256 margin = pos.marginQuote;
        uint256 entryNotional = pos.entryNotional;
        uint256 closeNotional = Math.mulDiv(size, mark, 1e18);
        int256 pnl = isLong
            ? closeNotional.toInt256() - entryNotional.toInt256()
            : entryNotional.toInt256() - closeNotional.toInt256();

        // Trader forfeits remaining equity: liquidator takes the fee cut,
        // the rest goes to the LP vault. Bad debt is absorbed by the vault
        // implicitly (it simply never receives the shortfall).
        uint256 remaining = _settleAgainstVault(margin, pnl);
        uint256 reward = remaining * liquidationFeeBps / BPS;
        totalLiquidity += remaining - reward;

        if (isLong) {
            longSizeBase -= size;
            longOpenNotional -= entryNotional;
        } else {
            shortSizeBase -= size;
            shortOpenNotional -= entryNotional;
        }
        delete positions[trader][isLong];
        if (reward > 0) IERC20(quoteToken).safeTransfer(msg.sender, reward);
        emit Liquidated(trader, isLong, msg.sender, size, mark, reward);
    }

    // ---------------------------------------------------------------- views

    function equityOf(address trader, bool isLong) external view returns (int256) {
        Position storage pos = positions[trader][isLong];
        if (pos.sizeBase == 0) return 0;
        uint256 mark = cachedMarkX18;
        uint256 cumSide = isLong ? cumFundingLongX18 : cumFundingShortX18;
        uint256 fundingOwed = Math.mulDiv(pos.sizeBase, cumSide - pos.entryFundingX18, 1e18);
        uint256 closeNotional = Math.mulDiv(pos.sizeBase, mark, 1e18);
        int256 pnl = isLong
            ? closeNotional.toInt256() - pos.entryNotional.toInt256()
            : pos.entryNotional.toInt256() - closeNotional.toInt256();
        return pos.marginQuote.toInt256() - fundingOwed.toInt256() + pnl;
    }

    // ------------------------------------------------------------------ fees

    function collectProtocolFees() external nonReentrant {
        uint256 fee = protocolFeesQuote;
        protocolFeesQuote = 0;
        if (fee > 0) IERC20(quoteToken).safeTransfer(treasury, fee);
        emit ProtocolFeesCollected(fee);
    }

    // ------------------------------------------------------------- internals

    function _mintShares(address to, uint256 amount) internal {
        totalShares += amount;
        sharesOf[to] += amount;
    }

    function _burnShares(address from, uint256 amount) internal {
        uint256 balance = sharesOf[from];
        if (amount > balance) revert InsufficientShares();
        sharesOf[from] = balance - amount;
        totalShares -= amount;
    }

    /// @dev Settle accrued funding on a position: owed quote moves from the
    /// position's margin to the LP vault (capped at available margin).
    function _settleFunding(Position storage pos, bool isLong) internal {
        uint256 cumSide = isLong ? cumFundingLongX18 : cumFundingShortX18;
        if (pos.sizeBase > 0 && cumSide > pos.entryFundingX18) {
            uint256 owed = Math.mulDiv(pos.sizeBase, cumSide - pos.entryFundingX18, 1e18);
            uint256 paid = Math.min(owed, pos.marginQuote);
            pos.marginQuote -= paid;
            totalLiquidity += paid;
        }
        pos.entryFundingX18 = cumSide;
    }

    /// @dev Settle a margin bucket plus signed PnL against the vault and
    /// return the trader-side claim. Conserves the accounting invariant:
    /// margin leaves the margin ledger; claim − margin comes from (or margin
    /// − claim goes to) totalLiquidity; profits are capped by the vault.
    function _settleAgainstVault(uint256 margin, int256 pnl) internal returns (uint256 claim) {
        int256 settled = margin.toInt256() + pnl;
        if (settled <= 0) {
            totalLiquidity += margin;
            return 0;
        }
        claim = uint256(settled);
        if (claim > margin) {
            uint256 fromVault = claim - margin;
            if (fromVault > totalLiquidity) {
                claim = margin + totalLiquidity; // vault-insolvency cap
                fromVault = totalLiquidity;
            }
            totalLiquidity -= fromVault;
        } else {
            totalLiquidity += margin - claim;
        }
    }

    function _belowMaintenance(Position storage pos, bool isLong, uint256 mark) internal view returns (bool) {
        uint256 closeNotional = Math.mulDiv(pos.sizeBase, mark, 1e18);
        int256 pnl = isLong
            ? closeNotional.toInt256() - pos.entryNotional.toInt256()
            : pos.entryNotional.toInt256() - closeNotional.toInt256();
        int256 equity = pos.marginQuote.toInt256() + pnl; // funding already settled
        return equity < Math.mulDiv(closeNotional, maintenanceMarginBps, BPS).toInt256();
    }

    /// @dev Per-side open-interest cap versus LP equity (post-change).
    function _checkUtilization(uint256 mark, uint256 equity, uint256 addedSize, bool isLong) internal view {
        uint256 sideSize = (isLong ? longSizeBase : shortSizeBase) + addedSize;
        if (sideSize == 0) return;
        if (mark == 0) return;
        uint256 sideNotional = Math.mulDiv(sideSize, mark, 1e18);
        if (sideNotional > Math.mulDiv(equity, maxUtilizationBps, BPS)) revert UtilizationExceeded();
    }

    function _pull(uint256 amount) internal returns (uint256 received) {
        if (amount == 0) return 0;
        uint256 balanceBefore = IERC20(quoteToken).balanceOf(address(this));
        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(quoteToken).balanceOf(address(this)) - balanceBefore;
    }

    function _globalUnrealizedPnl(uint256 mark) internal view returns (int256) {
        if (mark == 0) return 0;
        int256 longPnl = Math.mulDiv(longSizeBase, mark, 1e18).toInt256() - longOpenNotional.toInt256();
        int256 shortPnl = shortOpenNotional.toInt256() - Math.mulDiv(shortSizeBase, mark, 1e18).toInt256();
        return longPnl + shortPnl;
    }
}

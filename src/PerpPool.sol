// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {FeeSplit} from "./libraries/FeeSplit.sol";
import {ISpotPool} from "./interfaces/ISpotPool.sol";
import {IDexRegistry} from "./interfaces/IDexRegistry.sol";
import {PerpParams, LpStatus} from "./interfaces/IPerpPool.sol";
import {Pausing} from "./libraries/Pausing.sol";

/// @notice Perpetual futures pool (DEX.md §5.2), GMX-style: a single-sided
/// quote-token LP vault is the counterparty to every position. Funding
/// accrues from the heavier side to the LP vault (compensation for
/// directional exposure). Fee policy mirrors spot: creator-chosen lpFeeRate
/// on notional, 0.1% of it to the protocol.
///
/// Prices come from the linked spot pool's epoch observations: the mark at
/// an epoch boundary is the TWAP over the `MARK_WINDOW` ending there.
///
/// Everything that moves value between a trader or LP and the vault settles
/// in two steps (DEX.md §5.2.1). A request escrows what it needs and is
/// priced at the mark of the first full window that starts after it was
/// made; anyone may execute it during the epoch that window closes on. A
/// price already known when the trade is placed hands the trader a free
/// option on the vault — a TWAP lags the pool, and the next one could be
/// computed a block before it was published. A price made entirely of
/// future blocks does not. The rest of the rules keep it that way: once a
/// request is made, nothing the requester does later changes its outcome.
///   - A position request cannot be cancelled. An LP request can, but only
///     before its window opens.
///   - Open interest is admitted, against the oracle's depth and the
///     vault's utilization cap, when it is requested, and held for the
///     request until it resolves. Checked at execution instead, either cap
///     could be tripped on purpose to turn an unwanted fill into a refund.
///   - A request that misses its settlement epoch rolls to a fresh window
///     and remembers every price it has been through, filling at the worst
///     of them for the requester, and an increase is judged at its fill
///     price. Missing the epoch can only cost the requester.
///   - Margin cannot be added to a side with a pending request: a pending
///     request is judged on the position it was made against.
///   - A settlement inside a pause also counts the pool's price during the
///     pause, so an exit requested after a crash cannot take the mark from
///     before it.
///   - A settlement on an oracle that thinned out after admission also
///     counts the hour before its window, so a thin pool pushed for one
///     window cannot set a fill.
/// Liquidation and funding read the current mark directly; adding margin
/// needs no price and is immediate.
///
/// Accounting invariant: quote balance == totalLiquidity + sum of position
/// margins + protocolFeesQuote + escrowedQuote (all realized flows move
/// between these buckets; unrealized PnL only affects LP share pricing).
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

    struct Position {
        uint256 sizeBase;
        uint256 marginQuote;
        uint256 entryNotional; // sum of size * entry price / 1e36
        uint256 entryFundingX36; // cumulative funding index snapshot
    }

    enum OrderKind {
        NONE,
        INCREASE,
        DECREASE,
        REMOVE_MARGIN
    }

    /// @dev One pending position change per trader and side. `lowX36` and
    /// `highX36` are the lowest and highest settlement prices it has rolled
    /// through, 0 until it first rolls.
    struct Order {
        OrderKind kind;
        uint64 settleAt;
        uint256 sizeBase;
        uint256 marginQuote; // INCREASE: escrowed margin; REMOVE_MARGIN: amount to take out
        uint256 acceptablePriceX36; // 0 = any
        uint256 executionFee; // escrowed, paid to whoever executes
        uint256 reservedNotional; // INCREASE: open interest held for it since admission
        uint256 lowX36;
        uint256 highX36;
    }

    struct LpRequest {
        address owner; // may cancel before the window opens
        address receiver; // gets the shares (deposit) or the quote (withdrawal)
        address refundTo; // gets the escrow back if the request fails
        bool isDeposit;
        LpStatus status;
        uint64 settleAt;
        uint256 amount; // quote in (deposit) / shares (withdrawal)
        uint256 minOut; // min shares / min quote
        uint256 executionFee;
        uint256 out; // shares minted / quote paid, once executed
        uint256 lowX36; // as in Order
        uint256 highX36;
    }

    /// @dev What a request settles against at its boundary.
    struct Settlement {
        uint256 mark;
        uint256 spot; // pool price during the pause the settlement fell in; 0 otherwise
        uint256 slow; // TWAP of the hour before the window, when the oracle is thin; 0 otherwise
        bool paused;
        bool inPause;
    }

    uint32 public constant MAX_LEVERAGE_CAP = 50;
    uint32 public constant MIN_MAINTENANCE_MARGIN_BPS = 100;
    uint32 public constant MAX_MAINTENANCE_MARGIN_BPS = 2000;
    uint32 public constant MAX_LIQUIDATION_FEE_BPS = 500;
    uint64 public constant MAX_FUNDING_COEFF_PPM_PER_HOUR = 10_000;

    /// @notice Span of every mark: the TWAP over this many seconds.
    uint256 public constant MARK_WINDOW = 300;
    /// @notice Long horizon the oracle pool's depth is also averaged over.
    /// Liquidity has to sit in the pool for this long to count in full, so
    /// it cannot be lent to the pool for one window to open a position and
    /// pulled before the close.
    uint256 public constant DEPTH_WINDOW = 3600;
    /// @notice Liquidator bounty floor, as bps of the closed notional. A
    /// position that gapped straight through maintenance leaves no equity to
    /// take a cut of, and an unliquidated position costs the vault far more
    /// than the bounty does.
    uint256 public constant LIQ_REWARD_FLOOR_BPS = 10;
    /// @notice A side's open interest, pending increases included, may not
    /// exceed this share of the oracle pool's quote-side depth — the smaller
    /// of its harmonic means over `MARK_WINDOW` and `DEPTH_WINDOW`. What it
    /// costs to hold the pool off its price for a window grows with its
    /// depth; what holding it there pays grows with open interest.
    uint256 public constant ORACLE_DEPTH_BPS = 5_000;
    /// @notice A settlement whose open interest is over this share of its
    /// own window's depth reads the oracle as thin, and also counts the hour
    /// before that window. Twice the admission cap, so a side admitted at
    /// the cap trips it only when the pool has lost depth: the ratio moves
    /// with the square root of the price, and a routine move does not
    /// double it.
    uint256 public constant THIN_ORACLE_BPS = 10_000;
    /// @notice An increase that fails at execution still pays for the
    /// capacity it held since admission: its pool's open fee on the reserved
    /// notional, and at least this share of it. Price moves after admission
    /// are visible to the requester — a spot already past the TWAP tells
    /// them the fill will breach their limit — so a free failure would let
    /// anyone hold open interest, blocking other traders, at no cost.
    uint256 public constant FAILED_INCREASE_FEE_BPS = 10;
    /// @notice Burned to 0xdead on the first deposit, mirroring SpotPool: it
    /// puts a floor under totalShares so the share price cannot be set by
    /// whoever deposits one wei first.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint256 internal constant BPS = 1e4;
    uint256 internal constant PRICE_SCALE = 1e36;
    /// @dev ppm * seconds-per-hour * X18 imbalance, the combined scale of the
    /// funding accrual's divisors.
    uint256 internal constant FUNDING_DENOMINATOR = 1e6 * 3600 * 1e18;

    address public immutable registry;
    address public immutable treasury;
    address public immutable spotPool;
    address public immutable baseToken;
    address public immutable quoteToken;
    bool public immutable baseIsToken0;
    uint32 public immutable lpFeeRatePpm;
    address public immutable pair;
    uint32 public immutable maxLeverageX;
    uint32 public immutable maintenanceMarginBps;
    uint32 public immutable liquidationFeeBps;
    uint32 public immutable maxUtilizationBps;
    uint64 public immutable fundingCoeffPpmPerHour;
    /// @notice The spot pool's oracle epoch: marks are read at its multiples,
    /// and a settled request is executable for one epoch.
    uint256 public immutable epoch;

    mapping(address => mapping(bool => Position)) public positions; // trader => isLong => position
    mapping(address => mapping(bool => Order)) public orders; // trader => isLong => pending change
    mapping(uint256 => LpRequest) public lpRequests;
    uint256 public nextLpRequestId = 1;

    uint256 public totalShares; // includes shares escrowed by pending withdrawals
    mapping(address => uint256) public sharesOf;
    uint256 public escrowedShares;

    uint256 public totalLiquidity; // LP-owned quote (realized)
    uint256 public protocolFeesQuote;
    uint256 public escrowedQuote; // pending margins, deposits and execution fees; unclaimed payouts
    /// @notice Payouts whose transfer failed, waiting for `claim` — usually
    /// because the token refuses the recipient's address.
    mapping(address => uint256) public claimableQuote;
    uint256 public longSizeBase;
    uint256 public longOpenNotional;
    uint256 public shortSizeBase;
    uint256 public shortOpenNotional;
    /// @notice Open interest admitted but not yet executed, per side, at the
    /// mark it was admitted at.
    uint256 public pendingLongNotional;
    uint256 public pendingShortNotional;
    /// @dev Sum over each side's positions of size * entryFunding / 1e36, so
    /// the funding owed to the vault is known without visiting positions.
    uint256 public longFundingEntry;
    uint256 public shortFundingEntry;
    uint256 public cumFundingLongX36; // quote per base unit, X36, monotone
    uint256 public cumFundingShortX36;
    uint64 public lastFundingTime;

    error ZeroAmount();
    error ZeroAddress();
    error InvalidPerpParams();
    error MarkNotReady();
    error NoPosition();
    error OrderPending();
    error NoOrder();
    error NotSettled();
    error WindowOpen();
    error InsufficientShares();
    error NotLiquidatable();
    error LiquidationCooldown();
    error NoRequest();
    error NotRequestOwner();
    error OracleTooShallow();
    error UtilizationExceeded();
    error LeverageTooHigh();
    error UnfillableLimit();
    error MarginBelowFee();

    event FundingAccrued(bool longPays, uint256 deltaX36);
    event OrderRequested(
        address indexed trader,
        bool indexed isLong,
        OrderKind kind,
        uint256 sizeBase,
        uint256 marginQuote,
        uint64 settleAt
    );
    event OrderRolled(address indexed trader, bool indexed isLong, uint64 settleAt);
    event OrderExecuted(
        address indexed trader, bool indexed isLong, OrderKind kind, bool success, address indexed executor
    );
    event PositionIncreased(
        address indexed trader,
        bool indexed isLong,
        uint256 sizeBase,
        uint256 marginAdded,
        uint256 priceX36,
        uint256 fee
    );
    event PositionDecreased(
        address indexed trader, bool indexed isLong, uint256 sizeBase, uint256 payout, uint256 priceX36, uint256 fee
    );
    event MarginAdded(address indexed trader, bool indexed isLong, uint256 amount);
    event MarginRemoved(address indexed trader, bool indexed isLong, uint256 amount);
    event Liquidated(
        address indexed trader,
        bool indexed isLong,
        address indexed liquidator,
        uint256 sizeBase,
        uint256 markX36,
        uint256 reward
    );
    event LpRequested(
        uint256 indexed requestId, address indexed owner, bool isDeposit, uint256 amount, uint64 settleAt
    );
    event LpCancelled(uint256 indexed requestId);
    event LpRolled(uint256 indexed requestId, uint64 settleAt);
    event LpExecuted(uint256 indexed requestId, bool success, uint256 out, address indexed executor);
    event ProtocolFeesCollected(uint256 amount);
    event Claimed(address indexed account, address to, uint256 amount);

    constructor(
        address registry_,
        address treasury_,
        address spotPool_,
        address baseToken_,
        address quoteToken_,
        uint32 lpFeeRatePpm_,
        address pair_,
        PerpParams memory params
    ) {
        if (
            params.maxLeverageX == 0 || params.maxLeverageX > MAX_LEVERAGE_CAP
                || params.maintenanceMarginBps < MIN_MAINTENANCE_MARGIN_BPS
                || params.maintenanceMarginBps > MAX_MAINTENANCE_MARGIN_BPS
                || params.liquidationFeeBps > MAX_LIQUIDATION_FEE_BPS || params.maxUtilizationBps == 0
                || params.maxUtilizationBps > BPS || params.fundingCoeffPpmPerHour > MAX_FUNDING_COEFF_PPM_PER_HOUR
        ) revert InvalidPerpParams();
        // Initial margin at the pool's own max leverage has to clear
        // maintenance plus the liquidation fee. Without this the two bounds
        // pass independently while combining into a pool where a max-leverage
        // position is liquidatable the block it opens (50x = 200bps initial
        // margin against a 2000bps maintenance floor).
        if (BPS / params.maxLeverageX <= uint256(params.maintenanceMarginBps) + params.liquidationFeeBps) {
            revert InvalidPerpParams();
        }
        uint256 epoch_ = ISpotPool(spotPool_).ORACLE_EPOCH();
        if (epoch_ == 0 || MARK_WINDOW % epoch_ != 0 || DEPTH_WINDOW % epoch_ != 0) revert InvalidPerpParams();

        registry = registry_;
        treasury = treasury_;
        spotPool = spotPool_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        baseIsToken0 = ISpotPool(spotPool_).token0() == baseToken_;
        lpFeeRatePpm = lpFeeRatePpm_;
        pair = pair_;
        maxLeverageX = params.maxLeverageX;
        maintenanceMarginBps = params.maintenanceMarginBps;
        liquidationFeeBps = params.liquidationFeeBps;
        maxUtilizationBps = params.maxUtilizationBps;
        fundingCoeffPpmPerHour = params.fundingCoeffPpmPerHour;
        epoch = epoch_;
        lastFundingTime = uint64(block.timestamp);
    }

    // ------------------------------------------------------------- oracle

    /// @notice The current mark: TWAP over the window ending at the latest
    /// epoch boundary, or at the boundary a pause began on while paused.
    /// 0 until the oracle has a full window.
    function markX36() public view returns (uint256 mark) {
        (bool paused, uint64 pausedAt,) = IDexRegistry(registry).pauseWindow();
        (mark,) = _tryTwap(_currentBoundary(paused, pausedAt), MARK_WINDOW);
    }

    /// @notice When a request made now would settle.
    function nextSettleAt() public view returns (uint64) {
        return uint64((block.timestamp / epoch + 1) * epoch + MARK_WINDOW);
    }

    /// @notice TWAP of base in quote over the `length` seconds ending at epoch
    /// boundary `boundary`, and the harmonic mean of the oracle pool's
    /// sqrt(k) over them — its depth, weighted to its thinnest stretches.
    /// Hints as for `SpotPool.observe`, one per end; zero lets the pool search.
    function twapAt(uint256 boundary, uint256 length, uint256 hintStart, uint256 hintEnd)
        external
        view
        returns (uint256 mark, uint256 liquidity)
    {
        return _twap(boundary, length, hintStart, hintEnd);
    }

    function _currentBoundary(bool paused, uint256 pausedAt) internal view returns (uint256 b) {
        b = block.timestamp / epoch * epoch;
        if (paused) {
            // The pause freezes the mark at the last boundary before it.
            // Swaps are stopped, so the pool's price cannot be arbitraged
            // back while paused, and a mark still rolling over it would
            // install whatever the price was when the stop landed.
            uint256 frozen = pausedAt / epoch * epoch;
            if (frozen < b) b = frozen;
        }
    }

    /// @dev The prices a request settling at `settleAt` is judged by. A
    /// boundary inside a pause reads the frozen mark — whenever it is
    /// executed, so that executing during the pause or after it is never a
    /// choice between two known prices — together with the pool's price
    /// during the pause. The frozen mark predates the pause; an exit
    /// requested after a crash that landed just before the stop would
    /// otherwise take the price from before the crash, a price public when
    /// it was requested. On a thin oracle the TWAP of the rest of the hour
    /// before the window counts as well (see below). `hints[0..1]` locate
    /// the window's ends, `hints[2]` the in-pause boundary the pool's price
    /// is read at.
    function _settlement(uint64 settleAt, uint256[3] calldata hints) internal view returns (Settlement memory s) {
        (bool paused, uint64 pausedAt, uint64 unpausedAt) = IDexRegistry(registry).pauseWindow();
        uint256 frozen = uint256(pausedAt) / epoch * epoch;
        s.paused = paused;
        s.inPause = pausedAt != 0 && settleAt > frozen && (paused || settleAt <= unpausedAt);
        uint256 boundary = s.inPause ? frozen : settleAt;
        uint256 liquidity;
        (s.mark, liquidity) = _twap(boundary, MARK_WINDOW, hints[0], hints[1]);
        if (s.mark == 0) revert MarkNotReady();
        // Open interest, pending included, over twice the depth cap of the
        // very window it settles on means the oracle thinned out after
        // admission — liquidity held in the pool just long enough to be
        // admitted against, say. The depth is a harmonic mean, so pulling
        // the liquidity for part of the window counts as nearly all of it. One window of a thin pool is cheap to push, so the
        // average over the rest of the hour before it counts too, and the
        // worse of the two fills: pushing the price for the window buys
        // nothing. Read without hints; within its settlement epoch neither
        // end ever needs one, and a roll only ever widens the range.
        uint256 longSide = Math.mulDiv(longSizeBase, s.mark, PRICE_SCALE) + pendingLongNotional;
        uint256 shortSide = Math.mulDiv(shortSizeBase, s.mark, PRICE_SCALE) + pendingShortNotional;
        uint256 depth = Math.mulDiv(liquidity, Math.sqrt(s.mark), 1e18);
        if (Math.max(longSide, shortSide) > Math.mulDiv(depth, THIN_ORACLE_BPS, BPS)) {
            (s.slow,) = _tryTwap(boundary - MARK_WINDOW, DEPTH_WINDOW - MARK_WINDOW);
        }
        if (s.inPause) {
            // Swaps are stopped while paused, so the pool's price at any point
            // of the pause is its price for the whole pause: live while still
            // paused, and afterwards at the settlement boundary, which lies
            // inside it.
            uint256 r0;
            uint256 r1;
            if (paused) (r0, r1,) = ISpotPool(spotPool).getReserves();
            else (,,, r0, r1) = ISpotPool(spotPool).observe(settleAt / epoch, hints[2]);
            s.spot = baseIsToken0 ? Math.mulDiv(r1, PRICE_SCALE, r0) : Math.mulDiv(r0, PRICE_SCALE, r1);
        }
    }

    /// @dev Reverts with the spot pool's reason when an observation needs a
    /// hint or does not exist.
    function _twap(uint256 boundary, uint256 length, uint256 hintStart, uint256 hintEnd)
        internal
        view
        returns (uint256 mark, uint256 liquidity)
    {
        if (boundary < length) revert MarkNotReady();
        ISpotPool spot = ISpotPool(spotPool);
        (uint256 p0a, uint256 p1a, uint256 ia,,) = spot.observe((boundary - length) / epoch, hintStart);
        (uint256 p0b, uint256 p1b, uint256 ib,,) = spot.observe(boundary / epoch, hintEnd);
        uint256 inverseSum;
        unchecked {
            mark = (baseIsToken0 ? p0b - p0a : p1b - p1a) / length;
            inverseSum = ib - ia; // reserves are capped at uint112: every second adds at least 1e36 / 2^112
        }
        liquidity = length * PRICE_SCALE / inverseSum;
    }

    /// @dev `_twap` without hints, reading "not available" as zero.
    function _tryTwap(uint256 boundary, uint256 length) internal view returns (uint256 mark, uint256 liquidity) {
        if (boundary < length) return (0, 0);
        try this.twapAt(boundary, length, 0, 0) returns (uint256 m, uint256 l) {
            return (m, l);
        } catch {
            return (0, 0);
        }
    }

    /// @dev Fold a price into a request's remembered range; 0 is no price.
    function _fold(uint256 low, uint256 high, uint256 price) internal pure returns (uint256, uint256) {
        if (price == 0) return (low, high);
        if (high == 0) return (price, price);
        return (Math.min(low, price), Math.max(high, price));
    }

    // ------------------------------------------------------------- funding

    /// @notice Accrue imbalance funding up to now at the current mark.
    function updateFunding() external nonReentrant {
        _accrueFunding(markX36());
    }

    /// @dev The heavier side pays the LP vault; the lighter side pays nothing.
    /// Without a mark nothing accrues *and the clock does not move*, so the
    /// span is charged in full once a mark exists rather than dropped.
    // ponytail: one-sided funding to LP; long<->short transfer if peg quality matters
    function _accrueFunding(uint256 mark) internal {
        uint256 dt = block.timestamp - lastFundingTime;
        if (dt == 0 || mark == 0) return;
        uint256 longSize = longSizeBase;
        uint256 shortSize = shortSizeBase;
        if (longSize != shortSize) {
            bool longPays = longSize > shortSize;
            uint256 imbalanceX18 =
                (longPays ? longSize - shortSize : shortSize - longSize) * 1e18 / (longSize + shortSize);
            // Quote per base (X36) over dt:
            //   coeff/1e6 * imbalanceX18/1e18 * dt/3600 * mark
            // as a single mulDiv, so a small imbalance or a short dt is not
            // floored away in an intermediate step.
            uint256 deltaX36 =
                Math.mulDiv(uint256(fundingCoeffPpmPerHour) * imbalanceX18 * dt, mark, FUNDING_DENOMINATOR);
            if (deltaX36 > 0) {
                if (longPays) cumFundingLongX36 += deltaX36;
                else cumFundingShortX36 += deltaX36;
                emit FundingAccrued(longPays, deltaX36);
            }
        }
        lastFundingTime = uint64(block.timestamp);
    }

    // ------------------------------------------------------------ positions

    /// @notice Request a larger position. The open interest is admitted now,
    /// against the current mark, the oracle's depth and the utilization cap,
    /// and held until the request resolves; margin and fee are escrowed. The
    /// position opens at execution at `nextSettleAt()`'s mark (or, after a
    /// roll, the highest settlement price for a long and the lowest for a
    /// short), bounded by `acceptablePriceX36` (0 = any). Irrevocable.
    function requestIncrease(
        bool isLong,
        uint256 marginQuote,
        uint256 sizeBase,
        uint256 acceptablePriceX36,
        uint256 executionFee
    ) external nonReentrant {
        Pausing.requireNotPaused(registry);
        if (sizeBase == 0) revert ZeroAmount();
        Order storage o = _freeOrder(msg.sender, isLong);
        uint256 credited = _pull(marginQuote + executionFee);
        uint256 fee = Math.min(executionFee, credited);
        uint256 reserved = _admit(isLong, sizeBase, credited - fee, acceptablePriceX36);
        escrowedQuote += credited;
        o.kind = OrderKind.INCREASE;
        o.settleAt = nextSettleAt();
        o.sizeBase = sizeBase;
        o.marginQuote = credited - fee;
        o.acceptablePriceX36 = acceptablePriceX36;
        o.executionFee = fee;
        o.reservedNotional = reserved;
        emit OrderRequested(msg.sender, isLong, OrderKind.INCREASE, sizeBase, credited - fee, o.settleAt);
    }

    /// @notice Request a smaller position; more than the position closes it.
    /// Irrevocable. Open while paused.
    function requestDecrease(bool isLong, uint256 sizeBase, uint256 acceptablePriceX36, uint256 executionFee)
        external
        nonReentrant
    {
        if (sizeBase == 0) revert ZeroAmount();
        if (positions[msg.sender][isLong].sizeBase == 0) revert NoPosition();
        Order storage o = _freeOrder(msg.sender, isLong);
        uint256 fee = _pull(executionFee);
        escrowedQuote += fee;
        o.kind = OrderKind.DECREASE;
        o.settleAt = nextSettleAt();
        o.sizeBase = sizeBase;
        o.acceptablePriceX36 = acceptablePriceX36;
        o.executionFee = fee;
        emit OrderRequested(msg.sender, isLong, OrderKind.DECREASE, sizeBase, 0, o.settleAt);
    }

    /// @notice Request margin back. Judged at the settlement price worse for
    /// the position, on equity and on margin alone, so neither a stale mark
    /// nor an unrealized profit can be withdrawn. Irrevocable. Open while
    /// paused.
    function requestRemoveMargin(bool isLong, uint256 amount, uint256 executionFee) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (positions[msg.sender][isLong].sizeBase == 0) revert NoPosition();
        Order storage o = _freeOrder(msg.sender, isLong);
        uint256 fee = _pull(executionFee);
        escrowedQuote += fee;
        o.kind = OrderKind.REMOVE_MARGIN;
        o.settleAt = nextSettleAt();
        o.marginQuote = amount;
        o.executionFee = fee;
        emit OrderRequested(msg.sender, isLong, OrderKind.REMOVE_MARGIN, 0, amount, o.settleAt);
    }

    /// @notice Execute a settled request; anyone may, for its execution fee.
    ///
    /// During the epoch its window closes on, the request takes effect —
    /// or, if it fails at its price, is consumed without effect (an
    /// increase's margin goes back). Either way the outcome is fixed by then
    /// and does not depend on who executes. After that epoch the call only
    /// rolls the request to a fresh window instead, and returns false.
    /// `hints` locate observations for a call made long after an idle
    /// stretch (see `_settlement`); zeros let the pool search.
    function executeOrder(address trader, bool isLong, uint256[3] calldata hints)
        external
        nonReentrant
        returns (bool ok)
    {
        Order storage stored = orders[trader][isLong];
        Order memory o = stored;
        if (o.kind == OrderKind.NONE) revert NoOrder();
        if (block.timestamp < o.settleAt) revert NotSettled();

        // Entry is closed while paused, and an increase settling inside a
        // pause would be priced off a frozen mark known in advance: refunded,
        // whenever it is touched.
        (bool paused, uint64 pausedAt, uint64 unpausedAt) = IDexRegistry(registry).pauseWindow();
        if (o.kind == OrderKind.INCREASE && (paused || _inPause(o.settleAt, pausedAt, unpausedAt))) {
            _endOrder(trader, isLong, o);
            _payOrCredit(trader, o.marginQuote);
            _payExecutor(o.executionFee);
            emit OrderExecuted(trader, isLong, o.kind, false, msg.sender);
            return false;
        }

        Settlement memory s = _settlement(o.settleAt, hints);
        (uint256 low, uint256 high) = _fold(o.lowX36, o.highX36, s.mark);
        (low, high) = _fold(low, high, s.spot);
        (low, high) = _fold(low, high, s.slow);
        if (block.timestamp >= uint256(o.settleAt) + epoch) {
            stored.lowX36 = low;
            stored.highX36 = high;
            stored.settleAt = nextSettleAt();
            emit OrderRolled(trader, isLong, stored.settleAt);
            return false;
        }

        _endOrder(trader, isLong, o);
        // Within the settlement epoch the settlement mark is the current one.
        _accrueFunding(s.mark);
        _settleFunding(trader, isLong);

        if (o.kind == OrderKind.INCREASE) {
            ok = _increase(trader, isLong, o, isLong ? high : low);
            if (!ok) _payOrCredit(trader, o.marginQuote - _chargeFailedIncrease(o));
        } else if (o.kind == OrderKind.DECREASE) {
            ok = _decrease(trader, isLong, o, isLong ? low : high);
        } else {
            ok = _removeMargin(trader, isLong, o, isLong ? low : high);
        }
        _payExecutor(o.executionFee);
        emit OrderExecuted(trader, isLong, o.kind, ok, msg.sender);
    }

    /// @notice Adding collateral needs no price and only makes a position
    /// safer, so it is immediate and stays open while paused — a pause is
    /// exactly when a trader may want to top up before liquidations resume.
    /// Not while a request is pending on the side: it is judged on the
    /// position it was made against, and a top-up after its price is known
    /// would let the requester decide whether it passes.
    function addMargin(bool isLong, uint256 quoteIn) external nonReentrant {
        if (positions[msg.sender][isLong].sizeBase == 0) revert NoPosition();
        if (orders[msg.sender][isLong].kind != OrderKind.NONE) revert OrderPending();
        _accrueFunding(markX36());
        _settleFunding(msg.sender, isLong);
        uint256 credited = _pull(quoteIn);
        positions[msg.sender][isLong].marginQuote += credited;
        emit MarginAdded(msg.sender, isLong, credited);
    }

    function liquidate(address trader, bool isLong) external nonReentrant {
        // Blocked while paused, unlike most perp designs. The likeliest reason
        // to pause is the mark being wrong, and liquidating against a wrong
        // mark takes solvent traders' collateral irreversibly. Bad debt left
        // sitting is a loss the vault can absorb and unwind; a wrongful
        // liquidation is not recoverable.
        Pausing.requireNotPaused(registry);
        // For one full window after a restart the mark still averages prices
        // from while swaps were stopped; traders get that long to top up.
        (,, uint64 unpausedAt) = IDexRegistry(registry).pauseWindow();
        if (unpausedAt != 0 && block.timestamp < uint256(unpausedAt) + MARK_WINDOW + epoch) {
            revert LiquidationCooldown();
        }
        (uint256 mark,) = _tryTwap(block.timestamp / epoch * epoch, MARK_WINDOW);
        if (mark == 0) revert MarkNotReady();
        _accrueFunding(mark);
        _settleFunding(trader, isLong);
        Position memory p = positions[trader][isLong];
        if (p.sizeBase == 0) revert NoPosition();
        if (_healthy(p, isLong, mark, false)) revert NotLiquidatable();

        uint256 closeNotional = Math.mulDiv(p.sizeBase, mark, PRICE_SCALE);
        // Trader forfeits remaining equity to the LP vault; the liquidator is
        // then paid out of it. Bad debt is absorbed by the vault implicitly
        // (it simply never receives the shortfall).
        uint256 remaining = _settleAgainstVault(p.marginQuote, _pnl(p.sizeBase, p.entryNotional, mark, isLong));
        totalLiquidity += remaining;
        // Cut of the forfeited equity, floored at a slice of closed notional
        // so a position that gapped through maintenance is still worth
        // liquidating, and capped by what the vault actually holds.
        uint256 reward = Math.max(
            Math.mulDiv(remaining, liquidationFeeBps, BPS), Math.mulDiv(closeNotional, LIQ_REWARD_FLOOR_BPS, BPS)
        );
        if (reward > totalLiquidity) reward = totalLiquidity;
        totalLiquidity -= reward;

        if (isLong) {
            longSizeBase -= p.sizeBase;
            longOpenNotional -= p.entryNotional;
        } else {
            shortSizeBase -= p.sizeBase;
            shortOpenNotional -= p.entryNotional;
        }
        _writePosition(trader, isLong, Position(0, 0, 0, 0));
        if (reward > 0) IERC20(quoteToken).safeTransfer(msg.sender, reward);
        emit Liquidated(trader, isLong, msg.sender, p.sizeBase, mark, reward);
    }

    // ------------------------------------------------------------------ LP

    /// @notice Request a deposit. The quote is escrowed now; shares are
    /// minted at execution against the vault valued at full mark-to-market,
    /// at the settlement price that values it highest, so a deposit never
    /// buys in below what the vault is worth.
    function requestDeposit(
        uint256 quoteIn,
        uint256 minShares,
        address receiver,
        address refundTo,
        uint256 executionFee
    ) external nonReentrant returns (uint256 requestId) {
        Pausing.requireNotPaused(registry);
        if (receiver == address(0) || refundTo == address(0)) revert ZeroAddress();
        // Its window starts after this request, so a seeded pool guarantees
        // the window will have a price.
        (uint256 r0, uint256 r1,) = ISpotPool(spotPool).getReserves();
        if (r0 == 0 || r1 == 0) revert MarkNotReady();
        uint256 credited = _pull(quoteIn + executionFee);
        uint256 fee = Math.min(executionFee, credited);
        if (credited == fee) revert ZeroAmount();
        escrowedQuote += credited;
        requestId = _newLpRequest(true, receiver, refundTo, credited - fee, minShares, fee);
    }

    /// @notice Request a withdrawal. The shares are escrowed now; quote is
    /// paid at execution against the vault valued conservatively — traders'
    /// unrealized profits counted, their unrealized losses not — at the
    /// settlement price that values it lowest. Open while paused.
    function requestWithdraw(
        uint256 shares,
        uint256 minQuoteOut,
        address receiver,
        address refundTo,
        uint256 executionFee
    ) external nonReentrant returns (uint256 requestId) {
        if (receiver == address(0) || refundTo == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroAmount();
        if (shares > sharesOf[msg.sender]) revert InsufficientShares();
        uint256 fee = _pull(executionFee);
        escrowedQuote += fee;
        sharesOf[msg.sender] -= shares;
        escrowedShares += shares;
        requestId = _newLpRequest(false, receiver, refundTo, shares, minQuoteOut, fee);
    }

    function cancelLp(uint256 requestId) external nonReentrant {
        LpRequest storage r = lpRequests[requestId];
        if (r.status != LpStatus.PENDING) revert NoRequest();
        if (msg.sender != r.owner) revert NotRequestOwner();
        if (r.highX36 != 0 || block.timestamp >= r.settleAt - MARK_WINDOW) revert WindowOpen();
        r.status = LpStatus.CANCELLED;
        _refundLp(r);
        escrowedQuote -= r.executionFee;
        if (r.executionFee > 0) IERC20(quoteToken).safeTransfer(r.owner, r.executionFee);
        emit LpCancelled(requestId);
    }

    /// @notice Execute a settled LP request; anyone may, for its fee. Same
    /// timing rules as `executeOrder`: it takes effect during its settlement
    /// epoch — or is refunded to `refundTo` if it fails — and after that
    /// epoch the call rolls it to a fresh window.
    function executeLp(uint256 requestId, uint256[3] calldata hints) external nonReentrant {
        LpRequest storage r = lpRequests[requestId];
        if (r.status != LpStatus.PENDING) revert NoRequest();
        if (block.timestamp < r.settleAt) revert NotSettled();

        bool ok;
        (bool paused, uint64 pausedAt, uint64 unpausedAt) = IDexRegistry(registry).pauseWindow();
        if (r.isDeposit && (paused || _inPause(r.settleAt, pausedAt, unpausedAt))) {
            // Entry: refused while paused or when it settled inside a pause —
            // without reading a price, which a pause soon after the pool's
            // seeding may not have.
            ok = false;
        } else {
            Settlement memory s = _settlement(r.settleAt, hints);
            (uint256 low, uint256 high) = _fold(r.lowX36, r.highX36, s.mark);
            (low, high) = _fold(low, high, s.spot);
            (low, high) = _fold(low, high, s.slow);
            if (block.timestamp >= uint256(r.settleAt) + epoch) {
                r.lowX36 = low;
                r.highX36 = high;
                r.settleAt = nextSettleAt();
                emit LpRolled(requestId, r.settleAt);
                return;
            }
            _accrueFunding(s.mark);
            ok = r.isDeposit ? _executeDeposit(r, low, high) : _executeWithdraw(r, low, high);
        }

        if (r.isDeposit) escrowedQuote -= r.amount;
        else escrowedShares -= r.amount;
        if (ok) {
            r.status = LpStatus.EXECUTED;
        } else {
            r.status = LpStatus.REFUNDED;
            _refundLp(r);
        }
        escrowedQuote -= r.executionFee;
        _payExecutor(r.executionFee);
        emit LpExecuted(requestId, ok, r.out, msg.sender);
    }

    function lpRequestOutcome(uint256 requestId)
        external
        view
        returns (LpStatus status, bool isDeposit, uint256 amount, uint256 out)
    {
        LpRequest storage r = lpRequests[requestId];
        return (r.status, r.isDeposit, r.amount, r.out);
    }

    // ---------------------------------------------------------------- views

    /// @notice What a withdrawal is paid against at the current mark.
    function lpEquityForWithdraw() external view returns (uint256) {
        return _withdrawEquity(markX36());
    }

    /// @notice What a deposit buys into at the current mark.
    function lpEquityForDeposit() external view returns (uint256) {
        return _depositEquity(markX36());
    }

    function equityOf(address trader, bool isLong) external view returns (int256) {
        Position storage pos = positions[trader][isLong];
        if (pos.sizeBase == 0) return 0;
        uint256 cumSide = isLong ? cumFundingLongX36 : cumFundingShortX36;
        uint256 fundingOwed = Math.mulDiv(pos.sizeBase, cumSide - pos.entryFundingX36, PRICE_SCALE);
        return
            pos.marginQuote.toInt256() - fundingOwed.toInt256()
                + _pnl(pos.sizeBase, pos.entryNotional, markX36(), isLong);
    }

    /// @notice Collect payouts whose transfer failed, to any address — the
    /// usual reason a transfer failed is that the token refuses the
    /// recipient's own address.
    function claim(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = claimableQuote[msg.sender];
        if (amount == 0) revert ZeroAmount();
        claimableQuote[msg.sender] = 0;
        escrowedQuote -= amount;
        IERC20(quoteToken).safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    // ------------------------------------------------------------------ fees

    function collectProtocolFees() external nonReentrant {
        uint256 fee = protocolFeesQuote;
        protocolFeesQuote = 0;
        if (fee > 0) IERC20(quoteToken).safeTransfer(treasury, fee);
        emit ProtocolFeesCollected(fee);
    }

    // ------------------------------------------------------------- internals

    function _freeOrder(address trader, bool isLong) internal view returns (Order storage o) {
        o = orders[trader][isLong];
        if (o.kind != OrderKind.NONE) revert OrderPending();
    }

    /// @dev Admit an increase of `sizeBase` against the latest boundary's
    /// mark and the oracle's depth over both horizons, and hold the
    /// notional for it. Admission needs a full `DEPTH_WINDOW` of oracle
    /// history, so a new market takes positions an hour after its pool has a
    /// price.
    ///
    /// The request must also be fillable at that mark — a limit on the right
    /// side of it, enough margin for the whole position. Held capacity blocks
    /// other traders and LP exits until the request resolves, and a request
    /// built to fail would hold it for free and get its margin back.
    function _admit(bool isLong, uint256 sizeBase, uint256 margin, uint256 acceptablePriceX36)
        internal
        returns (uint256 reserved)
    {
        uint256 b = block.timestamp / epoch * epoch;
        (uint256 mark, uint256 liqShort) = _tryTwap(b, MARK_WINDOW);
        (, uint256 liqLong) = _tryTwap(b, DEPTH_WINDOW);
        if (mark == 0 || liqLong == 0) revert MarkNotReady();
        reserved = Math.mulDiv(sizeBase, mark, PRICE_SCALE);
        if (reserved == 0) revert ZeroAmount();
        // The escrow alone has to cover what a failure costs; margin already
        // in the position is not the request's to spend.
        if (margin < _failedIncreaseFee(reserved)) revert MarginBelowFee();
        if (acceptablePriceX36 != 0 && (isLong ? acceptablePriceX36 < mark : acceptablePriceX36 > mark)) {
            revert UnfillableLimit();
        }
        (uint256 totalFee,,) = FeeSplit.split(reserved, lpFeeRatePpm);
        Position memory p = positions[msg.sender][isLong];
        if (p.marginQuote + margin <= totalFee) revert LeverageTooHigh();
        p.marginQuote = p.marginQuote + margin - totalFee;
        p.sizeBase += sizeBase;
        p.entryNotional += reserved;
        if (!_healthy(p, isLong, mark, true)) revert LeverageTooHigh();
        uint256 pending = isLong ? pendingLongNotional : pendingShortNotional;
        uint256 sideNotional =
            Math.mulDiv(isLong ? longSizeBase : shortSizeBase, mark, PRICE_SCALE) + pending + reserved;
        // A constant-product pool holds sqrt(k * p) of its quote token; mark
        // is p scaled by 1e36, so its square root carries a 1e18 scale.
        uint256 depth = Math.mulDiv(Math.min(liqShort, liqLong), Math.sqrt(mark), 1e18);
        if (sideNotional > Math.mulDiv(depth, ORACLE_DEPTH_BPS, BPS)) revert OracleTooShallow();
        if (sideNotional > Math.mulDiv(_withdrawEquity(mark), maxUtilizationBps, BPS)) revert UtilizationExceeded();
        if (isLong) pendingLongNotional = pending + reserved;
        else pendingShortNotional = pending + reserved;
    }

    /// @dev Retire an order: release its escrow and, for an increase, the
    /// open interest held for it.
    function _endOrder(address trader, bool isLong, Order memory o) internal {
        delete orders[trader][isLong];
        if (o.kind == OrderKind.INCREASE) {
            escrowedQuote -= o.executionFee + o.marginQuote;
            if (isLong) pendingLongNotional -= o.reservedNotional;
            else pendingShortNotional -= o.reservedNotional;
        } else {
            escrowedQuote -= o.executionFee;
        }
    }

    /// @dev What a failed increase pays for the open interest it held: the
    /// pool's open fee on it, and at least `FAILED_INCREASE_FEE_BPS`.
    function _failedIncreaseFee(uint256 reserved) internal view returns (uint256 fee) {
        (fee,,) = FeeSplit.split(reserved, lpFeeRatePpm);
        fee = Math.max(fee, Math.mulDiv(reserved, FAILED_INCREASE_FEE_BPS, BPS, Math.Rounding.Ceil));
    }

    /// @dev Charge a failed increase's fee to its escrowed margin, which
    /// admission made sure covers it, and split it like any fee.
    function _chargeFailedIncrease(Order memory o) internal returns (uint256 fee) {
        fee = Math.min(_failedIncreaseFee(o.reservedNotional), o.marginQuote);
        (uint256 protocolFee, uint256 lpFee) = FeeSplit.splitFee(fee);
        protocolFeesQuote += protocolFee;
        totalLiquidity += lpFee;
    }

    /// @dev Pay out without letting the recipient block the call. A refund
    /// or payout the token refuses — a blocklisted address, say — would
    /// otherwise revert every execution of the request, leaving it rolling
    /// forever with any open interest it holds. It is credited for `claim`
    /// instead, and stays in `escrowedQuote` until then.
    function _payOrCredit(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!IERC20(quoteToken).trySafeTransfer(to, amount)) {
            claimableQuote[to] += amount;
            escrowedQuote += amount;
        }
    }

    function _inPause(uint256 settleAt, uint256 pausedAt, uint256 unpausedAt) internal view returns (bool) {
        return pausedAt != 0 && settleAt > pausedAt / epoch * epoch && settleAt <= unpausedAt;
    }

    function _payExecutor(uint256 fee) internal {
        if (fee > 0) IERC20(quoteToken).safeTransfer(msg.sender, fee);
    }

    /// @dev `px` is the fill: the highest settlement price for a long, the
    /// lowest for a short. The position is judged at that same price. It
    /// already carries every price the request went through, and a check at
    /// any other one — the opposite extreme, say — is one the requester
    /// could fail on purpose by letting the request roll, walking away from
    /// a fill they no longer liked with their margin back.
    function _increase(address trader, bool isLong, Order memory o, uint256 px) internal returns (bool) {
        if (o.acceptablePriceX36 != 0 && (isLong ? px > o.acceptablePriceX36 : px < o.acceptablePriceX36)) {
            return false;
        }
        uint256 notionalDelta = Math.mulDiv(o.sizeBase, px, PRICE_SCALE);
        if (notionalDelta == 0) return false;
        (uint256 totalFee, uint256 protocolFee, uint256 lpFee) = FeeSplit.split(notionalDelta, lpFeeRatePpm);

        Position memory p = positions[trader][isLong];
        // Funding was settled just before; a fresh position starts here too.
        p.entryFundingX36 = isLong ? cumFundingLongX36 : cumFundingShortX36;
        uint256 margin = p.marginQuote + o.marginQuote;
        if (margin <= totalFee) return false;
        p.marginQuote = margin - totalFee;
        p.sizeBase += o.sizeBase;
        p.entryNotional += notionalDelta;
        // The whole position — not just the margin — must stay inside max
        // leverage and above maintenance afterwards.
        if (!_healthy(p, isLong, px, true)) return false;

        _writePosition(trader, isLong, p);
        if (isLong) {
            longSizeBase += o.sizeBase;
            longOpenNotional += notionalDelta;
        } else {
            shortSizeBase += o.sizeBase;
            shortOpenNotional += notionalDelta;
        }
        protocolFeesQuote += protocolFee;
        totalLiquidity += lpFee;
        emit PositionIncreased(trader, isLong, o.sizeBase, o.marginQuote, px, totalFee);
        return true;
    }

    /// @dev `px` is the fill: the lowest settlement price for a long, the
    /// highest for a short.
    function _decrease(address trader, bool isLong, Order memory o, uint256 px) internal returns (bool) {
        Position memory p = positions[trader][isLong];
        if (p.sizeBase == 0) return false;
        uint256 reduce = Math.min(o.sizeBase, p.sizeBase);
        if (o.acceptablePriceX36 != 0 && (isLong ? px < o.acceptablePriceX36 : px > o.acceptablePriceX36)) {
            return false;
        }

        uint256 notionalPortion = Math.mulDiv(p.entryNotional, reduce, p.sizeBase);
        uint256 marginPortion = Math.mulDiv(p.marginQuote, reduce, p.sizeBase);
        uint256 closeNotional = Math.mulDiv(reduce, px, PRICE_SCALE);
        int256 pnl = _pnl(reduce, notionalPortion, px, isLong);
        p.sizeBase -= reduce;
        p.entryNotional -= notionalPortion;
        p.marginQuote -= marginPortion;
        // A partial close keeps the remainder's leverage, so a position below
        // maintenance can only be closed in full.
        if (p.sizeBase > 0 && !_healthy(p, isLong, px, false)) return false;

        uint256 payout = _settleAgainstVault(marginPortion, pnl);
        // Close fee comes out of the trader's claim (capped by it) and is
        // split like every other fee: 0.1% protocol, rest to LPs.
        (uint256 totalFee,,) = FeeSplit.split(closeNotional, lpFeeRatePpm);
        totalFee = Math.min(totalFee, payout);
        payout -= totalFee;
        // Re-split the capped fee rather than restating the protocol cut by
        // hand here, which is how the two fee paths drift apart.
        (uint256 protocolFee, uint256 lpFee) = FeeSplit.splitFee(totalFee);
        protocolFeesQuote += protocolFee;
        totalLiquidity += lpFee;

        if (isLong) {
            longSizeBase -= reduce;
            longOpenNotional -= notionalPortion;
        } else {
            shortSizeBase -= reduce;
            shortOpenNotional -= notionalPortion;
        }
        if (p.sizeBase == 0) {
            // Return any residual margin along with the payout.
            payout += p.marginQuote;
            p.marginQuote = 0;
        }
        _writePosition(trader, isLong, p);
        _payOrCredit(trader, payout);
        emit PositionDecreased(trader, isLong, reduce, payout, px, totalFee);
        return true;
    }

    function _removeMargin(address trader, bool isLong, Order memory o, uint256 healthPrice) internal returns (bool) {
        Position memory p = positions[trader][isLong];
        if (p.sizeBase == 0 || o.marginQuote > p.marginQuote) return false;
        p.marginQuote -= o.marginQuote;
        if (!_healthy(p, isLong, healthPrice, true)) return false;
        _writePosition(trader, isLong, p);
        _payOrCredit(trader, o.marginQuote);
        emit MarginRemoved(trader, isLong, o.marginQuote);
        return true;
    }

    function _executeDeposit(LpRequest storage r, uint256 low, uint256 high) internal returns (bool) {
        uint256 supply = totalShares;
        uint256 shares;
        if (supply == 0) {
            if (r.amount <= MINIMUM_LIQUIDITY) return false;
            shares = r.amount - MINIMUM_LIQUIDITY;
        } else {
            uint256 equity = Math.max(_depositEquity(low), _depositEquity(high));
            // A wiped vault must not mint against nothing.
            if (equity == 0) return false;
            shares = Math.mulDiv(r.amount, supply, equity);
        }
        if (shares == 0 || shares < r.minOut) return false;
        if (supply == 0) _mintShares(address(0xdead), MINIMUM_LIQUIDITY);
        totalLiquidity += r.amount;
        _mintShares(r.receiver, shares);
        r.out = shares;
        return true;
    }

    function _executeWithdraw(LpRequest storage r, uint256 low, uint256 high) internal returns (bool) {
        uint256 equity = Math.min(_withdrawEquity(low), _withdrawEquity(high));
        uint256 quoteOut = Math.mulDiv(r.amount, equity, totalShares);
        // Unrealized trader losses back LP equity on paper only; cash out is
        // capped by realized liquidity.
        if (quoteOut < r.minOut || quoteOut > totalLiquidity) return false;
        if (!(_exposureCovered(equity - quoteOut, low) && _exposureCovered(equity - quoteOut, high))) return false;

        totalShares -= r.amount;
        totalLiquidity -= quoteOut;
        r.out = quoteOut;
        _payOrCredit(r.receiver, quoteOut);
        return true;
    }

    function _newLpRequest(
        bool isDeposit,
        address receiver,
        address refundTo,
        uint256 amount,
        uint256 minOut,
        uint256 executionFee
    ) internal returns (uint256 requestId) {
        requestId = nextLpRequestId++;
        uint64 settleAt = nextSettleAt();
        lpRequests[requestId] = LpRequest({
            owner: msg.sender,
            receiver: receiver,
            refundTo: refundTo,
            isDeposit: isDeposit,
            status: LpStatus.PENDING,
            settleAt: settleAt,
            amount: amount,
            minOut: minOut,
            executionFee: executionFee,
            out: 0,
            lowX36: 0,
            highX36: 0
        });
        emit LpRequested(requestId, msg.sender, isDeposit, amount, settleAt);
    }

    /// @dev Escrow of a cancelled or failed LP request goes to `refundTo`:
    /// the quote of a deposit, the shares of a withdrawal. A cancellation
    /// also releases the escrow here; an execution has already released it.
    function _refundLp(LpRequest storage r) internal {
        if (r.isDeposit) {
            if (r.status == LpStatus.CANCELLED) escrowedQuote -= r.amount;
            _payOrCredit(r.refundTo, r.amount);
        } else {
            if (r.status == LpStatus.CANCELLED) escrowedShares -= r.amount;
            sharesOf[r.refundTo] += r.amount;
        }
    }

    function _mintShares(address to, uint256 amount) internal {
        totalShares += amount;
        sharesOf[to] += amount;
    }

    /// @dev Store a position and keep the side's funding-entry sum in step.
    /// Every change to size or funding entry goes through here.
    function _writePosition(address trader, bool isLong, Position memory p) internal {
        Position storage s = positions[trader][isLong];
        uint256 before = Math.mulDiv(s.sizeBase, s.entryFundingX36, PRICE_SCALE);
        uint256 afterwards = Math.mulDiv(p.sizeBase, p.entryFundingX36, PRICE_SCALE);
        if (isLong) longFundingEntry = longFundingEntry + afterwards - before;
        else shortFundingEntry = shortFundingEntry + afterwards - before;
        if (p.sizeBase == 0 && p.marginQuote == 0) delete positions[trader][isLong];
        else positions[trader][isLong] = p;
    }

    /// @dev Settle accrued funding on a position: owed quote moves from the
    /// position's margin to the LP vault (capped at available margin).
    function _settleFunding(address trader, bool isLong) internal {
        Position memory p = positions[trader][isLong];
        uint256 cumSide = isLong ? cumFundingLongX36 : cumFundingShortX36;
        if (p.sizeBase == 0 || p.entryFundingX36 == cumSide) return;
        uint256 owed = Math.mulDiv(p.sizeBase, cumSide - p.entryFundingX36, PRICE_SCALE);
        uint256 paid = Math.min(owed, p.marginQuote);
        p.marginQuote -= paid;
        totalLiquidity += paid;
        p.entryFundingX36 = cumSide;
        _writePosition(trader, isLong, p);
    }

    /// @dev Settle a margin bucket plus signed PnL against the vault and
    /// return what the trader is due. Conserves the accounting invariant:
    /// margin leaves the margin ledger; due − margin comes from (or margin −
    /// due goes to) totalLiquidity; profits are capped by the vault.
    function _settleAgainstVault(uint256 margin, int256 pnl) internal returns (uint256 due) {
        int256 settled = margin.toInt256() + pnl;
        if (settled <= 0) {
            totalLiquidity += margin;
            return 0;
        }
        due = uint256(settled);
        if (due > margin) {
            uint256 fromVault = due - margin;
            if (fromVault > totalLiquidity) {
                due = margin + totalLiquidity; // vault-insolvency cap
                fromVault = totalLiquidity;
            }
            totalLiquidity -= fromVault;
        } else {
            totalLiquidity += margin - due;
        }
    }

    /// @dev Above maintenance at `price`, and — with `checkLeverage` —
    /// inside max leverage on the smaller of margin and equity: losses count
    /// against it, unrealized profit does not count for it.
    function _healthy(Position memory p, bool isLong, uint256 price, bool checkLeverage) internal view returns (bool) {
        uint256 notional = Math.mulDiv(p.sizeBase, price, PRICE_SCALE);
        int256 equity = p.marginQuote.toInt256() + _pnl(p.sizeBase, p.entryNotional, price, isLong);
        if (equity < Math.mulDiv(notional, maintenanceMarginBps, BPS).toInt256()) return false;
        if (checkLeverage) {
            uint256 backing = equity <= 0 ? 0 : Math.min(uint256(equity), p.marginQuote);
            if (notional > backing * maxLeverageX) return false;
        }
        return true;
    }

    function _pnl(uint256 size, uint256 openNotional, uint256 price, bool isLong) internal pure returns (int256) {
        int256 value = Math.mulDiv(size, price, PRICE_SCALE).toInt256();
        return isLong ? value - openNotional.toInt256() : openNotional.toInt256() - value;
    }

    /// @dev Realized liquidity minus each side's unrealized profit; trader
    /// losses and unsettled funding are not counted until collected. A
    /// position can lose more than its margin, and counting that loss as LP
    /// equity let an informed LP exit at a price the vault will never see.
    function _withdrawEquity(uint256 price) internal view returns (uint256) {
        if (price == 0) return totalLiquidity;
        int256 longPnl = _pnl(longSizeBase, longOpenNotional, price, true);
        int256 shortPnl = _pnl(shortSizeBase, shortOpenNotional, price, false);
        int256 equity =
            totalLiquidity.toInt256() - (longPnl > 0 ? longPnl : int256(0)) - (shortPnl > 0 ? shortPnl : int256(0));
        return equity <= 0 ? 0 : uint256(equity);
    }

    /// @dev Full mark-to-market: trader losses and funding owed included. A
    /// deposit pays for the vault's paper gains, so new LPs cannot dilute the
    /// ones whose capital earned them.
    function _depositEquity(uint256 price) internal view returns (uint256) {
        int256 equity = totalLiquidity.toInt256() + _fundingOwed().toInt256();
        if (price != 0) {
            equity -= _pnl(longSizeBase, longOpenNotional, price, true)
            + _pnl(shortSizeBase, shortOpenNotional, price, false);
        }
        return equity <= 0 ? 0 : uint256(equity);
    }

    function _fundingOwed() internal view returns (uint256) {
        uint256 longAccrued = Math.mulDiv(longSizeBase, cumFundingLongX36, PRICE_SCALE);
        uint256 shortAccrued = Math.mulDiv(shortSizeBase, cumFundingShortX36, PRICE_SCALE);
        return (longAccrued > longFundingEntry ? longAccrued - longFundingEntry : 0)
            + (shortAccrued > shortFundingEntry ? shortAccrued - shortFundingEntry : 0);
    }

    /// @dev What a withdrawal must leave behind. The vault's directional
    /// risk is the net of the two sides, held to the same cap new positions
    /// face; gross exposure gets twice that. Capping each side on its own let
    /// a hedged pair of positions — no market risk, no funding — fill both
    /// caps and lock every LP in. Pending increases count like the positions
    /// they become: the vault committed to them at admission, and an exit
    /// ahead of their fill would leave the LPs who stay over the cap. An
    /// increase requested only to block an exit pays for it — the failed
    /// increase fee, or a real position.
    function _exposureCovered(uint256 equityAfter, uint256 price) internal view returns (bool) {
        uint256 longNotional = Math.mulDiv(longSizeBase, price, PRICE_SCALE) + pendingLongNotional;
        uint256 shortNotional = Math.mulDiv(shortSizeBase, price, PRICE_SCALE) + pendingShortNotional;
        uint256 cap = Math.mulDiv(equityAfter, maxUtilizationBps, BPS);
        uint256 net = longNotional > shortNotional ? longNotional - shortNotional : shortNotional - longNotional;
        return net <= cap && Math.max(longNotional, shortNotional) <= 2 * cap;
    }

    function _pull(uint256 amount) internal returns (uint256 received) {
        if (amount == 0) return 0;
        uint256 balanceBefore = IERC20(quoteToken).balanceOf(address(this));
        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), amount);
        received = IERC20(quoteToken).balanceOf(address(this)) - balanceBefore;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {PairKey} from "./libraries/PairKey.sol";
import {IOrderbook} from "./interfaces/IOrderbook.sol";
import {ISpotPool} from "./interfaces/ISpotPool.sol";
import {PerpParams} from "./interfaces/IPerpPool.sol";

interface ISpotPoolFactory {
    function deploy(
        address orderbook,
        address treasury,
        address token0,
        address token1,
        uint32 lpFeeRatePpm,
        bytes32 pairId
    ) external returns (address pool);
}

interface IPerpPoolFactory {
    function deploy(
        address treasury,
        address spotPool,
        address baseToken,
        address quoteToken,
        uint32 lpFeeRatePpm,
        bytes32 pairId,
        PerpParams calldata params
    ) external returns (address pool);
}

/// @notice Entry point for pair registration and pool creation (DEX.md §3).
/// Pairs are ANY/ANY ERC-20, identified by keccak256 of the sorted token
/// addresses. One pair may host many spot and perp pools, each with its own
/// creator-chosen fee. UUPS-upgradeable; deployed pools stay immutable.
contract DexRegistry is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    struct Pair {
        address token0;
        address token1;
        bool exists;
    }

    address public treasury;
    address public orderbook;
    address public spotPoolFactory;
    address public perpPoolFactory;
    uint32 public maxLpFeeRatePpm;

    mapping(bytes32 => Pair) public pairs;
    mapping(bytes32 => address[]) internal _spotPools;
    mapping(bytes32 => address[]) internal _perpPools;
    mapping(address => bytes32) public poolPairId;
    mapping(address => bool) public isSpotPool;

    uint32 public constant MAX_LEVERAGE_CAP = 50;
    uint32 public constant MIN_MAINTENANCE_MARGIN_BPS = 100;
    uint32 public constant MAX_MAINTENANCE_MARGIN_BPS = 2000;
    uint32 public constant MAX_LIQUIDATION_FEE_BPS = 500;
    uint64 public constant MAX_FUNDING_COEFF_PPM_PER_HOUR = 10_000;

    error ZeroAddress();
    error OrderbookAlreadySet();
    error OrderbookNotSet();
    error FactoryNotSet();
    error FeeRateTooHigh();
    error InvalidQuoteToken();
    error UnknownSpotPool();
    error SpotPoolPairMismatch();
    error InvalidPerpParams();

    event OrderbookSet(address indexed orderbook);
    event FactoriesSet(address indexed spotPoolFactory, address indexed perpPoolFactory);
    event MaxLpFeeRateSet(uint32 previousPpm, uint32 newPpm);
    event PairRegistered(bytes32 indexed pairId, address indexed token0, address indexed token1);
    event SpotPoolCreated(
        bytes32 indexed pairId, address indexed pool, address indexed creator, uint32 lpFeeRatePpm, uint256 tickSize
    );
    event PerpPoolCreated(
        bytes32 indexed pairId, address indexed pool, address indexed creator, address quoteToken, uint32 lpFeeRatePpm
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address treasury_) external initializer {
        if (treasury_ == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        treasury = treasury_;
        maxLpFeeRatePpm = 50_000; // 5%
    }

    // ---------------------------------------------------------------- admin

    function setOrderbook(address orderbook_) external onlyOwner {
        if (orderbook != address(0)) revert OrderbookAlreadySet();
        if (orderbook_ == address(0)) revert ZeroAddress();
        orderbook = orderbook_;
        emit OrderbookSet(orderbook_);
    }

    function setFactories(address spotPoolFactory_, address perpPoolFactory_) external onlyOwner {
        if (spotPoolFactory_ == address(0)) revert ZeroAddress();
        spotPoolFactory = spotPoolFactory_;
        perpPoolFactory = perpPoolFactory_; // zero allowed: perp creation disabled
        emit FactoriesSet(spotPoolFactory_, perpPoolFactory_);
    }

    function setMaxLpFeeRate(uint32 ppm) external onlyOwner {
        emit MaxLpFeeRateSet(maxLpFeeRatePpm, ppm);
        maxLpFeeRatePpm = ppm;
    }

    // -------------------------------------------------------- pool creation

    function createSpotPool(address tokenX, address tokenY, uint32 lpFeeRatePpm, uint256 tickSize)
        external
        returns (address pool)
    {
        if (spotPoolFactory == address(0)) revert FactoryNotSet();
        if (orderbook == address(0)) revert OrderbookNotSet();
        if (lpFeeRatePpm > maxLpFeeRatePpm) revert FeeRateTooHigh();

        (address token0, address token1) = PairKey.sort(tokenX, tokenY);
        bytes32 pairId = PairKey.pairId(token0, token1);
        bool newPair = _registerPair(pairId, token0, token1);

        pool = ISpotPoolFactory(spotPoolFactory).deploy(orderbook, treasury, token0, token1, lpFeeRatePpm, pairId);
        _spotPools[pairId].push(pool);
        poolPairId[pool] = pairId;
        isSpotPool[pool] = true;

        if (newPair) {
            // Tick is fixed by the first pool creator for the whole pair
            // (DEX.md §4.2 "가격 단위는 풀 생성 시 설정").
            IOrderbook(orderbook).initBook(pairId, token0, token1, tickSize);
        }
        emit SpotPoolCreated(pairId, pool, msg.sender, lpFeeRatePpm, tickSize);
    }

    function createPerpPool(
        address tokenX,
        address tokenY,
        address quoteToken,
        address spotPool,
        uint32 lpFeeRatePpm,
        PerpParams calldata params
    ) external returns (address pool) {
        if (perpPoolFactory == address(0)) revert FactoryNotSet();
        if (lpFeeRatePpm > maxLpFeeRatePpm) revert FeeRateTooHigh();

        (address token0, address token1) = PairKey.sort(tokenX, tokenY);
        bytes32 pairId = PairKey.pairId(token0, token1);
        if (quoteToken != token0 && quoteToken != token1) revert InvalidQuoteToken();
        if (!isSpotPool[spotPool]) revert UnknownSpotPool();
        if (poolPairId[spotPool] != pairId) revert SpotPoolPairMismatch();
        if (
            params.maxLeverageX == 0 || params.maxLeverageX > MAX_LEVERAGE_CAP
                || params.maintenanceMarginBps < MIN_MAINTENANCE_MARGIN_BPS
                || params.maintenanceMarginBps > MAX_MAINTENANCE_MARGIN_BPS
                || params.liquidationFeeBps > MAX_LIQUIDATION_FEE_BPS || params.maxUtilizationBps == 0
                || params.maxUtilizationBps > 10_000 || params.fundingCoeffPpmPerHour > MAX_FUNDING_COEFF_PPM_PER_HOUR
        ) revert InvalidPerpParams();

        _registerPair(pairId, token0, token1);
        address baseToken = quoteToken == token0 ? token1 : token0;
        pool = IPerpPoolFactory(perpPoolFactory)
            .deploy(treasury, spotPool, baseToken, quoteToken, lpFeeRatePpm, pairId, params);
        _perpPools[pairId].push(pool);
        poolPairId[pool] = pairId;
        emit PerpPoolCreated(pairId, pool, msg.sender, quoteToken, lpFeeRatePpm);
    }

    // ---------------------------------------------------------------- views

    function getSpotPools(bytes32 pairId) external view returns (address[] memory) {
        return _spotPools[pairId];
    }

    function getPerpPools(bytes32 pairId) external view returns (address[] memory) {
        return _perpPools[pairId];
    }

    // ------------------------------------------------------------- internals

    function _registerPair(bytes32 pairId, address token0, address token1) internal returns (bool newPair) {
        if (!pairs[pairId].exists) {
            pairs[pairId] = Pair({token0: token0, token1: token1, exists: true});
            emit PairRegistered(pairId, token0, token1);
            return true;
        }
        return false;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[40] private _gap;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Create2} from "openzeppelin-contracts/contracts/utils/Create2.sol";
import {PairKey} from "./libraries/PairKey.sol";
import {Pair} from "./Pair.sol";

/// @notice Entry point for pair registration (DEX.md §3). Pairs are ANY/ANY
/// ERC-20, one `Pair` contract per token pair, CREATE2-deployed here so its
/// address is predictable off-chain from the two token addresses and the
/// chosen tick size. The Pair itself owns pool creation, its orderbook, and
/// its tickSize — this registry only tracks which Pair/pool addresses are
/// legitimate. UUPS-upgradeable; deployed Pairs and pools stay immutable.
contract DexRegistry is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    address public treasury;
    address public spotPoolFactory;
    address public perpPoolFactory;
    uint32 public maxLpFeeRatePpm;

    mapping(bytes32 => address) internal _getPair; // sorted-token-hash -> Pair address (internal lookup/salt key only)
    mapping(address => bool) public isPair;
    mapping(address => address) public poolToPair;
    mapping(address => bool) public isSpotPool;

    error ZeroAddress();
    error FactoryNotSet();
    error PairAlreadyExists();
    error OnlyPair();

    event FactoriesSet(address indexed spotPoolFactory, address indexed perpPoolFactory);
    event MaxLpFeeRateSet(uint32 previousPpm, uint32 newPpm);
    event PairCreated(address indexed pair, address indexed token0, address indexed token1);
    event PoolRegistered(address indexed pair, address indexed pool, bool isSpot);

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

    // --------------------------------------------------------- pair creation

    /// @notice Deploys the Pair itself — no tick, no pool. Tick is fixed
    /// later, by whoever creates the pair's first spot pool (`Pair.
    /// createSpotPool`), so this call carries no creator-chosen value an
    /// attacker could front-run for and lock in for free.
    function createPair(address tokenX, address tokenY) external returns (address pair) {
        (address token0, address token1) = PairKey.sort(tokenX, tokenY);
        bytes32 key = PairKey.pairId(token0, token1);
        if (_getPair[key] != address(0)) revert PairAlreadyExists();

        pair = address(new Pair{salt: key}(address(this), token0, token1));
        _getPair[key] = pair;
        isPair[pair] = true;
        emit PairCreated(pair, token0, token1);
    }

    /// @notice Called by a legitimate Pair when it deploys a pool, so
    /// periphery (e.g. `DexPositionManager`) can verify a pool address
    /// without knowing which Pair it belongs to in advance.
    function registerPool(address pool, bool isSpot) external {
        if (!isPair[msg.sender]) revert OnlyPair();
        poolToPair[pool] = msg.sender;
        if (isSpot) isSpotPool[pool] = true;
        emit PoolRegistered(msg.sender, pool, isSpot);
    }

    // ---------------------------------------------------------------- views

    function getPair(address tokenA, address tokenB) external view returns (address) {
        (address t0, address t1) = PairKey.sort(tokenA, tokenB);
        return _getPair[PairKey.pairId(t0, t1)];
    }

    function predictPairAddress(address tokenX, address tokenY) external view returns (address) {
        (address t0, address t1) = PairKey.sort(tokenX, tokenY);
        bytes32 salt = PairKey.pairId(t0, t1);
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(Pair).creationCode, abi.encode(address(this), t0, t1)));
        return Create2.computeAddress(salt, initCodeHash);
    }

    // ------------------------------------------------------------------ UUPS

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[40] private _gap;
}

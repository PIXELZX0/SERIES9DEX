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

    mapping(bytes32 => address) internal _getPair; // sorted-token-hash -> Pair address (internal lookup/salt key only)
    mapping(address => bool) public isPair;
    mapping(address => address) public poolToPair;
    mapping(address => bool) public isSpotPool;

    /// @notice Emergency stop, read by every pool and pair of this deployment.
    /// It gates entry only — swaps, new liquidity, new positions, new orders
    /// and matching. Withdrawing liquidity, closing a position and cancelling
    /// an order stay open in every state, so a pause can never trap funds and
    /// therefore never needs an expiry to be safe.
    bool public paused;
    /// @notice May pause but not unpause, and holds nothing else. A Safe is
    /// the right owner for this system and the wrong thing to be assembling
    /// signatures on while an incident runs, so the fast path is a single
    /// key that can only ever stop the system.
    address public guardian;

    error ZeroAddress();
    error FactoryNotSet();
    error PairAlreadyExists();
    error OnlyPair();
    error NotPauser();
    error AlreadyInState();

    event FactoriesSet(address indexed spotPoolFactory, address indexed perpPoolFactory);
    event PairCreated(address indexed pair, address indexed token0, address indexed token1);
    event PoolRegistered(address indexed pair, address indexed pool, bool isSpot);
    event PausedSet(bool paused, address indexed by);
    event GuardianSet(address indexed guardian);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address treasury_) external initializer {
        if (treasury_ == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        treasury = treasury_;
    }

    // ---------------------------------------------------------------- admin

    function setFactories(address spotPoolFactory_, address perpPoolFactory_) external onlyOwner {
        if (spotPoolFactory_ == address(0)) revert ZeroAddress();
        spotPoolFactory = spotPoolFactory_;
        perpPoolFactory = perpPoolFactory_; // zero allowed: perp creation disabled
        emit FactoriesSet(spotPoolFactory_, perpPoolFactory_);
    }

    /// @notice Owner or guardian. Entry points stop; exits stay open.
    function pause() external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotPauser();
        if (paused) revert AlreadyInState();
        paused = true;
        emit PausedSet(true, msg.sender);
    }

    /// @notice Owner only. Restarting the system is a deliberate act and does
    /// not belong on the fast key.
    function unpause() external onlyOwner {
        if (!paused) revert AlreadyInState();
        paused = false;
        emit PausedSet(false, msg.sender);
    }

    /// @notice Zero disables the fast path, leaving the owner as sole pauser.
    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianSet(guardian_);
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
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(Pair).creationCode, abi.encode(address(this), t0, t1)));
        return Create2.computeAddress(salt, initCodeHash);
    }

    // ------------------------------------------------------------------ UUPS

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Two new variables pack into one slot, so the gap drops by one and the
    // reserved region still ends where it always did.
    uint256[39] private _gap;
}

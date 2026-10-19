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
/// address is predictable off-chain from the two token addresses alone
/// (`predictPairAddress`). The Pair itself owns pool creation and its
/// orderbook, and carries no per-pair parameter — order prices sit on a
/// decimal grid derived from the price. This registry only tracks which
/// Pair/pool addresses are legitimate, and holds the emergency stop every
/// pool and pair reads. UUPS-upgradeable; deployed Pairs and pools stay
/// immutable.
///
/// Three roles, split by how fast each has to act (DEX.md §10.3):
///   - `owner` — the timelock. Upgrades and factory changes: anything that
///     changes what code users' funds pass through waits out the delay, so a
///     key compromise is an observable, cancellable proposal.
///   - `emergencyAdmin` — the Safe. Restarts the system and names the
///     guardian, the two powers that are useless behind a delay.
///   - `guardian` — a single fast key that can only stop the system.
/// The owner holds every lesser power too, so losing the Safe's keys is a
/// delay, not a permanent loss of control.
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
    /// the wrong thing to be assembling signatures on while an incident runs,
    /// so the fast path is a single key that can only ever stop the system.
    address public guardian;
    /// @notice May unpause and set the guardian, and pause. Rotated by the
    /// owner.
    address public emergencyAdmin;
    /// @notice When the current (or, once lifted, the latest) pause began and
    /// when the latest one was lifted. Perp pools freeze their mark at the
    /// start of a pause and need both ends to keep doing so for settlements
    /// that fell inside it.
    uint64 public lastPausedAt;
    uint64 public lastUnpausedAt;

    error ZeroAddress();
    error FactoryNotSet();
    error PairAlreadyExists();
    error OnlyPair();
    error NotPauser();
    error NotEmergencyAdmin();
    error AlreadyInState();

    event FactoriesSet(address indexed spotPoolFactory, address indexed perpPoolFactory);
    event PairCreated(address indexed pair, address indexed token0, address indexed token1);
    event PoolRegistered(address indexed pair, address indexed pool, bool isSpot);
    event PausedSet(bool paused, address indexed by);
    event GuardianSet(address indexed guardian);
    event EmergencyAdminSet(address indexed emergencyAdmin);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev The initial owner starts out as emergency admin too; deployment
    /// hands the two roles to different holders before it finishes.
    function initialize(address initialOwner, address treasury_) external initializer {
        if (treasury_ == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        treasury = treasury_;
        emergencyAdmin = initialOwner;
        emit EmergencyAdminSet(initialOwner);
    }

    modifier onlyEmergency() {
        if (msg.sender != emergencyAdmin && msg.sender != owner()) revert NotEmergencyAdmin();
        _;
    }

    // ---------------------------------------------------------------- admin

    /// @notice The spot factory only reaches pairs created afterwards: a Pair
    /// fixes it when deployed, so pointing it at a malicious contract cannot
    /// add a pool to any pair that already holds orders. The perp factory is
    /// read at each perp pool's creation; perp pools never touch a pair's
    /// escrow. Both changes wait out the owner's timelock.
    function setFactories(address spotPoolFactory_, address perpPoolFactory_) external onlyOwner {
        if (spotPoolFactory_ == address(0)) revert ZeroAddress();
        spotPoolFactory = spotPoolFactory_;
        perpPoolFactory = perpPoolFactory_; // zero allowed: perp creation disabled
        emit FactoriesSet(spotPoolFactory_, perpPoolFactory_);
    }

    function setEmergencyAdmin(address emergencyAdmin_) external onlyOwner {
        if (emergencyAdmin_ == address(0)) revert ZeroAddress();
        emergencyAdmin = emergencyAdmin_;
        emit EmergencyAdminSet(emergencyAdmin_);
    }

    /// @notice Guardian, emergency admin or owner. Entry points stop; exits
    /// stay open.
    function pause() external {
        if (msg.sender != guardian && msg.sender != emergencyAdmin && msg.sender != owner()) revert NotPauser();
        if (paused) revert AlreadyInState();
        paused = true;
        lastPausedAt = uint64(block.timestamp);
        emit PausedSet(true, msg.sender);
    }

    /// @notice Restarting the system is a deliberate act and does not belong
    /// on the fast key.
    function unpause() external onlyEmergency {
        if (!paused) revert AlreadyInState();
        paused = false;
        lastUnpausedAt = uint64(block.timestamp);
        emit PausedSet(false, msg.sender);
    }

    /// @notice Zero disables the fast path, leaving the admins as sole
    /// pausers.
    function setGuardian(address guardian_) external onlyEmergency {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    // --------------------------------------------------------- pair creation

    /// @notice Deploys the Pair itself — no pool, no per-pair parameter. The
    /// Pair reads and keeps the current factories, so they must be set first:
    /// a pair created without one could never get a pool.
    function createPair(address tokenX, address tokenY) external returns (address pair) {
        if (spotPoolFactory == address(0)) revert FactoryNotSet();
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

    /// @notice Pause state in one call, for perp pools.
    function pauseWindow() external view returns (bool isPaused, uint64 pausedAt, uint64 unpausedAt) {
        return (paused, lastPausedAt, lastUnpausedAt);
    }

    // ------------------------------------------------------------------ UUPS

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // `paused` and `guardian` share a slot; `emergencyAdmin` and `lastPausedAt`
    // take the next, `lastUnpausedAt` the one after. The gap drops by those
    // two, so the reserved region still ends where it always did.
    uint256[37] private _gap;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// The treasury is owned by a timelock, not by the Safe. These tests cover the
/// wiring that decision depends on — that the Safe alone cannot move fees, that
/// the delay is real, that the guardian can kill a queued withdrawal, and that
/// nobody can quietly take the guardian's ability to do so.
contract TreasuryTimelockTest is Test {
    TimelockController internal timelock;
    ProtocolTreasury internal treasury;
    MockERC20 internal token;

    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    address internal deployer = makeAddr("deployer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant DELAY = 48 hours;

    function setUp() public {
        // Mirrors DeployDex exactly.
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // open execution

        vm.startPrank(deployer);
        timelock = new TimelockController(DELAY, proposers, executors, deployer);
        timelock.grantRole(timelock.CANCELLER_ROLE(), guardian);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopPrank();

        treasury = ProtocolTreasury(
            address(
                new ERC1967Proxy(
                    address(new ProtocolTreasury()), abi.encodeCall(ProtocolTreasury.initialize, (address(timelock)))
                )
            )
        );

        token = new MockERC20("T", "T", 18);
        token.mint(address(treasury), 1_000 ether);
    }

    function _withdrawCall() internal view returns (bytes memory) {
        return abi.encodeCall(ProtocolTreasury.withdraw, (address(token), safe, 1_000 ether));
    }

    function _queue() internal returns (bytes memory payload) {
        payload = _withdrawCall();
        vm.prank(safe);
        timelock.schedule(address(treasury), 0, payload, bytes32(0), bytes32(0), DELAY);
    }

    // ------------------------------------------------------------- ownership

    function testSafeCannotWithdrawDirectly() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, safe));
        treasury.withdraw(address(token), safe, 1 ether);
        assertEq(treasury.owner(), address(timelock));
    }

    // ----------------------------------------------------------- the delay

    function testWithdrawalNeedsTheFullDelay() public {
        bytes memory payload = _queue();

        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(safe);
        vm.expectRevert();
        timelock.execute(address(treasury), 0, payload, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 1);
        // Execution is open, so a bystander can push it through — the Safe
        // cannot be censored out of its own funds.
        vm.prank(stranger);
        timelock.execute(address(treasury), 0, payload, bytes32(0), bytes32(0));
        assertEq(token.balanceOf(safe), 1_000 ether);
        assertEq(token.balanceOf(address(treasury)), 0);
    }

    // -------------------------------------------------------- the guardian

    /// The point of the delay: a compromised Safe queues a drain, and the fast
    /// key that already exists to pause the system kills it in time.
    function testGuardianCancelsAQueuedDrain() public {
        bytes memory payload = _queue();
        bytes32 id = timelock.hashOperation(address(treasury), 0, payload, bytes32(0), bytes32(0));
        assertTrue(timelock.isOperationPending(id));

        vm.prank(guardian);
        timelock.cancel(id);

        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(stranger);
        vm.expectRevert();
        timelock.execute(address(treasury), 0, payload, bytes32(0), bytes32(0));
        assertEq(token.balanceOf(address(treasury)), 1_000 ether);
    }

    /// A compromised Safe cannot strip the canceller faster than the canceller
    /// can act: the timelock is self-administered, so role changes are delayed
    /// too, and the guardian can cancel the attempt to remove it.
    function testSafeCannotStripTheGuardian() public {
        // Read both roles before arming expectRevert: a getter called inside
        // the argument list is itself the "next call" and eats the prank.
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, safe, adminRole)
        );
        timelock.revokeRole(cancellerRole, guardian);

        // Even routed through the timelock it is just another delayed
        // operation, which the guardian can cancel.
        bytes memory payload = abi.encodeCall(IAccessControl.revokeRole, (cancellerRole, guardian));
        vm.prank(safe);
        timelock.schedule(address(timelock), 0, payload, bytes32(0), bytes32(0), DELAY);
        bytes32 id = timelock.hashOperation(address(timelock), 0, payload, bytes32(0), bytes32(0));

        vm.prank(guardian);
        timelock.cancel(id);
        assertTrue(timelock.hasRole(cancellerRole, guardian));
    }

    function testStrangerCannotQueueOrCancel() public {
        vm.prank(stranger);
        vm.expectRevert();
        timelock.schedule(address(treasury), 0, _withdrawCall(), bytes32(0), bytes32(0), DELAY);

        bytes memory payload = _queue();
        bytes32 id = timelock.hashOperation(address(treasury), 0, payload, bytes32(0), bytes32(0));
        vm.prank(stranger);
        vm.expectRevert();
        timelock.cancel(id);
    }

    /// Nobody holds the admin role but the timelock itself, so there is no
    /// key that can rewrite the rules without going through the delay.
    function testTimelockIsSelfAdministeredOnly() public view {
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        assertTrue(timelock.hasRole(adminRole, address(timelock)));
        assertFalse(timelock.hasRole(adminRole, deployer));
        assertFalse(timelock.hasRole(adminRole, safe));
        assertFalse(timelock.hasRole(adminRole, guardian));
        // The guardian may cancel and nothing else.
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), guardian));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), guardian));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), guardian));
    }
}

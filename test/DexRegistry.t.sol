// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {PairKey} from "../src/libraries/PairKey.sol";
import {PerpParams} from "../src/interfaces/IPerpPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOrderbook} from "./mocks/MockOrderbook.sol";

contract DexRegistryTest is Test {
    DexRegistry internal registry;
    ProtocolTreasury internal treasury;
    MockOrderbook internal orderbook;
    SpotPoolFactory internal factory;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        ProtocolTreasury treasuryImpl = new ProtocolTreasury();
        treasury = ProtocolTreasury(
            address(new ERC1967Proxy(address(treasuryImpl), abi.encodeCall(ProtocolTreasury.initialize, (owner))))
        );
        DexRegistry registryImpl = new DexRegistry();
        registry = DexRegistry(
            address(
                new ERC1967Proxy(
                    address(registryImpl), abi.encodeCall(DexRegistry.initialize, (owner, address(treasury)))
                )
            )
        );
        orderbook = new MockOrderbook();
        factory = new SpotPoolFactory(address(registry));
        vm.startPrank(owner);
        registry.setOrderbook(address(orderbook));
        registry.setFactories(address(factory), address(0));
        vm.stopPrank();

        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
    }

    function _sorted() internal view returns (address t0, address t1) {
        (t0, t1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
    }

    function _defaultPerpParams() internal pure returns (PerpParams memory) {
        return PerpParams({
            maxLeverageX: 10,
            maintenanceMarginBps: 500,
            liquidationFeeBps: 100,
            maxUtilizationBps: 8000,
            fundingCoeffPpmPerHour: 100
        });
    }

    // ------------------------------------------------------------- creation

    function testCreateSpotPoolNormalizesPairId() public {
        address poolXY = registry.createSpotPool(address(tokenA), address(tokenB), 3000, 1e15);
        (address t0, address t1) = _sorted();
        bytes32 expectedId = keccak256(abi.encodePacked(t0, t1));
        assertEq(registry.poolPairId(poolXY), expectedId);
        assertEq(SpotPool(poolXY).token0(), t0);
        assertEq(SpotPool(poolXY).token1(), t1);
        assertTrue(registry.isSpotPool(poolXY));
        assertTrue(orderbook.bookInitialized(expectedId));

        // Reversed direction lands on the same pair, adds a second pool.
        address poolYX = registry.createSpotPool(address(tokenB), address(tokenA), 5000, 1e15);
        assertEq(registry.poolPairId(poolYX), expectedId);
        assertEq(registry.getSpotPools(expectedId).length, 2);
    }

    function testCreateSpotPoolSelfPairReverts() public {
        vm.expectRevert(PairKey.IdenticalTokens.selector);
        registry.createSpotPool(address(tokenA), address(tokenA), 3000, 1e15);
    }

    function testCreateSpotPoolZeroTokenReverts() public {
        vm.expectRevert(PairKey.ZeroToken.selector);
        registry.createSpotPool(address(tokenA), address(0), 3000, 1e15);
    }

    function testCreateSpotPoolFeeGuardrail() public {
        // 5% boundary passes, above reverts.
        registry.createSpotPool(address(tokenA), address(tokenB), 50_000, 1e15);
        vm.expectRevert(DexRegistry.FeeRateTooHigh.selector);
        registry.createSpotPool(address(tokenA), address(tokenB), 50_001, 1e15);
    }

    function testCreatePerpPoolRequiresFactory() public {
        address spot = registry.createSpotPool(address(tokenA), address(tokenB), 3000, 1e15);
        vm.expectRevert(DexRegistry.FactoryNotSet.selector);
        registry.createPerpPool(address(tokenA), address(tokenB), address(tokenA), spot, 3000, _defaultPerpParams());
    }

    // ----------------------------------------------------------------- admin

    function testSetOrderbookOneShot() public {
        vm.prank(owner);
        vm.expectRevert(DexRegistry.OrderbookAlreadySet.selector);
        registry.setOrderbook(address(1));
    }

    function testAdminOnlyOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setMaxLpFeeRate(1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setFactories(address(1), address(0));
        vm.stopPrank();
    }

    function testFactoryOnlyRegistry() public {
        vm.expectRevert(SpotPoolFactory.OnlyRegistry.selector);
        factory.deploy(address(orderbook), address(treasury), address(tokenA), address(tokenB), 3000, bytes32(0));
    }

    function testTreasuryWithdrawOnlyOwner() public {
        tokenA.mint(address(treasury), 5 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        treasury.withdraw(address(tokenA), stranger, 5 ether);
        vm.prank(owner);
        treasury.withdraw(address(tokenA), owner, 5 ether);
        assertEq(tokenA.balanceOf(owner), 5 ether);
    }
}

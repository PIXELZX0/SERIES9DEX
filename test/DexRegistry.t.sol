// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {DexRegistry} from "../src/DexRegistry.sol";
import {Pair} from "../src/Pair.sol";
import {ProtocolTreasury} from "../src/ProtocolTreasury.sol";
import {SpotPool} from "../src/SpotPool.sol";
import {SpotPoolFactory} from "../src/SpotPoolFactory.sol";
import {PairKey} from "../src/libraries/PairKey.sol";
import {PerpParams} from "../src/interfaces/IPerpPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DexRegistryTest is Test {
    DexRegistry internal registry;
    ProtocolTreasury internal treasury;
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
        factory = new SpotPoolFactory(address(registry));
        vm.startPrank(owner);
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

    // -------------------------------------------------------- pair creation

    function testCreatePairAndSpotPool() public {
        address pairAddr = registry.createPair(address(tokenA), address(tokenB), 1e15);
        (address t0, address t1) = _sorted();
        Pair pair = Pair(pairAddr);
        assertEq(pair.base(), t0);
        assertEq(pair.quote(), t1);
        assertEq(registry.getPair(address(tokenA), address(tokenB)), pairAddr);
        assertTrue(registry.isPair(pairAddr));

        address poolXY = pair.createSpotPool(3000);
        assertEq(registry.poolToPair(poolXY), pairAddr);
        assertEq(SpotPool(poolXY).token0(), t0);
        assertEq(SpotPool(poolXY).token1(), t1);
        assertTrue(registry.isSpotPool(poolXY));

        // Second pool, different fee, same pair.
        address poolXY2 = pair.createSpotPool(5000);
        assertEq(registry.poolToPair(poolXY2), pairAddr);
        assertEq(pair.spotPoolsLength(), 2);
    }

    function testCreatePairDedupReverts() public {
        registry.createPair(address(tokenA), address(tokenB), 1e15);
        vm.expectRevert(DexRegistry.PairAlreadyExists.selector);
        registry.createPair(address(tokenB), address(tokenA), 1e15); // reversed order, same pair
    }

    function testGetPairAndPredictRoundTrip() public {
        address predicted = registry.predictPairAddress(address(tokenA), address(tokenB), 1e15);
        address pairAddr = registry.createPair(address(tokenA), address(tokenB), 1e15);
        assertEq(pairAddr, predicted);
        assertEq(registry.getPair(address(tokenA), address(tokenB)), pairAddr);
        assertEq(registry.getPair(address(tokenB), address(tokenA)), pairAddr);
    }

    function testRegisterPoolOnlyPair() public {
        vm.expectRevert(DexRegistry.OnlyPair.selector);
        registry.registerPool(address(1), true);
    }

    function testCreatePairSelfPairReverts() public {
        vm.expectRevert(PairKey.IdenticalTokens.selector);
        registry.createPair(address(tokenA), address(tokenA), 1e15);
    }

    function testCreatePairZeroTokenReverts() public {
        vm.expectRevert(PairKey.ZeroToken.selector);
        registry.createPair(address(tokenA), address(0), 1e15);
    }

    function testCreateSpotPoolFeeGuardrail() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB), 1e15));
        // 5% boundary passes, above reverts.
        pair.createSpotPool(50_000);
        vm.expectRevert(Pair.FeeRateTooHigh.selector);
        pair.createSpotPool(50_001);
    }

    function testCreatePerpPoolRequiresFactory() public {
        Pair pair = Pair(registry.createPair(address(tokenA), address(tokenB), 1e15));
        address spot = pair.createSpotPool(3000);
        vm.expectRevert(Pair.FactoryNotSet.selector);
        pair.createPerpPool(address(tokenA), spot, 3000, _defaultPerpParams());
    }

    // ----------------------------------------------------------------- admin

    function testAdminOnlyOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setMaxLpFeeRate(1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setFactories(address(1), address(0));
        vm.stopPrank();
    }

    function testFactoryOnlyPair() public {
        vm.expectRevert(SpotPoolFactory.NotPair.selector);
        factory.deploy(address(treasury), address(tokenA), address(tokenB), 3000);
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

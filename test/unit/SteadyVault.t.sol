// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SteadyVault} from "steady/core/SteadyVault.sol";
import {SteadyPlanRegistry} from "steady/core/SteadyPlanRegistry.sol";
import {ISteadyVault} from "steady/interfaces/ISteadyVault.sol";
import {ISteadyPlanRegistry} from "steady/interfaces/ISteadyPlanRegistry.sol";

contract SteadyVaultTest is Test {
    SteadyPlanRegistry registry;
    SteadyVault vault;
    MockERC20 tokenIn;
    address tokenOut = makeAddr("tokenOut");

    address owner = makeAddr("owner");
    address funder = makeAddr("funder");

    uint256 constant AMOUNT = 50e6;
    uint64 constant INTERVAL = 7 days;
    uint32 constant EXECUTIONS = 10;

    uint256 planId;

    function setUp() public {
        registry = new SteadyPlanRegistry();
        vault = new SteadyVault(registry);
        tokenIn = new MockERC20("USD Coin", "USDC", 6);

        vm.prank(owner);
        planId = registry.createPlan(address(tokenIn), tokenOut, AMOUNT, INTERVAL, EXECUTIONS);

        tokenIn.mint(owner, 1_000e6);
        tokenIn.mint(funder, 1_000e6);
        vm.prank(owner);
        tokenIn.approve(address(vault), type(uint256).max);
        vm.prank(funder);
        tokenIn.approve(address(vault), type(uint256).max);
    }

    function test_deposit_creditsBalance_andPullsTokens() public {
        vm.prank(owner);
        vault.deposit(planId, 100e6);

        assertEq(vault.balanceOf(planId), 100e6);
        assertEq(tokenIn.balanceOf(address(vault)), 100e6);
        assertEq(tokenIn.balanceOf(owner), 900e6);
    }

    function test_deposit_anyoneCanFund() public {
        vm.prank(funder);
        vault.deposit(planId, 30e6);
        assertEq(vault.balanceOf(planId), 30e6);
        assertEq(tokenIn.balanceOf(address(vault)), 30e6);
    }

    function test_deposit_reverts_zero() public {
        vm.prank(owner);
        vm.expectRevert(ISteadyVault.ZeroAmount.selector);
        vault.deposit(planId, 0);
    }

    function test_deposit_reverts_whenPlanMissing() public {
        vm.prank(owner);
        vm.expectRevert(ISteadyPlanRegistry.PlanDoesNotExist.selector);
        vault.deposit(999, 10e6);
    }

    function test_withdraw_byOwner() public {
        vm.prank(owner);
        vault.deposit(planId, 100e6);

        vm.prank(owner);
        vault.withdraw(planId, 40e6);

        assertEq(vault.balanceOf(planId), 60e6);
        assertEq(tokenIn.balanceOf(owner), 940e6);
    }

    function test_withdraw_reverts_forNonOwner() public {
        vm.prank(owner);
        vault.deposit(planId, 100e6);

        vm.prank(funder);
        vm.expectRevert(ISteadyVault.NotPlanOwner.selector);
        vault.withdraw(planId, 10e6);
    }

    function test_withdraw_reverts_insufficientBalance() public {
        vm.prank(owner);
        vault.deposit(planId, 20e6);

        vm.prank(owner);
        vm.expectRevert(ISteadyVault.InsufficientBalance.selector);
        vault.withdraw(planId, 21e6);
    }

    function testFuzz_deposit_withdraw_accounting(uint256 dep, uint256 wd) public {
        dep = bound(dep, 1, 1_000e6);
        wd = bound(wd, 1, dep);

        vm.startPrank(owner);
        vault.deposit(planId, dep);
        vault.withdraw(planId, wd);
        vm.stopPrank();

        assertEq(vault.balanceOf(planId), dep - wd);
        assertEq(tokenIn.balanceOf(address(vault)), dep - wd);
    }
}

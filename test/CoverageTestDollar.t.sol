// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {TestDollar} from "../src/testnet/TestDollar.sol";

/// The testnet heartbeat/estate token: minting is restricted, transfers and allowances behave like a plain ERC-20.
contract CoverageTestDollarTest is Test {
    TestDollar t;
    address minter = makeAddr("minter");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.prank(minter);
        t = new TestDollar();
    }

    function test_metadata() public view {
        assertEq(t.name(), "Heirloom Test Dollar (testnet)");
        assertEq(t.symbol(), "tHTD");
        assertEq(t.decimals(), 6);
        assertEq(t.minter(), minter);
    }

    function test_only_minter_mints() public {
        vm.prank(minter);
        t.mint(alice, 5e6);
        assertEq(t.balanceOf(alice), 5e6);
        assertEq(t.totalSupply(), 5e6);
        vm.prank(alice);
        vm.expectRevert(bytes("minter"));
        t.mint(alice, 1);
    }

    function test_transfer_moves_balance_and_rejects_overdraft() public {
        vm.prank(minter);
        t.mint(alice, 5e6);
        vm.prank(alice);
        assertTrue(t.transfer(bob, 2e6));
        assertEq(t.balanceOf(alice), 3e6);
        assertEq(t.balanceOf(bob), 2e6);
        vm.prank(alice);
        vm.expectRevert(bytes("balance"));
        t.transfer(bob, 4e6);
    }

    function test_transferFrom_spends_finite_allowance() public {
        vm.prank(minter);
        t.mint(alice, 5e6);
        vm.prank(alice);
        assertTrue(t.approve(bob, 3e6));
        vm.prank(bob);
        assertTrue(t.transferFrom(alice, bob, 2e6));
        assertEq(t.allowance(alice, bob), 1e6);
        vm.prank(bob);
        vm.expectRevert(bytes("allowance"));
        t.transferFrom(alice, bob, 2e6);
    }

    function test_transferFrom_with_infinite_allowance_never_decrements() public {
        vm.prank(minter);
        t.mint(alice, 5e6);
        vm.prank(alice);
        t.approve(bob, type(uint256).max);
        vm.prank(bob);
        t.transferFrom(alice, bob, 5e6);
        assertEq(t.allowance(alice, bob), type(uint256).max);
        assertEq(t.balanceOf(bob), 5e6);
    }

    function test_zero_value_transferFrom_needs_no_allowance() public {
        // The spoof surface Heirloom refuses: anyone can emit Transfer(from = owner, value 0).
        vm.prank(bob);
        assertTrue(t.transferFrom(alice, bob, 0));
    }
}

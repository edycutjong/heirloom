// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {OmniReactiveTest} from "reactive-kit/test/OmniReactiveTest.sol";
import {CronTopics} from "reactive-kit/CronTopics.sol";
import {CallbackResult} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";
import {ProbeReactive} from "../src/probe/ProbeReactive.sol";
import {ProbeCallback} from "../src/probe/ProbeCallback.sol";

contract MockUSDC {
    event Transfer(address indexed from, address indexed to, uint256 value);

    // Zero-value transfer/transferFrom succeed on Circle USDC (simulated on all three Sepolia chains, Day 1).
    function transfer(address to, uint256 v) external returns (bool) {
        emit Transfer(msg.sender, to, v);
        return true;
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        require(v == 0, "no allowance");
        emit Transfer(from, to, v);
        return true;
    }
}

/// Replays the Day-1 Lasna probe locally: same contracts, same subscriptions, same callback path.
contract ProbeTest is OmniReactiveTest {
    uint256 constant BASE_SEPOLIA = 84532;
    uint256 constant ETH_SEPOLIA = 11155111;
    address deployer = makeAddr("deployer");
    address spoofer = makeAddr("spoofer");
    MockUSDC usdcBase;
    MockUSDC usdcEth;
    ProbeCallback cb;
    ProbeReactive rc;

    function setUp() public override {
        super.setUp();
        usdcBase = new MockUSDC();
        usdcEth = new MockUSDC();
        onChain(address(usdcBase), BASE_SEPOLIA);
        onChain(address(usdcEth), ETH_SEPOLIA);
        vm.startPrank(deployer);
        cb = new ProbeCallback(address(proxy));
        rc = new ProbeReactive(BASE_SEPOLIA, address(cb), 3, 4);
        rc.watchToken(BASE_SEPOLIA, address(usdcBase));
        rc.watchToken(ETH_SEPOLIA, address(usdcEth));
        rc.watchAck();
        vm.stopPrank();
        onChain(address(cb), BASE_SEPOLIA);
    }

    function _send(MockUSDC t) internal returns (CallbackResult[] memory) {
        return cycle(deployer, address(t), abi.encodeCall(MockUSDC.transfer, (spoofer, 0)));
    }

    function test_owner_transfer_full_loop_with_ack() public {
        CallbackResult[] memory r = _send(usdcBase);
        assertCallbacks(r, 1);
        assertAllSucceeded(r);
        assertEq(cb.pings(), 1);
        assertEq(cb.lastRvm(), address(rc), "proxy injects the requesting RC");
        assertEq(rc.callbacksSent(), 1);
    }

    function test_eth_sepolia_origin_calls_back_to_base() public {
        CallbackResult[] memory r = _send(usdcEth);
        assertCallbacks(r, 1);
        assertEq(r[0].chainId, BASE_SEPOLIA);
        assertEq(r[0].target, address(cb));
    }

    function test_zero_value_spoof_reaches_react() public {
        // The spoof surface the production filter must refuse (value > 0 + allowlist come first in react()).
        CallbackResult[] memory r =
            cycle(spoofer, address(usdcBase), abi.encodeCall(MockUSDC.transferFrom, (deployer, spoofer, 0)));
        assertCallbacks(r, 1);
    }

    function test_callback_cap_bounds_spend() public {
        for (uint256 i; i < 5; i++) {
            _send(usdcBase);
        }
        assertEq(rc.callbacksSent(), 3);
        assertEq(cb.pings(), 3);
    }

    function test_cron_unsubscribes_itself_after_max_ticks() public {
        vm.prank(deployer);
        rc.cronStart();
        for (uint256 i; i < 6; i++) {
            vm.warp(block.timestamp + 11);
            cron(CronTopics.CRON10);
        }
        assertEq(rc.cronTicks(), 4, "react() unsubscribed itself at tick 4, as on Lasna");
        assertFalse(rc.cronOn());
    }

    function test_forced_revert_rolls_back_its_own_flag() public {
        vm.prank(deployer);
        cb.setFailNext(true);
        CallbackResult[] memory r = _send(usdcBase);
        assertFalse(r[0].success);
        assertTrue(cb.failNext(), "state written by a reverting callback is rolled back (Day-1 lesson)");
        assertEq(cb.pings(), 0);
    }

    function test_only_owner_controls_probe() public {
        vm.expectRevert(ProbeReactive.NotOwner.selector);
        rc.cronStart();
        vm.expectRevert(ProbeCallback.NotOwner.selector);
        cb.setFailNext(true);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {OmniReactiveTest} from "reactive-kit/test/OmniReactiveTest.sol";
import {CronTopics} from "reactive-kit/CronTopics.sol";
import {ProbeReactive} from "../src/probe/ProbeReactive.sol";
import {ProbeCallback} from "../src/probe/ProbeCallback.sol";

/// Deploys both probes, so it is their owner; it has no receive hook, so draining to it fails.
contract RejectingProbeOwner {
    ProbeReactive public rc;
    ProbeCallback public cb;

    function deploy(address proxy) external payable {
        cb = new ProbeCallback{value: 1 ether}(proxy);
        rc = new ProbeReactive{value: 1 ether}(84532, address(cb), 1, 1);
    }

    function drainRc() external {
        rc.drain();
    }

    function drainCb() external {
        cb.drain();
    }
}

/// The Day-1 probes' owner-only lifecycle: manual CRON stop and returning unspent funds.
contract CoverageProbeTest is OmniReactiveTest {
    address deployer = makeAddr("deployer");
    ProbeCallback cb;
    ProbeReactive rc;

    function setUp() public override {
        super.setUp();
        vm.deal(deployer, 10 ether);
        vm.startPrank(deployer);
        cb = new ProbeCallback{value: 1 ether}(address(proxy));
        rc = new ProbeReactive{value: 2 ether}(84532, address(cb), 3, 4);
        vm.stopPrank();
    }

    function test_cronStop_is_the_manual_unsubscribe_fallback() public {
        vm.prank(deployer);
        rc.cronStart();
        assertEq(sys.activeSubscriptions(address(rc)), 1);
        vm.expectEmit(address(rc));
        emit ProbeReactive.CronOff(0, false);
        vm.prank(deployer);
        rc.cronStop();
        assertFalse(rc.cronOn());
        assertEq(sys.activeSubscriptions(address(rc)), 0);
        vm.warp(block.timestamp + 11);
        cron(CronTopics.CRON10);
        assertEq(rc.cronTicks(), 0, "no tick reaches a stopped probe");
    }

    function test_probe_drain_returns_unspent_funds_to_owner() public {
        uint256 before = deployer.balance;
        vm.prank(deployer);
        rc.drain();
        vm.prank(deployer);
        cb.drain();
        assertEq(deployer.balance - before, 3 ether);
        assertEq(address(rc).balance, 0);
        assertEq(address(cb).balance, 0);
    }

    function test_probe_reactive_owner_only_entry_points() public {
        bytes[5] memory calls = [
            abi.encodeCall(ProbeReactive.watchToken, (84532, address(1))),
            abi.encodeCall(ProbeReactive.watchAck, ()),
            abi.encodeCall(ProbeReactive.cronStart, ()),
            abi.encodeCall(ProbeReactive.cronStop, ()),
            abi.encodeCall(ProbeReactive.drain, ())
        ];
        for (uint256 i; i < calls.length; i++) {
            (bool ok, bytes memory ret) = address(rc).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(ret), ProbeReactive.NotOwner.selector);
        }
    }

    function test_probe_callback_drain_rejects_non_owner() public {
        vm.expectRevert(ProbeCallback.NotOwner.selector);
        cb.drain();
    }

    function test_probe_reactive_drain_reverts_when_owner_rejects_eth() public {
        RejectingProbeOwner o = new RejectingProbeOwner();
        o.deploy{value: 2 ether}(address(proxy));
        vm.expectRevert(bytes("drain"));
        o.drainRc();
    }

    function test_probe_callback_drain_reverts_when_owner_rejects_eth() public {
        RejectingProbeOwner o = new RejectingProbeOwner();
        o.deploy{value: 2 ether}(address(proxy));
        vm.expectRevert(bytes("drain"));
        o.drainCb();
    }
}

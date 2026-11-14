// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {CronTopics} from "reactive-kit/CronTopics.sol";
import {AckLedger} from "reactive-kit/AckLedger.sol";
import {CallbackFailureWatch} from "reactive-kit/CallbackFailureWatch.sol";
import {HeirloomReactive} from "../src/HeirloomReactive.sol";
import {HeirloomVault} from "../src/HeirloomVault.sol";
import {HeirloomTypes, IHeirloomVault} from "../src/HeirloomTypes.sol";
import {HeirloomBase} from "./HeirloomBase.sol";

/// A recipient with no receive/fallback: every native transfer to it fails.
contract EthRejector {}

/// External surface for the reactive-kit library functions Heirloom does not call on its own paths.
contract KitLibHarness {
    function alarmBound(AckLedger.Policy memory p, uint64 tick) external pure returns (uint64) {
        return AckLedger.alarmBound(p, tick);
    }

    function argWord(bytes memory p, uint256 n) external pure returns (uint256) {
        return CallbackFailureWatch.argWord(p, n);
    }

    function selectorOf(bytes memory p) external pure returns (bytes4) {
        return CallbackFailureWatch.selectorOf(p);
    }
}

/// Edge paths of HeirloomReactive: every constructor/wiring guard, the reserve views, and the inputs the react()
/// filter must ignore. Each guard has its own test so a single revert can never hide another.
contract CoverageReactiveTest is HeirloomBase {
    uint256 internal constant ACK_T0 = uint256(keccak256("Ack(uint64,uint64,bytes32,bool)"));

    // ================================================================ constructor guards (one revert per test)

    function test_constructor_rejects_zero_owner() public {
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        new HeirloomReactive(address(0), _cfg());
    }

    function test_constructor_rejects_zero_silence_T() public {
        HeirloomReactive.Config memory c = _cfg();
        c.T = 0;
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        new HeirloomReactive(owner, c);
    }

    function test_constructor_rejects_zero_tick_period() public {
        HeirloomReactive.Config memory c = _cfg();
        c.tickPeriod = 0;
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        new HeirloomReactive(owner, c);
    }

    function test_constructor_rejects_non_cron_grace_tier() public {
        HeirloomReactive.Config memory c = _cfg();
        c.graceCronTopic = 123;
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        new HeirloomReactive(owner, c);
    }

    function test_constructor_rejects_disabled_spam_brake() public {
        HeirloomReactive.Config memory c = _cfg();
        c.brakeWindow = 0;
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        new HeirloomReactive(owner, c);
    }

    function test_constructor_rejects_zero_dest_chain() public {
        HeirloomReactive.Config memory c = _cfg();
        c.destChainId = 0;
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        new HeirloomReactive(owner, c);
    }

    function test_constructor_rejects_zero_ack_timeout_as_bad_policy() public {
        HeirloomReactive.Config memory c = _cfg();
        c.ackTimeout = 0;
        vm.expectRevert(AckLedger.BadPolicy.selector);
        new HeirloomReactive(owner, c);
    }

    function test_constructor_accepts_every_real_cron_tier() public {
        uint256[3] memory tiers = [CronTopics.CRON1, CronTopics.CRON1000, CronTopics.CRON10000];
        for (uint256 i; i < tiers.length; i++) {
            HeirloomReactive.Config memory c = _cfg();
            c.cronTopic = tiers[i];
            HeirloomReactive r = new HeirloomReactive(owner, c);
            assertEq(r.cronTopic(), tiers[i]);
        }
    }

    // ================================================================ setVault canary guards

    function test_setVault_rejects_canary_without_aggregator() public {
        HeirloomReactive r = new HeirloomReactive(owner, _cfg());
        HeirloomReactive.TokenRef[] memory refs = new HeirloomReactive.TokenRef[](0);
        HeirloomReactive.CanaryInit[] memory cans = new HeirloomReactive.CanaryInit[](1);
        cans[0] = HeirloomReactive.CanaryInit(BASE, address(0), 100);
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        r.setVault(address(0xBEEF), refs, cans);
    }

    function test_setVault_rejects_canary_with_zero_gap() public {
        HeirloomReactive r = new HeirloomReactive(owner, _cfg());
        HeirloomReactive.TokenRef[] memory refs = new HeirloomReactive.TokenRef[](0);
        HeirloomReactive.CanaryInit[] memory cans = new HeirloomReactive.CanaryInit[](1);
        cans[0] = HeirloomReactive.CanaryInit(BASE, address(agg), 0);
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        r.setVault(address(0xBEEF), refs, cans);
    }

    function test_canaryChains_lists_the_configured_feeds() public {
        _deploy(_cfg(), 100);
        uint256[] memory chains = rc.canaryChains();
        assertEq(chains.length, 1);
        assertEq(chains[0], BASE);
    }

    // ================================================================ reserve: reclaim, receive, runway

    function test_reclaim_reverts_when_recipient_rejects_eth() public {
        _deployDefault();
        ownerCall(abi.encodeCall(HeirloomVault.retire, ()));
        assertPhase(HeirloomTypes.Phase.DONE);
        EthRejector sink = new EthRejector();
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        rc.reclaim(payable(address(sink)));
        assertEq(address(rc).balance, 10 ether, "a failed reclaim keeps the reserve");
    }

    function test_topup_is_counted_as_deposit_not_as_spend() public {
        _deployDefault();
        (bool ok,) = payable(address(rc)).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(rc.depositsSinceAttest(), 1 ether);
        vm.warp(block.timestamp + 1 days);
        assertEq(rc.runwayDays(), type(uint32).max, "nothing spent yet: runway is unbounded");
        vm.deal(address(rc), 10 ether); // the network billed 1 ether of the 11 in one day
        assertEq(rc.runwayDays(), 10, "10 ether left at 1 ether/day, the top-up is not read as spend");
    }

    function test_runway_days_estimate_from_measured_spend() public {
        _deployDefault();
        vm.warp(block.timestamp + 1 days);
        vm.deal(address(rc), 9 ether);
        assertEq(rc.runwayDays(), 9);
        HeirloomReactive.Status memory s = rc.status();
        assertEq(s.runwayDays, 9);
    }

    function test_runway_days_saturates_at_uint32_max() public {
        _deployDefault();
        vm.warp(block.timestamp + 1 days);
        vm.deal(address(rc), 10 ether - 1); // 1 wei per day
        assertEq(rc.runwayDays(), type(uint32).max);
    }

    function test_status_view_mirrors_live_state() public {
        _deployDefault();
        vm.warp(block.timestamp + 5);
        heartbeat(usdcEth, 1e6);
        HeirloomReactive.Status memory s = rc.status();
        assertEq(uint8(s.phase), uint8(HeirloomTypes.Phase.ARMED));
        assertEq(s.lastSeen, rc.lastSeen());
        assertEq(s.lastChain, ETH);
        assertEq(s.lastOriginTx, rc.lastOriginTx());
        assertEq(s.deadline, rc.deadline());
        assertEq(s.graceEndsAt, 0);
        assertEq(s.refusedTotal, 0);
        assertEq(s.brakedCount, 0);
        assertEq(s.cronTopic, CronTopics.CRON10);
        assertFalse(s.pendingOpen);
    }

    // ================================================================ react(): inputs that must be ignored

    function test_stale_ack_for_superseded_seq_does_not_close_pending() public {
        _deployDefault();
        uint64 seq = _openUndelivered();
        deliverAs(_ackLog(seq + 1));
        assertTrue(_pendingOpen(), "an Ack for another seq never closes the open one");
        deliverAs(_ackLog(seq));
        assertFalse(_pendingOpen());
    }

    function test_failure_log_with_foreign_selector_is_ignored() public {
        _deployDefault();
        uint64 seq = _openUndelivered();
        IReactive.LogRecord memory l = failureLog(seq);
        l.data = abi.encode(abi.encodePacked(bytes4(0xdeadbeef), uint256(uint160(address(rc))), uint256(seq)));
        deliverAs(l);
        assertEq(_pendingTries(), 1, "a failure of another vault function is not a sync failure");
    }

    function test_failure_log_with_truncated_payload_is_ignored() public {
        _deployDefault();
        uint64 seq = _openUndelivered();
        IReactive.LogRecord memory l = failureLog(seq);
        l.data = abi.encode(hex"01"); // shorter than a selector
        deliverAs(l);
        l.data = abi.encode(abi.encodePacked(IHeirloomVault.sync.selector, uint256(uint160(address(rc))))); // no seq word
        deliverAs(l);
        assertEq(_pendingTries(), 1, "a payload too short to name our seq never triggers a resend");
    }

    function test_disallow_of_a_non_first_token_compacts_the_watch_set() public {
        _deployDefault();
        ownerCall(abi.encodeCall(HeirloomVault.setAllowlist, (UNI, address(usdcUni), false)));
        HeirloomReactive.TokenRef[] memory t = rc.tokens();
        assertEq(t.length, 2);
        for (uint256 i; i < t.length; i++) {
            assertTrue(t[i].token != address(usdcUni), "the removed token leaves the watch set");
        }
        assertFalse(rc.allowed(UNI, address(usdcUni)));
        assertFalse(rc.subscribed(UNI, address(usdcUni)));
        uint64 before = rc.lastSeen();
        vm.warp(block.timestamp + 10);
        heartbeat(usdcUni, 1e6);
        assertEq(rc.lastSeen(), before, "a transfer of an unwatched token is not proof of life");
    }

    // ================================================================ reactive-kit library edges

    function test_alarm_bound_rounds_each_try_up_to_whole_ticks() public {
        KitLibHarness h = new KitLibHarness();
        assertEq(h.alarmBound(AckLedger.Policy({ackTimeout: 30, fastTries: 3, slowEvery: 600}), 11), 99);
    }

    function test_failure_argWord_rejects_short_payload() public {
        KitLibHarness h = new KitLibHarness();
        assertEq(h.selectorOf(hex"0102"), bytes4(0), "under 4 bytes there is no selector");
        vm.expectRevert(bytes("CallbackFailureWatch: short payload"));
        h.argWord(hex"01020304", 0);
    }

    // ================================================================ helpers

    /// Past the deadline, deliver one tick by hand so GRACE is requested but never delivered (no Ack).
    function _openUndelivered() internal returns (uint64 seq) {
        vm.warp(rc.deadline() + 1);
        IReactive.LogRecord memory tick;
        tick.chainId = block.chainid;
        tick.contractAddress = CronTopics.LEGACY_SYSTEM_ADDR;
        tick.topic0 = CronTopics.CRON10;
        tick.opCode = 1;
        deliverAs(tick);
        seq = _pendingSeq();
        assertTrue(_pendingOpen());
        assertEq(_pendingTries(), 1);
    }

    function _ackLog(uint64 seq) internal view returns (IReactive.LogRecord memory l) {
        l.chainId = BASE;
        l.contractAddress = address(vault);
        l.topic0 = ACK_T0;
        l.topic1 = seq;
        l.data = abi.encode(rc.ownerNonceSeen(), rc.ownerActionIdSeen(), false);
        l.opCode = 2;
        l.txHash = uint256(keccak256(abi.encode("ack", seq, block.timestamp)));
    }
}

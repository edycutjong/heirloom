// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {CallbackResult} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";
import {CronTopics} from "reactive-kit/CronTopics.sol";
import {HeirloomReactive} from "../src/HeirloomReactive.sol";
import {HeirloomVault} from "../src/HeirloomVault.sol";
import {HeirloomTypes} from "../src/HeirloomTypes.sol";
import {HeirloomBase, TestToken} from "./HeirloomBase.sol";

/// P1b items 1-5 and 7-8: filter, lastSeen, silence, grace (+ grace Cron), canary freeze, attest, resend.
contract HeirloomReactiveTest is HeirloomBase {
    function setUp() public override {
        super.setUp();
        _deployDefault();
    }

    // ================================================================ 1. allowlist + value > 0 filter (H2, H6)

    function test_spoof_zero_value() public {
        uint64 before = rc.lastSeen();
        vm.warp(block.timestamp + 50);
        CallbackResult[] memory r = spoof(usdcBase);
        assertCallbacks(r, 0);
        assertEq(rc.lastSeen(), before, "a refused log never resets lastSeen (I1)");
        assertEq(rc.refusedTotal(), 1);
        assertEq(rc.refusedBy(HeirloomReactive.Refusal.ZERO_VALUE), 1);
    }

    function test_spoof_not_allowlisted() public {
        // Enumerated mode never delivers a non-subscribed token; deliver it by hand (the wildcard variant would).
        IReactive.LogRecord memory l = _transferLog(BASE, address(fakeToken), owner, 5);
        deliverAs(l);
        assertEq(rc.refusedBy(HeirloomReactive.Refusal.NOT_ALLOWLISTED), 1);
        assertEq(rc.lastSeen(), T0);
    }

    function test_spoof_malformed_shape() public {
        IReactive.LogRecord memory l = _transferLog(BASE, address(usdcBase), owner, 5);
        l.opCode = 4; // e.g. an ERC-721-shaped Transfer (tokenId indexed)
        deliverAs(l);
        l = _transferLog(BASE, address(usdcBase), owner, 5);
        l.data = abi.encode(uint256(5), uint256(6));
        deliverAs(l);
        assertEq(rc.refusedBy(HeirloomReactive.Refusal.MALFORMED), 2);
        assertEq(rc.lastSeen(), T0);
    }

    function test_spoof_wrong_owner_topic() public {
        deliverAs(_transferLog(BASE, address(usdcBase), stranger, 5));
        assertEq(rc.refusedBy(HeirloomReactive.Refusal.NOT_OWNER), 1);
    }

    function test_refused_react_gas_ceiling() public {
        // Steady state (second refusal in the window; the first pays one-time zero->nonzero SSTOREs).
        deliverAs(_transferLog(BASE, address(usdcBase), owner, 0));
        IReactive.LogRecord memory l = _transferLog(BASE, address(usdcBase), owner, 0);
        vm.prank(SYSTEM_ADDR);
        uint256 g = gasleft();
        rc.react(l);
        uint256 used = g - gasleft();
        // The filter runs first: a refused react never touches the clock, canaries or callbacks.
        assertLt(used, 60_000, "refused react above the gas ceiling");
        emit log_named_uint("refused react gas (steady state)", used);
        // ...and it is far cheaper than an accepted heartbeat react
        l = _transferLog(BASE, address(usdcBase), owner, 1);
        vm.prank(SYSTEM_ADDR);
        g = gasleft();
        rc.react(l);
        emit log_named_uint("accepted heartbeat react gas", g - gasleft());
    }

    function test_spam_brake() public {
        for (uint256 i; i < MAX_REFUSED - 1; i++) spoof(usdcBase);
        assertTrue(rc.subscribed(BASE, address(usdcBase)));
        spoof(usdcBase);
        (,, uint64 until) = rc.brakes(BASE, address(usdcBase));
        assertEq(until, block.timestamp + BRAKE_WINDOW);
        assertFalse(rc.subscribed(BASE, address(usdcBase)), "braked token unsubscribed");
        assertEq(rc.brakedCount(), 1);
        // further spoofs are no longer delivered at all (bounded spend)
        uint32 refused = rc.refusedTotal();
        spoof(usdcBase);
        assertEq(rc.refusedTotal(), refused);
        // the vault channel is never braked: ping still counts
        vm.warp(block.timestamp + 5);
        ownerCall(abi.encodeCall(HeirloomVault.ping, ()));
        assertEq(rc.lastSeen(), block.timestamp);
    }

    function test_brake_window_resets() public {
        for (uint256 i; i < MAX_REFUSED - 1; i++) spoof(usdcBase);
        vm.warp(block.timestamp + BRAKE_WINDOW);
        spoof(usdcBase); // new window: 1 of 20
        assertEq(rc.brakedCount(), 0);
    }

    function test_brake_lift() public {
        for (uint256 i; i < MAX_REFUSED; i++) spoof(usdcBase);
        (,, uint64 until) = rc.brakes(BASE, address(usdcBase));
        tickAt(until - 1);
        assertEq(rc.brakedCount(), 1, "not before brakedUntil");
        vm.expectEmit(true, true, false, true, address(rc));
        emit HeirloomReactive.ObservationReset(BASE, address(usdcBase), until + TICK);
        tickAt(until + TICK);
        assertEq(rc.brakedCount(), 0);
        assertTrue(rc.subscribed(BASE, address(usdcBase)), "re-subscribed on lift");
    }

    function test_brake_lift_respects_allowlist() public {
        for (uint256 i; i < MAX_REFUSED; i++) spoof(usdcBase);
        // owner removes the braked token while it is braked
        ownerCall(abi.encodeCall(HeirloomVault.setAllowlist, (BASE, address(usdcBase), false)));
        assertEq(rc.brakedCount(), 0);
        tickAt(block.timestamp + BRAKE_WINDOW + TICK);
        assertFalse(rc.subscribed(BASE, address(usdcBase)), "a removed token stays unsubscribed after the lift");
        assertFalse(rc.allowed(BASE, address(usdcBase)));
    }

    function test_brake_blocks_transitions() public {
        vm.warp(T0 + T_ - 100);
        for (uint256 i; i < MAX_REFUSED; i++) spoof(usdcBase);
        tickAt(T0 + T_ + TICK);
        assertPhase(HeirloomTypes.Phase.ARMED); // past the deadline, but a token is braked
    }

    function test_brake_lift_restarts_T() public {
        vm.warp(T0 + 100);
        for (uint256 i; i < MAX_REFUSED; i++) spoof(usdcBase);
        uint64 lift = uint64(T0 + 100 + BRAKE_WINDOW + TICK);
        tickAt(lift);
        assertEq(rc.observedFrom(), lift);
        assertEq(rc.deadline(), lift + T_);
        tickAt(T0 + T_ + TICK + BRAKE_WINDOW); // past the original deadline
        assertPhase(HeirloomTypes.Phase.ARMED);
    }

    function test_missed_transfer_during_brake_no_early_release() public {
        // Owner transfers while the token is braked (unsubscribed => never delivered). The release clock must not
        // count the blind interval as silence.
        vm.warp(T0 + 500);
        for (uint256 i; i < MAX_REFUSED; i++) spoof(usdcBase);
        heartbeat(usdcBase, 1e6); // invisible
        assertEq(rc.lastSeen(), T0);
        runUntil(T0 + 500 + BRAKE_WINDOW + T_ - TICK);
        assertPhase(HeirloomTypes.Phase.ARMED);
        assertVault(HeirloomTypes.VaultState.ARMED);
    }

    function test_brake_in_grace_returns_to_armed() public {
        runUntil(rc.deadline() + TICK);
        assertPhase(HeirloomTypes.Phase.GRACE);
        assertVault(HeirloomTypes.VaultState.GRACE);
        for (uint256 i; i < MAX_REFUSED; i++) spoof(usdcBase);
        assertPhase(HeirloomTypes.Phase.ARMED);
        assertVault(HeirloomTypes.VaultState.ARMED);
    }

    // ================================================================ 2. lastSeen per chain

    function test_heartbeat_updates_lastSeen_per_chain() public {
        TestToken[3] memory toks = [usdcBase, usdcEth, usdcUni];
        uint256[3] memory chains = [BASE, ETH, UNI];
        for (uint256 i; i < 3; i++) {
            vm.warp(T0 + 100 * (i + 1));
            CallbackResult[] memory r = heartbeat(toks[i], 1e6);
            assertCallbacks(r, 0); // ARMED: life is recorded, no callback needed
            assertEq(rc.lastSeen(), block.timestamp);
            assertEq(rc.lastChain(), chains[i]);
            assertEq(rc.lastToken(), address(toks[i]));
            assertEq(rc.deadline(), block.timestamp + T_);
        }
    }

    function test_cron_and_canary_never_reset_lastSeen() public {
        tickAt(T0 + 50);
        assertEq(rc.lastSeen(), T0);
        beat();
        assertEq(rc.lastSeen(), T0);
    }

    function test_ping_is_proof_of_life() public {
        vm.warp(T0 + 77);
        ownerCall(abi.encodeCall(HeirloomVault.ping, ()));
        assertEq(rc.lastSeen(), T0 + 77);
        assertEq(rc.lastChain(), BASE);
        assertEq(rc.ownerNonceSeen(), 1);
    }

    // ================================================================ 3. slow-Cron silence check

    function test_no_grace_before_T() public {
        runUntil(T0 + T_);
        assertPhase(HeirloomTypes.Phase.ARMED);
    }

    function test_grace_after_T() public {
        CallbackResult[] memory r = tickAt(T0 + T_ + 1);
        assertPhase(HeirloomTypes.Phase.GRACE);
        assertCallbacks(r, 1);
        assertAllSucceeded(r);
        assertEq(r[0].chainId, BASE);
        assertEq(r[0].target, address(vault));
        assertVault(HeirloomTypes.VaultState.GRACE);
        assertEq(vault.graceEndsAt(), T0 + T_ + 1 + GRACE);
        assertFalse(_pendingOpen(), "Ack fed back and closed the pending slot");
    }

    function test_heartbeat_pushes_deadline() public {
        vm.warp(T0 + 400);
        heartbeat(usdcEth, 1);
        tickAt(T0 + T_ + 1);
        assertPhase(HeirloomTypes.Phase.ARMED);
        tickAt(T0 + 400 + T_ + 1);
        assertPhase(HeirloomTypes.Phase.GRACE);
    }

    function test_tick_before_setVault_is_noop() public {
        HeirloomReactive fresh = new HeirloomReactive(owner, _cfg());
        IReactive.LogRecord memory l;
        l.chainId = block.chainid;
        l.contractAddress = CronTopics.LEGACY_SYSTEM_ADDR;
        l.topic0 = CronTopics.CRON10;
        vm.warp(T0 + 10_000);
        vm.prank(SYSTEM_ADDR);
        fresh.react(l);
        assertEq(uint8(fresh.phase()), uint8(HeirloomTypes.Phase.ARMED));
        assertEq(fresh.nextSeq(), 0);
    }

    // ================================================================ 4. grace + owner cancel

    function test_cancel_by_transfer_in_grace() public {
        tickAt(T0 + T_ + 1);
        vm.warp(block.timestamp + 60);
        CallbackResult[] memory r = heartbeat(usdcUni, 1);
        assertCallbacks(r, 1);
        assertAllSucceeded(r);
        assertPhase(HeirloomTypes.Phase.ARMED);
        assertVault(HeirloomTypes.VaultState.ARMED);
        assertEq(vault.lastChainMirror(), UNI, "the CANCEL snapshot carries the proof of life");
    }

    function test_cancel_by_ping_in_grace() public {
        tickAt(T0 + T_ + 1);
        ownerCall(abi.encodeCall(HeirloomVault.ping, ()));
        assertVault(HeirloomTypes.VaultState.ARMED); // Base-side reset, immediately
        assertPhase(HeirloomTypes.Phase.ARMED); // RC saw OwnerActive -> CANCEL
    }

    function test_spoof_in_grace_does_not_cancel() public {
        tickAt(T0 + T_ + 1);
        spoof(usdcBase);
        assertPhase(HeirloomTypes.Phase.GRACE);
        assertVault(HeirloomTypes.VaultState.GRACE);
    }

    // ================================================================ 5. canary freeze (H1)

    function test_freeze_once() public {
        _redeploy(100); // armWindow = 2*11 + 2*100 = 222 < T: armed near the deadline
        runUntil(T0 + T_ - 222 + TICK);
        (,,,, bool armed) = rc.canaries(BASE);
        assertTrue(armed, "armed inside the window");
        // the canary stays silent (simulated network outage): stale at the deadline
        runUntil(T0 + T_ + TICK);
        assertPhase(HeirloomTypes.Phase.ARMED);
        assertTrue(rc.epochFreezeUsed());
        assertEq(rc.deadline(), T0 + T_ + FREEZE);
    }

    function test_freeze_not_twice() public {
        _redeploy(100);
        runUntil(T0 + T_ + TICK);
        assertTrue(rc.epochFreezeUsed());
        runUntil(T0 + T_ + FREEZE + TICK);
        assertPhase(HeirloomTypes.Phase.GRACE); // still stale, but the cap is spent
    }

    function test_freeze_resets_on_activity() public {
        _redeploy(100);
        runUntil(T0 + T_ + TICK);
        assertTrue(rc.epochFreezeUsed());
        heartbeat(usdcBase, 1);
        assertFalse(rc.epochFreezeUsed(), "real activity starts a new epoch");
        (,,,, bool armed) = rc.canaries(BASE);
        assertFalse(armed, "activity unsubscribes the canary");
    }

    function test_brake_lift_starts_fresh_freeze_epoch() public {
        _redeploy(100);
        runUntil(T0 + T_ + TICK);
        assertTrue(rc.epochFreezeUsed());
        for (uint256 i; i < MAX_REFUSED; i++) spoof(usdcBase);
        uint64 lift = uint64(block.timestamp + BRAKE_WINDOW + TICK);
        tickAt(lift);
        assertFalse(rc.epochFreezeUsed(), "the lift starts a new epoch");
        assertEq(rc.deadline(), lift + T_, "no extension carried over from the old epoch");
    }

    function test_no_freeze_with_healthy_canary() public {
        _redeploy(100);
        while (block.timestamp < T0 + T_ + TICK) {
            tickAt(block.timestamp + TICK);
            if (block.timestamp % 55 < TICK) beat();
        }
        assertFalse(rc.epochFreezeUsed());
        assertPhase(HeirloomTypes.Phase.GRACE);
        (,,, uint64 seen, bool armed) = rc.canaries(BASE);
        assertLe(seen, 100, "healthy gaps only");
        assertFalse(armed, "disarmed after the check");
    }

    function test_canary_outage_that_ended_still_counts() public {
        _redeploy(100);
        runUntil(T0 + T_ - 222 + TICK); // armed
        runUntil(block.timestamp + 150); // 150 s gap > maxGap 100 ...
        beat(); // ... closed just before the deadline
        runUntil(T0 + T_ + TICK);
        assertTrue(rc.epochFreezeUsed(), "maxGapSeen catches an outage that already ended");
    }

    function test_no_freeze_without_canary() public {
        runUntil(T0 + T_ + TICK); // default deploy has no canary entry
        assertFalse(rc.epochFreezeUsed());
        assertPhase(HeirloomTypes.Phase.GRACE);
    }

    function test_canary_always_on_when_T_shorter_than_window() public {
        _redeploy(3633); // measured Base Sepolia maxGap: window >> T (demo instance)
        (,,,, bool armed) = rc.canaries(BASE);
        assertTrue(armed, "subscribed from setVault");
        beat();
        heartbeat(usdcBase, 1);
        (,,,, armed) = rc.canaries(BASE);
        assertTrue(armed, "no arm/disarm churn");
    }

    // ================================================================ 7. weekly attest

    function test_attest_cadence() public {
        runUntil(T0 + ATTEST - 1);
        assertEq(vault.lastAppliedSeq(), 0);
        heartbeat(usdcBase, 1); // keeps the instance alive through 3 periods
        runUntil(T0 + ATTEST + TICK);
        assertEq(vault.lastAppliedSeq(), 1, "first attest");
        assertEq(uint8(rc.pendingKind()), uint8(HeirloomTypes.Kind.ATTEST));
        assertEq(vault.lastSeenMirror(), rc.lastSeen());
        vm.warp(block.timestamp + 1);
        heartbeat(usdcBase, 1);
        runUntil(T0 + 2 * ATTEST + 2 * TICK);
        assertEq(vault.lastAppliedSeq(), 2, "second attest");
        assertVault(HeirloomTypes.VaultState.ARMED);
    }

    function test_attest_skipped_when_pending() public {
        injectOverride = stranger; // every callback fails auth: nothing is ever acked
        tickAt(T0 + T_ + 1); // GRACE sent, un-acked
        uint64 seq = _pendingSeq();
        tickAt(T0 + T_ + 2); // attest due (> ATTEST since setVault) but a state change is pending
        assertEq(_pendingSeq(), seq, "attest never overwrites a pending state change");
        assertEq(uint8(rc.pendingKind()), uint8(HeirloomTypes.Kind.GRACE));
    }

    function test_grace_overwrites_attest() public {
        injectOverride = stranger;
        tickAt(T0 + ATTEST + 1); // ATTEST sent, un-acked
        assertEq(uint8(rc.pendingKind()), uint8(HeirloomTypes.Kind.ATTEST));
        uint64 attestSeq = _pendingSeq();
        tickAt(T0 + T_ + 1);
        assertEq(uint8(rc.pendingKind()), uint8(HeirloomTypes.Kind.GRACE));
        assertGt(_pendingSeq(), attestSeq);
        injectOverride = address(0);
        tickAt(T0 + T_ + 1 + ACK); // resend lands
        assertVault(HeirloomTypes.VaultState.GRACE);
    }

    // ================================================================ 8. resend + CallbackFailure (capped)

    function test_no_resend_before_ack_timeout() public {
        injectOverride = stranger;
        tickAt(T0 + T_ + 1);
        assertEq(_pendingTries(), 1);
        tickAt(T0 + T_ + 1 + ACK - 1);
        assertEq(_pendingTries(), 1, "no resend before a full ackTimeout");
        tickAt(T0 + T_ + 1 + ACK);
        assertEq(_pendingTries(), 2);
        tickAt(T0 + T_ + 1 + ACK + 11);
        assertEq(_pendingTries(), 2, "sentAt reset on every try");
    }

    function test_resend_backoff_after_3() public {
        injectOverride = stranger; // nothing is ever acked
        uint256 t = T0 + ATTEST + 1;
        tickAt(t); // ATTEST sent (try 1)
        assertEq(uint8(rc.pendingKind()), uint8(HeirloomTypes.Kind.ATTEST));
        tickAt(t += ACK);
        tickAt(t += ACK);
        assertEq(_pendingTries(), 3);
        tickAt(t += ACK); // try 4 = first past the fast budget: CallbackStuck
        assertEq(_pendingTries(), 4);
        vm.warp(t + 9);
        heartbeat(usdcBase, 1); // keep the instance ARMED (no state change, no new seq)
        tickAt(t + ACK);
        assertEq(_pendingTries(), 4, "past 3 tries: one resend per attestEvery");
        tickAt(t + ATTEST - 1);
        assertEq(_pendingTries(), 4);
        tickAt(t + ATTEST);
        assertEq(_pendingTries(), 5);
        assertEq(uint8(rc.pendingKind()), uint8(HeirloomTypes.Kind.ATTEST));
    }

    function test_stuck_alarm_emitted_once() public {
        injectOverride = stranger;
        uint256 t = T0 + ATTEST + 1;
        tickAt(t);
        tickAt(t += ACK);
        tickAt(t += ACK);
        vm.warp(t += ACK);
        uint64 seq = _pendingSeq();
        vm.expectEmit(true, false, false, false, address(rc));
        emit HeirloomReactive.CallbackStuck(seq);
        deliverAs(_cronLog());
        runCallbacks();
        vm.warp(t + 9);
        heartbeat(usdcBase, 1);
        vm.warp(t + ATTEST);
        vm.recordLogs();
        deliverAs(_cronLog());
        assertEq(_pendingTries(), 5);
        assertEq(_countRc(HeirloomReactive.CallbackStuck.selector), 0, "alarm only on the first slow resend");
    }

    function test_resend_delivers_after_outage() public {
        injectOverride = stranger;
        tickAt(T0 + T_ + 1);
        assertVault(HeirloomTypes.VaultState.ARMED);
        injectOverride = address(0);
        tickAt(T0 + T_ + 1 + ACK);
        assertVault(HeirloomTypes.VaultState.GRACE);
        assertFalse(_pendingOpen());
    }

    function test_callback_failure_immediate_resend() public {
        injectOverride = stranger;
        tickAt(T0 + T_ + 1);
        uint64 seq = _pendingSeq();
        injectOverride = address(0);
        IReactive.LogRecord memory f = failureLog(seq);
        deliverAs(f);
        assertEq(_pendingTries(), 2, "resent on the failure log, before ackTimeout");
        (CallbackResult[] memory r,) = runCallbacks();
        assertCallbacks(r, 1);
        assertAllSucceeded(r);
        assertVault(HeirloomTypes.VaultState.GRACE);
    }

    function test_callback_failure_resend_capped() public {
        injectOverride = stranger;
        tickAt(T0 + T_ + 1);
        uint64 seq = _pendingSeq();
        for (uint256 i; i < 10; i++) {
            deliverAs(failureLog(seq));
            runCallbacks();
        }
        assertEq(_pendingTries(), 4, "failure-driven resends stop past the fast budget");
    }

    function test_callback_failure_for_old_seq_ignored() public {
        injectOverride = stranger;
        tickAt(T0 + T_ + 1);
        deliverAs(failureLog(_pendingSeq() + 7));
        assertEq(_pendingTries(), 1);
    }

    function test_callback_target_base_only() public {
        uint256 t = T0 + T_ + 1;
        CallbackResult[] memory a = tickAt(t);
        CallbackResult[] memory b = heartbeat(usdcEth, 1);
        CallbackResult[] memory c = tickAt(t + ATTEST);
        CallbackResult[][3] memory all = [a, b, c];
        uint256 n;
        for (uint256 k; k < 3; k++) {
            for (uint256 i; i < all[k].length; i++) {
                assertEq(all[k][i].chainId, BASE);
                assertEq(all[k][i].target, address(vault));
                assertEq(all[k][i].gasLimit, rc.CALLBACK_GAS());
                n++;
            }
        }
        assertGt(n, 2);
    }

    // ================================================================ grace Cron (armed only during grace)

    function test_grace_cron_armed_only_during_grace() public {
        HeirloomReactive.Config memory c = _cfg();
        c.cronTopic = CronTopics.CRON100;
        c.graceCronTopic = CronTopics.CRON10;
        _deploy(c, 0);
        uint256 base = sys.activeSubscriptions(address(rc));
        vm.warp(T0 + T_ + 1);
        cron(CronTopics.CRON10); // not subscribed yet: no-op
        assertPhase(HeirloomTypes.Phase.ARMED);
        cron(CronTopics.CRON100);
        assertPhase(HeirloomTypes.Phase.GRACE);
        assertEq(sys.activeSubscriptions(address(rc)), base + 1, "grace Cron subscribed");
        vm.warp(block.timestamp + 30);
        heartbeat(usdcBase, 1);
        assertEq(sys.activeSubscriptions(address(rc)), base, "grace Cron unsubscribed on cancel");
        // expiry path also disarms it
        vm.warp(rc.deadline() + 1);
        cron(CronTopics.CRON100);
        vm.warp(rc.graceEndsAt() + 1);
        cron(CronTopics.CRON10); // the fast tier drives the expiry
        assertPhase(HeirloomTypes.Phase.EXPIRED);
        assertEq(sys.activeSubscriptions(address(rc)), base);
    }

    // ================================================================ setup guards

    function test_owner_not_deployer_rc() public {
        assertEq(rc.owner(), owner);
        assertEq(rc.deployer(), address(this));
        HeirloomReactive other = new HeirloomReactive(owner, _cfg());
        HeirloomReactive.TokenRef[] memory none;
        HeirloomReactive.CanaryInit[] memory nc;
        vm.prank(owner);
        vm.expectRevert(HeirloomReactive.NotDeployer.selector);
        other.setVault(address(vault), none, nc);
        vm.expectRevert(HeirloomReactive.AlreadyWired.selector);
        rc.setVault(address(vault), none, nc);
    }

    function test_react_only_from_system() public {
        IReactive.LogRecord memory l;
        vm.expectPartialRevert(AbstractPayer.NotAuthorized.selector);
        rc.react(l);
    }

    function test_bad_config_rejected() public {
        HeirloomReactive.Config memory c = _cfg();
        c.cronTopic = 123;
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        new HeirloomReactive(owner, c);
        c = _cfg();
        c.ackTimeout = ATTEST + 1; // slow cadence must be >= ackTimeout
        vm.expectRevert();
        new HeirloomReactive(owner, c);
    }

    function test_allowlist_add_subscribes_and_caps() public {
        TestToken extra = new TestToken();
        onChain(address(extra), ETH);
        ownerCall(abi.encodeCall(HeirloomVault.setAllowlist, (ETH, address(extra), true)));
        assertTrue(rc.subscribed(ETH, address(extra)));
        extra.mint(owner, 1);
        vm.warp(block.timestamp + 9);
        heartbeat(extra, 1);
        assertEq(rc.lastToken(), address(extra));
        assertEq(rc.tokens().length, 4);
    }

    // ================================================================ QA r2 fixes

    function test_unarmed_canary_at_deadline_fails_closed() public {
        _redeploy(100); // arm window 222 s before the deadline
        tickAt(T0 + 10);
        tickAt(T0 + T_ + 5); // ticks paused through the whole arm window
        assertTrue(rc.epochFreezeUsed(), "a canary never armed by the deadline spends the freeze");
        assertPhase(HeirloomTypes.Phase.ARMED);
        tickAt(T0 + T_ + FREEZE + 6);
        assertPhase(HeirloomTypes.Phase.GRACE); // once only
    }

    function test_canary_arrival_advances_lastAt() public {
        _redeploy(3633); // always on
        (,, uint64 armedAt,,) = rc.canaries(BASE);
        vm.warp(block.timestamp + 40);
        beat();
        (,, uint64 lastAt, uint64 gapSeen,) = rc.canaries(BASE);
        assertEq(lastAt, armedAt + 40, "a real arrival advances lastAt past arming");
        assertEq(gapSeen, 40);
    }

    function test_no_double_send_when_transition_supersedes_resend() public {
        injectOverride = stranger;
        tickAt(T0 + ATTEST + 1); // ATTEST pending, un-acked
        CallbackResult[] memory r = tickAt(T0 + T_ + 1); // resend due AND grace fires
        assertCallbacks(r, 1);
        assertEq(uint8(rc.pendingKind()), uint8(HeirloomTypes.Kind.GRACE));
        assertEq(_pendingTries(), 1);
    }

    function test_rc_allowlist_cap() public {
        for (uint256 i; i < 5; i++) {
            ownerCall(abi.encodeCall(HeirloomVault.setAllowlist, (ETH, address(uint160(0x1000 + i)), true)));
        }
        assertEq(rc.tokens().length, 8);
        // a 9th can only come from a vault/RC mismatch: deliver it by hand
        IReactive.LogRecord memory l;
        l.chainId = BASE;
        l.contractAddress = address(vault);
        l.topic0 = uint256(keccak256("AllowlistChanged(uint256,address,bool)"));
        l.topic1 = ETH;
        l.topic2 = uint256(uint160(address(0x2000)));
        l.data = abi.encode(true);
        l.opCode = 3;
        deliverAs(l);
        assertEq(rc.tokens().length, 8);
        assertFalse(rc.allowed(ETH, address(0x2000)));
        assertFalse(rc.subscribed(ETH, address(0x2000)));
    }

    function test_config_guards() public {
        HeirloomReactive.Config memory c = _cfg();
        c.graceCronTopic = c.cronTopic; // would unsubscribe the main tier on cancel
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        new HeirloomReactive(owner, c);
        c = _cfg();
        c.brakeWindow = 0;
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        new HeirloomReactive(owner, c);
        c = _cfg();
        c.maxRefusedPerWindow = 0;
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        new HeirloomReactive(owner, c);
        c = _cfg();
        c.destChainId = 0;
        vm.expectRevert(HeirloomReactive.BadConfig.selector);
        new HeirloomReactive(owner, c);
    }

    function test_brake_lift_starts_fresh_canary_epoch() public {
        _redeploy(100);
        runUntil(T0 + T_ - 222 + TICK); // armed near the deadline
        (,,,, bool armed) = rc.canaries(BASE);
        assertTrue(armed);
        for (uint256 i; i < MAX_REFUSED; i++) spoof(usdcBase);
        (,, uint64 until) = rc.brakes(BASE, address(usdcBase));
        tickAt(until + 1);
        (,,,, armed) = rc.canaries(BASE);
        assertFalse(armed, "lift = new epoch: the near-deadline canary is unsubscribed");
    }

    // ================================================================ helpers

    function _cronLog() internal view returns (IReactive.LogRecord memory l) {
        l.chainId = block.chainid;
        l.contractAddress = CronTopics.LEGACY_SYSTEM_ADDR;
        l.topic0 = CronTopics.CRON10;
        l.opCode = 1;
        l.txHash = uint256(keccak256(abi.encode("cron", block.timestamp)));
    }

    function _countRc(bytes32 sel) internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(rc) && logs[i].topics.length > 0 && logs[i].topics[0] == sel) n++;
        }
    }

    function _redeploy(uint64 canaryGap) internal {
        vm.warp(T0);
        _deploy(_cfg(), canaryGap);
    }

    function _transferLog(uint256 chainId, address token, address from, uint256 v)
        internal
        view
        returns (IReactive.LogRecord memory l)
    {
        l.chainId = chainId;
        l.contractAddress = token;
        l.topic0 = uint256(keccak256("Transfer(address,address,uint256)"));
        l.topic1 = uint256(uint160(from));
        l.topic2 = uint256(uint160(stranger));
        l.data = abi.encode(v);
        l.opCode = 3;
        l.txHash = uint256(keccak256(abi.encode(token, v, block.timestamp)));
    }
}

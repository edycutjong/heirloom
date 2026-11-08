// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {CallbackResult} from "reactive-test-lib/interfaces/IReactiveInterfaces.sol";
import {HeirloomReactive} from "../src/HeirloomReactive.sol";
import {HeirloomVault} from "../src/HeirloomVault.sol";
import {HeirloomTypes} from "../src/HeirloomTypes.sol";
import {HeirloomBase, TestToken} from "./HeirloomBase.sol";

/// P1b item 6 (expiry -> heir two-step claim on the Base vault) + callback auth, versioning, teardown, and the
/// two end-to-end flows the Lasna run repeats on real chains.
contract HeirloomVaultTest is HeirloomBase {
    function setUp() public override {
        super.setUp();
        _deployDefault();
        ownerCall(abi.encodeCall(HeirloomVault.deposit, (address(usdcBase), 4e6)));
    }

    // ================================================================ callback auth (A1, A13, I10)

    function test_sync_direct_call_reverts() public {
        HeirloomTypes.Snapshot memory s = _snap(99, HeirloomTypes.Phase.EXPIRED);
        vm.expectPartialRevert(AbstractPayer.NotAuthorized.selector);
        vault.sync(address(rc), s); // anyone passing the RC as first arg is still not the proxy
    }

    function test_sync_wrong_rvm_reverts() public {
        // Through the real proxy, but the injected identity is not the measured callbackSender (the RC).
        (bool ok, bytes memory ret) = proxy.executeCallback(
            address(vault), abi.encodeCall(HeirloomVault.sync, (address(0), _snap(5, HeirloomTypes.Phase.GRACE))), 1e6, address(this)
        );
        assertFalse(ok);
        assertEq(bytes4(ret), AbstractCallback.CallbackNotAuthorized.selector);
        assertEq(vault._CALLBACK_SENDER(), address(rc), "callbackSender = the RC (Day-1 measured identity)");
    }

    function testFuzz_forged_sync_rejected(address injected, uint64 seq) public {
        vm.assume(injected != address(rc));
        (bool ok,) = proxy.executeCallback(
            address(vault), abi.encodeCall(HeirloomVault.sync, (address(0), _snap(seq, HeirloomTypes.Phase.EXPIRED))), 1e6, injected
        );
        assertFalse(ok);
        assertEq(vault.lastAppliedSeq(), 0);
    }

    function test_forged_max_seq_rejected() public {
        HeirloomTypes.Snapshot memory s = _snap(type(uint64).max, HeirloomTypes.Phase.ARMED);
        vm.prank(stranger);
        vm.expectPartialRevert(AbstractPayer.NotAuthorized.selector);
        vault.sync(address(rc), s);
        assertEq(vault.lastAppliedSeq(), 0, "a forged max seq can never wedge later snapshots");
    }

    function test_replayed_seq_only_acks() public {
        _proxySync(_snap(3, HeirloomTypes.Phase.ARMED));
        assertEq(vault.lastAppliedSeq(), 3);
        HeirloomTypes.Snapshot memory g = _snap(2, HeirloomTypes.Phase.GRACE);
        _proxySync(g);
        assertVault(HeirloomTypes.VaultState.ARMED); // stale seq ignored
    }

    // ================================================================ version (A2, A9)

    function test_stale_snapshot_after_ping_rejected() public {
        tickAt(T0 + T_ + 1); // GRACE on both sides
        HeirloomTypes.Snapshot memory s = _snap(50, HeirloomTypes.Phase.EXPIRED); // the RC's (pre-ping) version
        vm.prank(owner);
        vault.ping(); // OwnerActive NOT delivered to the RC (lost log)
        assertVault(HeirloomTypes.VaultState.ARMED);
        assertEq(s.ownerNonce + 1, vault.ownerNonce());
        s.graceEndsAt = uint64(block.timestamp);
        _proxySync(s);
        assertVault(HeirloomTypes.VaultState.ARMED);
    }

    function test_missed_owner_action_self_heals() public {
        tickAt(T0 + T_ + 1);
        assertPhase(HeirloomTypes.Phase.GRACE);
        vm.prank(owner);
        vault.ping(); // lost OwnerActive
        // grace runs out on the RC; its EXPIRE snapshot is refused but ACKED with the vault's version
        runUntil(rc.graceEndsAt() + TICK);
        assertVault(HeirloomTypes.VaultState.ARMED);
        assertEq(rc.ownerNonceSeen(), vault.ownerNonce(), "RC adopted the vault's version from the Ack");
        assertPhase(HeirloomTypes.Phase.ARMED); // the mismatch counted as life -> REVIVE
        assertEq(rc.lastChain(), BASE);
    }

    function test_reorged_nonce_reuse_rejected() public {
        ownerCall(abi.encodeCall(HeirloomVault.ping, ()));
        assertEq(vault.ownerNonce(), 2); // deposit + ping
        HeirloomTypes.Snapshot memory s = _snap(10, HeirloomTypes.Phase.GRACE);
        s.ownerNonce = 2;
        s.ownerActionId = keccak256("a different action that once had nonce 2 (pre-reorg)");
        _proxySync(s);
        assertVault(HeirloomTypes.VaultState.ARMED);
        s.seq = 11;
        s.ownerActionId = vault.ownerActionId();
        _proxySync(s);
        assertVault(HeirloomTypes.VaultState.GRACE);
    }

    // ================================================================ expiry -> two-step claim (H5, A6)

    function test_expire_then_claimable() public {
        toClaimable();
        assertTrue(vault.claimCanInitiate());
        assertEq(vault.graceEndsAt(), rc.graceEndsAt());
    }

    function test_two_step_claim() public {
        toClaimable();
        vm.prank(heir);
        vault.initiateClaim();
        assertVault(HeirloomTypes.VaultState.CLAIM_PENDING);
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.TooEarly.selector, uint64(block.timestamp) + CLAIM_DELAY));
        vault.finalizeClaim();
        vm.warp(block.timestamp + CLAIM_DELAY);
        vault.finalizeClaim();
        assertVault(HeirloomTypes.VaultState.RELEASED);
        assertEq(usdcBase.balanceOf(heir), 4e6);
        assertTrue(vault.paid(address(usdcBase)));
    }

    function test_claim_not_before_expiry() public {
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.BadState.selector, HeirloomTypes.VaultState.ARMED));
        vault.initiateClaim();
        tickAt(T0 + T_ + 1);
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.BadState.selector, HeirloomTypes.VaultState.GRACE));
        vault.initiateClaim();
    }

    function test_third_party_finalize_pays_heir() public {
        toClaimable();
        vm.prank(stranger);
        vault.initiateClaim();
        vm.warp(block.timestamp + CLAIM_DELAY);
        vm.prank(stranger);
        vault.finalizeClaim();
        assertEq(usdcBase.balanceOf(heir), 4e6, "payout only ever to the heir");
        assertEq(usdcBase.balanceOf(stranger), 0);
    }

    function test_release_failed_token_retryable() public {
        toClaimable();
        vault.initiateClaim();
        vm.warp(block.timestamp + CLAIM_DELAY);
        usdcBase.setPaused(true);
        vault.finalizeClaim();
        assertVault(HeirloomTypes.VaultState.RELEASED); // finalized, not paid
        assertFalse(vault.paid(address(usdcBase)));
        assertEq(usdcBase.balanceOf(address(vault)), 4e6);
        usdcBase.setPaused(false);
        vm.prank(stranger);
        vault.finalizeToken(address(usdcBase));
        assertEq(usdcBase.balanceOf(heir), 4e6);
    }

    function test_redirect_payout() public {
        vm.prank(stranger);
        vm.expectRevert(HeirloomVault.NotHeir.selector);
        vault.redirectPayout(stranger);
        address cold = makeAddr("heir-cold");
        vm.prank(heir);
        vault.redirectPayout(cold);
        toClaimable();
        vault.initiateClaim();
        vm.warp(block.timestamp + CLAIM_DELAY);
        vault.finalizeClaim();
        assertEq(usdcBase.balanceOf(cold), 4e6);
    }

    function test_owner_withdraw_any_state() public {
        toClaimable();
        vault.initiateClaim();
        ownerCall(abi.encodeCall(HeirloomVault.withdraw, (address(usdcBase), 1e6)));
        assertVault(HeirloomTypes.VaultState.ARMED); // an owner action cancels the pending claim
        assertEq(usdcBase.balanceOf(owner), 100e6 - 4e6 + 1e6);
        assertPhase(HeirloomTypes.Phase.ARMED);
    }

    function test_deposit_cap() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.OverCap.selector, 4e6 + 2e6, CAP));
        vault.deposit(address(usdcBase), 2e6);
        ownerCall(abi.encodeCall(HeirloomVault.deposit, (address(usdcBase), 1e6)));
        assertEq(usdcBase.balanceOf(address(vault)), CAP);
    }

    function test_only_owner_actions() public {
        vm.startPrank(stranger);
        vm.expectRevert(HeirloomVault.NotOwner.selector);
        vault.ping();
        vm.expectRevert(HeirloomVault.NotOwner.selector);
        vault.withdraw(address(usdcBase), 1);
        vm.expectRevert(HeirloomVault.NotOwner.selector);
        vault.setHeir(stranger);
        vm.expectRevert(HeirloomVault.NotOwner.selector);
        vault.retire();
        vm.stopPrank();
    }

    function test_owner_not_deployer_vault() public view {
        assertEq(vault.owner(), owner);
        assertTrue(owner != address(this));
    }

    function test_allowlist_cap_on_vault() public {
        for (uint256 i; i < 5; i++) {
            ownerCall(abi.encodeCall(HeirloomVault.setAllowlist, (ETH, address(uint160(0x1000 + i)), true)));
        }
        vm.prank(owner);
        vm.expectRevert(HeirloomVault.TooManyTokens.selector);
        vault.setAllowlist(ETH, address(0x2000), true);
    }

    function test_revive_from_claimable() public {
        toClaimable();
        vm.warp(block.timestamp + 5);
        CallbackResult[] memory r = heartbeat(usdcEth, 1); // the owner was alive after all
        assertCallbacks(r, 1);
        assertVault(HeirloomTypes.VaultState.ARMED);
        assertPhase(HeirloomTypes.Phase.ARMED);
    }

    function test_revive_cancels_claim_pending() public {
        toClaimable();
        vault.initiateClaim();
        vm.warp(block.timestamp + 5);
        heartbeat(usdcUni, 1);
        assertVault(HeirloomTypes.VaultState.ARMED);
        vm.warp(block.timestamp + CLAIM_DELAY);
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.BadState.selector, HeirloomTypes.VaultState.ARMED));
        vault.finalizeClaim();
    }

    /// The RC reaches GRACE again only through ARMED, so a newer GRACE snapshot reaching a CLAIMABLE / CLAIM_PENDING
    /// vault means its REVIVE was superseded before it landed (e.g. callbacks undeliverable for a full T, then the
    /// GRACE snapshot replaced the un-acked REVIVE). The claim must not outlive that proof of life.
    function test_superseded_revive_grace_cancels_claim_pending() public {
        toClaimable();
        vault.initiateClaim();
        HeirloomTypes.Snapshot memory s = _snap(vault.lastAppliedSeq() + 2, HeirloomTypes.Phase.GRACE);
        s.kind = HeirloomTypes.Kind.GRACE;
        vm.expectEmit(address(vault));
        emit HeirloomVault.ClaimCancelled(s.seq);
        _proxySync(s);
        assertVault(HeirloomTypes.VaultState.GRACE);
        assertEq(vault.graceEndsAt(), s.graceEndsAt);
        vm.warp(block.timestamp + CLAIM_DELAY);
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.BadState.selector, HeirloomTypes.VaultState.GRACE));
        vault.finalizeClaim();
    }

    function test_superseded_revive_grace_closes_claimable() public {
        toClaimable();
        HeirloomTypes.Snapshot memory s = _snap(vault.lastAppliedSeq() + 2, HeirloomTypes.Phase.GRACE);
        s.ownerNonce = vault.ownerNonce() + 7; // even a version mismatch (RC adopted a reorged version) only ever delays
        _proxySync(s);
        assertVault(HeirloomTypes.VaultState.GRACE);
        assertFalse(vault.claimCanInitiate());
    }

    function test_brake_in_claim_pending_cancels_claim() public {
        toClaimable();
        vault.initiateClaim();
        for (uint256 i; i < MAX_REFUSED; i++) spoof(usdcBase);
        assertPhase(HeirloomTypes.Phase.ARMED);
        assertVault(HeirloomTypes.VaultState.ARMED); // REVIVE: a claim clock never runs over a blind token
    }

    function test_no_release_during_callback_outage() public {
        injectOverride = stranger; // every callback fails
        runUntil(T0 + T_ + GRACE + 3 * TICK);
        assertPhase(HeirloomTypes.Phase.EXPIRED);
        assertVault(HeirloomTypes.VaultState.ARMED);
        vm.warp(block.timestamp + 3);
        heartbeat(usdcEth, 1); // Ethereum heartbeat while callbacks still fail
        assertEq(uint8(rc.pendingKind()), uint8(HeirloomTypes.Kind.REVIVE), "REVIVE overwrote the un-acked EXPIRE");
        injectOverride = address(0);
        runUntil(block.timestamp + ACK + TICK);
        assertVault(HeirloomTypes.VaultState.ARMED);
        assertGt(vault.lastAppliedSeq(), 0, "delivery resumed: the first applied snapshot is the REVIVE");
        assertPhase(HeirloomTypes.Phase.ARMED);
        runUntil(block.timestamp + CLAIM_DELAY);
        assertFalse(vault.claimCanInitiate(), "the claim stays closed across a full claimDelay");
    }

    // ================================================================ teardown (A4, A10, I9)

    function test_teardown_on_released() public {
        _release();
        assertPhase(HeirloomTypes.Phase.DONE);
        assertEq(sys.activeSubscriptions(address(rc)), 0, "no CRON, token, canary or vault subscription left");
        uint64 seq = rc.nextSeq();
        tickAt(block.timestamp + ATTEST * 3);
        assertEq(rc.nextSeq(), seq, "a torn-down RC ignores every log");
    }

    function test_reclaim_only_after_teardown() public {
        address payable sink = payable(makeAddr("sink"));
        vm.expectRevert(HeirloomReactive.NotDone.selector);
        rc.reclaim(sink);
        _release();
        vm.prank(owner);
        vm.expectRevert(HeirloomReactive.NotDeployer.selector);
        rc.reclaim(sink);
        rc.reclaim(sink);
        assertEq(sink.balance, 10 ether);
    }

    function test_retire_tears_down() public {
        ownerCall(abi.encodeCall(HeirloomVault.retire, ()));
        assertVault(HeirloomTypes.VaultState.RETIRED);
        assertEq(usdcBase.balanceOf(owner), 100e6);
        assertPhase(HeirloomTypes.Phase.DONE);
        assertEq(sys.activeSubscriptions(address(rc)), 0);
        vm.prank(owner);
        vm.expectRevert(HeirloomVault.Terminal.selector);
        vault.deposit(address(usdcBase), 1);
    }

    function test_terminal_ack_tears_down() public {
        toClaimable();
        vault.initiateClaim();
        vm.warp(block.timestamp + CLAIM_DELAY);
        vault.finalizeClaim(); // EstateReleased NOT delivered (lost log)
        assertPhase(HeirloomTypes.Phase.EXPIRED);
        runUntil(block.timestamp + ATTEST + TICK); // next snapshot -> Ack(terminal = true)
        assertPhase(HeirloomTypes.Phase.DONE);
        assertEq(sys.activeSubscriptions(address(rc)), 0);
    }

    function test_teardown_with_canary_and_grace_cron() public {
        vm.warp(T0);
        HeirloomReactive.Config memory c = _cfg();
        c.graceCronTopic = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70; // CRON100
        _deploy(c, 3633);
        ownerCall(abi.encodeCall(HeirloomVault.deposit, (address(usdcBase), 1e6)));
        _release();
        assertEq(sys.activeSubscriptions(address(rc)), 0);
    }

    // ================================================================ the two flows the Lasna run repeats

    /// heartbeat -> silence -> grace -> cancel
    function test_flow_grace_then_cancel() public {
        vm.warp(T0 + 100);
        heartbeat(usdcBase, 1);
        runUntil(T0 + 100 + T_ + TICK);
        assertVault(HeirloomTypes.VaultState.GRACE);
        vm.warp(block.timestamp + 20);
        heartbeat(usdcEth, 1);
        assertVault(HeirloomTypes.VaultState.ARMED);
        assertEq(vault.lastChainMirror(), ETH);
    }

    /// silence -> expiry -> heir claim -> teardown
    function test_flow_expiry_claim_teardown() public {
        _release();
        assertEq(usdcBase.balanceOf(heir), 4e6);
        assertPhase(HeirloomTypes.Phase.DONE);
    }

    // ================================================================ QA r2 fixes

    function test_early_expired_snapshot_deferred_then_applied() public {
        tickAt(T0 + T_ + 1);
        assertVault(HeirloomTypes.VaultState.GRACE);
        HeirloomTypes.Snapshot memory s = _snap(40, HeirloomTypes.Phase.EXPIRED);
        s.graceEndsAt = uint64(block.timestamp + 50); // Base clock behind the Reactive grace end
        uint64 applied = vault.lastAppliedSeq();
        _proxySync(s);
        assertEq(vault.lastAppliedSeq(), applied, "not applied, not acked: the RC will resend");
        assertVault(HeirloomTypes.VaultState.GRACE);
        vm.warp(block.timestamp + 50);
        _proxySync(s); // the resend (same seq)
        assertVault(HeirloomTypes.VaultState.CLAIMABLE);
    }

    function test_retire_with_paused_token_still_retires() public {
        usdcBase.setPaused(true);
        ownerCall(abi.encodeCall(HeirloomVault.retire, ()));
        assertVault(HeirloomTypes.VaultState.RETIRED);
        assertPhase(HeirloomTypes.Phase.DONE);
        assertEq(sys.activeSubscriptions(address(rc)), 0);
    }

    function test_claim_delay_minimum() public {
        uint256[] memory c = new uint256[](0);
        address[] memory t = new address[](0);
        vm.expectRevert(HeirloomVault.ClaimDelayTooShort.selector);
        new HeirloomVault(address(proxy), address(rc), owner, heir, 59, CAP, c, t);
    }

    function test_sweep_after_release() public {
        TestToken stray = new TestToken();
        stray.mint(address(vault), 7);
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.BadState.selector, HeirloomTypes.VaultState.ARMED));
        vault.sweep(address(stray));
        _release();
        vm.prank(stranger);
        vault.sweep(address(stray));
        assertEq(stray.balanceOf(heir), 7);
        uint256 reserve = address(vault).balance;
        vault.sweep(address(0));
        assertEq(heir.balance, reserve, "native gas reserve to the payee after release");
    }

    function test_teardown_retire_in_grace_with_grace_cron_and_late_token() public {
        vm.warp(T0);
        HeirloomReactive.Config memory c = _cfg();
        c.graceCronTopic = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70; // CRON100
        _deploy(c, 3633); // always-on canary
        TestToken late = new TestToken();
        onChain(address(late), UNI);
        ownerCall(abi.encodeCall(HeirloomVault.setAllowlist, (UNI, address(late), true)));
        assertTrue(rc.subscribed(UNI, address(late)));
        uint256 armedSubs = sys.activeSubscriptions(address(rc));
        runUntil(rc.deadline() + TICK);
        assertPhase(HeirloomTypes.Phase.GRACE);
        assertEq(sys.activeSubscriptions(address(rc)), armedSubs + 1, "grace CRON live");
        ownerCall(abi.encodeCall(HeirloomVault.retire, ()));
        assertPhase(HeirloomTypes.Phase.DONE);
        assertEq(sys.activeSubscriptions(address(rc)), 0, "grace CRON, late token, canary, vault events, failure watch: all gone");
    }

    function test_teardown_with_braked_token_and_armed_canary() public {
        vm.warp(T0);
        _deploy(_cfg(), 100); // near-deadline canary
        runUntil(T0 + T_ - 222 + TICK);
        (,,,, bool armed) = rc.canaries(BASE);
        assertTrue(armed);
        for (uint256 i; i < MAX_REFUSED; i++) spoof(usdcBase);
        assertEq(rc.brakedCount(), 1);
        ownerCall(abi.encodeCall(HeirloomVault.retire, ()));
        assertPhase(HeirloomTypes.Phase.DONE);
        assertEq(sys.activeSubscriptions(address(rc)), 0);
    }

    // ================================================================ helpers

    function _release() internal {
        toClaimable();
        cycle(heir, address(vault), abi.encodeCall(HeirloomVault.initiateClaim, ()));
        vm.warp(block.timestamp + CLAIM_DELAY);
        cycle(heir, address(vault), abi.encodeCall(HeirloomVault.finalizeClaim, ()));
        assertVault(HeirloomTypes.VaultState.RELEASED);
    }

    function _snap(uint64 seq, HeirloomTypes.Phase p) internal view returns (HeirloomTypes.Snapshot memory s) {
        s.seq = seq;
        s.kind = HeirloomTypes.Kind.ATTEST;
        s.rcPhase = p;
        s.ownerNonce = vault.ownerNonce();
        s.ownerActionId = vault.ownerActionId();
        s.lastSeen = uint64(block.timestamp);
        s.graceEndsAt = uint64(block.timestamp + GRACE);
    }

    function _proxySync(HeirloomTypes.Snapshot memory s) internal {
        (bool ok, bytes memory ret) =
            proxy.executeCallback(address(vault), abi.encodeCall(HeirloomVault.sync, (address(0), s)), 1e6, address(rc));
        if (!ok) _bubble(ret);
    }
}

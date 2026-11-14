// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {HeirloomVault} from "../src/HeirloomVault.sol";
import {HeirloomTypes} from "../src/HeirloomTypes.sol";
import {HeirloomBase, TestToken} from "./HeirloomBase.sol";

/// A contract owner that is ALSO an ERC-20 estate token: its token calls and its native receive hook can re-enter the
/// vault as the owner, so every nonReentrant entry can be reached past its auth modifiers.
contract HookOwner {
    HeirloomVault public vault;
    bytes internal _hook;
    bytes4 public hookRevert;
    bool public rejectEth;
    mapping(address => uint256) public balanceOf;

    function setVault(HeirloomVault v) external {
        vault = v;
    }

    function setHook(bytes calldata h) external {
        _hook = h;
        hookRevert = bytes4(0);
    }

    function setRejectEth(bool r) external {
        rejectEth = r;
    }

    function exec(bytes calldata data) external {
        (bool ok, bytes memory ret) = address(vault).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        _fire();
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        _fire();
        balanceOf[from] -= v;
        balanceOf[to] += v;
        return true;
    }

    receive() external payable {
        if (rejectEth) revert("no eth");
        _fire();
    }

    function _fire() internal {
        if (_hook.length == 0) return;
        bytes memory h = _hook;
        delete _hook;
        (bool ok, bytes memory ret) = address(vault).call(h);
        if (!ok && ret.length >= 4) {
            bytes4 sel;
            assembly {
                sel := mload(add(ret, 0x20))
            }
            hookRevert = sel;
        }
    }
}

/// Edge paths of HeirloomVault: constructor guards, every auth/terminal/re-entry guard on every entry point, failed
/// token and native transfers, and the codeless-token defences. One revert per test where a guard is the subject.
contract CoverageVaultTest is HeirloomBase {
    function setUp() public override {
        super.setUp();
        _deployDefault();
    }

    // ================================================================ constructor guards

    function test_constructor_rejects_zero_owner() public {
        (uint256[] memory c, address[] memory t) = _noTokens();
        vm.expectRevert(HeirloomVault.ZeroAddress.selector);
        new HeirloomVault(address(proxy), address(rc), address(0), heir, CLAIM_DELAY, CAP, c, t);
    }

    function test_constructor_rejects_zero_heir() public {
        (uint256[] memory c, address[] memory t) = _noTokens();
        vm.expectRevert(HeirloomVault.ZeroAddress.selector);
        new HeirloomVault(address(proxy), address(rc), owner, address(0), CLAIM_DELAY, CAP, c, t);
    }

    function test_constructor_rejects_zero_callback_sender() public {
        (uint256[] memory c, address[] memory t) = _noTokens();
        vm.expectRevert(HeirloomVault.ZeroAddress.selector);
        new HeirloomVault(address(proxy), address(0), owner, heir, CLAIM_DELAY, CAP, c, t);
    }

    function test_constructor_rejects_mismatched_allowlist_arrays() public {
        uint256[] memory c = new uint256[](2);
        address[] memory t = new address[](1);
        vm.expectRevert(HeirloomVault.TooManyTokens.selector);
        new HeirloomVault(address(proxy), address(rc), owner, heir, CLAIM_DELAY, CAP, c, t);
    }

    function test_constructor_rejects_allowlist_over_cap() public {
        uint256[] memory c = new uint256[](9);
        address[] memory t = new address[](9);
        for (uint256 i; i < 9; i++) {
            c[i] = BASE;
            t[i] = address(uint160(0x1000 + i));
        }
        vm.expectRevert(HeirloomVault.TooManyTokens.selector);
        new HeirloomVault(address(proxy), address(rc), owner, heir, CLAIM_DELAY, CAP, c, t);
    }

    function test_constructor_counts_duplicate_allowlist_entry_once() public {
        uint256[] memory c = new uint256[](2);
        address[] memory t = new address[](2);
        c[0] = BASE;
        c[1] = BASE;
        t[0] = address(usdcBase);
        t[1] = address(usdcBase);
        HeirloomVault v = new HeirloomVault(address(proxy), address(rc), owner, heir, CLAIM_DELAY, CAP, c, t);
        assertEq(v.allowlistCount(), 1);
    }

    // ================================================================ owner actions

    function test_setHeir_replaces_heir_and_clears_redirect() public {
        address next = makeAddr("nextHeir");
        vm.prank(heir);
        vault.redirectPayout(makeAddr("redirect"));
        uint64 n = vault.ownerNonce();
        vm.prank(owner);
        vault.setHeir(next);
        assertEq(vault.heir(), next);
        assertEq(vault.payoutTo(), address(0), "a new heir starts with no redirect");
        assertEq(vault.payee(), next);
        assertEq(vault.ownerNonce(), n + 1, "setHeir is proof of life");
    }

    function test_setHeir_rejects_zero_address() public {
        vm.prank(owner);
        vm.expectRevert(HeirloomVault.ZeroAddress.selector);
        vault.setHeir(address(0));
    }

    function test_deposit_rejects_ninth_estate_token() public {
        vm.startPrank(owner);
        for (uint256 i; i < 8; i++) {
            TestToken t = new TestToken();
            vault.deposit(address(t), 0);
        }
        assertEq(vault.estateTokenCount(), 8);
        TestToken ninth = new TestToken();
        vm.expectRevert(HeirloomVault.TooManyTokens.selector);
        vault.deposit(address(ninth), 0);
        vm.stopPrank();
    }

    function test_deposit_from_codeless_token_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.TransferFailed2.selector, address(0xdead)));
        vault.deposit(address(0xdead), 1);
    }

    function test_deposit_of_paused_token_reverts() public {
        TestToken t = new TestToken();
        t.mint(owner, 1e6);
        t.setPaused(true);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.TransferFailed2.selector, address(t)));
        vault.deposit(address(t), 1e6);
    }

    function test_withdraw_more_than_balance_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.TransferFailed2.selector, address(usdcBase)));
        vault.withdraw(address(usdcBase), 1e6);
    }

    function test_withdraw_native_to_rejecting_owner_reverts() public {
        HookOwner o = new HookOwner();
        HeirloomVault v = _bareVault(address(o));
        o.setVault(v);
        o.setRejectEth(true);
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.TransferFailed2.selector, address(0)));
        o.exec(abi.encodeCall(HeirloomVault.withdraw, (address(0), 0.1 ether)));
    }

    // ================================================================ retire

    function test_retire_skips_empty_estate_token_and_pays_the_rest() public {
        TestToken empty = new TestToken();
        vm.startPrank(owner);
        vault.deposit(address(empty), 0);
        vault.deposit(address(usdcBase), 3e6);
        uint256 before = usdcBase.balanceOf(owner);
        vault.retire();
        vm.stopPrank();
        assertVault(HeirloomTypes.VaultState.RETIRED);
        assertEq(usdcBase.balanceOf(owner) - before, 3e6);
    }

    function test_retire_with_rejecting_owner_still_retires_and_keeps_native_for_sweep() public {
        HookOwner o = new HookOwner();
        HeirloomVault v = _bareVault(address(o));
        o.setVault(v);
        o.setRejectEth(true);
        vm.expectEmit(address(v));
        emit HeirloomVault.RetireFailed(address(0));
        o.exec(abi.encodeCall(HeirloomVault.retire, ()));
        assertEq(uint8(v.state()), uint8(HeirloomTypes.VaultState.RETIRED));
        assertEq(address(v).balance, 1 ether, "the native reserve stays for a later sweep");
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.TransferFailed2.selector, address(0)));
        o.exec(abi.encodeCall(HeirloomVault.sweep, (address(0))));
    }

    function test_retire_skips_estate_token_that_lost_its_code() public {
        TestToken t = new TestToken();
        t.mint(owner, 1e6);
        vm.prank(owner);
        vault.deposit(address(t), 1e6);
        vm.etch(address(t), ""); // balanceOf can no longer be read
        vm.prank(owner);
        vault.retire();
        assertVault(HeirloomTypes.VaultState.RETIRED);
    }

    // ================================================================ claim / release edges

    function test_finalizeToken_before_release_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.BadState.selector, HeirloomTypes.VaultState.ARMED));
        vault.finalizeToken(address(usdcBase));
    }

    function test_finalizeToken_rejects_non_estate_token() public {
        _releaseNow();
        vm.expectRevert(HeirloomVault.ZeroAddress.selector);
        vault.finalizeToken(address(fakeToken));
    }

    function test_sweep_refuses_unpaid_estate_token_after_release() public {
        TestToken t = new TestToken();
        t.mint(owner, 1e6);
        vm.prank(owner);
        vault.deposit(address(t), 1e6);
        t.setPaused(true);
        _releaseNow();
        assertFalse(vault.paid(address(t)));
        vm.expectRevert(abi.encodeWithSelector(HeirloomVault.BadState.selector, HeirloomTypes.VaultState.RELEASED));
        vault.sweep(address(t));
    }

    function test_release_marks_codeless_estate_token_failed() public {
        TestToken t = new TestToken();
        t.mint(owner, 1e6);
        vm.prank(owner);
        vault.deposit(address(t), 1e6);
        vm.etch(address(t), "");
        _claimPending();
        vm.expectEmit(address(vault));
        emit HeirloomVault.ReleaseFailed(address(t));
        vault.finalizeClaim();
        assertVault(HeirloomTypes.VaultState.RELEASED);
        assertFalse(vault.paid(address(t)));
    }

    function test_redirectPayout_rejects_zero_address() public {
        vm.prank(heir);
        vm.expectRevert(HeirloomVault.ZeroAddress.selector);
        vault.redirectPayout(address(0));
    }

    function test_vault_cover_debt_is_callable_with_no_debt() public {
        vault.coverDebt(); // MockCallbackProxy reports zero debt: a no-op that must not revert
    }

    // ================================================================ guards on every entry point

    function test_every_owner_action_rejects_non_owner() public {
        bytes[] memory calls = _ownerCalls();
        for (uint256 i; i < calls.length; i++) {
            vm.prank(stranger);
            (bool ok, bytes memory ret) = address(vault).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(ret), HeirloomVault.NotOwner.selector);
        }
    }

    function test_every_owner_action_reverts_after_retire() public {
        vm.prank(owner);
        vault.retire();
        bytes[] memory calls = _ownerCalls();
        for (uint256 i; i < calls.length; i++) {
            vm.prank(owner);
            (bool ok, bytes memory ret) = address(vault).call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(ret), HeirloomVault.Terminal.selector);
        }
    }

    function test_ping_reverts_after_release() public {
        _releaseNow();
        vm.prank(owner);
        vm.expectRevert(HeirloomVault.Terminal.selector);
        vault.ping();
    }

    function test_every_locked_entry_rejects_reentry() public {
        HookOwner o = new HookOwner();
        HeirloomVault v = _bareVault(address(o));
        o.setVault(v);
        o.mint(address(o), 100);
        bytes[7] memory inner = [
            abi.encodeCall(HeirloomVault.deposit, (address(o), 1)),
            abi.encodeCall(HeirloomVault.withdraw, (address(0), 1)),
            abi.encodeCall(HeirloomVault.retire, ()),
            abi.encodeCall(HeirloomVault.initiateClaim, ()),
            abi.encodeCall(HeirloomVault.finalizeClaim, ()),
            abi.encodeCall(HeirloomVault.finalizeToken, (address(o))),
            abi.encodeCall(HeirloomVault.sweep, (address(0)))
        ];
        for (uint256 i; i < inner.length; i++) {
            o.setHook(inner[i]);
            o.exec(abi.encodeCall(HeirloomVault.deposit, (address(o), 1))); // transferFrom fires the hook mid-deposit
            assertEq(o.hookRevert(), HeirloomVault.Reentered.selector);
        }
        assertEq(uint8(v.state()), uint8(HeirloomTypes.VaultState.ARMED));
    }

    // ================================================================ helpers

    function _ownerCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](6);
        calls[0] = abi.encodeCall(HeirloomVault.deposit, (address(usdcBase), 1));
        calls[1] = abi.encodeCall(HeirloomVault.withdraw, (address(0), 1));
        calls[2] = abi.encodeCall(HeirloomVault.ping, ());
        calls[3] = abi.encodeCall(HeirloomVault.setHeir, (stranger));
        calls[4] = abi.encodeCall(HeirloomVault.setAllowlist, (BASE, address(fakeToken), true));
        calls[5] = abi.encodeCall(HeirloomVault.retire, ());
    }

    function _noTokens() internal pure returns (uint256[] memory c, address[] memory t) {
        c = new uint256[](0);
        t = new address[](0);
    }

    function _bareVault(address owner_) internal returns (HeirloomVault v) {
        (uint256[] memory c, address[] memory t) = _noTokens();
        v = new HeirloomVault{value: 1 ether}(address(proxy), address(rc), owner_, heir, CLAIM_DELAY, CAP, c, t);
    }

    /// EXPIRED snapshot through the proxy (as the RC would send it), then the two-step claim.
    function _releaseNow() internal {
        _claimPending();
        vault.finalizeClaim();
        assertVault(HeirloomTypes.VaultState.RELEASED);
    }

    /// EXPIRED snapshot through the proxy, initiateClaim, and wait out claimDelay.
    function _claimPending() internal {
        HeirloomTypes.Snapshot memory s;
        s.seq = vault.lastAppliedSeq() + 1;
        s.kind = HeirloomTypes.Kind.EXPIRE;
        s.rcPhase = HeirloomTypes.Phase.EXPIRED;
        s.ownerNonce = vault.ownerNonce();
        s.ownerActionId = vault.ownerActionId();
        s.graceEndsAt = uint64(block.timestamp);
        (bool ok,) =
            proxy.executeCallback(address(vault), abi.encodeCall(HeirloomVault.sync, (address(0), s)), 1e6, address(rc));
        assertTrue(ok, "sync");
        assertVault(HeirloomTypes.VaultState.CLAIMABLE);
        vault.initiateClaim();
        vm.warp(block.timestamp + CLAIM_DELAY);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {CronTopics} from "reactive-kit/CronTopics.sol";
import {CallbackFailureWatch} from "reactive-kit/CallbackFailureWatch.sol";
import {HeirloomVault} from "../src/HeirloomVault.sol";
import {HeirloomTypes} from "../src/HeirloomTypes.sol";
import {HeirloomBase, TestToken} from "./HeirloomBase.sol";

/// A contract owner whose receive hook tries to retire the vault mid-withdraw.
contract ReenteringOwner {
    HeirloomVault public vault;
    bool public reentryReverted;

    function set(HeirloomVault v) external {
        vault = v;
    }

    function withdrawNative(uint256 a) external {
        vault.withdraw(address(0), a);
    }

    bool internal tried;

    receive() external payable {
        if (tried) return; // re-enter once (retire() pays this contract too)
        tried = true;
        try vault.retire() {} catch {
            reentryReverted = true;
        }
    }
}

/// ERC-20 whose transfer returns the word 2: a strict `abi.decode(ret, (bool))` would revert the whole payout.
contract TwoToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        balanceOf[from] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        assembly {
            mstore(0, 2)
            return(0, 32)
        }
    }
}

/// ERC-20 whose transfer burns all gas it is given.
contract GasEaterToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function transferFrom(address from, address to, uint256 v) external returns (bool) {
        balanceOf[from] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        while (true) {}
        return true;
    }
}

contract HeirloomHardeningTest is HeirloomBase {
    function setUp() public override {
        super.setUp();
        _deployDefault();
        ownerCall(abi.encodeCall(HeirloomVault.deposit, (address(usdcBase), 4e6)));
    }

    // ------------------------------------------------------------------ a2a r03: re-entry

    function test_owner_reentry_cannot_retire_mid_withdraw() public {
        ReenteringOwner o = new ReenteringOwner();
        HeirloomVault v = _bareVault(address(o));
        o.set(v);
        o.withdrawNative(0.1 ether);
        assertTrue(o.reentryReverted(), "retire() re-entered from withdraw must revert");
        assertEq(uint8(v.state()), uint8(HeirloomTypes.VaultState.ARMED));
    }

    // ------------------------------------------------------------------ a2a r03: payout isolation

    function test_hostile_tokens_cannot_block_the_payout() public {
        TwoToken two = new TwoToken();
        GasEaterToken eater = new GasEaterToken();
        two.mint(owner, 1e6);
        eater.mint(owner, 1e6);
        HeirloomVault v = _bareVault(owner);
        vm.startPrank(owner);
        v.deposit(address(two), 1e6);
        v.deposit(address(eater), 1e6);
        usdcBase.transfer(address(v), 2e6); // a good token as an estate token too
        v.deposit(address(usdcBase), 0);
        vm.stopPrank();
        _expire(v);
        v.initiateClaim();
        vm.warp(block.timestamp + CLAIM_DELAY);
        uint256 before = usdcBase.balanceOf(heir);
        v.finalizeClaim{gas: 3_000_000}();
        assertEq(uint8(v.state()), uint8(HeirloomTypes.VaultState.RELEASED));
        assertEq(usdcBase.balanceOf(heir) - before, 2e6, "the good token is paid despite the two hostile ones");
        assertFalse(v.paid(address(two)), "a non-1 return word is a failed transfer, not a revert");
        assertFalse(v.paid(address(eater)));
    }

    // ------------------------------------------------------------------ a2a r03: foreign CallbackFailure

    function test_foreign_callback_failure_does_not_spend_resends() public {
        vm.warp(rc.deadline() + 1);
        IReactive.LogRecord memory tick;
        tick.chainId = block.chainid;
        tick.contractAddress = CronTopics.LEGACY_SYSTEM_ADDR;
        tick.topic0 = CronTopics.CRON10;
        tick.opCode = 1;
        deliverAs(tick); // GRACE requested, not delivered
        uint64 seq = _pendingSeq();
        assertEq(_pendingTries(), 1);
        IReactive.LogRecord memory l = failureLog(seq);
        HeirloomTypes.Snapshot memory s;
        s.seq = seq;
        l.data = abi.encode(abi.encodeCall(HeirloomVault.sync, (stranger, s))); // another requester's failure
        deliverAs(l);
        assertEq(_pendingTries(), 1, "a foreign failure must not trigger a resend");
        deliverAs(failureLog(seq)); // our own failure still resends at once
        assertEq(_pendingTries(), 2);
    }

    // ------------------------------------------------------------------ a2a r03: debt settlement surface

    function test_cover_debt_is_callable_with_no_debt() public {
        rc.coverDebt(); // OmniSystemMock reports zero debt: a no-op that must not revert
    }

    // ------------------------------------------------------------------ helpers

    function _bareVault(address owner_) internal returns (HeirloomVault v) {
        uint256[] memory c = new uint256[](0);
        address[] memory t = new address[](0);
        v = new HeirloomVault{value: 1 ether}(address(proxy), address(rc), owner_, heir, CLAIM_DELAY, CAP, c, t);
    }

    function _expire(HeirloomVault v) internal {
        HeirloomTypes.Snapshot memory s;
        s.seq = v.lastAppliedSeq() + 1;
        s.kind = HeirloomTypes.Kind.EXPIRE;
        s.rcPhase = HeirloomTypes.Phase.EXPIRED;
        s.ownerNonce = v.ownerNonce();
        s.ownerActionId = v.ownerActionId();
        s.graceEndsAt = uint64(block.timestamp);
        (bool ok,) = proxy.executeCallback(address(v), abi.encodeCall(HeirloomVault.sync, (address(0), s)), 1e6, address(rc));
        assertTrue(ok, "sync");
        assertEq(uint8(v.state()), uint8(HeirloomTypes.VaultState.CLAIMABLE));
    }
}

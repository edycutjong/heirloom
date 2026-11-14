// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {OmniReactiveTest} from "reactive-kit/test/OmniReactiveTest.sol";
import {CronTopics} from "reactive-kit/CronTopics.sol";
import {ProbeReactive} from "../src/probe/ProbeReactive.sol";
import {ProbeCallback} from "../src/probe/ProbeCallback.sol";
import {HeirloomVault} from "../src/HeirloomVault.sol";
import {HeirloomTypes} from "../src/HeirloomTypes.sol";
import {HeirloomBase} from "./HeirloomBase.sol";

/// Log data shorter than one word: the probe decodes nothing and records 0 instead of reverting in react(); a full
/// word is decoded.
contract CoverageProbeShortDataTest is OmniReactiveTest {
    uint256 internal constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));
    address deployer = makeAddr("deployer");
    ProbeReactive rc;

    function setUp() public override {
        super.setUp();
        vm.deal(deployer, 10 ether);
        vm.startPrank(deployer);
        ProbeCallback cb = new ProbeCallback{value: 1 ether}(address(proxy));
        rc = new ProbeReactive{value: 2 ether}(84532, address(cb), 3, 4);
        vm.stopPrank();
    }

    function _log(address emitter, uint256 topic0, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory r)
    {
        r.chainId = 11155111;
        r.contractAddress = emitter;
        r.topic0 = topic0;
        r.topic1 = 1;
        r.topic2 = 2;
        r.data = data;
        r.txHash = 0xabc;
    }

    function test_probe_transfer_log_without_a_value_word_records_zero() public {
        vm.expectEmit(address(rc));
        emit ProbeReactive.Seen(11155111, address(0xBEEF), 1, 2, 0, 0xabc);
        vm.prank(SYSTEM_ADDR);
        rc.react(_log(address(0xBEEF), TRANSFER_TOPIC, hex"01"));
    }

    function test_probe_cron_log_without_a_block_word_records_block_zero() public {
        vm.prank(SYSTEM_ADDR);
        rc.react(_log(CronTopics.LEGACY_SYSTEM_ADDR, CronTopics.CRON10, ""));
        assertEq(rc.cronTicks(), 1);
        assertEq(rc.lastCronBlock(), 0, "no data word, so no CRON block number");
    }

    function test_probe_cron_log_with_a_block_word_records_that_block() public {
        vm.prank(SYSTEM_ADDR);
        rc.react(_log(CronTopics.LEGACY_SYSTEM_ADDR, CronTopics.CRON10, abi.encode(uint256(7_853_600))));
        assertEq(rc.lastCronBlock(), 7_853_600);
    }
}

/// A single-token retry passes the caller's gas minus a 60k reserve to the token. A caller that leaves less than the
/// reserve gets a soft failure (ReleaseFailed, token still unpaid, retryable), never a revert or a stranded token.
contract CoverageVaultLowGasRetryTest is HeirloomBase {
    function setUp() public override {
        super.setUp();
        _deployDefault();
        ownerCall(abi.encodeCall(HeirloomVault.deposit, (address(usdcBase), 4e6)));
    }

    function test_finalizeToken_below_the_recovery_reserve_fails_soft_and_stays_retryable() public {
        toClaimable();
        vault.initiateClaim();
        vm.warp(block.timestamp + CLAIM_DELAY);
        usdcBase.setPaused(true);
        vault.finalizeClaim();
        assertEq(uint256(vault.state()), uint256(HeirloomTypes.VaultState.RELEASED));
        usdcBase.setPaused(false);

        // Rising gas budgets: the lowest ones leave less than the reserve at the token call and soft-fail; the sweep
        // stops at the first budget that pays, so every earlier success is a soft failure that left the token retryable.
        uint256 softFails;
        bytes memory call_ = abi.encodeCall(HeirloomVault.finalizeToken, (address(usdcBase)));
        for (uint256 g = 30_000; g <= 400_000 && !vault.paid(address(usdcBase)); g += 2_000) {
            (bool ok,) = address(vault).call{gas: g}(call_);
            if (ok && !vault.paid(address(usdcBase))) softFails++;
        }
        assertGt(softFails, 0, "low budgets complete with the token left unpaid (ReleaseFailed), not a revert");
        assertTrue(vault.paid(address(usdcBase)), "a later retry with enough gas still pays the heir");
        assertEq(usdcBase.balanceOf(heir), 4e6);
    }
}

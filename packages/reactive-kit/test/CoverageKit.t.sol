// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {CronTopics} from "../src/CronTopics.sol";
import {CallbackFailureWatch} from "../src/CallbackFailureWatch.sol";

contract KitHarness {
    function selectorOf(bytes memory p) external pure returns (bytes4) {
        return CallbackFailureWatch.selectorOf(p);
    }

    function argWord(bytes memory p, uint256 n) external pure returns (uint256) {
        return CallbackFailureWatch.argWord(p, n);
    }
}

/// Every CRON tier maps to its block interval; a failure payload too short to decode never yields a fake word.
contract CoverageKitTest is Test {
    function test_cron_interval_of_every_tier() public pure {
        assertEq(CronTopics.interval(CronTopics.CRON1), 1);
        assertEq(CronTopics.interval(CronTopics.CRON10), 10);
        assertEq(CronTopics.interval(CronTopics.CRON100), 100);
        assertEq(CronTopics.interval(CronTopics.CRON1000), 1000);
        assertEq(CronTopics.interval(CronTopics.CRON10000), 10000);
        assertEq(CronTopics.interval(uint256(keccak256("Transfer(address,address,uint256)"))), 0);
    }

    function test_cron_topic_from_wrong_emitter_is_not_cron() public pure {
        assertTrue(CronTopics.isCron(CronTopics.LEGACY_SYSTEM_ADDR, CronTopics.CRON1));
        assertFalse(CronTopics.isCron(address(0xBEEF), CronTopics.CRON1), "a spoofed emitter is never a tick");
        assertFalse(CronTopics.isCron(CronTopics.LEGACY_SYSTEM_ADDR, 0), "a non-CRON topic is never a tick");
    }

    function test_selector_of_payload_shorter_than_four_bytes_is_zero() public {
        KitHarness h = new KitHarness();
        assertEq(h.selectorOf(hex"010203"), bytes4(0));
        assertEq(h.selectorOf(hex"01020304"), bytes4(0x01020304));
    }

    function test_arg_word_rejects_short_payload() public {
        KitHarness h = new KitHarness();
        vm.expectRevert(bytes("CallbackFailureWatch: short payload"));
        h.argWord(abi.encodePacked(bytes4(0x01020304), uint256(7)), 1);
    }
}

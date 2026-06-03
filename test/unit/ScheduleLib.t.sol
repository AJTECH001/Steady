// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {ScheduleLib} from "steady/libraries/ScheduleLib.sol";

contract ScheduleLibTest is Test {
    function test_nextDue_addsInterval() public pure {
        assertEq(ScheduleLib.nextDue(100, 50), 150);
    }

    function test_isDue_boundary() public pure {
        assertFalse(ScheduleLib.isDue(100, 99));
        assertTrue(ScheduleLib.isDue(100, 100)); // due exactly at dueAt
        assertTrue(ScheduleLib.isDue(100, 101));
    }

    function testFuzz_nextDue_noOverflow(uint64 from, uint64 interval) public pure {
        // Constrain so from + interval cannot overflow uint64.
        from = uint64(bound(from, 0, type(uint64).max - 1));
        interval = uint64(bound(interval, 1, type(uint64).max - from));

        uint64 next = ScheduleLib.nextDue(from, interval);
        assertEq(next, from + interval);
        assertGt(next, from); // strictly advances when interval > 0
    }

    function testFuzz_nextDue_revertsOnOverflow(uint64 from, uint64 interval) public {
        from = uint64(bound(from, 1, type(uint64).max));
        interval = uint64(bound(interval, type(uint64).max - from + 1, type(uint64).max));

        vm.expectRevert(stdError.arithmeticError);
        this.callNextDue(from, interval);
    }

    function callNextDue(uint64 from, uint64 interval) external pure returns (uint64) {
        return ScheduleLib.nextDue(from, interval);
    }

    function testFuzz_isDue_monotonic(uint64 dueAt, uint64 nowTs) public pure {
        assertEq(ScheduleLib.isDue(dueAt, nowTs), nowTs >= dueAt);
    }
}

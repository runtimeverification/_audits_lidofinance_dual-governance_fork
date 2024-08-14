// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {State as DualGovernanceState} from "contracts/libraries/DualGovernanceStateMachine.sol";
import {Tiebreaker} from "contracts/libraries/Tiebreaker.sol";
import {Duration, Durations, Timestamp, Timestamps} from "contracts/types/Duration.sol";
import {ISealable} from "contracts/interfaces/ISealable.sol";

import {UnitTest} from "test/utils/unit-test.sol";
import {SealableMock} from "../../mocks/SealableMock.sol";

contract TiebreakerTest is UnitTest {
    using EnumerableSet for EnumerableSet.AddressSet;

    Tiebreaker.Context private context;
    SealableMock private mockSealable1;
    SealableMock private mockSealable2;

    function setUp() external {
        mockSealable1 = new SealableMock();
        mockSealable2 = new SealableMock();
    }

    function test_addSealableWithdrawalBlocker() external {
        vm.expectEmit();
        emit Tiebreaker.SealableWithdrawalBlockerAdded(address(mockSealable1));
        Tiebreaker.addSealableWithdrawalBlocker(context, address(mockSealable1), 1);

        assertTrue(context.sealableWithdrawalBlockers.contains(address(mockSealable1)));
    }

    function test_AddSealableWithdrawalBlocker_RevertOn_LimitReached() external {
        Tiebreaker.addSealableWithdrawalBlocker(context, address(mockSealable1), 1);

        vm.expectRevert(Tiebreaker.SealableWithdrawalBlockersLimitReached.selector);
        Tiebreaker.addSealableWithdrawalBlocker(context, address(mockSealable2), 1);
    }

    function test_AddSealableWithdrawalBlocker_RevertOn_InvalidSealable() external {
        mockSealable1.setShouldRevertIsPaused(true);

        vm.expectRevert(abi.encodeWithSelector(Tiebreaker.InvalidSealable.selector, address(mockSealable1)));
        // external call should be used to intercept the revert
        this.external__addSealableWithdrawalBlocker(address(mockSealable1));

        vm.expectRevert();
        // external call should be used to intercept the revert
        this.external__addSealableWithdrawalBlocker(address(0x123));
    }

    function test_RemoveSealableWithdrawalBlocker() external {
        Tiebreaker.addSealableWithdrawalBlocker(context, address(mockSealable1), 1);
        assertTrue(context.sealableWithdrawalBlockers.contains(address(mockSealable1)));

        vm.expectEmit();
        emit Tiebreaker.SealableWithdrawalBlockerRemoved(address(mockSealable1));

        Tiebreaker.removeSealableWithdrawalBlocker(context, address(mockSealable1));
        assertFalse(context.sealableWithdrawalBlockers.contains(address(mockSealable1)));
    }

    function test_SetTiebreakerCommittee() external {
        address newCommittee = address(0x123);

        vm.expectEmit();
        emit Tiebreaker.TiebreakerCommitteeSet(newCommittee);
        Tiebreaker.setTiebreakerCommittee(context, newCommittee);

        assertEq(context.tiebreakerCommittee, newCommittee);
    }

    function test_SetTiebreakerCommittee_WithExistingCommitteeAddress() external {
        address newCommittee = address(0x123);

        Tiebreaker.setTiebreakerCommittee(context, newCommittee);
        Tiebreaker.setTiebreakerCommittee(context, newCommittee);
    }

    function test_SetTiebreakerCommittee_RevertOn_ZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(Tiebreaker.InvalidTiebreakerCommittee.selector, address(0)));
        Tiebreaker.setTiebreakerCommittee(context, address(0));
    }

    function testFuzz_SetTiebreakerActivationTimeout(uint32 minTimeout, uint32 maxTimeout, uint32 timeout) external {
        vm.assume(minTimeout < timeout && timeout < maxTimeout);

        Duration min = Duration.wrap(minTimeout);
        Duration max = Duration.wrap(maxTimeout);
        Duration newTimeout = Duration.wrap(timeout);

        vm.expectEmit();
        emit Tiebreaker.TiebreakerActivationTimeoutSet(newTimeout);

        Tiebreaker.setTiebreakerActivationTimeout(context, min, newTimeout, max);
        assertEq(context.tiebreakerActivationTimeout, newTimeout);
    }

    function test_SetTiebreakerActivationTimeout_RevertOn_InvalidTimeout() external {
        Duration minTimeout = Duration.wrap(1 days);
        Duration maxTimeout = Duration.wrap(10 days);
        Duration newTimeout = Duration.wrap(15 days);

        vm.expectRevert(abi.encodeWithSelector(Tiebreaker.InvalidTiebreakerActivationTimeout.selector, newTimeout));
        Tiebreaker.setTiebreakerActivationTimeout(context, minTimeout, newTimeout, maxTimeout);

        newTimeout = Duration.wrap(0 days);

        vm.expectRevert(abi.encodeWithSelector(Tiebreaker.InvalidTiebreakerActivationTimeout.selector, newTimeout));
        Tiebreaker.setTiebreakerActivationTimeout(context, minTimeout, newTimeout, maxTimeout);
    }

    function test_IsSomeSealableWithdrawalBlockerPaused() external {
        mockSealable1.pauseFor(1 days);
        Tiebreaker.addSealableWithdrawalBlocker(context, address(mockSealable1), 2);

        bool result = Tiebreaker.isSomeSealableWithdrawalBlockerPaused(context);
        assertTrue(result);

        mockSealable1.resume();

        result = Tiebreaker.isSomeSealableWithdrawalBlockerPaused(context);
        assertFalse(result);

        mockSealable1.setShouldRevertIsPaused(true);

        result = Tiebreaker.isSomeSealableWithdrawalBlockerPaused(context);
        assertTrue(result);
    }

    function test_CheckTie() external {
        Timestamp cooldownExitedAt = Timestamps.from(block.timestamp);

        Tiebreaker.addSealableWithdrawalBlocker(context, address(mockSealable1), 1);
        Tiebreaker.setTiebreakerActivationTimeout(
            context, Duration.wrap(1 days), Duration.wrap(3 days), Duration.wrap(10 days)
        );

        mockSealable1.pauseFor(1 days);
        Tiebreaker.checkTie(context, DualGovernanceState.RageQuit, cooldownExitedAt);

        _wait(Duration.wrap(3 days));
        Tiebreaker.checkTie(context, DualGovernanceState.VetoSignalling, cooldownExitedAt);
    }

    function test_CheckTie_RevertOn_NormalOrVetoCooldownState() external {
        Timestamp cooldownExitedAt = Timestamps.from(block.timestamp);

        vm.expectRevert(Tiebreaker.TiebreakNotAllowed.selector);
        Tiebreaker.checkTie(context, DualGovernanceState.Normal, cooldownExitedAt);

        vm.expectRevert(Tiebreaker.TiebreakNotAllowed.selector);
        Tiebreaker.checkTie(context, DualGovernanceState.VetoCooldown, cooldownExitedAt);
    }

    function test_CheckCallerIsTiebreakerCommittee() external {
        context.tiebreakerCommittee = address(this);

        vm.expectRevert(abi.encodeWithSelector(Tiebreaker.CallerIsNotTiebreakerCommittee.selector, address(0x456)));
        vm.prank(address(0x456));
        this.external__checkCallerIsTiebreakerCommittee();

        this.external__checkCallerIsTiebreakerCommittee();
    }

    function test_GetTimebreakerInfo() external {
        Tiebreaker.addSealableWithdrawalBlocker(context, address(mockSealable1), 1);

        Duration minTimeout = Duration.wrap(1 days);
        Duration maxTimeout = Duration.wrap(10 days);
        Duration timeout = Duration.wrap(5 days);

        context.tiebreakerActivationTimeout = timeout;
        context.tiebreakerCommittee = address(0x123);

        (address committee, Duration activationTimeout, address[] memory blockers) =
            Tiebreaker.getTiebreakerInfo(context);

        assertEq(committee, context.tiebreakerCommittee);
        assertEq(activationTimeout, context.tiebreakerActivationTimeout);
        assertEq(blockers[0], address(mockSealable1));
        assertEq(blockers.length, 1);
    }

    function external__checkCallerIsTiebreakerCommittee() external {
        Tiebreaker.checkCallerIsTiebreakerCommittee(context);
    }

    function external__addSealableWithdrawalBlocker(address sealable) external {
        Tiebreaker.addSealableWithdrawalBlocker(context, sealable, 1);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IDangerousContract,
    ScenarioTestBlueprint,
    ExternalCall,
    ExternalCallHelpers,
    DualGovernance,
    Timestamp,
    Timestamps,
    Durations
} from "../utils/scenario-test-blueprint.sol";

import {ExecutableProposals} from "contracts/libraries/ExecutableProposals.sol";
import {EmergencyProtection} from "contracts/libraries/EmergencyProtection.sol";

contract PlanBSetup is ScenarioTestBlueprint {
    function setUp() external {
        _selectFork();
        _deployTarget();
        _deployTimelockedGovernanceSetup( /* isEmergencyProtectionEnabled */ true);
    }

    function testFork_PlanB_Scenario() external {
        ExternalCall[] memory regularStaffCalls = _getTargetRegularStaffCalls();

        // ---
        // ACT 1. 📈 DAO OPERATES AS USUALLY
        // ---
        {
            uint256 proposalId = _submitProposal(
                _timelockedGovernance, "DAO does regular staff on potentially dangerous contract", regularStaffCalls
            );

            _assertProposalSubmitted(proposalId);
            _assertSubmittedProposalData(proposalId, regularStaffCalls);
            _assertCanSchedule(_timelockedGovernance, proposalId, false);

            _waitAfterSubmitDelayPassed();

            _assertCanSchedule(_timelockedGovernance, proposalId, true);
            _scheduleProposal(_timelockedGovernance, proposalId);
            _assertProposalScheduled(proposalId);

            _waitAfterScheduleDelayPassed();

            _assertCanExecute(proposalId, true);
            _executeProposal(proposalId);

            _assertTargetMockCalls(_timelock.getAdminExecutor(), regularStaffCalls);
        }

        // ---
        // ACT 2. 😱 DAO IS UNDER ATTACK
        // ---
        uint256 maliciousProposalId;
        EmergencyProtection.Context memory emergencyState;
        {
            // Malicious vote was proposed by the attacker with huge LDO wad (but still not the majority)
            ExternalCall[] memory maliciousCalls =
                ExternalCallHelpers.create(address(_target), abi.encodeCall(IDangerousContract.doRugPool, ()));

            maliciousProposalId = _submitProposal(_timelockedGovernance, "Rug Pool attempt", maliciousCalls);

            // the call isn't executable until the delay has passed
            _assertProposalSubmitted(maliciousProposalId);
            _assertCanSchedule(_timelockedGovernance, maliciousProposalId, false);

            // some time required to assemble the emergency committee and activate emergency mode
            _wait(_timelock.getAfterSubmitDelay().dividedBy(2));

            // malicious call still can't be scheduled
            _assertCanSchedule(_timelockedGovernance, maliciousProposalId, false);

            // emergency committee activates emergency mode
            vm.prank(address(_emergencyActivationCommittee));
            _timelock.activateEmergencyMode();

            // emergency mode was successfully activated
            Timestamp expectedEmergencyModeEndTimestamp = _EMERGENCY_MODE_DURATION.addTo(Timestamps.now());
            emergencyState = _timelock.getEmergencyProtectionContext();

            assertTrue(_timelock.isEmergencyModeActive());
            assertEq(emergencyState.emergencyModeEndsAfter, expectedEmergencyModeEndTimestamp);

            // after the submit delay has passed, the call still may be scheduled, but executed
            // only the emergency committee
            _wait(_timelock.getAfterSubmitDelay().dividedBy(2).plusSeconds(1));

            _assertCanSchedule(_timelockedGovernance, maliciousProposalId, true);
            _scheduleProposal(_timelockedGovernance, maliciousProposalId);

            _waitAfterScheduleDelayPassed();

            // but the call still not executable
            _assertCanExecute(maliciousProposalId, false);

            vm.expectRevert(abi.encodeWithSelector(EmergencyProtection.InvalidEmergencyModeState.selector, true));
            _executeProposal(maliciousProposalId);
        }

        // ---
        // ACT 3. 🔫 DAO STRIKES BACK (WITH DUAL GOVERNANCE SHIPMENT)
        // ---
        {
            // Lido contributors work hard to implement and ship the Dual Governance mechanism
            // before the emergency mode is over
            _wait(_EMERGENCY_PROTECTION_DURATION.dividedBy(2));

            // Time passes but malicious proposal still on hold
            _assertCanExecute(maliciousProposalId, false);

            // Dual Governance is deployed into mainnet
            _deployDualGovernance();

            ExternalCall[] memory dualGovernanceLaunchCalls = ExternalCallHelpers.create(
                address(_timelock),
                [
                    // Only Dual Governance contract can call the Timelock contract
                    abi.encodeCall(_timelock.setGovernance, (address(_dualGovernance))),
                    // Now the emergency mode may be deactivated (all scheduled calls will be canceled)
                    abi.encodeCall(_timelock.deactivateEmergencyMode, ()),
                    // Setup emergency committee for some period of time until the Dual Governance is battle tested
                    abi.encodeCall(
                        _timelock.setupEmergencyProtection,
                        (
                            address(_ADMIN_PROPOSER), // DAO_VOTING TODO: declare variable in scenario test blueprint
                            address(_emergencyActivationCommittee),
                            address(_emergencyExecutionCommittee),
                            _EMERGENCY_PROTECTION_DURATION.addTo(Timestamps.now()),
                            Durations.from(30 days)
                        )
                    )
                ]
            );

            // The vote to launch Dual Governance is launched and reached the quorum (the major part of LDO holder still have power)
            uint256 dualGovernanceLunchProposalId =
                _submitProposal(_timelockedGovernance, "Launch the Dual Governance", dualGovernanceLaunchCalls);

            // wait until the after submit delay has passed
            _waitAfterSubmitDelayPassed();

            _assertCanSchedule(_timelockedGovernance, dualGovernanceLunchProposalId, true);
            _scheduleProposal(_timelockedGovernance, dualGovernanceLunchProposalId);
            _assertProposalScheduled(dualGovernanceLunchProposalId);

            _waitAfterScheduleDelayPassed();

            // now emergency committee may execute the proposal
            _executeEmergencyExecute(dualGovernanceLunchProposalId);

            assertEq(_timelock.getGovernance(), address(_dualGovernance));
            // TODO: check emergency protection also was applied

            // malicious proposal now cancelled
            _assertProposalCancelled(maliciousProposalId);
        }

        // ---
        // ACT 4. 🫡 EMERGENCY COMMITTEE LIFETIME IS ENDED
        // ---
        {
            _wait(_EMERGENCY_PROTECTION_DURATION.plusSeconds(1));
            assertFalse(_timelock.isEmergencyProtectionEnabled());

            uint256 proposalId = _submitProposal(
                _dualGovernance, "DAO continues regular staff on potentially dangerous contract", regularStaffCalls
            );
            _assertProposalSubmitted(proposalId);
            _assertSubmittedProposalData(proposalId, regularStaffCalls);

            _waitAfterSubmitDelayPassed();

            _assertCanSchedule(_dualGovernance, proposalId, true);
            _scheduleProposal(_dualGovernance, proposalId);

            _waitAfterScheduleDelayPassed();

            // but the call still not executable
            _assertCanExecute(proposalId, true);
            _executeProposal(proposalId);

            _assertTargetMockCalls(_timelock.getAdminExecutor(), regularStaffCalls);
        }
        // TODO: update the deployment logic below
        // // ---
        // // ACT 5. 🔜 NEW DUAL GOVERNANCE VERSION IS COMING
        // // ---
        // {
        //     // some time later, the major Dual Governance update release is ready to be launched
        //     _wait(Durations.from(365 days));
        //     DualGovernance dualGovernanceV2 =
        //         new DualGovernance(address(_config), address(_timelock), address(_escrowMasterCopy), _ADMIN_PROPOSER);

        //     ExternalCall[] memory dualGovernanceUpdateCalls = ExternalCallHelpers.create(
        //         address(_timelock),
        //         [
        //             // Update the controller for timelock
        //             abi.encodeCall(_timelock.setGovernance, address(dualGovernanceV2)),
        //             // Assembly the emergency committee again, until the new version of Dual Governance is battle tested
        //             abi.encodeCall(
        //                 _timelock.setEmergencyProtection,
        //                 (
        //                     address(_emergencyActivationCommittee),
        //                     address(_emergencyExecutionCommittee),
        //                     _EMERGENCY_PROTECTION_DURATION,
        //                     Durations.from(30 days)
        //                 )
        //             )
        //         ]
        //     );

        //     uint256 updateDualGovernanceProposalId =
        //         _submitProposal(_dualGovernance, "Update Dual Governance to V2", dualGovernanceUpdateCalls);

        //     _waitAfterSubmitDelayPassed();

        //     _assertCanSchedule(_dualGovernance, updateDualGovernanceProposalId, true);
        //     _scheduleProposal(_dualGovernance, updateDualGovernanceProposalId);

        //     _waitAfterScheduleDelayPassed();

        //     // but the call still not executable
        //     _assertCanExecute(updateDualGovernanceProposalId, true);
        //     _executeProposal(updateDualGovernanceProposalId);

        //     // new version of dual governance attached to timelock
        //     assertEq(_timelock.getGovernance(), address(dualGovernanceV2));

        //     // - emergency protection enabled
        //     assertTrue(_timelock.isEmergencyProtectionEnabled());

        //     emergencyState = _timelock.getEmergencyState();
        //     assertEq(emergencyState.activationCommittee, address(_emergencyActivationCommittee));
        //     assertEq(emergencyState.executionCommittee, address(_emergencyExecutionCommittee));
        //     assertFalse(emergencyState.isEmergencyModeActivated);
        //     assertEq(emergencyState.emergencyModeDuration, Durations.from(30 days));
        //     assertEq(emergencyState.emergencyModeEndsAfter, Timestamps.ZERO);

        //     // use the new version of the dual governance in the future calls
        //     _dualGovernance = dualGovernanceV2;
        // }

        // // ---
        // // ACT 7. 📆 DAO CONTINUES THEIR REGULAR DUTIES (PROTECTED BY DUAL GOVERNANCE V2)
        // // ---
        // {
        //     uint256 proposalId = _submitProposal(
        //         _dualGovernance, "DAO does regular staff on potentially dangerous contract", regularStaffCalls
        //     );
        //     _assertProposalSubmitted(proposalId);
        //     _assertSubmittedProposalData(proposalId, regularStaffCalls);

        //     _waitAfterSubmitDelayPassed();

        //     _assertCanSchedule(_dualGovernance, proposalId, true);
        //     _scheduleProposal(_dualGovernance, proposalId);
        //     _assertProposalScheduled(proposalId);

        //     // wait while the after schedule delay has passed
        //     _waitAfterScheduleDelayPassed();

        //     // execute the proposal
        //     _assertCanExecute(proposalId, true);
        //     _executeProposal(proposalId);
        //     _assertProposalExecuted(proposalId);

        //     // call successfully executed
        //     _assertTargetMockCalls(_timelock.getAdminExecutor(), regularStaffCalls);
        // }
    }

    function testFork_SubmittedCallsCantBeExecutedAfterEmergencyModeDeactivation() external {
        ExternalCall[] memory maliciousCalls =
            ExternalCallHelpers.create(address(_target), abi.encodeCall(IDangerousContract.doRugPool, ()));

        // schedule some malicious call
        uint256 maliciousProposalId;
        {
            maliciousProposalId = _submitProposal(_timelockedGovernance, "Rug Pool attempt", maliciousCalls);

            // malicious calls can't be executed until the delays have passed
            _assertCanSchedule(_timelockedGovernance, maliciousProposalId, false);
        }

        // activate emergency mode
        EmergencyProtection.Context memory emergencyState;
        {
            _wait(_timelock.getAfterSubmitDelay().dividedBy(2));

            vm.prank(address(_emergencyActivationCommittee));
            _timelock.activateEmergencyMode();

            assertTrue(_timelock.isEmergencyModeActive());
        }

        // delay for malicious proposal has passed, but it can't be executed because of emergency mode was activated
        {
            // the after submit delay has passed, and proposal can be scheduled, but not executed
            _wait(_timelock.getAfterScheduleDelay() + Durations.from(1 seconds));
            _wait(_timelock.getAfterSubmitDelay().plusSeconds(1));
            _assertCanSchedule(_timelockedGovernance, maliciousProposalId, true);

            _scheduleProposal(_timelockedGovernance, maliciousProposalId);

            _wait(_timelock.getAfterScheduleDelay().plusSeconds(1));
            _assertCanExecute(maliciousProposalId, false);

            vm.expectRevert(abi.encodeWithSelector(EmergencyProtection.InvalidEmergencyModeState.selector, true));
            _executeProposal(maliciousProposalId);
        }

        // another malicious call is scheduled during the emergency mode also can't be executed
        uint256 anotherMaliciousProposalId;
        {
            _wait(_EMERGENCY_MODE_DURATION.dividedBy(2));

            // emergency mode still active
            assertTrue(emergencyState.emergencyModeEndsAfter > Timestamps.now());

            anotherMaliciousProposalId =
                _submitProposal(_timelockedGovernance, "Another Rug Pool attempt", maliciousCalls);

            // malicious calls can't be executed until the delays have passed
            _assertCanExecute(anotherMaliciousProposalId, false);

            // the after submit delay has passed, and proposal can not be executed
            _wait(_timelock.getAfterSubmitDelay().plusSeconds(1));
            _assertCanSchedule(_timelockedGovernance, anotherMaliciousProposalId, true);

            _wait(_timelock.getAfterScheduleDelay().plusSeconds(1));
            _assertCanExecute(anotherMaliciousProposalId, false);

            vm.expectRevert(abi.encodeWithSelector(EmergencyProtection.InvalidEmergencyModeState.selector, true));
            _executeProposal(anotherMaliciousProposalId);
        }

        // emergency mode is over but proposals can't be executed until the emergency mode turned off manually
        {
            _wait(_EMERGENCY_MODE_DURATION.dividedBy(2));
            assertTrue(emergencyState.emergencyModeEndsAfter < Timestamps.now());

            vm.expectRevert(abi.encodeWithSelector(EmergencyProtection.InvalidEmergencyModeState.selector, true));
            _executeProposal(maliciousProposalId);

            vm.expectRevert(abi.encodeWithSelector(EmergencyProtection.InvalidEmergencyModeState.selector, true));
            _executeProposal(anotherMaliciousProposalId);
        }

        // anyone can deactivate emergency mode when it's over
        {
            _timelock.deactivateEmergencyMode();

            assertFalse(_timelock.isEmergencyModeActive());
            assertFalse(_timelock.isEmergencyProtectionEnabled());
        }

        // all malicious calls is canceled now and can't be executed
        {
            _assertProposalCancelled(maliciousProposalId);
            _assertProposalCancelled(anotherMaliciousProposalId);

            vm.expectRevert(
                abi.encodeWithSelector(ExecutableProposals.ProposalNotScheduled.selector, maliciousProposalId)
            );
            _executeProposal(maliciousProposalId);

            vm.expectRevert(
                abi.encodeWithSelector(ExecutableProposals.ProposalNotScheduled.selector, anotherMaliciousProposalId)
            );
            _executeProposal(anotherMaliciousProposalId);
        }
    }

    function testFork_EmergencyResetGovernance() external {
        // deploy dual governance full setup
        {
            _deployDualGovernanceSetup( /* isEmergencyProtectionEnabled */ true);
            assertNotEq(_timelock.getGovernance(), _timelock.getEmergencyProtectionContext().emergencyGovernance);
        }

        // emergency committee activates emergency mode
        EmergencyProtection.Context memory emergencyState;
        {
            vm.prank(address(_emergencyActivationCommittee));
            _timelock.activateEmergencyMode();

            assertFalse(_timelock.isEmergencyModeActive());
        }

        // before the end of the emergency mode emergency committee can reset the controller to
        // disable dual governance
        {
            _wait(_EMERGENCY_MODE_DURATION.dividedBy(2));
            assertTrue(emergencyState.emergencyModeEndsAfter > Timestamps.now());

            _executeEmergencyReset();

            assertEq(_timelock.getGovernance(), _timelock.getEmergencyProtectionContext().emergencyGovernance);

            emergencyState = _timelock.getEmergencyProtectionContext();
            assertEq(emergencyState.emergencyActivationCommittee, address(0));
            assertEq(emergencyState.emergencyExecutionCommittee, address(0));
            assertEq(emergencyState.emergencyModeDuration, Durations.ZERO);
            assertEq(emergencyState.emergencyModeEndsAfter, Timestamps.ZERO);
            assertFalse(_timelock.isEmergencyModeActive());
        }
    }

    function testFork_ExpiredEmergencyCommitteeHasNoPower() external {
        // deploy dual governance full setup
        {
            _deployDualGovernanceSetup( /* isEmergencyProtectionEnabled */ true);
            assertNotEq(_timelock.getGovernance(), _timelock.getEmergencyProtectionContext().emergencyGovernance);
        }

        // wait till the protection duration passes
        {
            _wait(_EMERGENCY_PROTECTION_DURATION.plusSeconds(1));
        }

        EmergencyProtection.Context memory emergencyState = _timelock.getEmergencyProtectionContext();

        // attempt to activate emergency protection fails
        {
            vm.expectRevert(
                abi.encodeWithSelector(
                    EmergencyProtection.EmergencyProtectionExpired.selector, emergencyState.emergencyProtectionEndsAfter
                )
            );
            vm.prank(address(_emergencyActivationCommittee));
            _timelock.activateEmergencyMode();
        }
    }
}

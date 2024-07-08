pragma solidity 0.8.23;

import "test/kontrol/DualGovernanceSetUp.sol";

contract ProposalOperationsTest is DualGovernanceSetUp {
    // ?STORAGE3
    // ?WORD21: nextProposalId
    // ?WROD22: emergencyModeActive
    function _timelockSetup() internal {
        // Slot 6: nextProposalId
        uint256 nextProposalId = kevm.freshUInt(32);
        vm.assume(nextProposalId < type(uint256).max);
        _storeUInt256(address(timelock), 6, nextProposalId);
        // Slot 7: emergencyModeActive
        uint8 emergencyModeActive = uint8(kevm.freshUInt(1));
        vm.assume(emergencyModeActive < 2);
        _storeUInt256(address(timelock), 7, uint256(emergencyModeActive));
    }

    // Set up the storage for a proposal.
    // ?WORD23: numCalls
    // ?WORD24: submissionTime
    // ?WORD25: schedulingTime
    // ?WORD26: status
    function _proposalStorageSetup(uint256 proposalId) internal {
        // Slot 5
        // Proposal: id
        uint256 slot = uint256(keccak256(abi.encodePacked(proposalId, uint256(5))));
        vm.assume(slot <= type(uint256).max - 5);
        _storeUInt256(address(timelock), slot, proposalId);
        // Proposal: proposer
        address proposer = address(uint160(uint256(keccak256("proposer"))));
        vm.assume(dualGovernance.proposers(proposer));
        _storeAddress(address(timelock), slot + 1, proposer);
        // Proposal: ExecutorCall
        uint256 numCalls = kevm.freshUInt(32);
        vm.assume(numCalls > 0);
        uint256 callsSlot = uint256(keccak256(abi.encodePacked(slot + 2)));
        _storeUInt256(address(timelock), callsSlot, numCalls);
        // Proposal: submissionTime
        uint256 submissionTime = kevm.freshUInt(32);
        vm.assume(submissionTime < timeUpperBound);
        _storeUInt256(address(timelock), slot + 3, submissionTime);
        // Proposal: schedulingTime
        uint256 schedulingTime = kevm.freshUInt(32);
        vm.assume(schedulingTime < timeUpperBound);
        _storeUInt256(address(timelock), slot + 4, schedulingTime);
        // Proposal: status
        uint256 statusIndex = kevm.freshUInt(32);
        vm.assume(statusIndex < 4);
        ProposalStatus status = ProposalStatus(statusIndex);
        _storeUInt256(address(timelock), slot + 5, uint256(status));
    }

    struct ProposalRecord {
        DualGovernanceModel.State state;
        ProposalStatus status;
        uint256 submissionTime;
        uint256 schedulingTime;
        uint256 lastVetoSignallingTime;
    }

    // Record a proposal's details with the current governance state.
    function _recordProposal(uint256 proposalId) internal view returns (ProposalRecord memory pr) {
        (,, uint256 submissionTime, uint256 schedulingTime, ProposalStatus status) = timelock.proposals(proposalId);
        pr.state = dualGovernance.currentState();
        pr.status = status;
        pr.submissionTime = submissionTime;
        pr.schedulingTime = schedulingTime;
        pr.lastVetoSignallingTime = dualGovernance.lastVetoSignallingTime();
    }

    // Validate that a pending proposal meets the criteria.
    function _validPendingProposal(Mode mode, ProposalRecord memory pr) internal view {
        _establish(mode, pr.status == ProposalStatus.Pending);
        _establish(mode, pr.submissionTime <= block.timestamp);
        _establish(mode, pr.schedulingTime == 0);
    }

    // Validate that a scheduled proposal meets the criteria.
    function _validScheduledProposal(Mode mode, ProposalRecord memory pr) internal view {
        _establish(mode, pr.status == ProposalStatus.Scheduled);
        _establish(mode, pr.submissionTime <= block.timestamp);
        _establish(mode, block.timestamp >= pr.submissionTime + timelock.PROPOSAL_EXECUTION_MIN_TIMELOCK());
        _establish(mode, pr.schedulingTime <= block.timestamp);
        _establish(mode, pr.schedulingTime >= pr.submissionTime);
    }

    function _validExecutedProposal(Mode mode, ProposalRecord memory pr) internal view {
        _establish(mode, pr.status == ProposalStatus.Executed);
        _establish(mode, pr.submissionTime <= block.timestamp);
        _establish(mode, block.timestamp >= pr.submissionTime + timelock.PROPOSAL_EXECUTION_MIN_TIMELOCK());
        _establish(mode, pr.schedulingTime <= block.timestamp);
        _establish(mode, pr.schedulingTime >= pr.submissionTime);
    }

    function _validCanceledProposal(Mode mode, ProposalRecord memory pr) internal view {
        _establish(mode, pr.status == ProposalStatus.Canceled);
        _establish(mode, pr.submissionTime <= block.timestamp);
    }

    // Function to handle common assumptions.
    function _commonAssumptions() internal {
        vm.assume(block.timestamp < timeUpperBound);
        vm.assume(timelock.governance() == address(dualGovernance));
        uint256 emergencyProtectionTimelock = kevm.freshUInt(32);
        vm.assume(emergencyProtectionTimelock < timeUpperBound);
        vm.assume(timelock.emergencyProtectionTimelock() == emergencyProtectionTimelock);
    }

    /**
     * Test that proposals cannot be submitted in the VetoSignallingDeactivation and VetoCooldown states.
     */
    function testCannotProposeInInvalidState() external {
        _timelockSetup();
        vm.assume(block.timestamp < timeUpperBound);
        uint256 nextProposalId = timelock.nextProposalId();

        address proposer = address(uint160(uint256(keccak256("proposer"))));
        vm.assume(dualGovernance.proposers(proposer));
        DualGovernanceModel.State state = dualGovernance.currentState();

        vm.assume(
            state == DualGovernanceModel.State.VetoSignallingDeactivation
                || state == DualGovernanceModel.State.VetoCooldown
        );
        vm.prank(proposer);
        vm.expectRevert("Cannot submit in current state.");
        dualGovernance.submitProposal(new ExecutorCall[](1));

        assert(timelock.nextProposalId() == nextProposalId);
    }

    /**
     * Test that a proposal cannot be scheduled for execution if the Dual Governance state is not Normal or VetoCooldown.
     */
    function testCannotScheduleInInvalidStates(uint256 proposalId) external {
        _proposalStorageSetup(proposalId);
        _commonAssumptions();

        vm.assume(proposalId < timelock.nextProposalId());
        ProposalRecord memory pre = _recordProposal(proposalId);
        _validPendingProposal(Mode.Assume, pre);

        vm.assume(pre.state != DualGovernanceModel.State.Normal);
        vm.assume(pre.state != DualGovernanceModel.State.VetoCooldown);
        vm.expectRevert("Proposals can only be scheduled in Normal or Veto Cooldown states.");
        dualGovernance.scheduleProposal(proposalId);

        ProposalRecord memory post = _recordProposal(proposalId);
        _validPendingProposal(Mode.Assert, post);
    }

    /**
     * Test that a proposal cannot be scheduled for execution if it was submitted after the last time the VetoSignalling state was entered.
     */
    function testCannotScheduleSubmissionAfterLastVetoSignalling(uint256 proposalId) external {
        _proposalStorageSetup(proposalId);
        _commonAssumptions();

        vm.assume(proposalId < timelock.nextProposalId());
        ProposalRecord memory pre = _recordProposal(proposalId);
        _validPendingProposal(Mode.Assume, pre);
        vm.assume(pre.state == DualGovernanceModel.State.VetoCooldown);

        vm.assume(pre.submissionTime >= pre.lastVetoSignallingTime);
        vm.expectRevert("Proposal submitted after the last time Veto Signalling state was entered.");
        dualGovernance.scheduleProposal(proposalId);

        ProposalRecord memory post = _recordProposal(proposalId);
        _validPendingProposal(Mode.Assert, post);
    }

    // Test that actions that are canceled or executed cannot be rescheduled
    function testCanceledOrExecutedActionsCannotBeRescheduled(uint256 proposalId) public {
        _timelockSetup();
        _proposalStorageSetup(proposalId);
        _commonAssumptions();

        vm.assume(proposalId < timelock.nextProposalId());
        ProposalRecord memory pre = _recordProposal(proposalId);
        vm.assume(pre.state == DualGovernanceModel.State.Normal || pre.state == DualGovernanceModel.State.VetoCooldown);

        if (pre.state == DualGovernanceModel.State.VetoCooldown) {
            vm.assume(pre.submissionTime < pre.lastVetoSignallingTime);
        }

        vm.assume(pre.status == ProposalStatus.Canceled || pre.status == ProposalStatus.Executed);

        vm.expectRevert("Proposal must be in Pending status.");
        dualGovernance.scheduleProposal(proposalId);

        ProposalRecord memory post = _recordProposal(proposalId);
        _validPendingProposal(Mode.Assert, post);
    }

    /**
     * Test that a proposal cannot be scheduled for execution before ProposalExecutionMinTimelock has passed since its submission.
     */
    function testCannotScheduleBeforeMinTimelock(uint256 proposalId) external {
        _timelockSetup();
        _proposalStorageSetup(proposalId);
        _commonAssumptions();

        vm.assume(proposalId < timelock.nextProposalId());
        ProposalRecord memory pre = _recordProposal(proposalId);
        _validPendingProposal(Mode.Assume, pre);

        uint256 schedulingMinDelay = pre.submissionTime + timelock.PROPOSAL_EXECUTION_MIN_TIMELOCK();

        vm.assume(pre.state == DualGovernanceModel.State.Normal || pre.state == DualGovernanceModel.State.VetoCooldown);

        if (pre.state == DualGovernanceModel.State.VetoCooldown) {
            vm.assume(pre.submissionTime < pre.lastVetoSignallingTime);
        }

        vm.assume(block.timestamp < schedulingMinDelay);
        vm.expectRevert("Required time since submission has not yet elapsed.");
        dualGovernance.scheduleProposal(proposalId);

        ProposalRecord memory post = _recordProposal(proposalId);
        _validPendingProposal(Mode.Assert, post);
    }

    function testSchedulingSuccess(uint256 proposalId) external {
        _timelockSetup();
        _proposalStorageSetup(proposalId);
        _commonAssumptions();

        vm.assume(proposalId < timelock.nextProposalId());
        ProposalRecord memory pre = _recordProposal(proposalId);
        _validPendingProposal(Mode.Assume, pre);

        uint256 schedulingMinDelay = pre.submissionTime + timelock.PROPOSAL_EXECUTION_MIN_TIMELOCK();
        vm.assume(pre.state == DualGovernanceModel.State.Normal || pre.state == DualGovernanceModel.State.VetoCooldown);

        if (pre.state == DualGovernanceModel.State.VetoCooldown) {
            vm.assume(pre.submissionTime < pre.lastVetoSignallingTime);
        }

        vm.assume(block.timestamp >= schedulingMinDelay);
        dualGovernance.scheduleProposal(proposalId);

        ProposalRecord memory post = _recordProposal(proposalId);
        _validScheduledProposal(Mode.Assert, post);

        assert(post.state == pre.state);
        assert(post.submissionTime == pre.submissionTime);
        assert(post.schedulingTime == block.timestamp);
    }

    /**
     * Test that a proposal cannot be executed until the emergency protection timelock has passed since it was scheduled.
     */
    function testCannotExecuteBeforeEmergencyProtectionTimelock(uint256 proposalId) external {
        _timelockSetup();
        _proposalStorageSetup(proposalId);
        _commonAssumptions();

        vm.assume(proposalId < timelock.nextProposalId());
        ProposalRecord memory pre = _recordProposal(proposalId);
        _validScheduledProposal(Mode.Assume, pre);

        uint256 executionMinDelay = pre.schedulingTime + timelock.emergencyProtectionTimelock();
        vm.assume(!timelock.emergencyModeActive());

        vm.assume(block.timestamp < executionMinDelay);
        vm.expectRevert("Scheduled time plus delay must pass before execution.");
        timelock.execute(proposalId);

        ProposalRecord memory post = _recordProposal(proposalId);
        _validScheduledProposal(Mode.Assert, post);
    }
}

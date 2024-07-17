// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {HashConsensus} from "./HashConsensus.sol";
import {ProposalsList} from "./ProposalsList.sol";

interface IDualGovernance {
    function tiebreakerScheduleProposal(uint256 proposalId) external;
    function tiebreakerResumeSealable(address sealable) external;
}

enum ProposalType {
    ScheduleProposal,
    ResumeSelable
}

/// @title Tiebreaker Core Contract
/// @notice This contract allows a committee to vote on and execute proposals for scheduling and resuming sealable addresses
/// @dev Inherits from HashConsensus for voting mechanisms and ProposalsList for proposal management
contract TiebreakerCore is HashConsensus, ProposalsList {
    error ResumeSealableNonceMismatch();

    address immutable DUAL_GOVERNANCE;

    mapping(address => uint256) private _sealableResumeNonces;

    constructor(
        address owner,
        address[] memory committeeMembers,
        uint256 executionQuorum,
        address dualGovernance,
        uint256 timelock
    ) HashConsensus(owner, committeeMembers, executionQuorum, timelock) {
        DUAL_GOVERNANCE = dualGovernance;
    }

    // ---
    // Schedule proposal
    // ---

    /// @notice Votes on a proposal to schedule
    /// @dev Allows committee members to vote on scheduling a proposal
    /// @param proposalId The ID of the proposal to schedule
    function scheduleProposal(uint256 proposalId) public onlyMember {
        (bytes memory proposalData, bytes32 key) = _encodeScheduleProposal(proposalId);
        _vote(key, true);
        _pushProposal(key, uint256(ProposalType.ScheduleProposal), proposalData);
    }

    /// @notice Gets the current state of a schedule proposal
    /// @dev Retrieves the state of the schedule proposal for a given proposal ID
    /// @param proposalId The ID of the proposal
    /// @return support The number of votes in support of the proposal
    /// @return execuitionQuorum The required number of votes for execution
    /// @return isExecuted Whether the proposal has been executed
    function getScheduleProposalState(uint256 proposalId)
        public
        view
        returns (uint256 support, uint256 execuitionQuorum, bool isExecuted)
    {
        (, bytes32 key) = _encodeScheduleProposal(proposalId);
        return _getHashState(key);
    }

    /// @notice Executes an approved schedule proposal
    /// @dev Executes the schedule proposal by calling the tiebreakerScheduleProposal function on the Dual Governance contract
    /// @param proposalId The ID of the proposal to schedule
    function executeScheduleProposal(uint256 proposalId) public {
        (, bytes32 key) = _encodeScheduleProposal(proposalId);
        _markUsed(key);
        Address.functionCall(
            DUAL_GOVERNANCE, abi.encodeWithSelector(IDualGovernance.tiebreakerScheduleProposal.selector, proposalId)
        );
    }

    /// @notice Encodes a schedule proposal
    /// @dev Internal function to encode the proposal data and generate the proposal key
    /// @param proposalId The ID of the proposal to schedule
    /// @return data The encoded proposal data
    /// @return key The generated proposal key
    function _encodeScheduleProposal(uint256 proposalId) internal pure returns (bytes memory data, bytes32 key) {
        data = abi.encode(ProposalType.ScheduleProposal, proposalId);
        key = keccak256(data);
    }

    // ---
    // Resume sealable
    // ---

    /// @notice Gets the current resume nonce for a sealable address
    /// @dev Retrieves the resume nonce for the given sealable address
    /// @param sealable The address of the sealable to get the nonce for
    /// @return The current resume nonce for the sealable address
    function getSealableResumeNonce(address sealable) public view returns (uint256) {
        return _sealableResumeNonces[sealable];
    }

    function sealableResume(address sealable, uint256 nonce) public onlyMember {
        if (nonce != _sealableResumeNonces[sealable]) {
            revert ResumeSealableNonceMismatch();
        }
        (bytes memory proposalData, bytes32 key) = _encodeSealableResume(sealable, nonce);
        _vote(key, true);
        _pushProposal(key, uint256(ProposalType.ResumeSelable), proposalData);
    }

    /// @notice Gets the current state of a resume sealable proposal
    /// @dev Retrieves the state of the resume sealable proposal for a given address and nonce
    /// @param sealable The address to resume
    /// @param nonce The nonce for the resume proposal
    /// @return support The number of votes in support of the proposal
    /// @return execuitionQuorum The required number of votes for execution
    /// @return isExecuted Whether the proposal has been executed
    function getSealableResumeState(
        address sealable,
        uint256 nonce
    ) public view returns (uint256 support, uint256 execuitionQuorum, bool isExecuted) {
        (, bytes32 key) = _encodeSealableResume(sealable, nonce);
        return _getHashState(key);
    }

    /// @notice Executes an approved resume sealable proposal
    /// @dev Executes the resume sealable proposal by calling the tiebreakerResumeSealable function on the Dual Governance contract
    /// @param sealable The address to resume
    function executeSealableResume(address sealable) external {
        (, bytes32 key) = _encodeSealableResume(sealable, _sealableResumeNonces[sealable]);
        _markUsed(key);
        _sealableResumeNonces[sealable]++;
        Address.functionCall(
            DUAL_GOVERNANCE, abi.encodeWithSelector(IDualGovernance.tiebreakerResumeSealable.selector, sealable)
        );
    }

    /// @notice Encodes a resume sealable proposal
    /// @dev Internal function to encode the proposal data and generate the proposal key
    /// @param sealable The address to resume
    /// @param nonce The nonce for the resume proposal
    /// @return data The encoded proposal data
    /// @return key The generated proposal key
    function _encodeSealableResume(
        address sealable,
        uint256 nonce
    ) private pure returns (bytes memory data, bytes32 key) {
        data = abi.encode(ProposalType.ResumeSelable, sealable, nonce);
        key = keccak256(data);
    }
}

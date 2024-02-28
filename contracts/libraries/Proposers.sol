// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

struct Proposer {
    bool isAdmin;
    address account;
    address executor;
}

struct ProposerData {
    address proposer;
    address executor;
    bool isAdmin;
}

library Proposers {
    using SafeCast for uint256;

    error NotProposer(address account);
    error NotAdminProposer(address account);
    error NotAdminExecutor(address account);
    error ProposerNotRegistered(address proposer);
    error ProposerAlreadyRegistered(address proposer);
    error InvalidAdminExecutor(address executor);
    error ExecutorNotRegistered(address account);

    event AdminExecutorSet(address indexed adminExecutor);
    event ProposerRegistered(address indexed proposer, address indexed executor);
    event ProposerUnregistered(address indexed proposer, address indexed executor);

    struct ExecutorData {
        uint8 proposerIndexOneBased; // indexed from 1. The count of executors is limited
        address executor;
    }

    struct State {
        address[] proposers;
        mapping(address proposer => ExecutorData) executors;
        mapping(address executor => uint256 usagesCount) executorRefsCounts;
        address adminExecutor;
    }

    function setAdminExecutor(State storage self, address adminExecutor) internal {
        if (adminExecutor == address(0) || self.adminExecutor == adminExecutor) {
            revert InvalidAdminExecutor(adminExecutor);
        }
        if (self.executorRefsCounts[adminExecutor] == 0) {
            revert ExecutorNotRegistered(adminExecutor);
        }
        self.adminExecutor = adminExecutor;
        emit AdminExecutorSet(adminExecutor);
    }

    function register(State storage self, address proposer, address executor) internal {
        if (self.executors[proposer].proposerIndexOneBased != 0) {
            revert ProposerAlreadyRegistered(proposer);
        }
        self.proposers.push(proposer);
        self.executors[proposer] = ExecutorData(self.proposers.length.toUint8(), executor);
        self.executorRefsCounts[executor] += 1;
        emit ProposerRegistered(proposer, executor);
    }

    function unregister(State storage self, address proposer) internal {
        uint256 proposerIndexToDelete;
        ExecutorData memory executorData = self.executors[proposer];
        unchecked {
            proposerIndexToDelete = executorData.proposerIndexOneBased - 1;
        }
        if (proposerIndexToDelete == type(uint256).max) {
            revert ProposerNotRegistered(proposer);
        }

        uint256 lastProposerIndex = self.proposers.length - 1;
        if (proposerIndexToDelete != lastProposerIndex) {
            self.proposers[proposerIndexToDelete] = self.proposers[lastProposerIndex];
        }
        self.proposers.pop();
        delete self.executors[proposer];
        self.executorRefsCounts[executorData.executor] -= 1;
        emit ProposerUnregistered(proposer, executorData.executor);
    }

    function all(State storage self) internal view returns (Proposer[] memory proposers) {
        proposers = new Proposer[](self.proposers.length);
        for (uint256 i = 0; i < proposers.length; ++i) {
            proposers[i] = get(self, self.proposers[i]);
        }
    }

    function get(State storage self, address account) internal view returns (Proposer memory proposer) {
        ExecutorData memory executorData = self.executors[account];
        if (executorData.proposerIndexOneBased == 0) {
            revert ProposerNotRegistered(account);
        }
        proposer.account = account;
        proposer.executor = executorData.executor;
    }

    function isProposer(State storage self, address account) internal view returns (bool) {
        return self.executors[account].proposerIndexOneBased != 0;
    }

    function isAdminProposer(State storage self, address account) internal view returns (bool) {
        ExecutorData memory executorData = self.executors[account];
        return executorData.proposerIndexOneBased != 0 && executorData.executor == self.adminExecutor;
    }

    function isExecutor(State storage self, address account) internal view returns (bool) {
        return self.executorRefsCounts[account] > 0;
    }

    function isAdminExecutor(State storage self, address account) internal view returns (bool) {
        return self.adminExecutor == account;
    }

    function checkProposer(State storage self, address account) internal view {
        if (!isProposer(self, account)) {
            revert NotProposer(account);
        }
    }

    function checkAdminProposer(State storage self, address account) internal view {
        checkProposer(self, account);
        if (!isAdminProposer(self, account)) {
            revert NotAdminProposer(account);
        }
    }

    function checkExecutor(State storage self, address account) internal view {
        if (!isExecutor(self, account)) {
            revert ExecutorNotRegistered(account);
        }
    }

    function checkAdminExecutor(State storage self, address account) internal view {
        checkExecutor(self, account);
        if (!isAdminExecutor(self, account)) {
            revert NotAdminExecutor(account);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IEscrow} from "./interfaces/IEscrow.sol";
import {IConfiguration} from "./interfaces/IConfiguration.sol";

import {IStETH} from "./interfaces/IStETH.sol";
import {IWstETH} from "./interfaces/IWstETH.sol";
import {IWithdrawalQueue, WithdrawalRequestStatus} from "./interfaces/IWithdrawalQueue.sol";

import {
    ETHValue,
    ETHValues,
    SharesValue,
    SharesValues,
    HolderAssets,
    StETHAccounting,
    UnstETHAccounting,
    AssetsAccounting
} from "./libraries/AssetsAccounting.sol";
import {WithdrawalsBatchesQueue} from "./libraries/WithdrawalBatchesQueue.sol";

interface IDualGovernance {
    function activateNextState() external;
}

enum EscrowState {
    NotInitialized,
    SignallingEscrow,
    RageQuitEscrow
}

struct LockedAssetsTotals {
    uint256 stETHLockedShares;
    uint256 stETHClaimedETH;
    uint256 unstETHUnfinalizedShares;
    uint256 unstETHFinalizedETH;
}

struct VetoerState {
    uint256 stETHLockedShares;
    uint256 unstETHLockedShares;
    uint256 unstETHIdsCount;
    uint256 lastAssetsLockTimestamp;
}

contract Escrow is IEscrow {
    using AssetsAccounting for AssetsAccounting.State;
    using WithdrawalsBatchesQueue for WithdrawalsBatchesQueue.State;

    error UnexpectedUnstETHId();
    error InvalidHintsLength(uint256 actual, uint256 expected);
    error ClaimingIsFinished();
    error InvalidBatchSize(uint256 size);
    error WithdrawalsTimelockNotPassed();
    error InvalidETHSender(address actual, address expected);
    error NotDualGovernance(address actual, address expected);
    error MasterCopyCallForbidden();
    error InvalidState(EscrowState actual, EscrowState expected);
    error RageQuitExtraTimelockNotStarted();

    address public immutable MASTER_COPY;

    // TODO: move to config
    uint256 public immutable MIN_BATCH_SIZE = 8;
    uint256 public immutable MAX_BATCH_SIZE = 128;

    uint256 public immutable MIN_WITHDRAWAL_REQUEST_AMOUNT;
    uint256 public immutable MAX_WITHDRAWAL_REQUEST_AMOUNT;

    IStETH public immutable ST_ETH;
    IWstETH public immutable WST_ETH;
    IWithdrawalQueue public immutable WITHDRAWAL_QUEUE;

    IConfiguration public immutable CONFIG;

    EscrowState internal _escrowState;
    IDualGovernance private _dualGovernance;
    AssetsAccounting.State private _accounting;
    WithdrawalsBatchesQueue.State private _batchesQueue;

    uint256 internal _rageQuitExtraTimelock;
    uint256 internal _rageQuitTimelockStartedAt;
    uint256 internal _rageQuitWithdrawalsTimelock;

    constructor(address stETH, address wstETH, address withdrawalQueue, address config) {
        ST_ETH = IStETH(stETH);
        WST_ETH = IWstETH(wstETH);
        MASTER_COPY = address(this);
        CONFIG = IConfiguration(config);
        WITHDRAWAL_QUEUE = IWithdrawalQueue(withdrawalQueue);
        MIN_WITHDRAWAL_REQUEST_AMOUNT = WITHDRAWAL_QUEUE.MIN_STETH_WITHDRAWAL_AMOUNT();
        MAX_WITHDRAWAL_REQUEST_AMOUNT = WITHDRAWAL_QUEUE.MAX_STETH_WITHDRAWAL_AMOUNT();
    }

    function initialize(address dualGovernance) external {
        if (address(this) == MASTER_COPY) {
            revert MasterCopyCallForbidden();
        }
        _checkEscrowState(EscrowState.NotInitialized);

        _escrowState = EscrowState.SignallingEscrow;
        _dualGovernance = IDualGovernance(dualGovernance);

        ST_ETH.approve(address(WST_ETH), type(uint256).max);
        ST_ETH.approve(address(WITHDRAWAL_QUEUE), type(uint256).max);
    }

    // ---
    // Lock & Unlock stETH
    // ---

    function lockStETH(uint256 amount) external {
        uint256 shares = ST_ETH.getSharesByPooledEth(amount);
        _accounting.accountStETHSharesLock(msg.sender, SharesValues.from(shares));
        ST_ETH.transferSharesFrom(msg.sender, address(this), shares);
        _activateNextGovernanceState();
    }

    function unlockStETH() external {
        _accounting.checkAssetsUnlockDelayPassed(msg.sender, CONFIG.SIGNALLING_ESCROW_MIN_LOCK_TIME());
        SharesValue sharesUnlocked = _accounting.accountStETHSharesUnlock(msg.sender);
        ST_ETH.transferShares(msg.sender, sharesUnlocked.toUint256());
        _activateNextGovernanceState();
    }

    // ---
    // Lock / Unlock wstETH
    // ---

    function lockWstETH(uint256 amount) external {
        WST_ETH.transferFrom(msg.sender, address(this), amount);
        uint256 stETHAmount = WST_ETH.unwrap(amount);
        _accounting.accountStETHSharesLock(msg.sender, SharesValues.from(ST_ETH.getSharesByPooledEth(stETHAmount)));
        _activateNextGovernanceState();
    }

    function unlockWstETH() external returns (uint256) {
        _accounting.checkAssetsUnlockDelayPassed(msg.sender, CONFIG.SIGNALLING_ESCROW_MIN_LOCK_TIME());
        SharesValue wstETHUnlocked = _accounting.accountStETHSharesUnlock(msg.sender);
        uint256 wstETHAmount = WST_ETH.wrap(ST_ETH.getPooledEthByShares(wstETHUnlocked.toUint256()));
        WST_ETH.transfer(msg.sender, wstETHAmount);
        _activateNextGovernanceState();
        return wstETHAmount;
    }

    // ---
    // Lock / Unlock unstETH
    // ---
    function lockUnstETH(uint256[] memory unstETHIds) external {
        WithdrawalRequestStatus[] memory statuses = WITHDRAWAL_QUEUE.getWithdrawalStatus(unstETHIds);
        _accounting.accountUnstETHLock(msg.sender, unstETHIds, statuses);

        uint256 unstETHIdsCount = unstETHIds.length;
        for (uint256 i = 0; i < unstETHIdsCount; ++i) {
            WITHDRAWAL_QUEUE.transferFrom(msg.sender, address(this), unstETHIds[i]);
        }
    }

    function unlockUnstETH(uint256[] memory unstETHIds) external {
        _accounting.checkAssetsUnlockDelayPassed(msg.sender, CONFIG.SIGNALLING_ESCROW_MIN_LOCK_TIME());
        _accounting.accountUnstETHUnlock(msg.sender, unstETHIds);
        uint256 unstETHIdsCount = unstETHIds.length;
        for (uint256 i = 0; i < unstETHIdsCount; ++i) {
            WITHDRAWAL_QUEUE.transferFrom(address(this), msg.sender, unstETHIds[i]);
        }
    }

    function markUnstETHFinalized(uint256[] memory unstETHIds, uint256[] calldata hints) external {
        _checkEscrowState(EscrowState.SignallingEscrow);

        uint256[] memory claimableAmounts = WITHDRAWAL_QUEUE.getClaimableEther(unstETHIds, hints);
        _accounting.accountUnstETHFinalized(unstETHIds, claimableAmounts);
    }

    // ---
    // Convert to NFT
    // ---

    function requestWithdrawals(uint256[] calldata stEthAmounts) external returns (uint256[] memory unstETHIds) {
        unstETHIds = WITHDRAWAL_QUEUE.requestWithdrawals(stEthAmounts, address(this));
        WithdrawalRequestStatus[] memory statuses = WITHDRAWAL_QUEUE.getWithdrawalStatus(unstETHIds);

        uint256 sharesTotal = 0;
        for (uint256 i = 0; i < statuses.length; ++i) {
            sharesTotal += statuses[i].amountOfShares;
        }
        _accounting.accountStETHSharesUnlock(msg.sender, SharesValues.from(sharesTotal));
        _accounting.accountUnstETHLock(msg.sender, unstETHIds, statuses);
    }

    // ---
    // State Updates
    // ---

    function startRageQuit(uint256 rageQuitExtraTimelock, uint256 rageQuitWithdrawalsTimelock) external {
        _checkDualGovernance(msg.sender);
        _checkEscrowState(EscrowState.SignallingEscrow);

        _batchesQueue.open();
        _escrowState = EscrowState.RageQuitEscrow;
        _rageQuitExtraTimelock = rageQuitExtraTimelock;
        _rageQuitWithdrawalsTimelock = rageQuitWithdrawalsTimelock;
    }

    function requestNextWithdrawalsBatch(uint256 maxBatchSize) external {
        _checkEscrowState(EscrowState.RageQuitEscrow);
        _batchesQueue.checkOpened();

        if (maxBatchSize < MIN_BATCH_SIZE || maxBatchSize > MAX_BATCH_SIZE) {
            revert InvalidBatchSize(maxBatchSize);
        }

        uint256 stETHRemaining = ST_ETH.balanceOf(address(this));
        if (stETHRemaining < MIN_WITHDRAWAL_REQUEST_AMOUNT) {
            return _batchesQueue.close();
        }

        uint256[] memory requestAmounts = WithdrawalsBatchesQueue.calcRequestAmounts({
            minRequestAmount: MIN_WITHDRAWAL_REQUEST_AMOUNT,
            requestAmount: MAX_WITHDRAWAL_REQUEST_AMOUNT,
            amount: Math.min(stETHRemaining, MAX_WITHDRAWAL_REQUEST_AMOUNT * maxBatchSize)
        });

        _batchesQueue.add(WITHDRAWAL_QUEUE.requestWithdrawals(requestAmounts, address(this)));
    }

    function claimWithdrawalsBatch(uint256 maxUnstETHIdsCount) external {
        _checkEscrowState(EscrowState.RageQuitEscrow);
        if (_rageQuitTimelockStartedAt != 0) {
            revert ClaimingIsFinished();
        }

        uint256[] memory unstETHIds = _batchesQueue.claimNextBatch(maxUnstETHIdsCount);

        _claimWithdrawalsBatch(
            unstETHIds, WITHDRAWAL_QUEUE.findCheckpointHints(unstETHIds, 1, WITHDRAWAL_QUEUE.getLastCheckpointIndex())
        );
    }

    function claimWithdrawalsBatch(uint256 fromUnstETHIds, uint256[] calldata hints) external {
        _checkEscrowState(EscrowState.RageQuitEscrow);
        if (_rageQuitTimelockStartedAt != 0) {
            revert ClaimingIsFinished();
        }

        uint256[] memory unstETHIds = _batchesQueue.claimNextBatch(hints.length);

        if (unstETHIds.length > 0 && fromUnstETHIds != unstETHIds[0]) {
            revert UnexpectedUnstETHId();
        }
        if (hints.length != unstETHIds.length) {
            revert InvalidHintsLength(hints.length, unstETHIds.length);
        }

        _claimWithdrawalsBatch(unstETHIds, hints);
    }

    function claimUnstETH(uint256[] calldata unstETHIds, uint256[] calldata hints) external {
        _checkEscrowState(EscrowState.RageQuitEscrow);
        uint256[] memory claimableAmounts = WITHDRAWAL_QUEUE.getClaimableEther(unstETHIds, hints);

        uint256 ethBalanceBefore = address(this).balance;
        WITHDRAWAL_QUEUE.claimWithdrawals(unstETHIds, hints);
        uint256 ethBalanceAfter = address(this).balance;

        ETHValue totalAmountClaimed = _accounting.accountUnstETHClaimed(unstETHIds, claimableAmounts);
        assert(totalAmountClaimed == ETHValues.from(ethBalanceAfter - ethBalanceBefore));
    }

    // ---
    // Withdraw Logic
    // ---

    function withdrawETH() external {
        _checkEscrowState(EscrowState.RageQuitEscrow);
        _checkWithdrawalsTimelockPassed();
        ETHValue ethToWithdraw = _accounting.accountStETHSharesWithdraw(msg.sender);
        ethToWithdraw.sendTo(payable(msg.sender));
    }

    function withdrawETH(uint256[] calldata unstETHIds) external {
        _checkEscrowState(EscrowState.RageQuitEscrow);
        _checkWithdrawalsTimelockPassed();
        ETHValue ethToWithdraw = _accounting.accountUnstETHWithdraw(msg.sender, unstETHIds);
        ethToWithdraw.sendTo(payable(msg.sender));
    }

    // ---
    // Getters
    // ---

    function getLockedAssetsTotals() external view returns (LockedAssetsTotals memory totals) {
        StETHAccounting memory stETHTotals = _accounting.stETHTotals;
        totals.stETHClaimedETH = stETHTotals.claimedETH.toUint256();
        totals.stETHLockedShares = stETHTotals.lockedShares.toUint256();

        UnstETHAccounting memory unstETHTotals = _accounting.unstETHTotals;
        totals.unstETHUnfinalizedShares = unstETHTotals.unfinalizedShares.toUint256();
        totals.unstETHFinalizedETH = unstETHTotals.finalizedETH.toUint256();
    }

    function getVetoerState(address vetoer) external view returns (VetoerState memory state) {
        HolderAssets storage assets = _accounting.assets[vetoer];

        state.unstETHIdsCount = assets.unstETHIds.length;
        state.stETHLockedShares = assets.stETHLockedShares.toUint256();
        state.unstETHLockedShares = assets.stETHLockedShares.toUint256();
        state.lastAssetsLockTimestamp = assets.lastAssetsLockTimestamp;
    }

    function getNextWithdrawalBatches(uint256 limit) external view returns (uint256[] memory unstETHIds) {
        return _batchesQueue.getNextWithdrawalsBatches(limit);
    }

    function getIsWithdrawalsBatchesFinalized() external view returns (bool) {
        return _batchesQueue.isClosed();
    }

    function getIsWithdrawalsClaimed() external view returns (bool) {
        return _rageQuitTimelockStartedAt != 0;
    }

    function getRageQuitTimelockStartedAt() external view returns (uint256) {
        return _rageQuitTimelockStartedAt;
    }

    function getRageQuitSupport() external view returns (uint256 rageQuitSupport) {
        StETHAccounting memory stETHTotals = _accounting.stETHTotals;
        UnstETHAccounting memory unstETHTotals = _accounting.unstETHTotals;

        uint256 finalizedETH = unstETHTotals.finalizedETH.toUint256();
        uint256 ufinalizedShares = (stETHTotals.lockedShares + unstETHTotals.unfinalizedShares).toUint256();

        rageQuitSupport = (
            10 ** 18 * (ST_ETH.getPooledEthByShares(ufinalizedShares) + finalizedETH)
                / (ST_ETH.totalSupply() + finalizedETH)
        );
    }

    function isRageQuitFinalized() external view returns (bool) {
        return _escrowState == EscrowState.RageQuitEscrow && _batchesQueue.isClosed() && _rageQuitTimelockStartedAt != 0
            && block.timestamp > _rageQuitTimelockStartedAt + _rageQuitExtraTimelock;
    }

    // ---
    // RECEIVE
    // ---

    receive() external payable {
        if (msg.sender != address(WITHDRAWAL_QUEUE)) {
            revert InvalidETHSender(msg.sender, address(WITHDRAWAL_QUEUE));
        }
    }

    // ---
    // Internal Methods
    // ---

    function _claimWithdrawalsBatch(uint256[] memory unstETHIds, uint256[] memory hints) internal {
        uint256 ethBalanceBefore = address(this).balance;
        WITHDRAWAL_QUEUE.claimWithdrawals(unstETHIds, hints);
        uint256 ethAmountClaimed = address(this).balance - ethBalanceBefore;

        _accounting.accountClaimedStETH(ETHValues.from(ethAmountClaimed));

        if (_batchesQueue.isClosed() && _batchesQueue.isAllUnstETHClaimed()) {
            _rageQuitTimelockStartedAt = block.timestamp;
        }
    }

    function _activateNextGovernanceState() internal {
        _dualGovernance.activateNextState();
    }

    function _checkEscrowState(EscrowState expected) internal view {
        if (_escrowState != expected) {
            revert InvalidState(_escrowState, expected);
        }
    }

    function _checkDualGovernance(address account) internal view {
        if (account != address(_dualGovernance)) {
            revert NotDualGovernance(account, address(_dualGovernance));
        }
    }

    function _checkWithdrawalsTimelockPassed() internal view {
        if (_rageQuitTimelockStartedAt == 0) {
            revert RageQuitExtraTimelockNotStarted();
        }
        if (block.timestamp <= _rageQuitTimelockStartedAt + _rageQuitExtraTimelock + _rageQuitWithdrawalsTimelock) {
            revert WithdrawalsTimelockNotPassed();
        }
    }
}

pragma solidity 0.8.26;

import "contracts/DualGovernance.sol";
//import {State as DualGovernanceState} from "contracts/libraries/DualGovernanceStateMachine.sol";
import "contracts/EmergencyProtectedTimelock.sol";
import "contracts/Escrow.sol";

import {Timestamp} from "contracts/types/Timestamp.sol";
import {State as WithdrawalBatchesQueueState} from "contracts/libraries/WithdrawalBatchesQueue.sol";
import {State as EscrowSt} from "contracts/libraries/EscrowState.sol";

import "contracts/model/StETHModel.sol";
import "contracts/model/WstETHAdapted.sol";

import "test/kontrol/KontrolTest.sol";

contract StorageSetup is KontrolTest {
    //
    //  STETH
    //
    function stEthStorageSetup(StETHModel _stEth, IEscrow _escrow) external {
        kevm.symbolicStorage(address(_stEth));
        // Slot 0
        uint256 totalPooledEther = kevm.freshUInt(32);
        vm.assume(0 < totalPooledEther);
        vm.assume(totalPooledEther < ethUpperBound);
        _stEth.setTotalPooledEther(totalPooledEther);
        // Slot 1
        uint256 totalShares = kevm.freshUInt(32);
        vm.assume(0 < totalShares);
        vm.assume(totalShares < ethUpperBound);
        _stEth.setTotalShares(totalShares);
        // Slot 2
        uint256 shares = kevm.freshUInt(32);
        vm.assume(shares < totalShares);
        vm.assume(shares < ethUpperBound);
        _stEth.setShares(address(_escrow), shares);
    }

    function stEthStorageInvariants(Mode mode, StETHModel _stEth, IEscrow _escrow) external {
        uint256 totalPooledEther = _stEth.getTotalPooledEther();
        uint256 totalShares = _stEth.getTotalShares();
        uint256 escrowShares = _stEth.sharesOf(address(_escrow));

        _establish(mode, 0 < _stEth.getTotalPooledEther());
        _establish(mode, 0 < _stEth.getTotalShares());
        _establish(mode, escrowShares < totalShares);
    }

    function stEthAssumeBounds(StETHModel _stEth, IEscrow _escrow) external {
        uint256 totalPooledEther = _stEth.getTotalPooledEther();
        uint256 totalShares = _stEth.getTotalShares();
        uint256 escrowShares = _stEth.sharesOf(address(_escrow));

        vm.assume(totalPooledEther < ethUpperBound);
        vm.assume(totalShares < ethUpperBound);
        vm.assume(escrowShares < ethUpperBound);
    }

    //
    //  WSTETH
    //
    function _wstEthStorageSetup(WstETHAdapted _wstEth, IStETH _stEth) internal {
        kevm.symbolicStorage(address(_wstEth));
    }

    //
    //  DUAL GOVERNANCE
    //
    function _getCurrentState(DualGovernance _dualGovernance) internal view returns (uint8) {
        return uint8(_loadData(address(_dualGovernance), 6, 0, 1));
    }

    function _getEnteredAt(DualGovernance _dualGovernance) internal view returns (uint40) {
        return uint40(_loadData(address(_dualGovernance), 6, 1, 5));
    }

    function _getVetoSignallingActivationTime(DualGovernance _dualGovernance) internal view returns (uint40) {
        return uint40(_loadData(address(_dualGovernance), 6, 6, 5));
    }

    function _getRageQuitRound(DualGovernance _dualGovernance) internal view returns (uint8) {
        return uint8(_loadData(address(_dualGovernance), 6, 31, 1));
    }

    function _getVetoSignallingReactivationTime(DualGovernance _dualGovernance) internal view returns (uint40) {
        return uint40(_loadData(address(_dualGovernance), 7, 0, 5));
    }

    function _getNormalOrVetoCooldownExitedAt(DualGovernance _dualGovernance) internal view returns (uint40) {
        return uint40(_loadData(address(_dualGovernance), 7, 5, 5));
    }

    function dualGovernanceStorageSetup(
        DualGovernance _dualGovernance,
        IEscrow _signallingEscrow,
        IEscrow _rageQuitEscrow,
        IDualGovernanceConfigProvider _config
    ) external {
        kevm.symbolicStorage(address(_dualGovernance));

        // Slot 6:
        uint256 currentState = kevm.freshUInt(1);
        vm.assume(currentState <= 4);
        uint256 enteredAt = kevm.freshUInt(5);
        vm.assume(enteredAt <= block.timestamp);
        vm.assume(enteredAt < timeUpperBound);
        uint256 vetoSignallingActivationTime = kevm.freshUInt(5);
        vm.assume(vetoSignallingActivationTime <= block.timestamp);
        vm.assume(vetoSignallingActivationTime < timeUpperBound);
        uint256 rageQuitRound = kevm.freshUInt(1);
        vm.assume(rageQuitRound < type(uint8).max);

        _storeData(address(_dualGovernance), 6, 0, 1, currentState);
        _storeData(address(_dualGovernance), 6, 1, 5, enteredAt);
        _storeData(address(_dualGovernance), 6, 6, 5, vetoSignallingActivationTime);
        _storeData(address(_dualGovernance), 6, 11, 20, uint256(uint160(address(_signallingEscrow))));
        _storeData(address(_dualGovernance), 6, 31, 1, rageQuitRound);

        // Slot 7
        uint256 vetoSignallingReactivationTime = kevm.freshUInt(5);
        vm.assume(vetoSignallingReactivationTime <= block.timestamp);
        vm.assume(vetoSignallingReactivationTime < timeUpperBound);
        uint256 normalOrVetoCooldownExitedAt = kevm.freshUInt(5);
        vm.assume(normalOrVetoCooldownExitedAt <= block.timestamp);
        vm.assume(normalOrVetoCooldownExitedAt < timeUpperBound);

        _storeData(address(_dualGovernance), 7, 0, 5, vetoSignallingReactivationTime);
        _storeData(address(_dualGovernance), 7, 5, 5, normalOrVetoCooldownExitedAt);
        _storeData(address(_dualGovernance), 7, 10, 20, uint256(uint160(address(_rageQuitEscrow))));

        // Slot 8
        _storeData(address(_dualGovernance), 8, 0, 20, uint256(uint160(address(_config))));
    }

    function dualGovernanceStorageInvariants(Mode mode, DualGovernance _dualGovernance) external {
        uint8 currentState = _getCurrentState(_dualGovernance);
        uint40 enteredAt = _getEnteredAt(_dualGovernance);
        uint40 vetoSignallingActivationTime = _getVetoSignallingActivationTime(_dualGovernance);
        uint40 vetoSignallingReactivationTime = _getVetoSignallingReactivationTime(_dualGovernance);
        uint40 normalOrVetoCooldownExitedAt = _getNormalOrVetoCooldownExitedAt(_dualGovernance);
        uint8 rageQuitRound = _getRageQuitRound(_dualGovernance);

        _establish(mode, currentState <= 4);
        _establish(mode, enteredAt <= block.timestamp);
        _establish(mode, vetoSignallingActivationTime <= block.timestamp);
        _establish(mode, vetoSignallingReactivationTime <= block.timestamp);
        _establish(mode, normalOrVetoCooldownExitedAt <= block.timestamp);
    }

    function dualGovernanceAssumeBounds(DualGovernance _dualGovernance) external {
        uint40 enteredAt = _getEnteredAt(_dualGovernance);
        uint40 vetoSignallingActivationTime = _getVetoSignallingActivationTime(_dualGovernance);
        uint40 vetoSignallingReactivationTime = _getVetoSignallingReactivationTime(_dualGovernance);
        uint40 normalOrVetoCooldownExitedAt = _getNormalOrVetoCooldownExitedAt(_dualGovernance);
        uint8 rageQuitRound = _getRageQuitRound(_dualGovernance);

        vm.assume(enteredAt < timeUpperBound);
        vm.assume(vetoSignallingActivationTime < timeUpperBound);
        vm.assume(vetoSignallingReactivationTime < timeUpperBound);
        vm.assume(normalOrVetoCooldownExitedAt < timeUpperBound);
        vm.assume(rageQuitRound < type(uint8).max);
    }

    function dualGovernanceInitializeStorage(
        DualGovernance _dualGovernance,
        IEscrow _signallingEscrow,
        IEscrow _rageQuitEscrow,
        IDualGovernanceConfigProvider _config
    ) external {
        this.dualGovernanceStorageSetup(_dualGovernance, _signallingEscrow, _rageQuitEscrow, _config);
        this.dualGovernanceStorageInvariants(Mode.Assume, _dualGovernance);
        this.dualGovernanceAssumeBounds(_dualGovernance);
    }

    //
    //  ESCROW
    //
    function _getCurrentState(IEscrow _escrow) internal view returns (uint8) {
        return uint8(_loadUInt256(address(_escrow), 0));
    }

    function _getStEthLockedShares(IEscrow _escrow) internal view returns (uint128) {
        return uint128(_loadUInt256(address(_escrow), 1));
    }

    function _getClaimedEth(IEscrow _escrow) internal view returns (uint128) {
        return uint128(_loadUInt256(address(_escrow), 1) >> 128);
    }

    function _getUnfinalizedShares(IEscrow _escrow) internal view returns (uint128) {
        return uint128(_loadUInt256(address(_escrow), 2));
    }

    function _getFinalizedEth(IEscrow _escrow) internal view returns (uint128) {
        return uint128(_loadUInt256(address(_escrow), 2) >> 128);
    }

    function _getLastAssetsLockTimestamp(IEscrow _escrow, address _vetoer) internal view returns (uint256) {
        uint256 assetsSlot = 3;
        uint256 vetoerAddressPadded = uint256(uint160(_vetoer));
        bytes32 vetoerAssetsSlot = keccak256(abi.encodePacked(vetoerAddressPadded, assetsSlot));
        uint256 lastAssetsLockTimestampSlot = uint256(vetoerAssetsSlot) + 1;
        return _loadUInt256(address(_escrow), lastAssetsLockTimestampSlot);
    }

    function _getBatchesQueueStatus(IEscrow _escrow) internal view returns (uint8) {
        return uint8(_loadUInt256(address(_escrow), 5));
    }

    function _getRageQuitExtensionDelay(IEscrow _escrow) internal view returns (uint32) {
        return uint32(_loadUInt256(address(_escrow), 9));
    }

    function _getRageQuitWithdrawalsTimelock(IEscrow _escrow) internal view returns (uint32) {
        return uint32(_loadUInt256(address(_escrow), 9) >> 32);
    }

    function _getRageQuitTimelockStartedAt(IEscrow _escrow) internal view returns (uint40) {
        return uint40(_loadUInt256(address(_escrow), 9) >> 64);
    }

    struct AccountingRecord {
        EscrowSt escrowState;
        uint256 allowance;
        uint256 userBalance;
        uint256 escrowBalance;
        uint256 userShares;
        uint256 escrowShares;
        uint256 userSharesLocked;
        uint256 totalSharesLocked;
        uint256 totalEth;
        uint256 userUnstEthLockedShares;
        uint256 unfinalizedShares;
        Timestamp userLastLockedTime;
    }

    struct EscrowRecord {
        EscrowSt escrowState;
        AccountingRecord accounting;
    }

    function saveEscrowRecord(address user, Escrow escrow) external view returns (EscrowRecord memory er) {
        AccountingRecord memory accountingRecord = this.saveAccountingRecord(user, escrow);
        er.escrowState = EscrowSt(_getCurrentState(escrow));
        er.accounting = accountingRecord;
    }

    function saveAccountingRecord(address user, Escrow escrow) external view returns (AccountingRecord memory ar) {
        IStETH stEth = escrow.ST_ETH();
        ar.allowance = stEth.allowance(user, address(escrow));
        ar.userBalance = stEth.balanceOf(user);
        ar.escrowBalance = stEth.balanceOf(address(escrow));
        //ar.userShares = stEth.sharesOf(user);
        //ar.escrowShares = stEth.sharesOf(address(escrow));
        ar.userSharesLocked = escrow.getVetoerState(user).stETHLockedShares;
        ar.totalSharesLocked = escrow.getLockedAssetsTotals().stETHLockedShares;
        ar.totalEth = stEth.getPooledEthByShares(ar.totalSharesLocked);
        ar.userUnstEthLockedShares = escrow.getVetoerState(user).unstETHLockedShares;
        ar.unfinalizedShares = escrow.getLockedAssetsTotals().unstETHUnfinalizedShares;
        uint256 lastAssetsLockTimestamp = _getLastAssetsLockTimestamp(escrow, user);
        require(lastAssetsLockTimestamp < timeUpperBound, "lastAssetsLockTimestamp >= timeUpperBound");
        ar.userLastLockedTime = Timestamp.wrap(uint40(lastAssetsLockTimestamp));
    }

    function establishEqualAccountingRecords(
        Mode mode,
        AccountingRecord memory ar1,
        AccountingRecord memory ar2
    ) external view {
        _establish(mode, ar1.allowance == ar2.allowance);
        _establish(mode, ar1.userBalance == ar2.userBalance);
        _establish(mode, ar1.escrowBalance == ar2.escrowBalance);
        _establish(mode, ar1.userShares == ar2.userShares);
        _establish(mode, ar1.escrowShares == ar2.escrowShares);
        _establish(mode, ar1.userSharesLocked == ar2.userSharesLocked);
        _establish(mode, ar1.totalSharesLocked == ar2.totalSharesLocked);
        _establish(mode, ar1.totalEth == ar2.totalEth);
        _establish(mode, ar1.userUnstEthLockedShares == ar2.userUnstEthLockedShares);
        _establish(mode, ar1.unfinalizedShares == ar2.unfinalizedShares);
        _establish(mode, ar1.userLastLockedTime == ar2.userLastLockedTime);
    }

    function escrowStorageSetup(IEscrow _escrow, DualGovernance _dualGovernance, EscrowSt _currentState) external {
        kevm.symbolicStorage(address(_escrow));
        // Slot 0
        {
            bytes memory slot0Abi = abi.encodePacked(uint88(0), uint160(address(_dualGovernance)), uint8(_currentState));
            bytes32 slot0;
            assembly {
                slot0 := mload(add(slot0Abi, 0x20))
            }
            _storeBytes32(address(_escrow), 0, slot0);
        }
        // Slot 1 + 0 + 0 = 1
        {
            uint128 lockedShares = uint128(kevm.freshUInt(16));
            vm.assume(lockedShares < ethUpperBound);
            uint128 claimedEth = uint128(kevm.freshUInt(16));
            vm.assume(claimedEth < ethUpperBound);
            bytes memory slot1Abi = abi.encodePacked(uint128(claimedEth), uint128(lockedShares));
            bytes32 slot1;
            assembly {
                slot1 := mload(add(slot1Abi, 0x20))
            }
            _storeBytes32(address(_escrow), 1, slot1);
        }
        // Slot 1 + 1 + 0 = 2
        {
            uint128 unfinalizedShares = uint128(kevm.freshUInt(16));
            vm.assume(unfinalizedShares < ethUpperBound);
            uint128 finalizedEth = uint128(kevm.freshUInt(16));
            vm.assume(finalizedEth < ethUpperBound);
            bytes memory slot2Abi = abi.encodePacked(uint128(finalizedEth), uint128(unfinalizedShares));
            bytes32 slot2;
            assembly {
                slot2 := mload(add(slot2Abi, 0x20))
            }
            _storeBytes32(address(_escrow), 2, slot2);
        }
        // Slot 5
        // FIXME: This branching is done to avoid the fresh existential generation bug
        if (_currentState == EscrowSt.RageQuitEscrow) {
            uint8 batchesQueueStatus = uint8(kevm.freshUInt(1));
            vm.assume(batchesQueueStatus < 3);
            _storeUInt256(address(_escrow), 5, batchesQueueStatus);
        } else {
            _storeUInt256(address(_escrow), 5, 0);
        }
        // Slot 8
        if (_currentState == EscrowSt.RageQuitEscrow) {
            uint256 batchesQueueLength = uint256(kevm.freshUInt(32));
            vm.assume(batchesQueueLength < 2 ** 64);
            _storeUInt256(address(_escrow), 8, batchesQueueLength);
        } else {
            _storeUInt256(address(_escrow), 8, 0);
        }
        // Slot 9
        // FIXME: This branching is done to avoid the fresh existential generation bug
        if (_currentState == EscrowSt.RageQuitEscrow) {
            uint32 rageQuitExtensionDelay = uint32(kevm.freshUInt(4));
            vm.assume(rageQuitExtensionDelay <= block.timestamp);
            vm.assume(rageQuitExtensionDelay < timeUpperBound);
            uint32 rageQuitWithdrawalsTimelock = uint32(kevm.freshUInt(4));
            vm.assume(rageQuitWithdrawalsTimelock <= block.timestamp);
            vm.assume(rageQuitWithdrawalsTimelock < timeUpperBound);
            uint40 rageQuitTimelockStartedAt = uint40(kevm.freshUInt(5));
            vm.assume(rageQuitTimelockStartedAt <= block.timestamp);
            vm.assume(rageQuitTimelockStartedAt < timeUpperBound);
            bytes memory slot9Abi = abi.encodePacked(
                uint152(0),
                uint40(rageQuitTimelockStartedAt),
                uint32(rageQuitWithdrawalsTimelock),
                uint32(rageQuitExtensionDelay)
            );
            bytes32 slot9;
            assembly {
                slot9 := mload(add(slot9Abi, 0x20))
            }
            _storeBytes32(address(_escrow), 9, slot9);
        } else {
            _storeUInt256(address(_escrow), 9, 0);
        }
    }

    function escrowStorageInvariants(Mode mode, IEscrow _escrow) external {
        uint8 batchesQueueStatus = _getBatchesQueueStatus(_escrow);
        uint32 rageQuitExtensionDelay = _getRageQuitExtensionDelay(_escrow);
        uint32 rageQuitWithdrawalsTimelock = _getRageQuitWithdrawalsTimelock(_escrow);
        uint40 rageQuitTimelockStartedAt = _getRageQuitTimelockStartedAt(_escrow);

        _establish(mode, batchesQueueStatus < 3);
        _establish(mode, rageQuitExtensionDelay <= block.timestamp);
        _establish(mode, rageQuitWithdrawalsTimelock <= block.timestamp);
        _establish(mode, rageQuitTimelockStartedAt <= block.timestamp);
    }

    function escrowAssumeBounds(IEscrow _escrow) external {
        uint128 lockedShares = _getStEthLockedShares(_escrow);
        uint128 claimedEth = _getClaimedEth(_escrow);
        uint128 unfinalizedShares = _getUnfinalizedShares(_escrow);
        uint128 finalizedEth = _getFinalizedEth(_escrow);
        uint32 rageQuitExtensionDelay = _getRageQuitExtensionDelay(_escrow);
        uint32 rageQuitWithdrawalsTimelock = _getRageQuitWithdrawalsTimelock(_escrow);
        uint40 rageQuitTimelockStartedAt = _getRageQuitTimelockStartedAt(_escrow);

        vm.assume(lockedShares < ethUpperBound);
        vm.assume(claimedEth < ethUpperBound);
        vm.assume(unfinalizedShares < ethUpperBound);
        vm.assume(finalizedEth < ethUpperBound);
        vm.assume(rageQuitExtensionDelay < timeUpperBound);
        vm.assume(rageQuitWithdrawalsTimelock < timeUpperBound);
        vm.assume(rageQuitTimelockStartedAt < timeUpperBound);
    }

    function escrowInitializeStorage(
        IEscrow _escrow,
        DualGovernance _dualGovernance,
        EscrowSt _currentState
    ) external {
        this.escrowStorageSetup(_escrow, _dualGovernance, _currentState);
        this.escrowStorageInvariants(Mode.Assume, _escrow);
        this.escrowAssumeBounds(_escrow);
    }

    function signallingEscrowStorageInvariants(Mode mode, IEscrow _signallingEscrow) external {
        uint32 rageQuitExtensionDelay = _getRageQuitExtensionDelay(_signallingEscrow);
        uint32 rageQuitWithdrawalsTimelock = _getRageQuitWithdrawalsTimelock(_signallingEscrow);
        uint40 rageQuitTimelockStartedAt = _getRageQuitTimelockStartedAt(_signallingEscrow);
        uint8 batchesQueueStatus = _getBatchesQueueStatus(_signallingEscrow);

        _establish(mode, rageQuitExtensionDelay == 0);
        _establish(mode, rageQuitWithdrawalsTimelock == 0);
        _establish(mode, rageQuitTimelockStartedAt == 0);
        _establish(mode, batchesQueueStatus == uint8(WithdrawalBatchesQueueState.Absent));
    }

    function signallingEscrowInitializeStorage(IEscrow _signallingEscrow, DualGovernance _dualGovernance) external {
        this.escrowInitializeStorage(_signallingEscrow, _dualGovernance, EscrowSt.SignallingEscrow);
        this.signallingEscrowStorageInvariants(Mode.Assume, _signallingEscrow);
    }

    function rageQuitEscrowStorageInvariants(Mode mode, IEscrow _rageQuitEscrow) external {
        uint8 batchesQueueStatus = _getBatchesQueueStatus(_rageQuitEscrow);

        _establish(mode, batchesQueueStatus != uint8(WithdrawalBatchesQueueState.Absent));
    }

    function rageQuitEscrowInitializeStorage(IEscrow _rageQuitEscrow, DualGovernance _dualGovernance) external {
        this.escrowInitializeStorage(_rageQuitEscrow, _dualGovernance, EscrowSt.RageQuitEscrow);
        this.rageQuitEscrowStorageInvariants(Mode.Assume, _rageQuitEscrow);
    }
}

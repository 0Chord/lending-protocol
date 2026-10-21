// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BorrowTestBase} from "./helpers/BorrowTestBase.sol";
import {FailingMockUSDC} from "./mocks/FailingMockUSDC.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title 실제 토큰 이동 뒤 실패한 대출·상환의 전체 복구
contract LendingPoolDebtFailureTest is BorrowTestBase {
    FailingMockUSDC private failing;

    /// @notice 장애를 끈 토큰으로 공급100·담보1을 정상 준비한다.
    function setUp() public override {
        failing = new FailingMockUSDC();
        _prepareBorrowPool(failing);
    }

    /// @notice 대출 transfer 후 false면 선증가 부채와 이동 토큰을 복구한다.
    function test_BorrowTransferFalseRestoresAndRetries() public {
        _borrowFailure(FailingMockUSDC.FailureMode.ReturnFalse);
    }

    /// @notice 대출 transfer 후 원본 오류도 전체 복구하고 원본대로 전파한다.
    function test_BorrowTransferRevertRestoresAndRetries() public {
        _borrowFailure(FailingMockUSDC.FailureMode.Revert);
    }

    /// @notice 상환 transferFrom 후 false면 토큰·유한 승인·부채를 복구한다.
    function test_RepayTransferFalseRestoresAndRetries() public {
        _repayFailure(FailingMockUSDC.FailureMode.ReturnFalse);
    }

    /// @notice 상환 transferFrom 후 원본 오류도 승인과 장부를 복구한다.
    function test_RepayTransferRevertRestoresAndRetries() public {
        _repayFailure(FailingMockUSDC.FailureMode.Revert);
    }

    /// @notice 실패 직전 전체 상태를 비교한 뒤 장애 해제 후 같은 대출을 한 번 실행한다.
    function _borrowFailure(FailingMockUSDC.FailureMode mode) private {
        failing.setTransferFailureMode(mode);
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(_error(mode));
        vm.prank(BOB);
        pool.borrow(40e6);
        _assertUnchanged(beforeState);
        failing.setTransferFailureMode(FailingMockUSDC.FailureMode.None);
        vm.recordLogs();
        vm.prank(BOB);
        pool.borrow(40e6);
        assertEq(pool.debtOf(BOB), 40e6);
        assertEq(pool.totalDebt(), 40e6);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.balanceOf(address(pool)), 60e6);
        _assertInitialRights();
        _assertEvent(vm.getRecordedLogs(), "Borrowed(address,uint256)", BOB, 40e6);
    }

    /// @notice 정상 부채40에서 상환15 실패를 복구하고 재시도는25만 남긴다.
    function _repayFailure(FailingMockUSDC.FailureMode mode) private {
        vm.startPrank(BOB);
        pool.borrow(40e6);
        usdc.approve(address(pool), 15e6);
        vm.stopPrank();
        failing.setFailureMode(mode);
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(_error(mode));
        vm.prank(BOB);
        pool.repay(15e6);
        _assertUnchanged(beforeState);
        failing.setFailureMode(FailingMockUSDC.FailureMode.None);
        vm.recordLogs();
        vm.prank(BOB);
        pool.repay(15e6);
        assertEq(pool.debtOf(BOB), 25e6);
        assertEq(pool.totalDebt(), 25e6);
        assertEq(usdc.balanceOf(BOB), 25e6);
        assertEq(usdc.balanceOf(address(pool)), 75e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertInitialRights();
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 15e6);
    }

    /// @notice false의 SafeERC20 오류와 원본 revert를 구분한다.
    function _error(FailingMockUSDC.FailureMode mode) private view returns (bytes memory) {
        if (mode == FailingMockUSDC.FailureMode.ReturnFalse) {
            return abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc));
        }
        return abi.encodeWithSelector(FailingMockUSDC.InjectedTransferFailure.selector);
    }
}

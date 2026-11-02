// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {InterestTestBase} from "./helpers/InterestTestBase.sol";
import {FailingMockUSDC} from "./mocks/FailingMockUSDC.sol";

/// @title 이자가 발생한 요청의 토큰 장애와 저장값 복구 검사
/// @notice 같은 시각의 정확 분자·개인/전체 기준 시각·토큰·유한 승인을 함께 비교한다.
contract LendingPoolInterestFailureTest is InterestTestBase {
    FailingMockUSDC private failing;

    /// @notice 정상 공급100·대출40 뒤 반년을 지나 현재 부채42와 미저장 이자2를 준비한다.
    function setUp() public override {
        failing = new FailingMockUSDC();
        _prepareBorrowPool(failing);
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.warp(block.timestamp + HALF_YEAR);
        assertEq(pool.debtOf(BOB), 42e6);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(interestPool.storedTotalDebt().interestNumerator, 0);
    }

    /// @notice 일부 상환 API의 승인 부족은 선행 이자 저장까지 복구하고 충분한 승인으로 재시도한다.
    function test_RepayInsufficientAllowanceRestoresInterestStorage() public {
        _insufficientAllowance(false);
    }

    /// @notice 전액 상환의 승인 요구액은 상한50이 아닌 견적42이며 실패 시 전체 상태가 복구된다.
    function test_RepayAllInsufficientAllowanceRestoresInterestStorage() public {
        _insufficientAllowance(true);
    }

    /// @notice 상환42의 잔고가40뿐이면 이미 실행된 유한 승인 차감과 이자 저장도 복구된다.
    function test_RepayInsufficientBalanceRestoresInterestStorage() public {
        _insufficientBalance(false);
    }

    /// @notice 전액 상환도 실제 견적42의 잔고를 검사하며 부족한2를 보충하면 같은 요청이 성공한다.
    function test_RepayAllInsufficientBalanceRestoresInterestStorage() public {
        _insufficientBalance(true);
    }

    /// @notice 상환 수령 뒤 false는 잔고·승인·미저장 이자까지 복구하며 재시도는12만 상환한다.
    function test_RepayPostTransferFalseRestoresAndRetries() public {
        _repaymentTransferFailure(false, FailingMockUSDC.FailureMode.ReturnFalse);
    }

    /// @notice 상환 수령 뒤 원본 오류가 전파되어도 이자 갱신을 남기지 않는다.
    function test_RepayPostTransferRevertRestoresAndRetries() public {
        _repaymentTransferFailure(false, FailingMockUSDC.FailureMode.Revert);
    }

    /// @notice 전액 상환 수령 뒤 false는42의 전송·승인 소비와 모든 이자 저장을 복구한다.
    function test_RepayAllPostTransferFalseRestoresAndRetries() public {
        _repaymentTransferFailure(true, FailingMockUSDC.FailureMode.ReturnFalse);
    }

    /// @notice 전액 상환 수령 뒤 원본 오류를 그대로 전달하고 정상 재시도는 완제한다.
    function test_RepayAllPostTransferRevertRestoresAndRetries() public {
        _repaymentTransferFailure(true, FailingMockUSDC.FailureMode.Revert);
    }

    /// @notice 새 대출 지급 뒤 false면 추가 원금10과 기존 기간 이자2의 저장을 모두 복구한다.
    function test_BorrowPostTransferFalseRestoresInterestStorage() public {
        _outgoingTransferFailure(true, FailingMockUSDC.FailureMode.ReturnFalse);
    }

    /// @notice 새 대출 지급 뒤 오류는 선반영 부채·새 기준 시각·이동 토큰을 함께 복구한다.
    function test_BorrowPostTransferRevertRestoresInterestStorage() public {
        _outgoingTransferFailure(true, FailingMockUSDC.FailureMode.Revert);
    }

    /// @notice 출금 지급 뒤 false면 차감 지분과 자산뿐 아니라 선행 이자 갱신도 복구한다.
    function test_WithdrawPostTransferFalseRestoresInterestStorage() public {
        _outgoingTransferFailure(false, FailingMockUSDC.FailureMode.ReturnFalse);
    }

    /// @notice 출금 지급 뒤 오류는 지분·정확 자산·토큰 현금·저장 시각을 보존한다.
    function test_WithdrawPostTransferRevertRestoresInterestStorage() public {
        _outgoingTransferFailure(false, FailingMockUSDC.FailureMode.Revert);
    }

    /// @notice 공급 수령 뒤 false면 승인·현금 이동을 복구하고 기존 공급자의 미저장 이자도 보존한다.
    function test_SupplyPostTransferFalseRestoresInterestStorage() public {
        _supplyTransferFailure(FailingMockUSDC.FailureMode.ReturnFalse);
    }

    /// @notice 공급 수령 뒤 오류는 새 공급자의 지분을 만들거나 기존 이자 저장을 남기지 않는다.
    function test_SupplyPostTransferRevertRestoresInterestStorage() public {
        _supplyTransferFailure(FailingMockUSDC.FailureMode.Revert);
    }

    /// @notice 자산 권리102가 있어도 현금60보다 많은 출금61은 이자 저장까지 복구한다.
    function test_InsufficientLiquidityRestoresInterestStorage() public {
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 60e6, 61e6));
        vm.prank(ALICE);
        pool.withdraw(61e6);
        _assertInterestUnchanged(beforeState);
    }

    /// @notice 원금40만 쓰면 통과할29 추가 대출도 현재 원리금42와 합치면 한도70 초과로 복구한다.
    function test_BorrowLimitFailureRestoresInterestStorage() public {
        price.setUpdatedAt(block.timestamp);
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, 70e6, 42e6, 29e6));
        vm.prank(BOB);
        pool.borrow(29e6);
        _assertInterestUnchanged(beforeState);
    }

    /// @notice 두 상환의 실제 전송 후 실패를 확인하고 장애를 끈 동일 입력의 성공으로 원인을 고립한다.
    function _repaymentTransferFailure(bool all, FailingMockUSDC.FailureMode mode) private {
        uint256 amount = all ? 42e6 : 12e6;
        if (all) usdc.mint(BOB, 2e6);
        vm.prank(BOB);
        usdc.approve(address(pool), amount);
        failing.setFailureMode(mode);
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(_error(mode));
        _repay(all, amount);
        _assertInterestUnchanged(beforeState);
        failing.setFailureMode(FailingMockUSDC.FailureMode.None);
        if (all) {
            _assertFullRetry(true);
        } else {
            vm.recordLogs();
            _repay(false, amount);
            assertEq(pool.debtOf(BOB), 30e6);
            assertEq(pool.totalAssets(), 102e6);
            assertEq(pool.availableLiquidity(), 72e6);
            assertEq(usdc.balanceOf(address(pool)), 72e6);
            assertEq(usdc.balanceOf(BOB), 28e6);
            assertEq(usdc.allowance(BOB, address(pool)), 0);
            _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, amount);
        }
    }

    /// @notice 충분한 담보·현재 가격·현금을 준비한 대출 또는 출금의 토큰 지급 장애만 주입한다.
    function _outgoingTransferFailure(bool borrowing, FailingMockUSDC.FailureMode mode) private {
        price.setUpdatedAt(block.timestamp);
        failing.setTransferFailureMode(mode);
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(_error(mode));
        vm.prank(borrowing ? BOB : ALICE);
        if (borrowing) pool.borrow(10e6);
        else pool.withdraw(10e6);
        _assertInterestUnchanged(beforeState);
        failing.setTransferFailureMode(FailingMockUSDC.FailureMode.None);
        vm.recordLogs();
        vm.prank(borrowing ? BOB : ALICE);
        if (borrowing) pool.borrow(10e6);
        else pool.withdraw(10e6);
        assertEq(pool.debtOf(BOB), borrowing ? 52e6 : 42e6);
        assertEq(pool.totalAssets(), borrowing ? 102e6 : 92e6);
        assertEq(pool.availableLiquidity(), 50e6);
        assertEq(usdc.balanceOf(address(pool)), 50e6);
        _assertEvent(
            vm.getRecordedLogs(),
            borrowing ? "Borrowed(address,uint256)" : "Withdrawn(address,uint256)",
            borrowing ? BOB : ALICE,
            10e6
        );
    }

    /// @notice Charlie의 공급10이 수령 단계에서만 실패하도록 잔고·유한 승인을 충분히 준비한다.
    function _supplyTransferFailure(FailingMockUSDC.FailureMode mode) private {
        usdc.mint(CHARLIE, 10e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 10e6);
        failing.setFailureMode(mode);
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(_error(mode));
        vm.prank(CHARLIE);
        pool.supply(10e6);
        _assertInterestUnchanged(beforeState);
        failing.setFailureMode(FailingMockUSDC.FailureMode.None);
        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.supply(10e6);
        assertEq(pool.totalAssets(), 112e6);
        assertEq(pool.debtOf(BOB), 42e6);
        assertEq(pool.availableLiquidity(), 70e6);
        assertEq(usdc.balanceOf(address(pool)), 70e6);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(pool.shares(CHARLIE), 9_803_921);
        _assertEvent(vm.getRecordedLogs(), "Supplied(address,uint256)", CHARLIE, 10e6);
    }

    /// @notice false의 SafeERC20 오류와 토큰의 원본 revert를 정확히 구분한다.
    function _error(FailingMockUSDC.FailureMode mode) private view returns (bytes memory) {
        if (mode == FailingMockUSDC.FailureMode.ReturnFalse) {
            return abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc));
        }
        return abi.encodeWithSelector(FailingMockUSDC.InjectedTransferFailure.selector);
    }

    /// @notice 견적보다 raw1 적은 승인만 실패 원인이 되도록 잔고42를 별도로 준비한다.
    function _insufficientAllowance(bool all) private {
        usdc.mint(BOB, 2e6);
        vm.prank(BOB);
        usdc.approve(address(pool), 42e6 - 1);
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 42e6 - 1, 42e6)
        );
        _repay(all, 42e6);
        _assertInterestUnchanged(beforeState);
        vm.prank(BOB);
        usdc.approve(address(pool), 42e6);
        _assertFullRetry(all);
    }

    /// @notice 승인42는 충분하지만 잔고40인 실패를 관측한 뒤 잔고만 보충한다.
    function _insufficientBalance(bool all) private {
        vm.prank(BOB);
        usdc.approve(address(pool), 42e6);
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 40e6, 42e6));
        _repay(all, 42e6);
        _assertInterestUnchanged(beforeState);
        usdc.mint(BOB, 2e6);
        _assertFullRetry(all);
    }

    /// @notice 장애 해제 뒤 완제는 견적42만 받아 정확히 한 번 기록하고 승인도42만 소비한다.
    function _assertFullRetry(bool all) private {
        vm.recordLogs();
        _repay(all, 42e6);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 102e6);
        assertEq(usdc.balanceOf(address(pool)), 102e6);
        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 42e6);
    }

    /// @notice 두 API에 같은 실제 상환액을 요청하되 전액 상환은 더 큰 상한을 전달한다.
    function _repay(bool all, uint256 amount) private {
        vm.prank(BOB);
        if (all) pool.repayAll(50e6);
        else pool.repay(amount);
    }
}

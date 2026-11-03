// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DebtLedger} from "../src/accounting/DebtLedger.sol";
import {InterestMath} from "../src/libraries/InterestMath.sol";
import {InterestTestBase} from "./helpers/InterestTestBase.sol";
import {FailingMockUSDC} from "./mocks/FailingMockUSDC.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title 다른 사람이 내는 상환의 지급자 오류와 전체 복구
/// @notice Bob 자원이 충분해도 Charlie의 잔고·승인만 사용하며 실패한 이자 저장까지 되돌린다.
contract LendingPoolRepaymentActorsFailureTest is InterestTestBase {
    uint256 private constant Q = InterestMath.DENOMINATOR;
    FailingMockUSDC private failing;

    /// @notice 공급100·Bob 차입40·반년 뒤 현재 부채42와 Bob의 충분한 상환 승인을 준비한다.
    function setUp() public override {
        failing = new FailingMockUSDC();
        _prepareBorrowPool(failing);
        vm.startPrank(BOB);
        pool.borrow(40e6);
        usdc.approve(address(pool), 12e6);
        vm.stopPrank();
        vm.warp(block.timestamp + HALF_YEAR);
        assertEq(pool.debtOf(BOB), 42e6);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        assertEq(interestPool.storedTotalDebt().interestNumerator, 0);
    }

    /// @notice Bob 승인12가 있어도 Charlie 승인11로12를 낼 수 없으며 승인만 보충하면 성공한다.
    function test_PayerInsufficientAllowanceRestoresAccrualAndRetries() public {
        _fundPayer(12e6, 11e6);
        bytes memory beforeState = _interestSnapshot();

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 11e6, 12e6)
        );
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 12e6);

        _assertInterestUnchanged(beforeState);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 12e6);
        _assertRetryPaysOnlyBobsDebt();
    }

    /// @notice Bob 잔고40을 대신 쓰지 않으며 Charlie 잔고11의 실패는 먼저 소모한 승인12도 복구한다.
    function test_PayerInsufficientBalanceRestoresFiniteAllowanceAndRetries() public {
        _fundPayer(11e6, 12e6);
        bytes memory beforeState = _interestSnapshot();

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, CHARLIE, 11e6, 12e6));
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 12e6);

        _assertInterestUnchanged(beforeState);
        usdc.mint(CHARLIE, 1e6);
        _assertRetryPaysOnlyBobsDebt();
    }

    /// @notice Charlie의 실제 전송 뒤 false는 SafeERC20 오류로 전체 복구하고 장애 해제 뒤 한 번 정산한다.
    function test_PostTransferFalseRestoresPayerAndBorrowerAndRetries() public {
        _postTransferFailure(FailingMockUSDC.FailureMode.ReturnFalse);
    }

    /// @notice 실제 전송 뒤 토큰 원본 오류를 전파하고 토큰·유한 승인·정확 장부를 함께 복구한다.
    function test_PostTransferRevertRestoresPayerAndBorrowerAndRetries() public {
        _postTransferFailure(FailingMockUSDC.FailureMode.Revert);
    }

    /// @notice Bob 현재 부채42보다 많은43은 지급자 자원이 충분해도 일부 수령 없이 기존 오류로 거절한다.
    function test_ExcessRepaymentUsesBorrowerQuoteAndRestoresAccrual() public {
        _fundPayer(43e6, 43e6);
        bytes memory beforeState = _interestSnapshot();

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.RepayExceedsDebt.selector, 42e6, 43e6));
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 43e6);

        _assertInterestUnchanged(beforeState);
    }

    /// @notice 부채 없는 대상의 양수 요청은 NoDebt로 바꾸지 않고 RepayExceedsDebt(0,1)을 유지한다.
    function test_NoDebtTargetRejectsPositiveRepaymentWithExistingError() public {
        _fundPayer(1, 1);
        bytes memory beforeState = _interestSnapshot();

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.RepayExceedsDebt.selector, 0, 1));
        vm.prank(CHARLIE);
        interestPool.repayForTest(ALICE, 1);

        _assertInterestUnchanged(beforeState);
    }

    /// @dev 실패 모형도 실제 Charlie 전송에 도달하도록 충분한 잔고·승인을 먼저 준비한다.
    function _postTransferFailure(FailingMockUSDC.FailureMode mode) private {
        _fundPayer(12e6, 12e6);
        failing.setFailureMode(mode);
        bytes memory beforeState = _interestSnapshot();
        bytes memory expected = mode == FailingMockUSDC.FailureMode.ReturnFalse
            ? abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc))
            : abi.encodeWithSelector(FailingMockUSDC.InjectedTransferFailure.selector);

        vm.recordLogs();
        vm.expectCall(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", CHARLIE, address(pool), 12e6)
        );
        vm.expectRevert(expected);
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 12e6);

        _assertInterestUnchanged(beforeState);
        failing.setFailureMode(FailingMockUSDC.FailureMode.None);
        _assertRetryPaysOnlyBobsDebt();
    }

    /// @dev Charlie가 실제 지급할 잔고와 유한 승인을 독립적으로 정한다.
    function _fundPayer(uint256 balance, uint256 allowance) private {
        usdc.mint(CHARLIE, balance);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), allowance);
    }

    /// @dev 같은12 요청은 Charlie 토큰만 한 번 받고 Bob 원금30·자산102로 끝나며 풀 이벤트를 내지 않는다.
    function _assertRetryPaysOnlyBobsDebt() private {
        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 12e6);

        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.allowance(BOB, address(pool)), 12e6);
        assertEq(usdc.balanceOf(address(pool)), 72e6);
        assertEq(usdc.totalSupply(), 112e6);
        assertEq(pool.debtOf(BOB), 30e6);
        assertEq(pool.totalDebt(), 30e6);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 72e6);
        assertEq(interestPool.storedAssetsNumerator(), 102e6 * Q);
        _assertPosition(interestPool.storedDebt(BOB), 30e6, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 30e6, 0, block.timestamp);
        _assertPosition(interestPool.storedDebt(CHARLIE), 0, 0, 0);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.collateralOf(CHARLIE), 0);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.deposits(ALICE), 102e6);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 1e8);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(pool));
        }
    }

    /// @dev 표시용 반올림값과 구분해 실제 저장 원금·분자·기준 시각을 확인한다.
    function _assertPosition(
        DebtLedger.Position memory position,
        uint256 principal,
        uint256 interest,
        uint256 updatedAt
    ) private pure {
        assertEq(position.principal, principal);
        assertEq(position.interestNumerator, interest);
        assertEq(position.updatedAt, updatedAt);
    }
}

/// @title 지급자와 차입자가 다른 상환의 산술 실패 위치와 기존 오류 순서
/// @notice 일관된 최대 분자 경계에서 수령 이전 누적 실패와 수령 이후 정산 실패를 구분한다.
contract LendingPoolRepaymentActorsPrecisionFailureTest is InterestTestBase {
    uint256 private constant Q = InterestMath.DENOMINATOR;

    /// @notice 1초 뒤 수령2는 성공하지만 올림 차이를 더할 때 넘치면 Charlie 전송과 Bob 장부를 복구한다.
    function test_SettlementOverflowAfterPayerTransferRestoresAllStoredState() public {
        uint256 storedAt = _prepareNumeratorBoundary();
        vm.warp(storedAt + 1);
        assertEq(pool.debtOf(BOB), 2);
        assertEq(pool.totalAssets(), type(uint256).max / Q);
        bytes memory beforeState = _storedSnapshot();

        vm.recordLogs();
        vm.expectCall(
            address(usdc), abi.encodeWithSignature("transferFrom(address,address,uint256)", CHARLIE, address(pool), 2)
        );
        vm.expectRevert(_overflow());
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 2);

        _assertStoredUnchanged(beforeState);
        _assertBoundaryPosition(storedAt);
        assertEq(usdc.balanceOf(CHARLIE), 2);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 2);
        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
    }

    /// @notice 2초 누적은 수령 전에 넘치며 토큰에 도달했다면 나올 별도 오류와 구분해 저장 복구를 확인한다.
    function test_AccrualOverflowPrecedesPayerTransferAndRestoresAllStoredState() public {
        uint256 storedAt = _prepareNumeratorBoundary();
        vm.warp(storedAt + 2);
        assertEq(pool.debtOf(BOB), 2);
        assertEq(pool.totalDebt(), 1);
        bytes memory beforeState = _storedSnapshot();
        _rejectUnexpectedPayerTransfer(2);

        vm.recordLogs();
        vm.expectRevert(_overflow());
        pool.totalAssets();
        vm.expectRevert(_overflow());
        pool.availableLiquidity();
        vm.expectRevert(_overflow());
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 2);

        _assertStoredUnchanged(beforeState);
        _assertBoundaryPosition(storedAt);
    }

    /// @notice 누적 자산이 넘칠 상태여도 하네스·기존 두 상환의0은 갱신이나 무부채보다 먼저 거절한다.
    function test_ZeroRequestPrecedesAccrualForHarnessAndExistingRepayments() public {
        uint256 storedAt = _prepareNumeratorBoundary();
        vm.warp(storedAt + 2);
        bytes memory beforeState = _storedSnapshot();

        vm.recordLogs();
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        vm.prank(CHARLIE);
        interestPool.repayForTest(ALICE, 0);
        _assertStoredUnchanged(beforeState);

        vm.recordLogs();
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        vm.prank(BOB);
        pool.repay(0);
        _assertStoredUnchanged(beforeState);

        vm.recordLogs();
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        vm.prank(CHARLIE);
        pool.repayAll(0);
        _assertStoredUnchanged(beforeState);
    }

    /// @notice 양수 정액3은 견적2를 초과해도 하네스와 기존 repay 모두 선행 누적의 산술 오류를 유지한다.
    function test_PositiveRepayAccrualPrecedesExcessAmountForHarnessAndPublicRepay() public {
        uint256 storedAt = _prepareNumeratorBoundary();
        vm.warp(storedAt + 2);
        assertEq(pool.debtOf(BOB), 2);
        bytes memory beforeState = _storedSnapshot();

        vm.recordLogs();
        vm.expectRevert(_overflow());
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 3);
        _assertStoredUnchanged(beforeState);

        vm.recordLogs();
        vm.expectRevert(_overflow());
        vm.prank(BOB);
        pool.repay(3);
        _assertStoredUnchanged(beforeState);
    }

    /// @notice 기존 repayAll의 무부채·상한 부족은 전역 누적보다 먼저 검사해 정확한 기존 오류를 유지한다.
    function test_RepayAllNoDebtAndLimitPrecedeAccrualOverflow() public {
        uint256 storedAt = _prepareNumeratorBoundary();
        vm.warp(storedAt + 2);
        bytes memory beforeState = _storedSnapshot();

        vm.recordLogs();
        vm.expectRevert(LendingPool.NoDebt.selector);
        vm.prank(CHARLIE);
        pool.repayAll(1);
        _assertStoredUnchanged(beforeState);

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.RepaymentLimitExceeded.selector, 2, 1));
        vm.prank(BOB);
        pool.repayAll(1);
        _assertStoredUnchanged(beforeState);
    }

    /// @dev 실제1지분을 만들고 A=M−1000, D=Q+r−1000, 현금=floor(M/Q)−1의 보존식을 맞춘다.
    function _prepareNumeratorBoundary() private returns (uint256 storedAt) {
        vm.startPrank(ALICE);
        pool.withdraw(100e6);
        usdc.approve(address(pool), 1);
        pool.supply(1);
        vm.stopPrank();
        storedAt = block.timestamp;
        uint256 maximum = type(uint256).max;
        uint256 remainder = maximum % Q;
        uint256 cash = maximum / Q - 1;
        interestPool.setAccountedAssetsNumeratorForTest(maximum - 1_000);
        interestPool.setDebtPositionForTest(BOB, 1, remainder - 1_000, storedAt);
        interestPool.setTotalDebtForTest(1, remainder - 1_000, storedAt);
        deal(address(usdc), address(pool), cash, true);
        usdc.mint(CHARLIE, 2);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 2);

        assertEq(pool.totalShares(), 1);
        assertEq(pool.shares(ALICE), 1);
        assertEq(interestPool.storedAssetsNumerator() - Q - (remainder - 1_000), cash * Q);
        assertEq(pool.availableLiquidity(), cash);
        assertEq(usdc.balanceOf(address(pool)), cash);
        _assertBoundaryPosition(storedAt);
    }

    /// @dev 수령 전 실패와 구분하도록 정확한 Charlie 전송이 실행되면 고유 오류를 발생시킨다.
    function _rejectUnexpectedPayerTransfer(uint256 amount) private {
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", CHARLIE, address(pool), amount),
            abi.encodeWithSignature("UnexpectedRepaymentTransfer()")
        );
    }

    /// @dev 최초 개인·전체 장부가 같은 정확 분자·원금·기준 시각으로 복구됐는지 확인한다.
    function _assertBoundaryPosition(uint256 storedAt) private view {
        DebtLedger.Position memory bob = interestPool.storedDebt(BOB);
        DebtLedger.Position memory total = interestPool.storedTotalDebt();
        assertEq(bob.principal, 1);
        assertEq(bob.interestNumerator, type(uint256).max % Q - 1_000);
        assertEq(bob.updatedAt, storedAt);
        assertEq(abi.encode(total), abi.encode(bob));
    }

    /// @dev 범위를 넘는 계산형 조회를 피하고 참여자의 실제 토큰·승인·권리만 읽는다.
    function _storedParticipant(address user) private view returns (uint256[6] memory) {
        return [
            usdc.balanceOf(user),
            wbtc.balanceOf(user),
            usdc.allowance(user, address(pool)),
            wbtc.allowance(user, address(pool)),
            pool.shares(user),
            pool.collateralOf(user)
        ];
    }

    /// @dev 공개 자산 조회가 실패하는 경계에서도 저장 자산·개인/전체 시각·모든 참여자 자원을 비교한다.
    function _storedSnapshot() private view returns (bytes memory) {
        uint256[6] memory global = [
            interestPool.storedAssetsNumerator(),
            pool.totalShares(),
            usdc.balanceOf(address(pool)),
            wbtc.balanceOf(address(pool)),
            usdc.totalSupply(),
            wbtc.totalSupply()
        ];
        return abi.encode(
            global,
            abi.encode(
                interestPool.storedTotalDebt(),
                interestPool.storedDebt(ALICE),
                interestPool.storedDebt(BOB),
                interestPool.storedDebt(CHARLIE),
                interestPool.storedDebt(address(usdc))
            ),
            abi.encode(
                _storedParticipant(ALICE),
                _storedParticipant(BOB),
                _storedParticipant(CHARLIE),
                _storedParticipant(address(usdc))
            )
        );
    }

    /// @dev 복구된 원시 저장값을 비교하고 실패한 호출이 풀 성공 이벤트를 남기지 않았는지 확인한다.
    function _assertStoredUnchanged(bytes memory beforeState) private view {
        assertEq(_storedSnapshot(), beforeState);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(pool));
        }
    }

    /// @dev 다른 토큰 오류와 혼동하지 않도록 정확한 산술 Panic(0x11)을 기대한다.
    function _overflow() private pure returns (bytes memory) {
        return abi.encodeWithSignature("Panic(uint256)", uint256(0x11));
    }
}

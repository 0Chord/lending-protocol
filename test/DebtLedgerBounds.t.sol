// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {DebtLedger} from "../src/accounting/DebtLedger.sol";
import {InterestMath} from "../src/libraries/InterestMath.sol";
import {DebtLedgerHarness} from "./mocks/DebtLedgerHarness.sol";

/// @title 내부 부채 장부의 거절 오류와 표현 범위 검증
/// @notice 실패한 호출의 원금·미납 이자·기준 시각 복구를 확인하며 토큰 전송은 다루지 않는다.
contract DebtLedgerBoundsTest is Test {
    uint256 private constant Q = 315_360_000_000;
    uint256 private constant U = type(uint256).max;
    address private constant BOB = address(0xB0B);
    address private constant CHARLIE = address(0xCA11);

    DebtLedgerHarness private ledger;

    /// @notice 저장 시각이 다른 두 개인까지 포함해 실패 전후를 비교한다.
    struct StoredState {
        DebtLedger.Position bob;
        DebtLedger.Position charlie;
        DebtLedger.Position total;
    }

    /// @notice 각 사례를 비어 있는 독립 장부에서 시작한다.
    function setUp() public {
        ledger = new DebtLedgerHarness();
    }

    /// @notice 정상 차입으로 전체 기준 시각을 앞당긴 뒤 과거 요청의 정확한 오류와 보존을 확인한다.
    function test_PastTotalTimestampRestoresEveryPosition() public {
        _prepareTwoBorrowers();
        StoredState memory beforeCall = _storedState();

        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, uint256(20), uint256(19)));
        ledger.accrueBorrower(BOB, 19);

        _assertStoredState(beforeCall);
    }

    /// @notice 개인 시각 거절이 전체 갱신 뒤 발생해도 먼저 바뀐 전체 분자·시각까지 복구한다.
    function test_PastBorrowerTimestampRollsBackEarlierTotalCheckpoint() public {
        // 정상 호출에서는 개인 시각이 전체보다 앞설 수 없으므로 이 오류 경계만 고립하는 불일치 fixture다.
        ledger.seedBorrower(BOB, 40, 0, 30);
        ledger.seedBorrower(CHARLIE, 20, 0, 10);
        ledger.seedTotal(60, 0, 10);
        StoredState memory beforeCall = _storedState();

        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, uint256(30), uint256(20)));
        ledger.accrueBorrower(BOB, 20);

        _assertStoredState(beforeCall);
    }

    /// @notice 개인 snapshot과 완제 견적은 자기 저장 시각보다 과거를 계산하지 않는다.
    function test_PersonalReadsRejectPastTimestampWithoutMutation() public {
        _prepareTwoBorrowers();
        StoredState memory beforeCall = _storedState();

        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, uint256(10), uint256(9)));
        ledger.borrowerSnapshot(BOB, 9);
        _assertStoredState(beforeCall);

        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, uint256(10), uint256(9)));
        ledger.quoteRepayment(BOB, 9);
        _assertStoredState(beforeCall);
    }

    /// @notice 전체 snapshot과 내림 표시는 전체 저장 시각보다 과거를 거절한다.
    function test_TotalReadsRejectPastTimestampWithoutMutation() public {
        _prepareTwoBorrowers();
        StoredState memory beforeCall = _storedState();

        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, uint256(20), uint256(19)));
        ledger.totalSnapshot(19);
        _assertStoredState(beforeCall);

        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, uint256(20), uint256(19)));
        ledger.totalDebtRaw(19);
        _assertStoredState(beforeCall);
    }

    /// @notice 완제해 원금이0이어도 기록된 시각은 유효하므로 과거 조회·갱신을 거절한다.
    function test_ZeroPrincipalStillRejectsPastTimestamp() public {
        ledger.borrow(BOB, 10, 10);
        ledger.repay(BOB, 10, 10);
        StoredState memory beforeCall = _storedState();
        _assertPosition(beforeCall.bob, 0, 0, 10);
        _assertPosition(beforeCall.total, 0, 0, 10);

        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, uint256(10), uint256(9)));
        ledger.borrowerSnapshot(BOB, 9);
        _assertStoredState(beforeCall);

        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, uint256(10), uint256(9)));
        ledger.totalSnapshot(9);
        _assertStoredState(beforeCall);

        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, uint256(10), uint256(9)));
        ledger.accrueTotal(9);
        _assertStoredState(beforeCall);
    }

    /// @notice 0상환이 계산기에서 거절되면 그 직전 개인·전체 이자 기록도 남지 않는다.
    function test_ZeroRepaymentRestoresEveryPosition() public {
        _prepareTwoBorrowers();
        StoredState memory beforeCall = _storedState();

        vm.expectRevert(InterestMath.ZeroAmount.selector);
        ledger.repay(BOB, 0, 30);

        _assertStoredState(beforeCall);
    }

    /// @notice 원금40과 소수 이자의 완제 견적41보다1 큰 상환은 부분 배분 없이 거절한다.
    function test_ExcessRepaymentRestoresEveryPosition() public {
        _prepareTwoBorrowers();
        StoredState memory beforeCall = _storedState();

        vm.expectRevert(abi.encodeWithSelector(InterestMath.RepayExceedsDebt.selector, uint256(41), uint256(42)));
        ledger.repay(BOB, 42, 30);

        _assertStoredState(beforeCall);
    }

    /// @notice uint256 최댓값 요청도 불필요한 배율 곱 전에 정확한 초과 상환 오류로 거절한다.
    function test_MaximumRepaymentAmountUsesExcessDebtError() public {
        _prepareTwoBorrowers();
        StoredState memory beforeCall = _storedState();

        vm.expectRevert(abi.encodeWithSelector(InterestMath.RepayExceedsDebt.selector, uint256(41), U));
        ledger.repay(BOB, U, 30);

        _assertStoredState(beforeCall);
    }

    /// @notice 빈 장부의 상환 실패가 개인·전체의 첫 기준 시각을 새로 만들지 않는다.
    function test_EmptyRepaymentRestoresUninitializedTimestamps() public {
        StoredState memory beforeCall = _storedState();

        vm.expectRevert(abi.encodeWithSelector(InterestMath.RepayExceedsDebt.selector, uint256(0), uint256(1)));
        ledger.repay(BOB, 1, 50);

        _assertStoredState(beforeCall);
    }

    /// @notice 0차입은 원금이나 이자 계산 시각을 바꾸지 않고 정확한 금액 오류를 반환한다.
    function test_ZeroBorrowRestoresEveryPosition() public {
        _prepareTwoBorrowers();
        StoredState memory beforeCall = _storedState();

        vm.expectRevert(InterestMath.ZeroAmount.selector);
        ledger.borrow(BOB, 0, 30);

        _assertStoredState(beforeCall);
    }

    /// @notice floor(U/Q) 차입은 원금 배율 변환의 최대 허용값을 손실 없이 기록한다.
    function test_MaximumRawBorrowPreservesExactNumerator() public {
        uint256 maximumRaw = U / Q;
        assertEq(ledger.borrow(BOB, maximumRaw, 1_000), 0);

        _assertPosition(ledger.storedBorrower(BOB), maximumRaw, 0, 1_000);
        _assertPosition(ledger.storedBorrower(CHARLIE), 0, 0, 0);
        _assertPosition(ledger.storedTotal(), maximumRaw, 0, 1_000);
        _assertSnapshot(ledger.borrowerSnapshot(BOB, 1_000), maximumRaw, 0, U - 168_649_639_935, 1_000);
        _assertSnapshot(ledger.totalSnapshot(1_000), maximumRaw, 0, U - 168_649_639_935, 1_000);
    }

    /// @notice 최대 raw 다음 값은 산술 오류이며 먼저 시도한 개인·전체 시각 갱신도 되돌린다.
    function test_OneAboveMaximumRawBorrowRestoresNewCheckpoints() public {
        ledger.accrueTotal(10);
        StoredState memory beforeCall = _storedState();

        _expectArithmeticPanic();
        ledger.borrow(BOB, U / Q + 1, 20);

        _assertStoredState(beforeCall);
    }

    /// @notice 이자 누적 뒤 정확 채권이 U와 같으면 개인·전체 모두 성공하며 잘라내지 않는다.
    function test_ExactDebtAtMaximumNumeratorSucceeds() public {
        // 시간 누적으로 생기지 않는 분자 끝자리도 허용하므로 일치하는 개인·전체 극단값을 직접 준비한다.
        ledger.seedBorrower(BOB, 1, U - Q - 1_000, 10);
        ledger.seedTotal(1, U - Q - 1_000, 10);

        assertEq(ledger.accrueBorrower(BOB, 11), 1_000);

        _assertPosition(ledger.storedBorrower(BOB), 1, U - Q, 11);
        _assertPosition(ledger.storedBorrower(CHARLIE), 0, 0, 0);
        _assertPosition(ledger.storedTotal(), 1, U - Q, 11);
        _assertSnapshot(ledger.borrowerSnapshot(BOB, 11), 1, U - Q, U, 11);
        _assertSnapshot(ledger.totalSnapshot(11), 1, U - Q, U, 11);
        assertEq(ledger.quoteRepayment(BOB, 11), U / Q + 1);
        assertEq(ledger.totalDebtRaw(11), U / Q);
    }

    /// @notice 미납 분자는 범위 안이어도 원금 분자와의 합이 넘으면 조회·갱신 모두 산술 오류다.
    function test_ExactDebtSumOverflowRejectsReadsAndAccrual() public {
        // 두 저장 기록은 같은 정확 채권 U를 나타내며 임의 분자 끝자리만 fixture로 준비한다.
        ledger.seedBorrower(BOB, 1, U - Q, 10);
        ledger.seedTotal(1, U - Q, 10);
        StoredState memory beforeCall = _storedState();

        _expectArithmeticPanic();
        ledger.borrowerSnapshot(BOB, 11);
        _assertStoredState(beforeCall);

        _expectArithmeticPanic();
        ledger.totalSnapshot(11);
        _assertStoredState(beforeCall);

        _expectArithmeticPanic();
        ledger.accrueBorrower(BOB, 11);
        _assertStoredState(beforeCall);
    }

    /// @notice 각 개인 채권이 표현 가능해도 전체 채권 합이 넘으면 추가 차입과 두 기준 시각을 복구한다.
    function test_TotalExactDebtSumOverflowRestoresNewCheckpoints() public {
        // 개인 합과 전체는 일치한다. 임의의 큰 미납 분자만 시험용으로 준비한다.
        ledger.seedBorrower(BOB, 1, U - 3 * Q, 10);
        ledger.seedBorrower(CHARLIE, 1, 0, 10);
        ledger.seedTotal(2, U - 3 * Q, 10);
        StoredState memory beforeCall = _storedState();
        _assertSnapshot(ledger.totalSnapshot(10), 2, U - 3 * Q, U - Q, 10);

        _expectArithmeticPanic();
        ledger.borrow(BOB, 1, 11);

        _assertStoredState(beforeCall);
    }

    /// @notice 정상 원금2도 지나치게 긴 기간과의 첫 곱이 넘으면 모든 저장값을 보존한다.
    function test_AccrualPrincipalTimeProductOverflowRestoresState() public {
        ledger.borrow(BOB, 2, 0);
        StoredState memory beforeCall = _storedState();

        _expectArithmeticPanic();
        ledger.accrueBorrower(BOB, U / 2 + 1);

        _assertStoredState(beforeCall);
    }

    /// @notice 원금·시간 곱이 유효해도 금리1,000을 곱한 분자가 넘으면 전체 호출을 거절한다.
    function test_AccrualRateProductOverflowRestoresState() public {
        ledger.borrow(BOB, 1, 0);
        StoredState memory beforeCall = _storedState();

        _expectArithmeticPanic();
        ledger.accrueBorrower(BOB, U / 1_000 + 1);

        _assertStoredState(beforeCall);
    }

    /// @notice 새 이자 곱은 범위 안이어도 기존 미납 분자와의 합이 넘으면 저장하지 않는다.
    function test_AccrualInterestAdditionOverflowRestoresState() public {
        // 시작 채권은 정확히 U다. 이번 경과의 새 이자 Q+1,000은 그 자체로는 유효하다.
        ledger.seedBorrower(BOB, 1, U - Q, 0);
        ledger.seedTotal(1, U - Q, 0);
        StoredState memory beforeCall = _storedState();
        _assertSnapshot(ledger.totalSnapshot(0), 1, U - Q, U, 0);

        _expectArithmeticPanic();
        ledger.accrueBorrower(BOB, 315_360_001);

        _assertStoredState(beforeCall);
    }

    /// @notice 기존 개인 원금에 U를 더해 넘칠 때 선행 이자와 기준 시각 기록도 모두 복구한다.
    function test_PersonalPrincipalAdditionOverflowRestoresNewCheckpoints() public {
        _prepareTwoBorrowers();
        StoredState memory beforeCall = _storedState();

        _expectArithmeticPanic();
        ledger.borrow(BOB, U, 30);

        _assertStoredState(beforeCall);
    }

    /// @notice Charlie의 원금0에는 U를 더할 수 있어도 Bob의1과 전체 합이 넘으면 개인 대입까지 복구한다.
    function test_TotalPrincipalAdditionOverflowRestoresPersonalWrite() public {
        ledger.borrow(BOB, 1, 10);
        StoredState memory beforeCall = _storedState();

        _expectArithmeticPanic();
        ledger.borrow(CHARLIE, U, 11);

        _assertStoredState(beforeCall);
    }

    /// @notice 정상 두 번의 차입으로 개인 시각 차이와 전체 미납 이자를 함께 준비한다.
    function _prepareTwoBorrowers() private {
        ledger.borrow(BOB, 40, 10);
        ledger.borrow(CHARLIE, 20, 20);
        _assertPosition(ledger.storedBorrower(BOB), 40, 0, 10);
        _assertPosition(ledger.storedBorrower(CHARLIE), 20, 0, 20);
        _assertPosition(ledger.storedTotal(), 60, 400_000, 20);
    }

    /// @notice 분자·원금 범위 초과를 다른 revert와 구분한다.
    function _expectArithmeticPanic() private {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
    }

    /// @notice 비교 중 이자를 다시 계산하지 않고 실제 세 저장 기록을 복사한다.
    function _storedState() private view returns (StoredState memory state) {
        state.bob = ledger.storedBorrower(BOB);
        state.charlie = ledger.storedBorrower(CHARLIE);
        state.total = ledger.storedTotal();
    }

    /// @notice 대상 외 개인을 포함한 아홉 필드가 실패 직전 값과 같아야 한다.
    function _assertStoredState(StoredState memory expected) private view {
        _assertSamePosition(ledger.storedBorrower(BOB), expected.bob);
        _assertSamePosition(ledger.storedBorrower(CHARLIE), expected.charlie);
        _assertSamePosition(ledger.storedTotal(), expected.total);
    }

    /// @notice 각 위치의 원금·미납 분자·기준 시각을 빠짐없이 비교한다.
    function _assertSamePosition(DebtLedger.Position memory actual, DebtLedger.Position memory expected) private pure {
        _assertPosition(actual, expected.principal, expected.interestNumerator, expected.updatedAt);
    }

    /// @notice 고정 기대값으로 저장 상태의 세 필드를 검증한다.
    function _assertPosition(DebtLedger.Position memory actual, uint256 principal, uint256 interest, uint256 timestamp)
        private
        pure
    {
        assertEq(actual.principal, principal, "principal");
        assertEq(actual.interestNumerator, interest, "interestNumerator");
        assertEq(actual.updatedAt, timestamp, "updatedAt");
    }

    /// @notice 조회의 원금·미납 이자·정확 채권·조회 시각을 독립 기대값과 비교한다.
    function _assertSnapshot(
        DebtLedger.Snapshot memory actual,
        uint256 principal,
        uint256 interest,
        uint256 debt,
        uint256 timestamp
    ) private pure {
        assertEq(actual.principal, principal, "snapshot principal");
        assertEq(actual.interestNumerator, interest, "snapshot interestNumerator");
        assertEq(actual.debtNumerator, debt, "snapshot debtNumerator");
        assertEq(actual.updatedAt, timestamp, "snapshot updatedAt");
    }
}

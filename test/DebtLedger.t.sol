// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {DebtLedger} from "../src/accounting/DebtLedger.sol";
import {InterestMath} from "../src/libraries/InterestMath.sol";
import {DebtLedgerHarness} from "./mocks/DebtLedgerHarness.sol";

/// @title 원금·이자의 개인 기록과 전체 기록 검증
/// @notice 실제 토큰 없이 고정 기대값, 같은 시각의 합계와 저장값을 비교한다.
contract DebtLedgerTest is Test {
    address private constant BOB = address(0xB0B);
    address private constant CHARLIE = address(0xCA11);
    uint256 private constant HALF_YEAR = 15_768_000;
    DebtLedgerHarness private ledger;

    /// @notice 각 테스트는 다른 부채가 없는 새 장부에서 시작한다.
    function setUp() public {
        ledger = new DebtLedgerHarness();
    }

    /// @notice 시각0에40 차입 후 반년 조회는 이자2를 보여주고 저장 기록을 그대로 둔다.
    function test_HalfYearSnapshotDoesNotWrite() public {
        assertEq(ledger.borrow(BOB, 40_000_000, 0), 0);
        bytes memory beforeState = abi.encode(ledger.storedBorrower(BOB), ledger.storedTotal());
        DebtLedger.Snapshot memory personal = ledger.borrowerSnapshot(BOB, HALF_YEAR);
        DebtLedger.Snapshot memory total = ledger.totalSnapshot(HALF_YEAR);

        assertEq(personal.principal, 40_000_000);
        assertEq(personal.interestNumerator, 630_720_000_000_000_000);
        assertEq(personal.debtNumerator, 13_245_120_000_000_000_000);
        assertEq(personal.updatedAt, HALF_YEAR);
        assertEq(abi.encode(total), abi.encode(personal));
        assertEq(abi.encode(ledger.storedBorrower(BOB), ledger.storedTotal()), beforeState);
    }

    /// @notice 이자2 발생 뒤12 상환은 원금30을 남기고 다음 반년에는1.5만 발생한다.
    function test_RepayTwelveAfterHalfYearLeavesThirty() public {
        ledger.borrow(BOB, 40_000_000, 0);
        assertEq(ledger.quoteRepayment(BOB, HALF_YEAR), 42_000_000);
        (uint256 accrued, InterestMath.Repayment memory result) = ledger.repay(BOB, 12_000_000, HALF_YEAR);
        assertEq(accrued, 630_720_000_000_000_000);
        assertEq(result.remainingPrincipal, 30_000_000);
        assertEq(result.remainingInterestNumerator, 0);
        assertEq(result.interestPaid, 2_000_000);
        assertEq(result.principalPaid, 10_000_000);
        assertEq(result.roundingSurplusNumerator, 0);
        DebtLedger.Position memory personal = ledger.storedBorrower(BOB);
        assertEq(personal.principal, 30_000_000);
        assertEq(personal.interestNumerator, 0);
        assertEq(personal.updatedAt, HALF_YEAR);
        assertEq(abi.encode(ledger.storedTotal()), abi.encode(personal));
        assertEq(ledger.borrowerSnapshot(BOB, 2 * HALF_YEAR).interestNumerator, 473_040_000_000_000_000);
        assertEq(ledger.totalDebtRaw(2 * HALF_YEAR), 31_500_000);
    }

    /// @notice 반년 뒤10 추가 차입은 기존 이자2를 보존하고 이후 원금50에만 이자를 붙인다.
    function test_AdditionalBorrowPreservesEarlierInterest() public {
        ledger.borrow(BOB, 40_000_000, 0);
        assertEq(ledger.borrow(BOB, 10_000_000, HALF_YEAR), 630_720_000_000_000_000);
        DebtLedger.Position memory personal = ledger.storedBorrower(BOB);
        assertEq(personal.principal, 50_000_000);
        assertEq(personal.interestNumerator, 630_720_000_000_000_000);
        assertEq(personal.updatedAt, HALF_YEAR);
        assertEq(ledger.borrowerSnapshot(BOB, 2 * HALF_YEAR).interestNumerator, 1_419_120_000_000_000_000);
        assertEq(ledger.quoteRepayment(BOB, 2 * HALF_YEAR), 54_500_000);
        _assertTotals(2 * HALF_YEAR);
    }

    /// @notice 시각이 다른 두 차입자는 같은 현재로 조회해야 원금60·이자5의 전체와 일치한다.
    function test_StaggeredBorrowersMatchCurrentGlobalDebt() public {
        _borrowAtDifferentTimes(ledger);
        assertEq(ledger.storedBorrower(BOB).interestNumerator, 0);
        DebtLedger.Snapshot memory bob = ledger.borrowerSnapshot(BOB, 2 * HALF_YEAR);
        DebtLedger.Snapshot memory charlie = ledger.borrowerSnapshot(CHARLIE, 2 * HALF_YEAR);
        DebtLedger.Snapshot memory total = ledger.totalSnapshot(2 * HALF_YEAR);
        assertEq(bob.interestNumerator, 1_261_440_000_000_000_000);
        assertEq(charlie.interestNumerator, 315_360_000_000_000_000);
        assertEq(total.principal, 60_000_000);
        assertEq(total.interestNumerator, 1_576_800_000_000_000_000);
        assertEq(total.debtNumerator, 20_498_400_000_000_000_000);
        assertEq(ledger.totalDebtRaw(2 * HALF_YEAR), 65_000_000);
        _assertTotals(2 * HALF_YEAR);
    }

    /// @notice 전체를 먼저 갱신한 뒤 개인을 어느 순서로 갱신해도 새 이자가 중복되지 않는다.
    function test_GlobalThenBorrowerOrderDoesNotDoubleCount() public {
        DebtLedgerHarness reversed = new DebtLedgerHarness();
        _borrowAtDifferentTimes(ledger);
        _borrowAtDifferentTimes(reversed);
        bytes memory bobBefore = abi.encode(ledger.storedBorrower(BOB));
        bytes memory charlieBefore = abi.encode(ledger.storedBorrower(CHARLIE));
        assertEq(ledger.accrueTotal(2 * HALF_YEAR), 946_080_000_000_000_000);
        assertEq(abi.encode(ledger.storedBorrower(BOB)), bobBefore);
        assertEq(abi.encode(ledger.storedBorrower(CHARLIE)), charlieBefore);
        assertEq(ledger.accrueBorrower(BOB, 2 * HALF_YEAR), 0);
        assertEq(ledger.accrueBorrower(CHARLIE, 2 * HALF_YEAR), 0);
        assertEq(reversed.accrueBorrower(CHARLIE, 2 * HALF_YEAR), 946_080_000_000_000_000);
        assertEq(reversed.accrueBorrower(BOB, 2 * HALF_YEAR), 0);
        assertEq(abi.encode(ledger.storedBorrower(BOB)), abi.encode(reversed.storedBorrower(BOB)));
        assertEq(abi.encode(ledger.storedBorrower(CHARLIE)), abi.encode(reversed.storedBorrower(CHARLIE)));
        assertEq(abi.encode(ledger.storedTotal()), abi.encode(reversed.storedTotal()));
        _assertTotals(2 * HALF_YEAR);
    }

    /// @notice 같은1년을12등분해 계산해도 원금40의 이자4와 반환한 이자 합은 같다.
    function test_MonthlyAndOnceAccrualAgree() public {
        DebtLedgerHarness once = new DebtLedgerHarness();
        ledger.borrow(BOB, 40_000_000, 0);
        once.borrow(BOB, 40_000_000, 0);
        uint256 reported;
        for (uint256 month = 1; month <= 12; ++month) {
            reported += ledger.accrueBorrower(BOB, month * 2_628_000);
        }
        assertEq(reported, 1_261_440_000_000_000_000);
        assertEq(once.accrueBorrower(BOB, 31_536_000), reported);
        assertEq(abi.encode(ledger.storedTotal()), abi.encode(once.storedTotal()));
        assertEq(abi.encode(ledger.storedBorrower(BOB)), abi.encode(once.storedBorrower(BOB)));
        assertEq(ledger.accrueTotal(31_536_000), 0);
        assertEq(ledger.accrueBorrower(BOB, 31_536_000), 0);
    }

    /// @notice 최소 단위보다 작은 이자도 분할 갱신에서 버리지 않고 합계 분자3,000을 남긴다.
    function test_SubRawAccrualSurvivesCheckpoints() public {
        ledger.borrow(BOB, 1, 0);
        for (uint256 timestamp = 1; timestamp <= 3; ++timestamp) {
            assertEq(ledger.accrueBorrower(BOB, timestamp), 1_000);
        }
        assertEq(ledger.storedBorrower(BOB).interestNumerator, 3_000);
        assertEq(ledger.storedTotal().interestNumerator, 3_000);
        assertEq(ledger.totalDebtRaw(3), 1);
        assertEq(ledger.quoteRepayment(BOB, 3), 2);
    }

    /// @notice 긴 빈 기간을 갱신한 뒤 처음 차입해도 그 이전 시간에는 이자를 붙이지 않는다.
    function test_LongEmptyPeriodDoesNotAccrueBeforeBorrow() public {
        uint256 start = 20 * 365 days;
        assertEq(ledger.accrueTotal(start - 1), 0);
        assertEq(ledger.borrow(BOB, 40_000_000, start), 0);
        assertEq(ledger.storedBorrower(BOB).interestNumerator, 0);
        assertEq(ledger.storedBorrower(BOB).updatedAt, start);
        assertEq(ledger.borrowerSnapshot(BOB, start + HALF_YEAR).interestNumerator, 630_720_000_000_000_000);
        _assertTotals(start + HALF_YEAR);
    }

    /// @notice 두 차입자 완제 뒤 재차입하면 이전 이자와 무차입 기간을 다시 붙이지 않는다.
    function test_ReborrowAfterEveryoneRepaysStartsFresh() public {
        _borrowAtDifferentTimes(ledger);
        uint256 end = 2 * HALF_YEAR;
        ledger.repay(BOB, ledger.quoteRepayment(BOB, end), end);
        ledger.repay(CHARLIE, ledger.quoteRepayment(CHARLIE, end), end);
        assertEq(ledger.storedTotal().principal, 0);
        assertEq(ledger.storedTotal().interestNumerator, 0);
        uint256 next = end + 20 * 365 days;
        assertEq(ledger.borrow(BOB, 10_000_000, next), 0);
        assertEq(ledger.storedBorrower(BOB).interestNumerator, 0);
        assertEq(ledger.storedBorrower(BOB).updatedAt, next);
        assertEq(ledger.quoteRepayment(BOB, next + HALF_YEAR), 10_500_000);
        assertEq(ledger.quoteRepayment(CHARLIE, next + HALF_YEAR), 0);
        _assertTotals(next + HALF_YEAR);
    }

    /// @notice 이자10 중3만 갚으면 원금100·이자7이 남고 다음 반년에는 원금에서5가 생긴다.
    function test_InterestOnlyRepaymentKeepsPrincipal() public {
        ledger.borrow(BOB, 100_000_000, 0);
        (uint256 accrued, InterestMath.Repayment memory result) = ledger.repay(BOB, 3_000_000, 2 * HALF_YEAR);
        assertEq(accrued, 3_153_600_000_000_000_000);
        assertEq(result.remainingPrincipal, 100_000_000);
        assertEq(result.remainingInterestNumerator, 2_207_520_000_000_000_000);
        assertEq(result.interestPaid, 3_000_000);
        assertEq(result.principalPaid, 0);
        assertEq(result.roundingSurplusNumerator, 0);
        assertEq(ledger.storedTotal().principal, 100_000_000);
        assertEq(ledger.storedTotal().interestNumerator, 2_207_520_000_000_000_000);
        assertEq(ledger.borrowerSnapshot(BOB, 3 * HALF_YEAR).interestNumerator, 3_784_320_000_000_000_000);
        _assertTotals(3 * HALF_YEAR);
    }

    /// @notice raw 이자0.4를 정산하면 새 이자0.4와 올림 차이0.6을 분리하고 원금71을 남긴다.
    function test_FractionalRepaymentSeparatesAccrualAndSurplus() public {
        ledger.borrow(BOB, 100, 0);
        (uint256 accrued, InterestMath.Repayment memory result) = ledger.repay(BOB, 30, 1_261_440);
        assertEq(accrued, 126_144_000_000);
        assertEq(result.remainingPrincipal, 71);
        assertEq(result.remainingInterestNumerator, 0);
        assertEq(result.interestPaid, 1);
        assertEq(result.principalPaid, 29);
        assertEq(result.roundingSurplusNumerator, 189_216_000_000);
        assertEq(ledger.storedTotal().principal, 71);
        assertEq(ledger.storedTotal().interestNumerator, 0);
        _assertTotals(1_261_440);

        (accrued, result) = ledger.repay(BOB, 1, 1_261_440);
        assertEq(accrued, 0);
        assertEq(result.interestPaid, 0);
        assertEq(result.principalPaid, 1);
        assertEq(result.roundingSurplusNumerator, 0);
        assertEq(ledger.storedTotal().principal, 70);
    }

    /// @notice raw10.2와10.7의 개인 견적은11씩이지만 전체20.9는20으로 표시하며 완제 때만 차이를 받는다.
    function test_TwoFractionalPayoffsPreserveOtherBorrower() public {
        // 동일 시각의 정확 소수 상태만 시험용으로 준비하며 운영 장부에는 setter가 없다.
        ledger.seedBorrower(BOB, 10, 63_072_000_000, 0);
        ledger.seedBorrower(CHARLIE, 10, 220_752_000_000, 0);
        ledger.seedTotal(20, 283_824_000_000, 0);
        bytes memory charlieBefore = abi.encode(ledger.storedBorrower(CHARLIE));
        assertEq(ledger.quoteRepayment(BOB, 0), 11);
        assertEq(ledger.quoteRepayment(CHARLIE, 0), 11);
        assertEq(ledger.totalDebtRaw(0), 20);
        assertEq(ledger.totalSnapshot(0).debtNumerator, 6_591_024_000_000);
        _assertTotals(0);

        (uint256 accrued, InterestMath.Repayment memory result) = ledger.repay(BOB, 11, 0);
        assertEq(accrued, 0);
        assertEq(result.interestPaid, 1);
        assertEq(result.principalPaid, 10);
        assertEq(result.roundingSurplusNumerator, 252_288_000_000);
        assertEq(ledger.quoteRepayment(BOB, 0), 0);
        assertEq(ledger.totalSnapshot(0).debtNumerator, 3_374_352_000_000);
        assertEq(abi.encode(ledger.storedBorrower(CHARLIE)), charlieBefore);
        _assertTotals(0);

        (accrued, result) = ledger.repay(CHARLIE, 11, 0);
        assertEq(accrued, 0);
        assertEq(result.interestPaid, 1);
        assertEq(result.principalPaid, 10);
        assertEq(result.roundingSurplusNumerator, 94_608_000_000);
        assertEq(ledger.storedTotal().principal, 0);
        assertEq(ledger.storedTotal().interestNumerator, 0);
        assertEq(ledger.totalSnapshot(0).debtNumerator, 0);
        _assertTotals(0);
    }

    /// @notice 시각·차입·상환·갱신을 섞어도 개인 합과 전체 부채, 수익 반환의 금액 보존은 유지된다.
    function testFuzz_InterleavedOperationsConserveExactDebt(uint256 entropy) public {
        uint256 timestamp;
        for (uint256 step; step < 16; ++step) {
            entropy = uint256(keccak256(abi.encode(entropy, step)));
            timestamp += entropy % 100_001;
            address borrower = entropy & 1 == 0 ? BOB : CHARLIE;
            DebtLedger.Snapshot memory beforeTotal = ledger.totalSnapshot(timestamp);
            uint256 expectedAccrual = beforeTotal.interestNumerator - ledger.storedTotal().interestNumerator;
            uint256 operation = (entropy >> 1) % 4;
            uint256 amount = 1 + (entropy >> 8) % 1_000_000_000;
            uint256 quote = ledger.quoteRepayment(borrower, timestamp);
            uint256 reported;
            uint256 expectedDebt = beforeTotal.debtNumerator;
            if (operation == 0 || (operation == 1 && quote == 0)) {
                reported = ledger.borrow(borrower, amount, timestamp);
                expectedDebt += amount * 315_360_000_000;
            } else if (operation == 1) {
                amount = 1 + (amount - 1) % quote;
                InterestMath.Repayment memory result;
                (reported, result) = ledger.repay(borrower, amount, timestamp);
                assertEq(result.interestPaid + result.principalPaid, amount);
                expectedDebt = expectedDebt + result.roundingSurplusNumerator - amount * 315_360_000_000;
            } else if (operation == 2) {
                reported = ledger.accrueTotal(timestamp);
            } else {
                reported = ledger.accrueBorrower(borrower, timestamp);
            }
            assertEq(reported, expectedAccrual);
            assertEq(ledger.totalSnapshot(timestamp).debtNumerator, expectedDebt);
            _assertTotals(timestamp);
        }
    }

    /// @notice 두 사람의 차입 시각 차이를 만들며 Bob 기록은 늦게 갱신된 채 둔다.
    function _borrowAtDifferentTimes(DebtLedgerHarness target) private {
        target.borrow(BOB, 40_000_000, 0);
        assertEq(target.borrow(CHARLIE, 20_000_000, HALF_YEAR), 630_720_000_000_000_000);
    }

    /// @notice 저장 시각 차이와 무관하게 같은 현재의 개인 합과 전체 세 금액을 대조한다.
    function _assertTotals(uint256 timestamp) private view {
        DebtLedger.Snapshot memory bob = ledger.borrowerSnapshot(BOB, timestamp);
        DebtLedger.Snapshot memory charlie = ledger.borrowerSnapshot(CHARLIE, timestamp);
        DebtLedger.Snapshot memory total = ledger.totalSnapshot(timestamp);
        assertEq(total.principal, bob.principal + charlie.principal);
        assertEq(total.interestNumerator, bob.interestNumerator + charlie.interestNumerator);
        assertEq(total.debtNumerator, bob.debtNumerator + charlie.debtNumerator);
    }
}

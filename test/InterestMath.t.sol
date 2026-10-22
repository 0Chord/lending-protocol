// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {InterestMath} from "../src/libraries/InterestMath.sol";

/// @title 순수 이자 계산의 오류를 관측하는 시험용 호출 경계
/// @notice 라이브러리 계산을 복제하지 않고 외부 호출로 전달한다.
contract InterestMathHarness {
    /// @notice 원시 금액의 배율 변환을 전달한다.
    function toNumerator(uint256 amount) external pure returns (uint256) {
        return InterestMath.toNumerator(amount);
    }

    /// @notice 완제 견적 합산의 오류를 외부 경계에서 관측한다.
    function quoteDebt(uint256 principal, uint256 interestNumerator) external pure returns (uint256) {
        return InterestMath.quoteDebt(principal, interestNumerator);
    }

    /// @notice 상환 배분의 반환 정보와 정확한 거절 오류를 전달한다.
    function allocateRepayment(uint256 principal, uint256 interestNumerator, uint256 amount)
        external
        pure
        returns (InterestMath.Repayment memory)
    {
        return InterestMath.allocateRepayment(principal, interestNumerator, amount);
    }

    /// @notice 기간 이자 누적을 전달하고 산술 오류를 그대로 전파한다.
    function accrue(uint256 principal, uint256 interestNumerator, uint256 elapsedSeconds)
        external
        pure
        returns (uint256)
    {
        return InterestMath.accrue(principal, interestNumerator, elapsedSeconds);
    }
}

/// @title 시간에 따른 단리 이자와 상환 배분 검증
/// @notice 실제 토큰 이동 없이 명세의 고정 금액과 정확한 이자 분자를 비교한다.
contract InterestMathTest is Test {
    InterestMathHarness private harness;

    /// @notice 정확한 오류를 관측할 외부 호출 경계를 매번 새로 준비한다.
    function setUp() public {
        harness = new InterestMathHarness();
    }

    /// @notice 연10%와 금리 기준·1년의 초 수를 독립 상수로 읽을 수 있다.
    function test_FixedAnnualRateIsSeparateFromDenominator() public pure {
        assertEq(InterestMath.YEAR_SECONDS, 31_536_000);
        assertEq(InterestMath.RATE_SCALE, 10_000);
        assertEq(InterestMath.ANNUAL_RATE_BPS, 1_000);
        assertEq(InterestMath.DENOMINATOR, 315_360_000_000);
    }

    /// @notice 원금40 USDC를 반년 유지하면 이자2 USDC의 분자가 생긴다.
    function test_FortyForHalfYearAccruesTwo() public pure {
        uint256 interest = InterestMath.accrue(40_000_000, 0, 15_768_000);
        assertEq(interest, 630_720_000_000_000_000);
        assertEq(InterestMath.toRawDown(interest), 2_000_000);
        assertEq(InterestMath.toRawUp(interest), 2_000_000);
    }

    /// @notice 같은 원금40의 1년·2년 이자는4·8로 늘어나며 복리를 만들지 않는다.
    function test_OneAndTwoYearsRemainSimpleInterest() public pure {
        assertEq(InterestMath.accrue(40_000_000, 0, 31_536_000), 1_261_440_000_000_000_000);
        assertEq(InterestMath.accrue(40_000_000, 0, 63_072_000), 2_522_880_000_000_000_000);
    }

    /// @notice 미납 이자10이 있어도 원금40에만 연 이자4를 더한다.
    function test_UnpaidInterestDoesNotEarnInterest() public pure {
        assertEq(InterestMath.accrue(40_000_000, 3_153_600_000_000_000_000, 31_536_000), 4_415_040_000_000_000_000);
    }

    /// @notice 원금이나 경과가0이면 큰 다른 입력에도 기존 분자를 보존한다.
    function test_ZeroPrincipalOrTimePreservesExistingInterest() public pure {
        uint256 max = type(uint256).max;
        assertEq(InterestMath.accrue(0, max, max), max);
        assertEq(InterestMath.accrue(max, max, 0), max);
        assertEq(InterestMath.accrue(0, 0, 0), 0);
    }

    /// @notice 최소 단위 미만의 이자도 3초 한 번과1초 세 번에서 같은 분자3,000을 남긴다.
    function test_SplittingTimePreservesSubRawInterest() public pure {
        uint256 split = InterestMath.accrue(1, 0, 1);
        split = InterestMath.accrue(1, split, 1);
        split = InterestMath.accrue(1, split, 1);
        assertEq(split, 3_000);
        assertEq(InterestMath.accrue(1, 0, 3), 3_000);
        assertEq(InterestMath.accrue(1, split, 0), 3_000);
    }

    /// @notice 금리 곱의 최대 허용값과 분자 합의 최댓값은 잘림 없이 성공한다.
    function test_AccrualAcceptsMaximumNumerator() public pure {
        uint256 max = type(uint256).max;
        assertEq(InterestMath.accrue(max / 1_000, 0, 1), max - 935);
        assertEq(InterestMath.accrue(1, max - 1_000, 1), max);
    }

    /// @notice 원금·시간의 곱 또는 이어지는 금리 곱이 범위를 넘으면 산술 오류다.
    function test_AccrualProductOverflowReverts() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.accrue(type(uint256).max, 0, 2);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.accrue(type(uint256).max / 1_000 + 1, 0, 1);
    }

    /// @notice 곱이 유효해도 기존 미납 이자와의 합이 넘치면 거절한다.
    function test_AccrualAdditionOverflowReverts() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.accrue(1, type(uint256).max - 999, 1);
    }

    /// @notice 원금100raw·이자0.4raw의 완제 견적은101raw다.
    function test_DebtQuoteRoundsOnlyUnpaidInterestUp() public pure {
        assertEq(InterestMath.quoteDebt(100, 126_144_000_000), 101);
    }

    /// @notice 이자1raw의 직전·정확값·직후에서 견적이2·2·3으로 달라진다.
    function test_QuoteAtOneRawInterestBoundary() public pure {
        uint256 before = InterestMath.accrue(1, 0, 315_359_999);
        uint256 exact = InterestMath.accrue(1, 0, 315_360_000);
        uint256 afterBoundary = InterestMath.accrue(1, 0, 315_360_001);
        assertEq(before, 315_359_999_000);
        assertEq(exact, 315_360_000_000);
        assertEq(afterBoundary, 315_360_001_000);
        assertEq(InterestMath.quoteDebt(1, before), 2);
        assertEq(InterestMath.quoteDebt(1, exact), 2);
        assertEq(InterestMath.quoteDebt(1, afterBoundary), 3);
    }

    /// @notice 입력0과 소수 없는 금액은 내림·올림에서 같은 값이다.
    function test_ExactAndZeroConversionsDoNotAddRounding() public pure {
        assertEq(InterestMath.toNumerator(0), 0);
        assertEq(InterestMath.toNumerator(2_000_000), 630_720_000_000_000_000);
        assertEq(InterestMath.toRawDown(630_720_000_000_000_000), 2_000_000);
        assertEq(InterestMath.toRawUp(630_720_000_000_000_000), 2_000_000);
        assertEq(InterestMath.toRawDown(0), 0);
        assertEq(InterestMath.toRawUp(0), 0);
        assertEq(InterestMath.quoteDebt(0, 0), 0);
        assertEq(InterestMath.quoteDebt(type(uint256).max, 0), type(uint256).max);
    }

    /// @notice 0.4raw를 표시하면0이고 실제 수령 단위까지 올리면1이다.
    function test_SubRawInterestHasDifferentFloorAndCeil() public pure {
        assertEq(InterestMath.toRawDown(126_144_000_000), 0);
        assertEq(InterestMath.toRawUp(126_144_000_000), 1);
    }

    /// @notice 누적식에서 생기지 않는 분자Q±1도 제한 없이 정확히 내림·올림한다.
    function test_ArbitraryNumeratorsAroundOneRawAreRounded() public pure {
        assertEq(InterestMath.toRawDown(315_359_999_999), 0);
        assertEq(InterestMath.toRawUp(315_359_999_999), 1);
        assertEq(InterestMath.toRawDown(315_360_000_000), 1);
        assertEq(InterestMath.toRawUp(315_360_000_000), 1);
        assertEq(InterestMath.toRawDown(315_360_000_001), 1);
        assertEq(InterestMath.toRawUp(315_360_000_001), 2);
    }

    /// @notice 최댓값 분자도 불필요한 덧셈 넘침 없이 몫과 다음 정수로 변환한다.
    function test_MaximumNumeratorCanBeRounded() public pure {
        uint256 max = type(uint256).max;
        uint256 whole = max / 315_360_000_000;
        assertEq(max % 315_360_000_000, 168_649_639_935);
        assertEq(InterestMath.toRawDown(max), whole);
        assertEq(InterestMath.toRawUp(max), whole + 1);
        assertEq(InterestMath.quoteDebt(0, max), whole + 1);
    }

    /// @notice 정확 분자로 표현할 수 있는 최대 raw와 그 다음 값을 구분한다.
    function test_NumeratorConversionHasExplicitUpperBound() public {
        uint256 max = type(uint256).max;
        uint256 whole = max / 315_360_000_000;
        assertEq(InterestMath.toNumerator(whole), max - 168_649_639_935);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.toNumerator(whole + 1);
    }

    /// @notice 이자 올림은 유효해도 원금과 합친 완제 견적이 넘치면 거절한다.
    function test_DebtQuoteAdditionOverflowReverts() public {
        uint256 max = type(uint256).max;
        uint256 whole = max / 315_360_000_000;
        assertEq(InterestMath.quoteDebt(max - whole - 1, max), max);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.quoteDebt(max - whole, max);
    }

    /// @notice 원금100·이자10에서30을 갚으면 이자10과 원금20을 배분한다.
    function test_RepaymentPaysInterestBeforePrincipal() public pure {
        _assertRepayment(
            InterestMath.allocateRepayment(100_000_000, 3_153_600_000_000_000_000, 30_000_000),
            80_000_000,
            0,
            10_000_000,
            20_000_000,
            0
        );
    }

    /// @notice 40의 반년 이자2 뒤12를 갚으면 이후1년은 남은 원금30에 이자3만 붙는다.
    function test_AccrualAfterRepaymentUsesReducedPrincipal() public pure {
        uint256 interest = InterestMath.accrue(40_000_000, 0, 15_768_000);
        assertEq(interest, 630_720_000_000_000_000);
        InterestMath.Repayment memory repayment = InterestMath.allocateRepayment(40_000_000, interest, 12_000_000);
        _assertRepayment(repayment, 30_000_000, 0, 2_000_000, 10_000_000, 0);
        assertEq(
            InterestMath.accrue(repayment.remainingPrincipal, repayment.remainingInterestNumerator, 31_536_000),
            946_080_000_000_000_000
        );
    }

    /// @notice 이자10 중3만 받으면 원금100과 남은 이자7을 보존한다.
    function test_PartialInterestPaymentPreservesPrincipal() public pure {
        _assertRepayment(
            InterestMath.allocateRepayment(100_000_000, 3_153_600_000_000_000_000, 3_000_000),
            100_000_000,
            2_207_520_000_000_000_000,
            3_000_000,
            0,
            0
        );
    }

    /// @notice 이자10만 정확히 갚으면 원금100과 올림 차이0을 유지한다.
    function test_ExactInterestOnlyPaymentPreservesPrincipal() public pure {
        _assertRepayment(
            InterestMath.allocateRepayment(100_000_000, 3_153_600_000_000_000_000, 10_000_000),
            100_000_000,
            0,
            10_000_000,
            0,
            0
        );
    }

    /// @notice 미납 이자가 없으면 상환액 전부를 원금에 배분한다.
    function test_NoInterestPaymentOnlyReducesPrincipal() public pure {
        _assertRepayment(InterestMath.allocateRepayment(100, 0, 40), 60, 0, 0, 40, 0);
    }

    /// @notice 이자1.4raw 중1raw만 갚으면 소수0.4raw를 남기고 아직 올림하지 않는다.
    function test_PartialFractionalInterestKeepsRemainder() public pure {
        _assertRepayment(InterestMath.allocateRepayment(100, 441_504_000_000, 1), 100, 126_144_000_000, 1, 0, 0);
    }

    /// @notice 이자1.4raw를2raw로 정산하면 원금은 그대로이며 차이0.6raw를 반환한다.
    function test_ClearingFractionalInterestOnlyRoundsOnce() public pure {
        _assertRepayment(InterestMath.allocateRepayment(100, 441_504_000_000, 2), 100, 0, 2, 0, 189_216_000_000);
    }

    /// @notice 이자0.4raw에서30raw를 받으면 이자1·원금29로 나눠 원금71을 남긴다.
    function test_FractionalInterestSettlementThenPrincipal() public pure {
        _assertRepayment(InterestMath.allocateRepayment(100, 126_144_000_000, 30), 71, 0, 1, 29, 189_216_000_000);
    }

    /// @notice 원금100raw·이자0.4raw의 견적101을 받으면 두 부채가 모두0이다.
    function test_FullRepaymentClearsPrincipalAndInterest() public pure {
        _assertRepayment(InterestMath.allocateRepayment(100, 126_144_000_000, 101), 0, 0, 1, 100, 189_216_000_000);
    }

    /// @notice 이미 정산한 소수 이자는 다음 상환에 다시 붙지 않는다.
    function test_SettledInterestIsNotChargedAgain() public pure {
        InterestMath.Repayment memory first = InterestMath.allocateRepayment(100, 126_144_000_000, 1);
        _assertRepayment(first, 100, 0, 1, 0, 189_216_000_000);
        _assertRepayment(
            InterestMath.allocateRepayment(first.remainingPrincipal, first.remainingInterestNumerator, 1),
            99,
            0,
            0,
            1,
            0
        );
    }

    /// @notice 원금4raw의 새 이자를 반년마다 정산하면1년 한 번보다 올림 수령액이 크다.
    function test_SeparateSettlementsCanAccumulateRounding() public pure {
        uint256 halfYearInterest = InterestMath.accrue(4, 0, 15_768_000);
        assertEq(halfYearInterest, 63_072_000_000);
        InterestMath.Repayment memory first = InterestMath.allocateRepayment(4, halfYearInterest, 1);
        _assertRepayment(first, 4, 0, 1, 0, 252_288_000_000);
        uint256 nextInterest =
            InterestMath.accrue(first.remainingPrincipal, first.remainingInterestNumerator, 15_768_000);
        InterestMath.Repayment memory second = InterestMath.allocateRepayment(first.remainingPrincipal, nextInterest, 1);
        _assertRepayment(second, 4, 0, 1, 0, 252_288_000_000);
        assertEq(first.interestPaid + second.interestPaid, 2);
        assertEq(first.roundingSurplusNumerator + second.roundingSurplusNumerator, 504_576_000_000);

        uint256 oneYearInterest = InterestMath.accrue(4, 0, 31_536_000);
        assertEq(oneYearInterest, 126_144_000_000);
        _assertRepayment(InterestMath.allocateRepayment(4, oneYearInterest, 1), 4, 0, 1, 0, 189_216_000_000);
    }

    /// @notice 0상환은 부채 조회의 산술 오류보다 먼저 명시적으로 거절한다.
    function test_ZeroRepaymentRevertsBeforeQuote() public {
        vm.expectRevert(InterestMath.ZeroAmount.selector);
        harness.allocateRepayment(0, 0, 0);
        vm.expectRevert(InterestMath.ZeroAmount.selector);
        harness.allocateRepayment(type(uint256).max, type(uint256).max, 0);
    }

    /// @notice 부채0의 양수 요청은 그 요청액을 가진 초과상환 오류다.
    function test_NoDebtRepaymentReverts() public {
        vm.expectRevert(abi.encodeWithSelector(InterestMath.RepayExceedsDebt.selector, 0, 1));
        harness.allocateRepayment(0, 0, 1);
    }

    /// @notice 견적 바로 위와 최댓값 요청 모두 배율 곱보다 먼저 초과상환으로 거절한다.
    function test_ExcessRepaymentRevertsBeforeScalingRequest() public {
        vm.expectRevert(abi.encodeWithSelector(InterestMath.RepayExceedsDebt.selector, 101, 102));
        harness.allocateRepayment(100, 126_144_000_000, 102);
        vm.expectRevert(abi.encodeWithSelector(InterestMath.RepayExceedsDebt.selector, 101, type(uint256).max));
        harness.allocateRepayment(100, 126_144_000_000, type(uint256).max);
    }

    /// @notice 양수 상환의 견적 자체가 범위를 넘으면 산술 오류를 전파한다.
    function test_RepaymentPropagatesQuoteOverflow() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.allocateRepayment(type(uint256).max, 1, 1);
    }

    /// @notice 최대 분자의 정수 부분만 갚으면 곱이 범위 안이고 정확 나머지를 남긴다.
    function test_PartialMaximumInterestPreservesExactRemainder() public pure {
        uint256 max = type(uint256).max;
        uint256 whole = max / 315_360_000_000;
        _assertRepayment(InterestMath.allocateRepayment(0, max, whole), 0, 168_649_639_935, whole, 0, 0);
    }

    /// @notice 최대 분자 완제는 큰 지급액 전체를 배율 곱하지 않고 차이만 반환한다.
    function test_MaximumInterestSettlementAvoidsUnneededMultiplication() public pure {
        uint256 max = type(uint256).max;
        uint256 due = max / 315_360_000_000 + 1;
        _assertRepayment(InterestMath.allocateRepayment(0, max, due), 0, 0, due, 0, 146_710_360_065);
    }

    /// @notice 순수 배분은 이자 없는 최대 raw 원금도 불필요한 배율 변환 없이 완제한다.
    function test_MaximumPrincipalSettlementDoesNotScalePayment() public pure {
        uint256 max = type(uint256).max;
        _assertRepayment(InterestMath.allocateRepayment(max, 0, max), 0, 0, 0, max, 0);
    }

    /// @notice 반환된 다섯 값을 명세에서 정한 고정 기대값과 각각 비교한다.
    function _assertRepayment(
        InterestMath.Repayment memory actual,
        uint256 remainingPrincipal,
        uint256 remainingInterestNumerator,
        uint256 interestPaid,
        uint256 principalPaid,
        uint256 roundingSurplusNumerator
    ) private pure {
        assertEq(actual.remainingPrincipal, remainingPrincipal, "remaining principal");
        assertEq(actual.remainingInterestNumerator, remainingInterestNumerator, "remaining interest numerator");
        assertEq(actual.interestPaid, interestPaid, "interest paid");
        assertEq(actual.principalPaid, principalPaid, "principal paid");
        assertEq(actual.roundingSurplusNumerator, roundingSurplusNumerator, "rounding surplus numerator");
    }
}

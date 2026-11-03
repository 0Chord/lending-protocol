// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {CollateralMath} from "../src/libraries/CollateralMath.sol";
import {InterestMath} from "../src/libraries/InterestMath.sol";
import {LiquidationMath} from "../src/libraries/LiquidationMath.sol";

/// @title 청산 계산 결과를 관측하는 시험 전용 호출 경계
/// @notice 계산을 복제하지 않고 입력값을 internal 순수 함수에 그대로 전달한다.
contract LiquidationMathHarness {
    /// @notice 정확 부채와 담보의 80% 초과 여부를 외부 호출로 관측한다.
    function isLiquidatable(
        uint256 debtNumerator,
        uint256 collateralWBTC8,
        int256 price8,
        uint256 updatedAt,
        uint256 currentTime
    ) external pure returns (bool) {
        return LiquidationMath.isLiquidatable(debtNumerator, collateralWBTC8, price8, updatedAt, currentTime);
    }

    /// @notice 실제 완제액에 5% 보상을 적용한 WBTC 지급량을 관측한다.
    function collateralOut(
        uint256 repaymentUSDC6,
        uint256 collateralWBTC8,
        int256 price8,
        uint256 updatedAt,
        uint256 currentTime
    ) external pure returns (uint256) {
        return LiquidationMath.collateralOut(repaymentUSDC6, collateralWBTC8, price8, updatedAt, currentTime);
    }
}

/// @title 정확한 청산 대상 판정과 WBTC 지급량 검증
/// @notice 합의한 부채·가격 예시와 정확히 80%인 경계를 고정 기대값으로 확인한다.
contract LiquidationMathTest is Test {
    LiquidationMathHarness private harness;

    /// @notice 매 테스트에서 계산을 외부 호출로 관측할 경계를 준비한다.
    function setUp() public {
        harness = new LiquidationMathHarness();
    }

    /// @notice 부채 70 USDC·1 WBTC·가격 80이면 청산 대상이며 완제 지급량은 0.91875000 WBTC다.
    function test_SeventyDebtAtEightyPriceIsLiquidatableWithFivePercentBonus() public view {
        uint256 debtNumerator = 70_000_000 * InterestMath.DENOMINATOR;

        assertTrue(harness.isLiquidatable(debtNumerator, 100_000_000, 8_000_000_000, 10_000, 10_000));
        assertEq(harness.collateralOut(70_000_000, 100_000_000, 8_000_000_000, 10_000, 10_000), 91_875_000);
    }

    /// @notice 부채 70 USDC가 가격 87.5인 1 WBTC 가치의 정확히 80%이면 청산 대상이 아니다.
    function test_ExactlyEightyPercentIsNotLiquidatable() public view {
        uint256 debtNumerator = 70_000_000 * InterestMath.DENOMINATOR;

        assertFalse(harness.isLiquidatable(debtNumerator, 100_000_000, 8_750_000_000, 10_000, 10_000));
    }

    /// @notice 완제 70 USDC의 보상 포함 73.5 USDC를 감당하지 못하는 가격 72·60에서는 전체 거절한다.
    function test_InsufficientCollateralAtSeventyTwoAndSixtyPricesReverts() public {
        vm.expectRevert(LiquidationMath.InsufficientLiquidationCollateral.selector);
        harness.collateralOut(70_000_000, 100_000_000, 7_200_000_000, 10_000, 10_000);

        vm.expectRevert(LiquidationMath.InsufficientLiquidationCollateral.selector);
        harness.collateralOut(70_000_000, 100_000_000, 6_000_000_000, 10_000, 10_000);
    }

    /// @notice 필요 담보가 1.05 raw이면 보유 1 raw와 내림 지급량 1이 같아도 부족으로 거절한다.
    function test_ExactCollateralRequirementIsCheckedBeforeRoundingDown() public {
        vm.expectRevert(LiquidationMath.InsufficientLiquidationCollateral.selector);
        harness.collateralOut(1, 1, 10_000_000_000, 10_000, 10_000);
    }

    /// @notice 유효 가격이어도 완제액 0은 지급 계산 전에 기존 금액 오류로 거절한다.
    function test_ZeroRepaymentWithValidPriceReverts() public {
        vm.expectRevert(InterestMath.ZeroAmount.selector);
        harness.collateralOut(0, 100_000_000, 8_000_000_000, 10_000, 10_000);
    }

    /// @notice 정확 필요 담보가 보유량 이하여도 최종 지급량을 내린 결과가 0이면 거절한다.
    function test_ZeroCollateralOutAfterRoundingDownReverts() public {
        vm.expectRevert(LiquidationMath.ZeroCollateralOut.selector);
        harness.collateralOut(1, 1, 11_000_000_000, 10_000, 10_000);
    }

    /// @notice 가격 73.5에서 완제 70 USDC의 필요 담보가 정확히 1 WBTC이면 전량 지급을 허용한다.
    function test_ExactCollateralCoverageIsAllowed() public view {
        assertEq(harness.collateralOut(70_000_000, 100_000_000, 7_350_000_000, 10_000, 10_000), 100_000_000);
    }

    /// @notice 보유 2 raw로 정확 필요량 1.75 raw를 충족하면 마지막에만 내려 1 raw를 지급한다.
    function test_CollateralOutRoundsDownOnlyAtFinalWBTCUnit() public view {
        assertEq(harness.collateralOut(1, 2, 6_000_000_000, 10_000, 10_000), 1);
    }

    /// @notice 같은 부채 70 USDC라도 가격 90에서는 안전하고 가격 85에서는 80% 경계를 넘는다.
    function test_PricesNinetyAndEightyFiveFallOnOppositeSidesOfThreshold() public view {
        uint256 debtNumerator = 70_000_000 * InterestMath.DENOMINATOR;

        assertFalse(harness.isLiquidatable(debtNumerator, 100_000_000, 9_000_000_000, 10_000, 10_000));
        assertTrue(harness.isLiquidatable(debtNumerator, 100_000_000, 8_500_000_000, 10_000, 10_000));
    }

    /// @notice 부채 1 raw·담보 가치 1.25 raw의 정확 80%를 담보 가치 내림으로 청산 대상으로 바꾸지 않는다.
    function test_FractionalCollateralValueIsNotRoundedDownBeforeThreshold() public view {
        assertFalse(harness.isLiquidatable(InterestMath.DENOMINATOR, 1, 12_500_000_000, 10_000, 10_000));
    }

    /// @notice 부채 1 raw에 작은 이자가 붙어도 완제 견적 2 raw를 써서 1.6 raw 경계를 넘긴 것으로 보지 않는다.
    function test_FractionalDebtIsNotRoundedUpBeforeThreshold() public view {
        assertFalse(harness.isLiquidatable(InterestMath.DENOMINATOR + 1_000, 2, 10_000_000_000, 10_000, 10_000));
    }

    /// @notice 반년 이자 포함 부채 73.5 USDC를 갚으면 가격 80에서 0.96468750 WBTC를 받고 0.03531250이 남는다.
    function test_SeventyThreePointFiveDebtIncludesAccruedInterestInPayout() public view {
        uint256 debtNumerator = 73_500_000 * InterestMath.DENOMINATOR;

        assertTrue(harness.isLiquidatable(debtNumerator, 100_000_000, 8_000_000_000, 10_000, 10_000));
        uint256 collateralOut = harness.collateralOut(73_500_000, 100_000_000, 8_000_000_000, 10_000, 10_000);
        assertEq(collateralOut, 96_468_750);
        assertEq(100_000_000 - collateralOut, 3_531_250);
    }

    /// @notice 유효 가격에서 부채가 0이면 담보가 있거나 없어도 청산 대상이 아니다.
    function test_ZeroDebtWithValidPriceIsNotLiquidatable() public view {
        assertFalse(harness.isLiquidatable(0, 100_000_000, 8_000_000_000, 10_000, 10_000));
        assertFalse(harness.isLiquidatable(0, 0, 8_000_000_000, 10_000, 10_000));
    }

    /// @notice 유효 가격에서 담보가 0이고 정확 부채가 양수이면 청산 대상이다.
    function test_PositiveDebtWithZeroCollateralIsLiquidatable() public view {
        assertTrue(harness.isLiquidatable(InterestMath.DENOMINATOR, 0, 8_000_000_000, 10_000, 10_000));
    }

    /// @notice 담보가 없으면 양수 완제액의 지급 계산은 지급 0 오류보다 담보 부족으로 거절한다.
    function test_PositiveRepaymentWithZeroCollateralRevertsAsInsufficient() public {
        vm.expectRevert(LiquidationMath.InsufficientLiquidationCollateral.selector);
        harness.collateralOut(1, 0, 8_000_000_000, 10_000, 10_000);
    }

    /// @notice 극소 완제액 1 raw·가격 55에서는 양수 지급 1 WBTC raw의 가치가 지불액보다 작을 수 있다.
    function test_PositiveDustPayoutMayBeWorthLessThanRepayment() public view {
        assertEq(harness.collateralOut(1, 2, 5_500_000_000, 10_000, 10_000), 1);
    }

    /// @notice 가격 0·음수·int256 최솟값은 두 계산 모두 같은 가격 오류와 전체 인수로 거절한다.
    function test_NonPositivePricesRevertForBothCalculations() public {
        int256[3] memory prices = [int256(0), int256(-1), type(int256).min];
        for (uint256 i; i < prices.length; ++i) {
            int256 price = prices[i];
            _assertCalculationsRevert(
                70_000_000 * InterestMath.DENOMINATOR,
                70_000_000,
                100_000_000,
                price,
                10_000,
                10_000,
                abi.encodeWithSelector(CollateralMath.InvalidPrice.selector, price)
            );
        }
    }

    /// @notice 부채·완제액·담보가 0이어도 잘못된 가격은 갱신시각이나 금액 검사보다 먼저 거절한다.
    function test_InvalidPricePrecedesTimestampAndAmountEvenForZeroInputs() public {
        _assertCalculationsRevert(
            0, 0, 0, 0, 0, 10_000, abi.encodeWithSelector(CollateralMath.InvalidPrice.selector, int256(0))
        );
    }

    /// @notice 갱신시각 0·미래시각은 두 계산 모두 경과시간을 계산하기 전에 거절한다.
    function test_ZeroOrFutureTimestampRevertsForBothCalculations() public {
        uint256[2] memory timestamps = [uint256(0), 10_001];
        for (uint256 i; i < timestamps.length; ++i) {
            uint256 updatedAt = timestamps[i];
            _assertCalculationsRevert(
                70_000_000 * InterestMath.DENOMINATOR,
                70_000_000,
                100_000_000,
                8_000_000_000,
                updatedAt,
                10_000,
                abi.encodeWithSelector(CollateralMath.InvalidPriceTimestamp.selector, updatedAt, uint256(10_000))
            );
        }
    }

    /// @notice 입력 금액이 모두 0이어도 시각 0의 오류가 오래된 가격·완제액 0 검사보다 먼저 발생한다.
    function test_InvalidTimestampPrecedesAgeAndAmountEvenForZeroInputs() public {
        _assertCalculationsRevert(
            0,
            0,
            0,
            8_000_000_000,
            0,
            10_000,
            abi.encodeWithSelector(CollateralMath.InvalidPriceTimestamp.selector, uint256(0), uint256(10_000))
        );
    }

    /// @notice 입력 금액이 모두 0이어도 미래 갱신시각과 3601초 지난 가격을 숨기지 않는다.
    function test_ZeroInputsStillRejectFutureAndStaleTimestamps() public {
        _assertCalculationsRevert(
            0,
            0,
            0,
            8_000_000_000,
            10_001,
            10_000,
            abi.encodeWithSelector(CollateralMath.InvalidPriceTimestamp.selector, uint256(10_001), uint256(10_000))
        );
        _assertCalculationsRevert(
            0,
            0,
            0,
            8_000_000_000,
            6_399,
            10_000,
            abi.encodeWithSelector(CollateralMath.StalePrice.selector, uint256(6_399), uint256(10_000))
        );
    }

    /// @notice 정확히 3600초 지난 가격은 청산 판정과 지급량 계산 모두에 유효하다.
    function test_ExactlyOneHourOldPriceIsValidForBothCalculations() public view {
        assertTrue(
            harness.isLiquidatable(70_000_000 * InterestMath.DENOMINATOR, 100_000_000, 8_000_000_000, 6_400, 10_000)
        );
        assertEq(harness.collateralOut(70_000_000, 100_000_000, 8_000_000_000, 6_400, 10_000), 91_875_000);
    }

    /// @notice 가격 유효 시간을 1초 넘기면 두 계산 모두 같은 오래된 가격 오류로 거절한다.
    function test_OneSecondPastValidityRevertsForBothCalculations() public {
        _assertCalculationsRevert(
            70_000_000 * InterestMath.DENOMINATOR,
            70_000_000,
            100_000_000,
            8_000_000_000,
            6_399,
            10_000,
            abi.encodeWithSelector(CollateralMath.StalePrice.selector, uint256(6_399), uint256(10_000))
        );
    }

    /// @notice 중간 곱이 uint256을 넘어도 정확 80%는 false이며 부채 분자 1만 더하면 true다.
    function test_LargeIntermediateProductsPreserveExactThresholdAndNextNumerator() public view {
        uint256 k = type(uint256).max / 15_768;
        uint256 debtNumerator = 15_768 * k;
        uint256 collateralWBTC8 = 625 * k;

        assertFalse(harness.isLiquidatable(debtNumerator, collateralWBTC8, 1, 10_000, 10_000));
        assertTrue(harness.isLiquidatable(debtNumerator + 1, collateralWBTC8, 1, 10_000, 10_000));
    }

    /// @notice 부채·담보가 최댓값이고 가격도 int256 최댓값이면 큰 담보 가치로 청산 대상이 아니다.
    function test_MaximumDebtAndCollateralAtMaximumPriceIsNotLiquidatable() public view {
        assertFalse(harness.isLiquidatable(type(uint256).max, type(uint256).max, type(int256).max, 10_000, 10_000));
    }

    /// @notice 완제액과 담보가 최댓값이어도 정확 필요 담보가 같으면 최댓값 지급을 허용한다.
    function test_MaximumRepaymentWithExactMaximumCoverageReturnsMaximum() public view {
        assertEq(
            harness.collateralOut(type(uint256).max, type(uint256).max, 10_500_000_000, 10_000, 10_000),
            type(uint256).max
        );
    }

    /// @notice 최댓값 지급이 필요한데 담보가 1 raw 모자라면 큰 중간 곱에도 정확 부족 오류로 거절한다.
    function test_MaximumRepaymentWithOneLessCollateralRevertsAsInsufficient() public {
        vm.expectRevert(LiquidationMath.InsufficientLiquidationCollateral.selector);
        harness.collateralOut(type(uint256).max, type(uint256).max - 1, 10_500_000_000, 10_000, 10_000);
    }

    /// @notice 가격 1 raw의 거대한 필요 수량을 먼저 계산해 Panic으로 바꾸지 않고 부족 오류로 거절한다.
    function test_UnrepresentableRequiredCollateralRevertsAsInsufficient() public {
        vm.expectRevert(LiquidationMath.InsufficientLiquidationCollateral.selector);
        harness.collateralOut(type(uint256).max, type(uint256).max, 1, 10_000, 10_000);
    }

    /// @notice 필요 담보를 내리면 최댓값이어도 정확값이 조금 넘으면 올림 Panic 대신 부족 오류로 거절한다.
    function test_FractionAboveMaximumCollateralRevertsWithoutCeilingOverflow() public {
        uint256 max = type(uint256).max;
        uint256 repaymentUSDC6 = max - max / 10_500_000_000;

        vm.expectRevert(LiquidationMath.InsufficientLiquidationCollateral.selector);
        harness.collateralOut(repaymentUSDC6, max, 10_499_999_999, 10_000, 10_000);
    }

    /// @notice 큰 수 전 구간에서 정확 80% 등호와 부채 분자 1 증가의 서로 다른 판정을 유지한다.
    function testFuzz_ExactThresholdAndNextNumerator(uint256 seed) public view {
        uint256 k = bound(seed, 1, type(uint256).max / 15_768);
        uint256 debtNumerator = 15_768 * k;
        uint256 collateralWBTC8 = 625 * k;

        assertFalse(harness.isLiquidatable(debtNumerator, collateralWBTC8, 1, 10_000, 10_000));
        assertTrue(harness.isLiquidatable(debtNumerator + 1, collateralWBTC8, 1, 10_000, 10_000));
    }

    /// @notice 작은 곱 범위에서 105%·6/8/8 단위 원식으로 정확 담보 충족과 최종 지급 내림을 대조한다.
    /// @dev 기대식의 중간 곱은 최대 4e30으로 제한해 제품의 전정밀도 연산을 복제하지 않는다.
    function testFuzz_PayoutMatchesExactSmallIntegerFormula(
        uint256 repaymentSeed,
        uint256 collateralSeed,
        uint256 priceSeed
    ) public {
        uint256 repaymentUSDC6 = bound(repaymentSeed, 1, 1e12);
        uint256 collateralWBTC8 = bound(collateralSeed, 0, 2e12);
        uint256 price8 = bound(priceSeed, 1, 2e10);
        // 위 bound로 가격이 int256 양수 범위 안에 있음을 확인했다.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 signedPrice = int256(price8);
        uint256 requiredNumerator = repaymentUSDC6 * 105 * 100_000_000 * 100_000_000;
        uint256 denominator = 100 * 1_000_000 * price8;

        if (requiredNumerator > collateralWBTC8 * denominator) {
            vm.expectRevert(LiquidationMath.InsufficientLiquidationCollateral.selector);
            harness.collateralOut(repaymentUSDC6, collateralWBTC8, signedPrice, 10_000, 10_000);
            return;
        }

        uint256 expected = requiredNumerator / denominator;
        if (expected == 0) {
            vm.expectRevert(LiquidationMath.ZeroCollateralOut.selector);
            harness.collateralOut(repaymentUSDC6, collateralWBTC8, signedPrice, 10_000, 10_000);
            return;
        }

        assertEq(harness.collateralOut(repaymentUSDC6, collateralWBTC8, signedPrice, 10_000, 10_000), expected);
    }

    /// @notice 두 외부 호출의 가격 오류 종류와 전체 인수를 각각 확인한다.
    function _assertCalculationsRevert(
        uint256 debtNumerator,
        uint256 repaymentUSDC6,
        uint256 collateralWBTC8,
        int256 price8,
        uint256 updatedAt,
        uint256 currentTime,
        bytes memory expected
    ) private {
        vm.expectRevert(expected);
        harness.isLiquidatable(debtNumerator, collateralWBTC8, price8, updatedAt, currentTime);
        vm.expectRevert(expected);
        harness.collateralOut(repaymentUSDC6, collateralWBTC8, price8, updatedAt, currentTime);
    }
}

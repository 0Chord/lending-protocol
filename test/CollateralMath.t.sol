// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {CollateralMath} from "../src/libraries/CollateralMath.sol";

/// @title 담보 계산 오류를 관측하는 시험 전용 호출 경계
/// @notice 계산을 복제하지 않고 입력값을 internal 순수 함수에 그대로 전달한다.
contract CollateralMathHarness {
    /// @notice WBTC 8자리 수량과 가격 8자리를 USDC 6자리 가치로 계산한다.
    function collateralValueDown(uint256 collateralWBTC8, int256 price8, uint256 updatedAt, uint256 currentTime)
        external
        pure
        returns (uint256)
    {
        return CollateralMath.collateralValueDown(collateralWBTC8, price8, updatedAt, currentTime);
    }

    /// @notice 담보 가치와 70% 한도를 각각 내림하는 계산을 그대로 전달한다.
    function maxDebtDown(uint256 collateralWBTC8, int256 price8, uint256 updatedAt, uint256 currentTime)
        external
        pure
        returns (uint256)
    {
        return CollateralMath.maxDebtDown(collateralWBTC8, price8, updatedAt, currentTime);
    }
}

/// @title WBTC 담보 가치와 USDC 대출 한도 검증
/// @notice 단위가 다른 수량·가격·결과를 고정 기대값으로 확인한다.
contract CollateralMathTest is Test {
    CollateralMathHarness private harness;

    /// @notice 매 테스트에서 계산을 외부 호출로 관측할 경계를 준비한다.
    function setUp() public {
        harness = new CollateralMathHarness();
    }

    /// @notice 1 WBTC를 100 USDC로 평가하면 가치는 100 USDC이고 한도는 70 USDC다.
    function test_OneWBTCAtOneHundredUSDC() public view {
        assertEq(harness.collateralValueDown(100_000_000, 10_000_000_000, 10_000, 10_000), 100_000_000);
        assertEq(harness.maxDebtDown(100_000_000, 10_000_000_000, 10_000, 10_000), 70_000_000);
    }

    /// @notice 0.5 WBTC의 가치와 한도도 USDC 6자리 최소 단위로 반환한다.
    function test_HalfWBTCUsesSixDecimalUSDC() public view {
        assertEq(harness.collateralValueDown(50_000_000, 10_000_000_000, 10_000, 10_000), 50_000_000);
        assertEq(harness.maxDebtDown(50_000_000, 10_000_000_000, 10_000, 10_000), 35_000_000);
    }

    /// @notice WBTC 최소 단위 3의 가치 4.5를 4로 내리고 그 한도 2.8도 2로 내린다.
    function test_ValueAndLimitRoundDownInTwoSteps() public view {
        assertEq(harness.collateralValueDown(3, 15_000_000_000, 10_000, 10_000), 4);
        assertEq(harness.maxDebtDown(3, 15_000_000_000, 10_000, 10_000), 2);
    }

    /// @notice 가격과 시각이 유효하면 담보 0의 가치와 한도는 모두 0이다.
    function test_ZeroCollateralWithValidPriceReturnsZero() public view {
        assertEq(harness.collateralValueDown(0, 10_000_000_000, 10_000, 10_000), 0);
        assertEq(harness.maxDebtDown(0, 10_000_000_000, 10_000, 10_000), 0);
    }

    /// @notice 가격 0·음수·int256 최솟값은 부호 변환 전에 같은 가격 오류로 거절한다.
    function test_NonPositivePricesRevert() public {
        int256[3] memory prices = [int256(0), int256(-1), type(int256).min];
        for (uint256 i; i < prices.length; ++i) {
            int256 price = prices[i];
            _assertCalculationsRevert(
                100_000_000, price, 10_000, 10_000, abi.encodeWithSelector(CollateralMath.InvalidPrice.selector, price)
            );
        }
    }

    /// @notice 담보가 0이어도 가격 오류가 잘못된 갱신시각 검사보다 먼저 발생한다.
    function test_InvalidPricePrecedesTimestampEvenForZeroCollateral() public {
        _assertCalculationsRevert(
            0, 0, 0, 10_000, abi.encodeWithSelector(CollateralMath.InvalidPrice.selector, int256(0))
        );
    }

    /// @notice 갱신 후 정확히 3600초인 가격은 가치와 한도 계산에 사용할 수 있다.
    function test_ExactlyOneHourOldIsValid() public view {
        assertEq(harness.collateralValueDown(100_000_000, 10_000_000_000, 6_400, 10_000), 100_000_000);
        assertEq(harness.maxDebtDown(100_000_000, 10_000_000_000, 6_400, 10_000), 70_000_000);
    }

    /// @notice 유효 시간을 1초 넘긴 가격은 두 계산 모두 같은 시각 인수로 거절한다.
    function test_OneSecondPastValidityReverts() public {
        _assertCalculationsRevert(
            100_000_000,
            10_000_000_000,
            6_399,
            10_000,
            abi.encodeWithSelector(CollateralMath.StalePrice.selector, uint256(6_399), uint256(10_000))
        );
    }

    /// @notice 갱신시각 0과 미래시각은 경과시간을 계산하기 전에 거절한다.
    function test_ZeroOrFutureTimestampReverts() public {
        uint256[2] memory timestamps = [uint256(0), 10_001];
        for (uint256 i; i < timestamps.length; ++i) {
            uint256 updatedAt = timestamps[i];
            _assertCalculationsRevert(
                100_000_000,
                10_000_000_000,
                updatedAt,
                10_000,
                abi.encodeWithSelector(CollateralMath.InvalidPriceTimestamp.selector, updatedAt, uint256(10_000))
            );
        }
    }

    /// @notice 담보가 0이어도 시각 0은 오래된 가격 오류보다 갱신시각 오류가 우선한다.
    function test_InvalidTimestampPrecedesAgeEvenForZeroCollateral() public {
        _assertCalculationsRevert(
            0,
            10_000_000_000,
            0,
            10_000,
            abi.encodeWithSelector(CollateralMath.InvalidPriceTimestamp.selector, uint256(0), uint256(10_000))
        );
    }

    /// @notice 담보 0의 조기 반환으로 미래시각과 오래된 가격 오류를 숨기지 않는다.
    function test_ZeroCollateralStillValidatesTime() public {
        _assertCalculationsRevert(
            0,
            10_000_000_000,
            10_001,
            10_000,
            abi.encodeWithSelector(CollateralMath.InvalidPriceTimestamp.selector, uint256(10_001), uint256(10_000))
        );
        _assertCalculationsRevert(
            0,
            10_000_000_000,
            6_399,
            10_000,
            abi.encodeWithSelector(CollateralMath.StalePrice.selector, uint256(6_399), uint256(10_000))
        );
    }

    /// @notice 두 단계의 중간 곱이 범위를 넘어도 최종 가치와 한도가 uint256에 맞으면 성공한다.
    function test_IntermediateProductsMayOverflowWhenResultsFit() public view {
        uint256 max = type(uint256).max;
        assertEq(harness.collateralValueDown(max, 10_000_000_000, 10_000, 10_000), max);
        assertEq(
            harness.maxDebtDown(max, 10_000_000_000, 10_000, 10_000),
            81054462466121336796499689506081535497288989265948394827620308805539190747954
        );
    }

    /// @notice 첫 가치부터 uint256 범위를 넘으면 한도 계산도 같은 Panic 전체 인수를 전파한다.
    function test_OverflowingCollateralValueRevertsForBothCalculations() public {
        _assertCalculationsRevert(
            type(uint256).max, 10_000_000_001, 10_000, 10_000, abi.encodeWithSignature("Panic(uint256)", uint256(0x11))
        );
    }

    /// @notice 두 외부 호출이 오류 종류와 전체 인수를 각각 그대로 반환하는지 확인한다.
    function _assertCalculationsRevert(
        uint256 collateralWBTC8,
        int256 price8,
        uint256 updatedAt,
        uint256 currentTime,
        bytes memory expected
    ) private {
        vm.expectRevert(expected);
        harness.collateralValueDown(collateralWBTC8, price8, updatedAt, currentTime);
        vm.expectRevert(expected);
        harness.maxDebtDown(collateralWBTC8, price8, updatedAt, currentTime);
    }
}

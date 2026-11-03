// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CollateralMath} from "./CollateralMath.sol";
import {InterestMath} from "./InterestMath.sol";

/// @title 정확한 청산 대상 판정과 WBTC 지급량 계산
/// @notice 토큰·장부·가격 원천에 접근하지 않고 고정 6/8/8 단위의 입력만 계산한다.
library LiquidationMath {
    uint256 private constant VALUE_SCALE = 1e10;
    uint256 private constant BPS_SCALE = 10_000;
    uint256 private constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    uint256 private constant LIQUIDATION_BONUS_BPS = 500;
    uint256 private constant PAYOUT_SCALE = VALUE_SCALE * (BPS_SCALE + LIQUIDATION_BONUS_BPS) / BPS_SCALE;

    /// @notice 정수 지급 전의 정확 필요 담보가 기록 담보를 넘으면 거절한다.
    error InsufficientLiquidationCollateral();

    /// @notice 충분한 담보가 있어도 최종 지급량이 0이면 거절한다.
    error ZeroCollateralOut();

    /// @notice 현재 정확 부채가 담보 가치의 80%를 초과할 때만 true다.
    /// @dev 양수·시각 검증 뒤 정확 부등호를 정수 곱의 비교로 옮긴다. 정확히 80%면 false다.
    /// @param debtNumerator InterestMath 분모 단위로 표현한 현재 정확 부채
    /// @param collateralWBTC8 차입자의 기록 담보인 WBTC 최소 단위 수량
    /// @param price8 소수점 8자리 WBTC의 USDC 직접호가
    /// @param updatedAt 가격 갱신시각
    /// @param currentTime 같은 부채와 가격을 평가할 현재 시각
    function isLiquidatable(
        uint256 debtNumerator,
        uint256 collateralWBTC8,
        int256 price8,
        uint256 updatedAt,
        uint256 currentTime
    ) internal pure returns (bool) {
        uint256 price = CollateralMath.validatePrice(price8, updatedAt, currentTime);
        // C*p는 정수이므로 C*p < 정확 경계와 C*p < ceil(정확 경계)는 동치다.
        // 부채나 담보 가치를 정수 USDC로 먼저 반올림하는 계산이 아니다.
        uint256 boundary = Math.mulDiv(
            debtNumerator,
            VALUE_SCALE * BPS_SCALE,
            InterestMath.DENOMINATOR * LIQUIDATION_THRESHOLD_BPS,
            Math.Rounding.Ceil
        );
        (uint256 high, uint256 low) = Math.mul512(collateralWBTC8, price);
        // 경계는 debtNumerator 이하여서 담보 곱의 상위 자리가 양수면 항상 대상 밖이다.
        return high == 0 && low < boundary;
    }

    /// @notice 정확 필요 담보가 충분할 때만 완제액의 105%를 WBTC 최소 단위에서 내린다.
    /// @dev 부족 여부는 나눗셈 전에 512비트 곱으로 비교하며 최종 지급 0도 거절한다.
    /// @param repaymentUSDC6 실제 받을 USDC 완제액의 최소 단위 수량
    /// @param collateralWBTC8 지급에 사용할 차입자의 기록 담보 수량
    /// @param price8 소수점 8자리 WBTC의 USDC 직접호가
    /// @param updatedAt 가격 갱신시각
    /// @param currentTime 같은 부채와 가격을 평가할 현재 시각
    /// @return 기록 담보 이하의 양수 WBTC 최소 단위 지급량
    function collateralOut(
        uint256 repaymentUSDC6,
        uint256 collateralWBTC8,
        int256 price8,
        uint256 updatedAt,
        uint256 currentTime
    ) internal pure returns (uint256) {
        uint256 price = CollateralMath.validatePrice(price8, updatedAt, currentTime);
        if (repaymentUSDC6 == 0) revert InterestMath.ZeroAmount();

        (uint256 requiredHigh, uint256 requiredLow) = Math.mul512(repaymentUSDC6, PAYOUT_SCALE);
        (uint256 availableHigh, uint256 availableLow) = Math.mul512(collateralWBTC8, price);
        if (requiredHigh > availableHigh || (requiredHigh == availableHigh && requiredLow > availableLow)) {
            revert InsufficientLiquidationCollateral();
        }

        // 정확 필요량이 기록 담보 이하여서 최종 몫도 uint256 안에 들어간다.
        uint256 amount = Math.mulDiv(repaymentUSDC6, PAYOUT_SCALE, price, Math.Rounding.Floor);
        if (amount == 0) revert ZeroCollateralOut();
        return amount;
    }
}

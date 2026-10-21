// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title WBTC 담보의 USDC 가치와 대출 한도 계산
/// @notice 토큰이나 가격 원천을 직접 읽지 않고 정수 입력만 계산한다.
/// @dev 담보 0도 가격·시각을 검증하며, 각 단계의 최종 범위 초과는 Panic(0x11)을 전파한다.
library CollateralMath {
    // 수량 8자리 × 가격 8자리에서 결과 USDC 6자리를 남기는 배율이다.
    uint256 private constant VALUE_SCALE = 1e10;
    uint256 private constant LTV_BPS = 7_000;
    uint256 private constant BPS_SCALE = 10_000;
    uint256 private constant MAX_PRICE_AGE = 1 hours;

    /// @notice 0 이하의 원시 가격은 담보 평가에 사용할 수 없다.
    error InvalidPrice(int256 price);

    /// @notice 갱신시각이 없거나 미래이면 담보 평가에 사용할 수 없다.
    error InvalidPriceTimestamp(uint256 updatedAt, uint256 currentTime);

    /// @notice 갱신 후 1시간을 초과한 가격은 담보 평가에 사용할 수 없다.
    error StalePrice(uint256 updatedAt, uint256 currentTime);

    /// @notice WBTC 수량과 가격을 USDC 최소 단위 가치로 환산한다.
    /// @param collateralWBTC8 소수점 8자리 WBTC 최소 단위 수량
    /// @param price8 1 WBTC당 USDC 직접호가의 소수점 8자리 정수
    /// @param updatedAt 가격 갱신시각의 초 단위 타임스탬프
    /// @param currentTime 호출자가 전달하는 현재 시각
    /// @return 소수점 6자리 USDC 최소 단위로 내린 담보 가치
    function collateralValueDown(uint256 collateralWBTC8, int256 price8, uint256 updatedAt, uint256 currentTime)
        internal
        pure
        returns (uint256)
    {
        if (price8 <= 0) revert InvalidPrice(price8);
        if (updatedAt == 0 || updatedAt > currentTime) {
            revert InvalidPriceTimestamp(updatedAt, currentTime);
        }
        if (currentTime - updatedAt > MAX_PRICE_AGE) revert StalePrice(updatedAt, currentTime);

        // 양수 검사를 통과한 int256 값은 uint256 범위 안에 있다.
        // forge-lint: disable-next-line(unsafe-typecast)
        return Math.mulDiv(collateralWBTC8, uint256(price8), VALUE_SCALE, Math.Rounding.Floor);
    }

    /// @notice 내림한 담보 가치의 70%를 다시 내려 USDC 대출 한도로 계산한다.
    /// @param collateralWBTC8 소수점 8자리 WBTC 최소 단위 수량
    /// @param price8 1 WBTC당 USDC 직접호가의 소수점 8자리 정수
    /// @param updatedAt 가격 갱신시각의 초 단위 타임스탬프
    /// @param currentTime 호출자가 전달하는 현재 시각
    /// @return 소수점 6자리 USDC 최소 단위로 내린 원금 대출 한도
    function maxDebtDown(uint256 collateralWBTC8, int256 price8, uint256 updatedAt, uint256 currentTime)
        internal
        pure
        returns (uint256)
    {
        uint256 value = collateralValueDown(collateralWBTC8, price8, updatedAt, currentTime);
        return Math.mulDiv(value, LTV_BPS, BPS_SCALE, Math.Rounding.Floor);
    }
}

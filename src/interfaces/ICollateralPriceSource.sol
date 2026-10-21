// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title WBTC 담보 평가용 가격 원천
/// @notice 1 WBTC당 USDC 직접호가와 갱신시각을 원시값으로 제공한다.
interface ICollateralPriceSource {
    /// @notice 가격 원시값의 소수점 자릿수를 반환한다.
    function decimals() external view returns (uint8);

    /// @notice 유효성 판단 없이 부호 있는 가격과 갱신시각을 반환한다.
    /// @return price 소수점 8자리의 USDC/WBTC 직접호가로, 0·음수 검증은 소비자가 수행한다.
    /// @return updatedAt 초 단위 가격 갱신시각으로, 현재시각과 다를 수 있다.
    function latestPrice() external view returns (int256 price, uint256 updatedAt);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ICollateralPriceSource} from "../../src/interfaces/ICollateralPriceSource.sol";

/// @title 가격과 갱신시각을 독립적으로 설정하는 시험 원천
/// @notice 잘못된 가격·시각도 그대로 제공해 소비자의 검증을 시험한다.
contract MockCollateralPriceSource is ICollateralPriceSource {
    int256 private _price;
    uint256 private _updatedAt;

    /// @notice 가격과 시각을 자동 보정하지 않고 초기 원시값으로 저장한다.
    /// @param price 소수점 8자리의 부호 있는 USDC/WBTC 직접호가
    /// @param updatedAt 초 단위 가격 갱신시각
    constructor(int256 price, uint256 updatedAt) {
        _price = price;
        _updatedAt = updatedAt;
    }

    /// @notice 갱신시각을 유지한 채 원시 가격만 바꾼다.
    function setPrice(int256 price) external {
        _price = price;
    }

    /// @notice 가격을 유지한 채 원시 갱신시각만 바꾼다.
    function setUpdatedAt(uint256 updatedAt) external {
        _updatedAt = updatedAt;
    }

    /// @inheritdoc ICollateralPriceSource
    function latestPrice() external view override returns (int256 price, uint256 updatedAt) {
        return (_price, _updatedAt);
    }
}

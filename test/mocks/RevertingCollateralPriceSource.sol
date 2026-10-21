// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ICollateralPriceSource} from "../../src/interfaces/ICollateralPriceSource.sol";

/// @title 가격 원천 장애를 재현하는 시험 대역
/// @notice 별도 설정 없이 모든 가격 조회에서 같은 오류를 발생시킨다.
contract RevertingCollateralPriceSource is ICollateralPriceSource {
    /// @inheritdoc ICollateralPriceSource
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /// @notice 소비자가 원천 장애를 삼키지 않고 전파하는지 구별하는 오류다.
    error PriceSourceUnavailable();

    /// @notice 정상값 대신 고정된 원천 장애를 발생시킨다.
    function latestPrice() external pure override returns (int256, uint256) {
        revert PriceSourceUnavailable();
    }
}

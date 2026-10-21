// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICollateralPriceSource} from "../../src/interfaces/ICollateralPriceSource.sol";

/// @title 잘못된 정밀도 연결을 시험하는 18자리 토큰
/// @notice 정상 ERC20 잔고·승인을 준비하되 단위만 USDC6·WBTC8과 다르게 유지한다.
contract EighteenDecimalToken is ERC20 {
    /// @notice OpenZeppelin 기본 정밀도 18을 그대로 사용한다.
    constructor() ERC20("Wrong precision", "WRONG") {}

    /// @notice 배포 거절 전후 비교할 기존 시험 잔고를 만든다.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title 값은 읽을 수 있지만 정밀도가 잘못된 가격 원천
contract EighteenDecimalPriceSource is ICollateralPriceSource {
    int256 private immutable _price;
    uint256 private immutable _updatedAt;

    /// @notice 배포 실패 전후 비교할 원시 가격과 갱신시각을 저장한다.
    constructor(int256 price, uint256 updatedAt) {
        _price = price;
        _updatedAt = updatedAt;
    }

    /// @notice 고정 계산이 요구하는 8과 다른 18을 보고한다.
    function decimals() external pure override returns (uint8) {
        return 18;
    }

    /// @inheritdoc ICollateralPriceSource
    function latestPrice() external view override returns (int256 price, uint256 updatedAt) {
        return (_price, _updatedAt);
    }
}

/// @title decimals 함수 없이 호출 자체만 성공시키는 대역
/// @notice 빈 응답을 정상 정밀도로 오인하는 구현을 구별한다.
contract MissingDecimalsMetadata {
    /// @notice 존재하지 않는 선택자에 성공·빈 응답을 반환한다.
    fallback() external {}
}

/// @title 정밀도 조회 자체가 실패하는 대역
contract RevertingDecimalsMetadata {
    /// @notice 원본 호출 실패가 배포 metadata 오류로 구분되는지 확인한다.
    error MetadataUnavailable();

    /// @notice 숫자 대신 고정된 호출 오류를 발생시킨다.
    function decimals() external pure returns (uint8) {
        revert MetadataUnavailable();
    }
}

/// @title 한 ABI word보다 짧은 응답을 반환하는 대역
contract ShortDecimalsMetadata {
    /// @notice 값이 8이어도 31바이트 응답은 uint8의 정상 ABI가 아니다.
    fallback() external {
        assembly {
            mstore(0, 8)
            return(1, 31)
        }
    }
}

/// @title uint8 범위를 벗어난 원시 정밀도를 반환하는 대역
contract OutOfRangeDecimalsMetadata {
    /// @notice 선택자는 같지만 raw256은 uint8로 디코딩하거나 잘라 사용할 수 없다.
    function decimals() external pure returns (uint256) {
        return 256;
    }
}

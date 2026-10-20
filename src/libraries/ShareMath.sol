// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title 인정자산과 내부 지분의 환산
/// @notice 토큰 이동 없이 정수 최소 단위의 환산 결과를 계산한다.
/// @dev 빈 장부의 1:1은 계산 규칙이며 실제 보유 권리나 지급 가능 금액이 아니다.
///      중간 곱은 전체 정밀도로 계산하고 최종 결과 초과는 Panic(0x11)을 전파한다.
library ShareMath {
    /// @notice 인정자산과 총지분 중 한쪽만 0인 장부는 환산할 수 없다.
    error InvalidAccountingState(uint256 assets, uint256 shares);

    /// @notice 공급 금액에 해당하는 지분을 최소 단위에서 내린다.
    /// @param assets 환산할 USDC 최소 단위 수량
    /// @param accountedAssets 풀에서 인정한 USDC 자산의 최소 단위 수량
    /// @param totalShares 풀의 총지분 최소 단위 수량
    /// @return shares 내림한 지분 최소 단위 수량
    function toSharesDown(uint256 assets, uint256 accountedAssets, uint256 totalShares)
        internal
        pure
        returns (uint256 shares)
    {
        if (_isEmptyAccounting(accountedAssets, totalShares)) return assets;
        return Math.mulDiv(assets, totalShares, accountedAssets, Math.Rounding.Floor);
    }

    /// @notice 요청한 USDC를 출금할 때 차감할 지분을 최소 단위에서 올린다.
    /// @param assets 환산할 USDC 최소 단위 수량
    /// @param accountedAssets 풀에서 인정한 USDC 자산의 최소 단위 수량
    /// @param totalShares 풀의 총지분 최소 단위 수량
    /// @return shares 올림한 지분 최소 단위 수량
    function toSharesUp(uint256 assets, uint256 accountedAssets, uint256 totalShares)
        internal
        pure
        returns (uint256 shares)
    {
        if (_isEmptyAccounting(accountedAssets, totalShares)) return assets;
        return Math.mulDiv(assets, totalShares, accountedAssets, Math.Rounding.Ceil);
    }

    /// @notice 지분의 USDC 환산 금액을 최소 단위에서 내린다.
    /// @param shares 환산할 지분 최소 단위 수량
    /// @param accountedAssets 풀에서 인정한 USDC 자산의 최소 단위 수량
    /// @param totalShares 풀의 총지분 최소 단위 수량
    /// @return assets 내림한 USDC 최소 단위 수량
    function toAssetsDown(uint256 shares, uint256 accountedAssets, uint256 totalShares)
        internal
        pure
        returns (uint256 assets)
    {
        if (_isEmptyAccounting(accountedAssets, totalShares)) return shares;
        return Math.mulDiv(shares, accountedAssets, totalShares, Math.Rounding.Floor);
    }

    /// @notice 입력 수량과 무관하게 장부를 검증하고 초기 비율 적용 여부를 반환한다.
    function _isEmptyAccounting(uint256 accountedAssets, uint256 totalShares) private pure returns (bool) {
        if ((accountedAssets == 0) != (totalShares == 0)) {
            revert InvalidAccountingState(accountedAssets, totalShares);
        }
        return accountedAssets == 0;
    }
}

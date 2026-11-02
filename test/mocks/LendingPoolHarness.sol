// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {DebtLedger} from "../../src/accounting/DebtLedger.sol";
import {ICollateralPriceSource} from "../../src/interfaces/ICollateralPriceSource.sol";
import {InterestMath} from "../../src/libraries/InterestMath.sol";

/// @title 비율·잘못된 장부 준비 전용 풀
/// @notice 실제 공급으로 지분을 만들고 시험에서만 정확 자산·부채를 주입하거나 저장값을 관측한다.
/// @dev 일반 풀에는 이 setter가 없으며 개인·전체 장부의 일관성과 토큰 현금은 시험에서 준비한다.
contract LendingPoolHarness is LendingPool {
    /// @notice 자산·담보·가격 원천을 일반 풀과 같은 생성자 검사에 그대로 전달한다.
    constructor(IERC20 asset_, IERC20 collateralAsset_, ICollateralPriceSource priceSource_)
        LendingPool(asset_, collateralAsset_, priceSource_)
    {}

    /// @notice 기존 raw 자산 준비값을 정확 분자로 바꾸며 표현 범위를 넘으면 거절한다.
    function setAccountedAssetsForTest(uint256 assets) external {
        _accountedAssetsNumerator = InterestMath.toNumerator(assets);
    }

    /// @notice 조회 시각의 이자를 계산하지 않고 개인의 실제 저장 원금·미납·시각을 반환한다.
    function storedDebt(address user) external view returns (DebtLedger.Position memory) {
        return _debtLedger.borrowers[user];
    }

    /// @notice 조회가 저장을 바꾸거나 전역 이자를 중복 기록했는지 비교할 전체 저장값이다.
    function storedTotalDebt() external view returns (DebtLedger.Position memory) {
        return _debtLedger.total;
    }

    /// @notice 미저장 이자를 더하지 않은 정확 자산 분자를 반환한다.
    function storedAssetsNumerator() external view returns (uint256) {
        return _accountedAssetsNumerator;
    }

    /// @notice 최소 USDC 단위보다 작은 자산과 표현 한계 상태를 시험에서만 준비한다.
    function setAccountedAssetsNumeratorForTest(uint256 assetsNumerator) external {
        _accountedAssetsNumerator = assetsNumerator;
    }

    /// @notice 개인 기록만 주입하며 전체 합과 자산의 일관성은 호출하는 시험이 맞춘다.
    function setDebtPositionForTest(address user, uint256 principal, uint256 interestNumerator, uint256 updatedAt)
        external
    {
        _debtLedger.borrowers[user] = DebtLedger.Position(principal, interestNumerator, updatedAt);
    }

    /// @notice 전체 기록만 주입하며 개인 기록은 별도 setter로 준비한다.
    function setTotalDebtForTest(uint256 principal, uint256 interestNumerator, uint256 updatedAt) external {
        _debtLedger.total = DebtLedger.Position(principal, interestNumerator, updatedAt);
    }
}

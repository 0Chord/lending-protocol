// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingPool} from "../../src/LendingPool.sol";

/// @title 비율·잘못된 장부 준비 전용 풀
/// @notice 실제 공급으로 지분을 만든 뒤 시험에서만 인정자산을 바꾼다.
/// @dev 일반 풀에는 이 setter가 없으며 토큰 현금도 별도로 준비해야 한다.
contract LendingPoolHarness is LendingPool {
    /// @notice 기존 풀과 같은 고정 자산 검사를 사용한다.
    constructor(IERC20 asset_) LendingPool(asset_) {}

    /// @notice 수익·손실 기능을 구현하지 않고 환산 테스트의 가정만 준비한다.
    function setAccountedAssetsForTest(uint256 assets) external {
        _accountedAssets = assets;
    }
}

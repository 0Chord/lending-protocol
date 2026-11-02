// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BorrowTestBase} from "./BorrowTestBase.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {LendingPoolHarness} from "../mocks/LendingPoolHarness.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title 정상 공급100·담보1 준비와 이자 저장값의 실패 전후 관측
abstract contract InterestTestBase is BorrowTestBase {
    uint256 internal constant HALF_YEAR = 365 days / 2;
    LendingPoolHarness internal interestPool;

    /// @notice 제품 API에 추가 조회를 노출하지 않고 시험용 하네스를 배포한다.
    function _newPool() internal override returns (LendingPool) {
        interestPool = new LendingPoolHarness(usdc, wbtc, price);
        return interestPool;
    }

    /// @notice 공개 값 외에 미세 분자·개인/전체 저장 시각까지 같은 시각에서 비교한다.
    function _interestSnapshot() internal view returns (bytes memory) {
        return abi.encode(
            _snapshot(),
            interestPool.storedAssetsNumerator(),
            interestPool.storedTotalDebt(),
            interestPool.storedDebt(ALICE),
            interestPool.storedDebt(BOB),
            interestPool.storedDebt(CHARLIE),
            interestPool.storedDebt(address(usdc))
        );
    }

    /// @notice 실패한 호출의 토큰·승인·정확 장부·저장 시각과 성공 이벤트 부재를 확인한다.
    function _assertInterestUnchanged(bytes memory beforeState) internal view {
        assertEq(_interestSnapshot(), beforeState);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(pool));
        }
    }
}

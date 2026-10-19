// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {LendingPool} from "../../src/LendingPool.sol";

/// @title 공급 중 중첩 호출 검증용 토큰
/// @notice 양수 공급을 한 번 재호출하고 실패를 잡아 바깥 전송은 계속한다.
contract ReentrantMockUSDC is MockUSDC {
    LendingPool public targetPool;
    bool public attempted;
    bool public nestedSucceeded;
    bytes public nestedError;

    /// @notice 중첩 호출자인 토큰 주소가 자기 토큰 1을 공급할 승인까지 준비한다.
    /// @dev 자체 잔고는 테스트에서 따로 발행하며 장애 설정은 모형에만 둔다.
    function configureReentry(LendingPool pool) external {
        targetPool = pool;
        _approve(address(this), address(pool), 1);
    }

    /// @notice 재귀를 한 번으로 제한하고 중첩 실패 이유를 바깥 성공 후 관측 가능하게 남긴다.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!attempted && address(targetPool) != address(0)) {
            attempted = true;
            try targetPool.supply(1) {
                nestedSucceeded = true;
            } catch (bytes memory reason) {
                nestedError = reason;
            }
        }
        return super.transferFrom(from, to, amount);
    }
}

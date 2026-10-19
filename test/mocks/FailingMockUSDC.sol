// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @title 전송 실패 복구 검증용 토큰
/// @notice 정상 전송으로 잔고·승인을 바꾼 다음 실패를 반환하거나 오류를 발생시킨다.
/// @dev 장애 설정은 테스트 모형에만 있으며 일반 MockUSDC와 풀에는 추가하지 않는다.
contract FailingMockUSDC is MockUSDC {
    enum FailureMode {
        None,
        ReturnFalse,
        Revert
    }

    FailureMode public failureMode;
    FailureMode public transferFailureMode;
    error InjectedTransferFailure();

    /// @notice 성공한 기존 예치를 준비한 뒤 다음 전송의 실패 방식을 선택한다.
    function setFailureMode(FailureMode mode) external {
        failureMode = mode;
    }

    /// @notice 공급 준비와 분리해 출금 transfer 경로의 장애만 선택한다.
    function setTransferFailureMode(FailureMode mode) external {
        transferFailureMode = mode;
    }

    /// @notice 먼저 전송·승인 차감을 실행하므로 호출자의 revert가 실제 변경을 복구해야 한다.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        if (failureMode == FailureMode.ReturnFalse) return false;
        if (failureMode == FailureMode.Revert) revert InjectedTransferFailure();
        return true;
    }

    /// @notice 출금의 실제 전송 후 false 또는 오류를 주어 예치와 토큰 이동의 복구를 검사한다.
    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        if (transferFailureMode == FailureMode.ReturnFalse) return false;
        if (transferFailureMode == FailureMode.Revert) revert InjectedTransferFailure();
        return true;
    }
}

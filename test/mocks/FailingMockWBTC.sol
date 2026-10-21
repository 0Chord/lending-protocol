// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MockWBTC} from "../../src/mocks/MockWBTC.sol";

/// @title 담보의 실제 전송 뒤 실패를 주는 테스트 토큰
/// @notice 8자리 WBTC 이동과 유한 승인 소비 후 false 또는 고정 오류를 발생시킨다.
/// @dev 입금과 반환 장애를 독립 설정하며 일반 MockWBTC에는 장애 기능을 넣지 않는다.
contract FailingMockWBTC is MockWBTC {
    /// @notice 정상 반환·false 반환·명시적 revert 중 다음 전송의 결과를 고른다.
    enum FailureMode {
        None,
        ReturnFalse,
        Revert
    }

    /// @notice transferFrom의 실제 전송 다음 적용할 장애다.
    FailureMode public failureMode;
    /// @notice transfer의 실제 전송 다음 적용할 장애다.
    FailureMode public transferFailureMode;

    /// @notice 담보 토큰이 실제 전송을 마친 뒤 발생시키는 고정 오류다.
    error InjectedCollateralTransferFailure();

    /// @notice 반환 준비와 분리해 담보 입금 transferFrom의 장애만 선택한다.
    function setFailureMode(FailureMode mode) external {
        failureMode = mode;
    }

    /// @notice 정상 담보 입금을 준비한 뒤 반환 transfer의 장애만 선택한다.
    function setTransferFailureMode(FailureMode mode) external {
        transferFailureMode = mode;
    }

    /// @notice 먼저 전송·승인 소비를 실행해 풀의 실패가 그 변경까지 복구하는지 검사한다.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        if (failureMode == FailureMode.ReturnFalse) return false;
        if (failureMode == FailureMode.Revert) revert InjectedCollateralTransferFailure();
        return true;
    }

    /// @notice 먼저 실제 반환을 실행하므로 풀의 실패는 담보 선차감과 토큰 이동을 모두 복구해야 한다.
    function transfer(address to, uint256 amount) public override returns (bool) {
        super.transfer(to, amount);
        if (transferFailureMode == FailureMode.ReturnFalse) return false;
        if (transferFailureMode == FailureMode.Revert) revert InjectedCollateralTransferFailure();
        return true;
    }
}

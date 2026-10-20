// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {LendingPool} from "../../src/LendingPool.sol";

/// @title 공급·출금 간 중첩 호출 검증용 토큰
/// @notice 실제 토큰 전송 뒤 양수 공급 또는 출금을 한 번 재호출한다.
/// @dev 중첩 오류를 기록하고 계속하거나 그대로 전파하는 테스트 전용 모형이다.
contract CrossReentrantMockUSDC is MockUSDC {
    /// @notice 중첩 호출을 시도할 바깥 토큰 전송 경로다.
    enum CallbackOn {
        TransferFrom,
        Transfer
    }

    /// @notice 토큰 주소가 호출할 풀의 양수 동작이다.
    enum NestedAction {
        Supply,
        Withdraw
    }

    /// @notice 중첩 호출과 예치 기록 관측의 대상 풀이다.
    LendingPool public targetPool;
    /// @notice 이번 설정에서 중첩 호출을 시도했는지 나타낸다.
    bool public attempted;
    /// @notice 시도한 중첩 호출의 성공 여부다.
    bool public nestedSucceeded;
    /// @notice 잡아서 계속한 중첩 실패의 원본 오류 데이터다.
    bytes public nestedError;
    /// @notice 중첩 호출 직전에 관측한 지정 사용자의 예치 기록이다.
    uint256 public observedDeposit;
    /// @notice 실제 토큰 전송 후 중첩 호출 직전의 인정자산이다.
    uint256 public observedAssets;
    /// @notice 같은 관측 시점의 내부 총지분이다.
    uint256 public observedTotalShares;
    /// @notice 같은 관측 시점의 지정 사용자 지분이다.
    uint256 public observedShares;
    /// @notice 중첩 호출자인 토큰 주소 자체의 지분이다.
    uint256 public observedOwnShares;

    bool private _armed;
    CallbackOn private _callbackOn;
    NestedAction private _nestedAction;
    bool private _propagateError;
    address private _observedUser;

    /// @notice 콜백을 끄고 토큰 주소 명의로 최소 단위 1을 정상 공급한다.
    /// @dev 자체 잔고는 테스트에서 미리 발행하며 이 호출은 콜백을 다시 켜지 않는다.
    function prepareOwnDeposit(LendingPool pool) external {
        _armed = false;
        _approve(address(this), address(pool), 1);
        pool.supply(1);
    }

    /// @notice 중첩 호출 조건과 관측 대상을 정하고 한 번의 콜백을 준비한다.
    /// @dev 중첩 공급용 승인 1을 만들며 자체 잔고·예치 기록은 별도로 준비한다.
    function arm(LendingPool pool, CallbackOn on, NestedAction action, bool propagateError, address observedUser)
        external
    {
        targetPool = pool;
        _callbackOn = on;
        _nestedAction = action;
        _propagateError = propagateError;
        _observedUser = observedUser;
        attempted = false;
        nestedSucceeded = false;
        delete nestedError;
        observedDeposit = 0;
        observedAssets = 0;
        observedTotalShares = 0;
        observedShares = 0;
        observedOwnShares = 0;
        _approve(address(this), address(pool), 1);
        _armed = true;
    }

    /// @notice 실제 승인 전송을 마친 뒤 선택된 공급 경로의 콜백을 시도한다.
    /// @dev 중첩 오류를 전파하면 앞서 수행한 토큰 전송도 함께 복구된다.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool transferred = super.transferFrom(from, to, amount);
        if (_armed && _callbackOn == CallbackOn.TransferFrom) _attemptCallback();
        return transferred;
    }

    /// @notice 실제 직접 전송을 마친 뒤 선택된 출금 경로의 콜백을 시도한다.
    /// @dev 중첩 오류를 전파하면 앞서 수행한 토큰 전송도 함께 복구된다.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool transferred = super.transfer(to, amount);
        if (_armed && _callbackOn == CallbackOn.Transfer) _attemptCallback();
        return transferred;
    }

    /// @notice 재귀를 먼저 막고 전송 후 자산·지분·환산권리를 관측한 뒤 최소 단위 1을 재호출한다.
    /// @dev 오류 전파 모드는 원본 바이트를 그대로 revert하여 모형 상태까지 복구한다.
    function _attemptCallback() private {
        if (attempted) return;
        attempted = true;
        _armed = false;
        observedDeposit = targetPool.deposits(_observedUser);
        observedAssets = targetPool.totalAssets();
        observedTotalShares = targetPool.totalShares();
        observedShares = targetPool.shares(_observedUser);
        observedOwnShares = targetPool.shares(address(this));

        bytes memory callData = _nestedAction == NestedAction.Supply
            ? abi.encodeCall(LendingPool.supply, (1))
            : abi.encodeCall(LendingPool.withdraw, (1));
        (bool succeeded, bytes memory reason) = address(targetPool).call(callData);
        nestedSucceeded = succeeded;
        if (!succeeded) {
            nestedError = reason;
            if (_propagateError) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }
}

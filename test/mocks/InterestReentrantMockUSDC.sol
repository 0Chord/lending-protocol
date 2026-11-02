// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LendingPool} from "../../src/LendingPool.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @title 이자 포함 장부를 수령 직후 관측하는 재진입 시험 토큰
/// @notice 실제 전송을 완료한 뒤 준비된 양수 요청을 한 번 호출하고 오류를 잡거나 전파한다.
contract InterestReentrantMockUSDC is MockUSDC {
    /// @notice 공급·상환의 승인 전송과 대출·출금의 직접 전송을 구분한다.
    enum CallbackOn {
        TransferFrom,
        Transfer
    }

    LendingPool private _pool;
    bool private _armed;
    CallbackOn private _callbackOn;
    bytes private _callData;
    bool private _propagate;
    address private _observedUser;

    /// @notice 콜백이 실제 중첩 호출까지 도달했는지 나타낸다.
    bool public attempted;
    /// @notice 중첩 호출의 성공 여부이며 공유 잠금이 있으면 false다.
    bool public nestedSucceeded;
    /// @notice 중첩 호출이 반환한 정확한 오류다.
    bytes public nestedError;
    uint256[5] private _observed;

    /// @notice 테스트에서 자원을 준비한 요청과 전송 경로·오류 전파 방식을 설정한다.
    function arm(LendingPool pool, CallbackOn on, bytes calldata callData, bool propagate, address observedUser)
        external
    {
        _pool = pool;
        _callbackOn = on;
        _callData = callData;
        _propagate = propagate;
        _observedUser = observedUser;
        _armed = true;
        attempted = false;
        nestedSucceeded = false;
        delete nestedError;
        delete _observed;
    }

    /// @notice 복구 뒤 같은 요청을 재시도할 때 콜백만 끈다.
    function disableCallback() external {
        _armed = false;
    }

    /// @notice 콜백 시점의 개인 부채·총부채·자산·실제 현금·가용 현금을 순서대로 반환한다.
    function observed() external view returns (uint256[5] memory) {
        return _observed;
    }

    /// @notice 전파된 실패가 설정·시도 여부·오류·관측 저장값도 복구하는지 비교한다.
    function callbackState() external view returns (bytes memory) {
        bytes memory configuration = abi.encode(_pool, _armed, _callbackOn, _callData, _propagate, _observedUser);
        return abi.encode(configuration, attempted, nestedSucceeded, nestedError, _observed);
    }

    /// @notice 유한 승인 소비와 잔고 이동 뒤에만 공급·상환 콜백을 실행한다.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        _afterTransfer(CallbackOn.TransferFrom);
        return success;
    }

    /// @notice 실제 잔고 이동 뒤에만 대출·출금 콜백을 실행한다.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        _afterTransfer(CallbackOn.Transfer);
        return success;
    }

    /// @notice 이자 포함 조회를 관측하고 중첩 오류를 바꾸지 않은 채 보존하거나 전파한다.
    function _afterTransfer(CallbackOn on) private {
        if (!_armed || attempted || on != _callbackOn || msg.sender != address(_pool)) return;
        _armed = false;
        attempted = true;
        _observed = [
            _pool.debtOf(_observedUser),
            _pool.totalDebt(),
            _pool.totalAssets(),
            balanceOf(address(_pool)),
            _pool.availableLiquidity()
        ];
        (bool success, bytes memory reason) = address(_pool).call(_callData);
        nestedSucceeded = success;
        if (!success) {
            nestedError = reason;
            if (_propagate) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }
}

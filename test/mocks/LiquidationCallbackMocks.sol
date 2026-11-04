// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockWBTC} from "../../src/mocks/MockWBTC.sol";
import {LendingPoolHarness} from "./LendingPoolHarness.sol";

/// @title 청산의 두 실제 전송 경계에서 장부와 중첩 오류를 관측하는 시험 지원
/// @notice 기존 arm/observed 방식으로 한 번 호출하며 오류를 잡거나 원문 그대로 전파한다.
abstract contract LiquidationCallback {
    LendingPoolHarness private _pool;
    bool private _armed;
    bytes private _callData;
    bool private _propagate;
    address private _observedBorrower;

    /// @notice 실제 토큰 이동 뒤 중첩 호출까지 도달했는지 나타낸다.
    bool public attempted;
    /// @notice 공유 잠금이 있으면 중첩 호출은 실패해야 한다.
    bool public nestedSucceeded;
    /// @notice 중첩 호출에서 받은 정확한 원본 오류다.
    bytes public nestedError;
    uint256[7] private _observed;
    bytes private _observedAccounting;
    bytes private _observedTokenResources;

    /// @notice 자원을 준비한 양수 요청과 관측 차입자·오류 전파 방식을 설정한다.
    function arm(LendingPoolHarness pool, bytes calldata callData, bool propagate, address observedBorrower) external {
        _pool = pool;
        _callData = callData;
        _propagate = propagate;
        _observedBorrower = observedBorrower;
        _armed = true;
        attempted = false;
        nestedSucceeded = false;
        delete nestedError;
        delete _observed;
        delete _observedAccounting;
        delete _observedTokenResources;
    }

    /// @notice 실패 복구 뒤 같은 청산을 재시도하기 위해 콜백만 해제한다.
    function disableCallback() external {
        _armed = false;
    }

    /// @notice 차입자 부채·기록 담보·총부채·자산·USDC/WBTC 풀 잔고·가용 현금이다.
    function observed() external view returns (uint256[7] memory) {
        return _observed;
    }

    /// @notice 조회 계산과 구분한 저장 자산 분자·전체와 개인의 원금/이자 분자/시각이다.
    function observedAccounting() external view returns (bytes memory) {
        return _observedAccounting;
    }

    /// @notice 두 토큰 주소 각각의 양 자산·승인·지분·권리·담보·부채와 정확 저장 부채다.
    function observedTokenResources() external view returns (bytes memory) {
        return _observedTokenResources;
    }

    /// @notice 전파 실패 때 설정·시도·오류·관측 저장값까지 복구되는지 비교한다.
    function callbackState() external view returns (bytes memory) {
        bytes memory configuration = abi.encode(_pool, _armed, _callData, _propagate, _observedBorrower);
        return abi.encode(
            configuration,
            attempted,
            nestedSucceeded,
            nestedError,
            _observed,
            _observedAccounting,
            _observedTokenResources
        );
    }

    /// @notice 실제 이동을 마친 풀 호출만 한 번 관측하고 준비한 중첩 요청을 실행한다.
    function _afterTransfer() internal {
        if (!_armed || attempted || msg.sender != address(_pool)) return;
        _armed = false;
        attempted = true;
        _observed = [
            _pool.debtOf(_observedBorrower),
            _pool.collateralOf(_observedBorrower),
            _pool.totalDebt(),
            _pool.totalAssets(),
            _pool.asset().balanceOf(address(_pool)),
            _pool.collateralAsset().balanceOf(address(_pool)),
            _pool.availableLiquidity()
        ];
        _observedAccounting =
            abi.encode(_pool.storedAssetsNumerator(), _pool.storedTotalDebt(), _pool.storedDebt(_observedBorrower));
        _observedTokenResources = abi.encode(
            _participant(address(_pool.asset())),
            _pool.storedDebt(address(_pool.asset())),
            _participant(address(_pool.collateralAsset())),
            _pool.storedDebt(address(_pool.collateralAsset()))
        );
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

    /// @notice 자산 표시값과 토큰 주소 자신의 권리·현재 부채를 같은 시각에 읽는다.
    function _participant(address user) private view returns (uint256[8] memory) {
        IERC20 usdc = _pool.asset();
        IERC20 wbtc = _pool.collateralAsset();
        return [
            usdc.balanceOf(user),
            wbtc.balanceOf(user),
            usdc.allowance(user, address(_pool)),
            wbtc.allowance(user, address(_pool)),
            _pool.shares(user),
            _pool.deposits(user),
            _pool.collateralOf(user),
            _pool.debtOf(user)
        ];
    }
}

/// @title USDC 수령 직후·차입자 부채 정산 전 콜백 토큰
/// @notice 유한 승인 소비와 잔고 이동을 먼저 완료해 실제 수령 경계를 검증한다.
contract LiquidationCallbackUSDC is MockUSDC, LiquidationCallback {
    /// @notice 실제 승인 전송을 마친 뒤 한 번 관측한다.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        _afterTransfer();
        return success;
    }
}

/// @title WBTC 지급 직후·부채 정산과 기록 담보 차감 후 콜백 토큰
/// @notice 실제 담보 잔고를 먼저 이동하므로 전파 실패가 두 토큰을 함께 복구해야 한다.
contract LiquidationCallbackWBTC is MockWBTC, LiquidationCallback {
    /// @notice 실제 직접 전송을 마친 뒤 한 번 관측한다.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        _afterTransfer();
        return success;
    }
}

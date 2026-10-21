// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockWBTC} from "../../src/mocks/MockWBTC.sol";

/// @title 담보와 공급 경계의 실제 중첩 호출 지원
/// @notice 토큰 주소 자신의 권리를 준비하고 실제 전송 뒤 양수 raw1 호출을 한 번 시도한다.
/// @dev 생산 풀에 분기를 넣지 않는 테스트 전용 지원이며 실패를 잡거나 그대로 전파한다.
abstract contract CollateralCallback {
    /// @notice 실제 승인 전송과 직접 전송 중 콜백을 발생시킬 경로다.
    enum CallbackOn {
        TransferFrom,
        Transfer
    }

    /// @notice 같은 잠금을 공유해야 하는 네 양수 진입점이다.
    enum NestedAction {
        Supply,
        Withdraw,
        DepositCollateral,
        WithdrawCollateral
    }

    /// @notice 중첩 호출과 장부 관측의 대상 풀이다.
    LendingPool public targetPool;
    /// @notice 실제 바깥 전송 뒤 중첩 호출을 시도했는지 나타낸다.
    bool public attempted;
    /// @notice 중첩 호출의 성공 여부다.
    bool public nestedSucceeded;
    /// @notice 잡아서 계속한 실패의 정확한 원본 오류다.
    bytes public nestedError;
    /// @notice 중첩 호출 직전의 인정 USDC 자산이다.
    uint256 public observedAssets;
    /// @notice 같은 시점의 내부 총지분이다.
    uint256 public observedTotalShares;
    /// @notice 관측 대상으로 지정한 외부 사용자의 지분이다.
    uint256 public observedShares;
    /// @notice 관측 대상으로 지정한 외부 사용자의 환산 USDC 권리다.
    uint256 public observedDeposit;
    /// @notice 입금 기록 증가 전 또는 반환 선차감 후의 외부 사용자 담보량이다.
    uint256 public observedCollateral;
    /// @notice 실제 바깥 전송 뒤 풀에 남은 USDC 현금이다.
    uint256 public observedPoolCash;
    /// @notice 실제 바깥 전송 뒤 풀에 남은 WBTC 수량이다.
    uint256 public observedPoolCollateral;

    uint256[7] private _observedOwnState;
    bool private _armed;
    CallbackOn private _callbackOn;
    NestedAction private _nestedAction;
    bool private _propagateError;
    address private _observedUser;

    /// @notice 콜백을 끄고 토큰 자신의 공급·담보 권리를 각각 raw1 정상 생성한다.
    /// @dev 양 자산 raw3을 미리 지급하면 잔고2·권리1·유한 잔여 승인1이 생긴다.
    function prepareOwnPositions(LendingPool pool) external {
        _armed = false;
        IERC20 usdc = pool.asset();
        IERC20 wbtc = pool.collateralAsset();
        usdc.approve(address(pool), 2);
        pool.supply(1);
        wbtc.approve(address(pool), 2);
        pool.depositCollateral(1);
    }

    /// @notice 한 번의 실제 전송 후 호출할 동작과 관측 사용자·오류 전파 여부를 정한다.
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
        observedAssets = 0;
        observedTotalShares = 0;
        observedShares = 0;
        observedDeposit = 0;
        observedCollateral = 0;
        observedPoolCash = 0;
        observedPoolCollateral = 0;
        delete _observedOwnState;
        _armed = true;
    }

    /// @notice 실패 뒤 같은 바깥 요청을 정상 재시도하기 위해 콜백만 해제한다.
    function disableCallback() external {
        _armed = false;
    }

    /// @notice 콜백 직전 토큰 주소의 USDC/WBTC 잔고·승인·지분·환산권리·담보7값이다.
    function observedOwnState() external view returns (uint256[7] memory) {
        return _observedOwnState;
    }

    /// @notice 전파 실패가 관측값과 콜백 설정까지 복구했는지 비교할 전체 저장 상태다.
    function callbackState() external view returns (bytes memory) {
        bytes memory configuration =
            abi.encode(targetPool, _armed, _callbackOn, _nestedAction, _propagateError, _observedUser);
        uint256[7] memory observations = [
            observedAssets,
            observedTotalShares,
            observedShares,
            observedDeposit,
            observedCollateral,
            observedPoolCash,
            observedPoolCollateral
        ];
        return abi.encode(configuration, attempted, nestedSucceeded, nestedError, observations, _observedOwnState);
    }

    /// @notice 풀의 실제 토큰 전송 직후 한 번 관측하고 raw1 중첩 오류를 원문 그대로 처리한다.
    function _afterTransfer(CallbackOn on) internal {
        if (!_armed || attempted || _callbackOn != on || msg.sender != address(targetPool)) return;
        attempted = true;
        _armed = false;
        IERC20 usdc = targetPool.asset();
        IERC20 wbtc = targetPool.collateralAsset();
        observedAssets = targetPool.totalAssets();
        observedTotalShares = targetPool.totalShares();
        observedShares = targetPool.shares(_observedUser);
        observedDeposit = targetPool.deposits(_observedUser);
        observedCollateral = targetPool.collateralOf(_observedUser);
        observedPoolCash = usdc.balanceOf(address(targetPool));
        observedPoolCollateral = wbtc.balanceOf(address(targetPool));
        _observedOwnState = [
            usdc.balanceOf(address(this)),
            wbtc.balanceOf(address(this)),
            usdc.allowance(address(this), address(targetPool)),
            wbtc.allowance(address(this), address(targetPool)),
            targetPool.shares(address(this)),
            targetPool.deposits(address(this)),
            targetPool.collateralOf(address(this))
        ];

        bytes memory callData;
        if (_nestedAction == NestedAction.Supply) {
            callData = abi.encodeCall(LendingPool.supply, (1));
        } else if (_nestedAction == NestedAction.Withdraw) {
            callData = abi.encodeCall(LendingPool.withdraw, (1));
        } else if (_nestedAction == NestedAction.DepositCollateral) {
            callData = abi.encodeCall(LendingPool.depositCollateral, (1));
        } else {
            callData = abi.encodeCall(LendingPool.withdrawCollateral, (1));
        }
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

/// @title 실제 WBTC 전송 뒤 공통 잠금을 재호출하는 담보 토큰
/// @notice 8자리 표준 전송을 먼저 수행하므로 실패 전 토큰 이동·승인 소비가 실제로 일어난다.
contract CollateralReentrantMockWBTC is MockWBTC, CollateralCallback {
    /// @notice 승인 전송 뒤 담보 입금 콜백을 시도한다.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool transferred = super.transferFrom(from, to, amount);
        _afterTransfer(CallbackOn.TransferFrom);
        return transferred;
    }

    /// @notice 직접 전송 뒤 담보 반환 콜백을 시도한다.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool transferred = super.transfer(to, amount);
        _afterTransfer(CallbackOn.Transfer);
        return transferred;
    }
}

/// @title 실제 USDC 전송 뒤 새 담보 경계를 재호출하는 공급 토큰
/// @notice 기존 USDC 재진입 대역과 분리해 6자리 전송과 담보 간 교차 잠금을 검사한다.
contract CollateralReentrantMockUSDC is MockUSDC, CollateralCallback {
    /// @notice 승인 전송 뒤 USDC 공급 콜백을 시도한다.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool transferred = super.transferFrom(from, to, amount);
        _afterTransfer(CallbackOn.TransferFrom);
        return transferred;
    }

    /// @notice 직접 전송 뒤 USDC 출금 콜백을 시도한다.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool transferred = super.transfer(to, amount);
        _afterTransfer(CallbackOn.Transfer);
        return transferred;
    }
}

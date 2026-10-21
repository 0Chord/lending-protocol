// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @title 실제 USDC 전송 뒤 대출·상환을 재호출하는 시험 토큰
/// @notice 토큰 자신의 정상 담보와 부채를 준비해 일반 자원 부족과 공유 잠금 거절을 구분한다.
contract DebtReentrantMockUSDC is MockUSDC {
    /// @notice 전송을 마친 뒤 콜백을 발생시킬 ERC20 진입점이다.
    enum CallbackOn {
        TransferFrom,
        Transfer
    }

    /// @notice 같은 잠금으로 막혀야 하는 원금 변경 동작이다.
    enum NestedAction {
        Borrow,
        Repay
    }

    /// @notice 관측과 중첩 호출의 대상 풀이다.
    LendingPool public targetPool;
    /// @notice 실제 전송 뒤 중첩 호출까지 도달했는지 나타낸다.
    bool public attempted;
    /// @notice 중첩 호출의 성공 여부다.
    bool public nestedSucceeded;
    /// @notice 잡아서 계속한 중첩 호출의 원본 오류다.
    bytes public nestedError;

    bool private _armed;
    CallbackOn private _callbackOn;
    NestedAction private _nestedAction;
    bool private _propagateError;
    address private _observedUser;
    uint256[8] private _observedGlobalState;
    uint256[8] private _observedUserState;
    uint256[8] private _observedOwnState;

    /// @notice 자기 USDC raw2·WBTC raw3에서 공급1·담보2와 필요 시 대출1을 정상 생성한다.
    /// @dev 가격100에서 담보 raw2의 대출 한도는 raw1이며 양 토큰의 유한 잔여 승인은 각각1이다.
    function prepareOwnPosition(LendingPool pool, bool withDebt) external {
        _armed = false;
        IERC20(address(this)).approve(address(pool), 2);
        pool.supply(1);
        pool.collateralAsset().approve(address(pool), 3);
        pool.depositCollateral(2);
        if (withDebt) pool.borrow(1);
    }

    /// @notice 한 번의 실제 전송 뒤 raw1 중첩 호출과 관측 사용자·오류 전파 방식을 설정한다.
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
        delete _observedGlobalState;
        delete _observedUserState;
        delete _observedOwnState;
        _armed = true;
    }

    /// @notice 실패한 바깥 요청의 정상 재시도를 위해 콜백만 해제한다.
    function disableCallback() external {
        _armed = false;
    }

    /// @notice 콜백의 A/S/D/available·풀 두 잔고·두 총발행량을 반환한다.
    function observedGlobalState() external view returns (uint256[8] memory) {
        return _observedGlobalState;
    }

    /// @notice 외부 사용자의 두 잔고·두 승인·지분·환산 권리·담보·부채를 반환한다.
    function observedUserState() external view returns (uint256[8] memory) {
        return _observedUserState;
    }

    /// @notice 중첩 호출자인 토큰 자신의 두 잔고·두 승인·지분·환산 권리·담보·부채를 반환한다.
    function observedOwnState() external view returns (uint256[8] memory) {
        return _observedOwnState;
    }

    /// @notice 전파 실패가 설정·시도 플래그·오류·관측 저장값까지 복구했는지 비교한다.
    function callbackState() external view returns (bytes memory) {
        bytes memory configuration =
            abi.encode(targetPool, _armed, _callbackOn, _nestedAction, _propagateError, _observedUser);
        return abi.encode(
            configuration,
            attempted,
            nestedSucceeded,
            nestedError,
            _observedGlobalState,
            _observedUserState,
            _observedOwnState
        );
    }

    /// @notice 실제 승인 소비·잔고 이동을 마친 뒤 공급 또는 상환 콜백을 시도한다.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool transferred = super.transferFrom(from, to, amount);
        _afterTransfer(CallbackOn.TransferFrom);
        return transferred;
    }

    /// @notice 실제 잔고 이동을 마친 뒤 출금 또는 대출 콜백을 시도한다.
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool transferred = super.transfer(to, amount);
        _afterTransfer(CallbackOn.Transfer);
        return transferred;
    }

    /// @notice 실제 전송 뒤 원금·공급 권리·담보를 관측하고 양수 호출의 오류를 그대로 처리한다.
    function _afterTransfer(CallbackOn on) private {
        if (!_armed || attempted || _callbackOn != on || msg.sender != address(targetPool)) return;
        attempted = true;
        _armed = false;
        IERC20 collateral = targetPool.collateralAsset();
        _observedGlobalState = [
            targetPool.totalAssets(),
            targetPool.totalShares(),
            targetPool.totalDebt(),
            targetPool.availableLiquidity(),
            balanceOf(address(targetPool)),
            collateral.balanceOf(address(targetPool)),
            totalSupply(),
            collateral.totalSupply()
        ];
        _observedUserState = _participant(_observedUser);
        _observedOwnState = _participant(address(this));
        bytes memory callData = _nestedAction == NestedAction.Borrow
            ? abi.encodeCall(LendingPool.borrow, (1))
            : abi.encodeCall(LendingPool.repay, (1));
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

    /// @notice 콜백 시점의 참여자 두 자산·승인·권리·담보·부채를 한 배열로 고정한다.
    function _participant(address user) private view returns (uint256[8] memory) {
        IERC20 collateral = targetPool.collateralAsset();
        return [
            balanceOf(user),
            collateral.balanceOf(user),
            allowance(user, address(targetPool)),
            collateral.allowance(user, address(targetPool)),
            targetPool.shares(user),
            targetPool.deposits(user),
            targetPool.collateralOf(user),
            targetPool.debtOf(user)
        ];
    }
}

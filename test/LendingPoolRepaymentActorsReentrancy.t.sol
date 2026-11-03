// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Vm} from "forge-std/Vm.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {InterestMath} from "../src/libraries/InterestMath.sol";
import {InterestTestBase} from "./helpers/InterestTestBase.sol";
import {InterestReentrantMockUSDC} from "./mocks/InterestReentrantMockUSDC.sol";

/// @title 제3자 지불 중 차입자 조회와 기존 일곱 진입점의 공유 잠금 검사
/// @notice 시험 전용 상환을 바깥 호출로 사용하며 제품의 공개 기능을 추가하지 않는다.
contract LendingPoolRepaymentActorsReentrancyTest is InterestTestBase {
    InterestReentrantMockUSDC private callbackUSDC;

    /// @notice 토큰 주소가 실제 자원을 갖고 정상 실행할 수 있는 기존 자금 이동 요청이다.
    enum NestedAction {
        Supply,
        Withdraw,
        DepositCollateral,
        WithdrawCollateral,
        Borrow,
        Repay,
        RepayAll
    }

    /// @notice 공급100·Bob 차입40을 같은 시각에 준비하고 중첩 요청의 자원 준비 뒤 시간을 보낸다.
    function setUp() public override {
        callbackUSDC = new InterestReentrantMockUSDC();
        _prepareBorrowPool(callbackUSDC);
        vm.prank(BOB);
        pool.borrow(40e6);
    }

    /// @notice Charlie의12 수령 중에는 Bob42·총42·자산102·현금72·가용60을 보이고 완료 뒤에만 정산한다.
    function test_RepayForCallbackObservesBorrowerBeforeReduction() public {
        _depositFor(address(callbackUSDC), 1e8);
        _advanceAndPreparePayer();
        bytes memory callData = abi.encodeCall(LendingPool.borrow, (1));
        _assertNormalCallSucceeds(callData);
        bytes memory ownBefore = _ownSnapshot();
        callbackUSDC.arm(pool, InterestReentrantMockUSDC.CallbackOn.TransferFrom, callData, false, BOB);

        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 12e6);

        _assertBlocked();
        _assertObserved([uint256(42e6), 42e6, 102e6, 72e6, 60e6]);
        assertEq(_ownSnapshot(), ownBefore);
        _assertCompletedPayment(102e6, 72e6, 30e6);
        assertEq(interestPool.storedTotalDebt().principal, 30e6);
        assertEq(interestPool.storedTotalDebt().interestNumerator, 0);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 102e6);
    }

    /// @notice 일곱 양수 중첩의 잠금 오류를 잡으면 토큰 주소의 자원은 유지하고 Charlie의12만 한 번 정산한다.
    function test_RepayForCatchesEachOfSevenFundMovingEntryPoints() public {
        uint256 initial = vm.snapshotState();
        for (uint256 i; i < 7; ++i) {
            NestedAction action = NestedAction(i);
            bytes memory callData = _prepareNestedAction(action);
            _assertNormalCallSucceeds(callData);
            bytes memory ownBefore = _ownSnapshot();
            callbackUSDC.arm(pool, InterestReentrantMockUSDC.CallbackOn.TransferFrom, callData, false, BOB);

            vm.recordLogs();
            vm.prank(CHARLIE);
            interestPool.repayForTest(BOB, 12e6);

            _assertBlocked();
            bool withDebt = _needsOwnDebt(action);
            _assertObserved(
                [
                    uint256(42e6),
                    withDebt ? 43_050_000 : 42e6,
                    withDebt ? 104_050_000 : 104e6,
                    withDebt ? 73e6 : 74e6,
                    withDebt ? 61e6 : 62e6
                ]
            );
            _assertPreparedPaymentResult(action, ownBefore);
            assertTrue(vm.revertToState(initial));
        }
    }

    /// @notice 일곱 잠금 오류를 전파하면 모든 참여자·정확 장부·시각·콜백 상태를 복구하고 재시도는 한 번 성공한다.
    function test_RepayForPropagatesEachOfSevenEntryPointsAndRestoresAllState() public {
        uint256 initial = vm.snapshotState();
        for (uint256 i; i < 7; ++i) {
            NestedAction action = NestedAction(i);
            bytes memory callData = _prepareNestedAction(action);
            _assertNormalCallSucceeds(callData);
            bytes memory ownBefore = _ownSnapshot();
            callbackUSDC.arm(pool, InterestReentrantMockUSDC.CallbackOn.TransferFrom, callData, true, BOB);
            bytes memory beforeState = _interestSnapshot();
            bytes memory beforeCallback = callbackUSDC.callbackState();

            vm.recordLogs();
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            vm.prank(CHARLIE);
            interestPool.repayForTest(BOB, 12e6);

            _assertInterestUnchanged(beforeState);
            assertEq(callbackUSDC.callbackState(), beforeCallback);
            assertFalse(callbackUSDC.attempted());
            callbackUSDC.disableCallback();
            vm.recordLogs();
            vm.prank(CHARLIE);
            interestPool.repayForTest(BOB, 12e6);
            _assertPreparedPaymentResult(action, ownBefore);
            assertTrue(vm.revertToState(initial));
        }
    }

    /// @notice 토큰 주소에 유한 승인·공급2·담보1과 필요한 상환 부채1을 정상 API로 준비한다.
    /// @dev 부채가 있으면 담보 반환이 거절되므로 부채는 상환 두 요청에만 만든다.
    function _prepareNestedAction(NestedAction action) private returns (bytes memory) {
        address own = address(callbackUSDC);
        usdc.mint(own, 4e6);
        wbtc.mint(own, 1e8 + 1);
        vm.startPrank(own);
        usdc.approve(address(pool), 4e6);
        pool.supply(2e6);
        wbtc.approve(address(pool), 1e8 + 1);
        pool.depositCollateral(1e8);
        if (_needsOwnDebt(action)) pool.borrow(1e6);
        vm.stopPrank();
        _advanceAndPreparePayer();

        if (action == NestedAction.Supply) return abi.encodeCall(LendingPool.supply, (1e6));
        if (action == NestedAction.Withdraw) return abi.encodeCall(LendingPool.withdraw, (1e6));
        if (action == NestedAction.DepositCollateral) return abi.encodeCall(LendingPool.depositCollateral, (1));
        if (action == NestedAction.WithdrawCollateral) return abi.encodeCall(LendingPool.withdrawCollateral, (1));
        if (action == NestedAction.Borrow) return abi.encodeCall(LendingPool.borrow, (1e6));
        if (action == NestedAction.Repay) return abi.encodeCall(LendingPool.repay, (1e6));
        return abi.encodeCall(LendingPool.repayAll, (2e6));
    }

    /// @notice 반년 이자는 조회에만 남기고 Charlie 잔고·유한 승인12와 유효 가격을 준비한다.
    function _advanceAndPreparePayer() private {
        vm.warp(block.timestamp + HALF_YEAR);
        price.setUpdatedAt(block.timestamp);
        usdc.mint(CHARLIE, 12e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 12e6);
        assertEq(pool.debtOf(BOB), 42e6);
        assertLt(interestPool.storedTotalDebt().updatedAt, block.timestamp);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
    }

    /// @notice 콜백과 같은 주소·양수 입력이 잠금 밖에서 성공하고 상태를 바꿈을 확인한 뒤 대조만 되돌린다.
    function _assertNormalCallSucceeds(bytes memory callData) private {
        uint256 prepared = vm.snapshotState();
        bytes memory beforeState = _interestSnapshot();
        vm.prank(address(callbackUSDC));
        (bool success,) = address(pool).call(callData);
        assertTrue(success, "prepared nested action must succeed without the lock");
        assertNotEq(keccak256(_interestSnapshot()), keccak256(beforeState));
        assertTrue(vm.revertToState(prepared));
    }

    /// @notice 중첩 호출자 자신의 부채·권리·유한 승인은 보존하고 Bob에게만12가 반영되는지 확인한다.
    function _assertPreparedPaymentResult(NestedAction action, bytes memory ownBefore) private view {
        bool withDebt = _needsOwnDebt(action);
        assertEq(_ownSnapshot(), ownBefore);
        assertEq(pool.totalShares(), 102e6);
        _assertCompletedPayment(withDebt ? 104_050_000 : 104e6, withDebt ? 73e6 : 74e6, withDebt ? 31_050_000 : 30e6);
        assertEq(interestPool.storedTotalDebt().principal, withDebt ? 31e6 : 30e6);
        assertEq(interestPool.storedTotalDebt().interestNumerator, withDebt ? 50_000 * InterestMath.DENOMINATOR : 0);
    }

    /// @notice 실제 지급자·차입자 지갑과 정산 장부·자산·현금을 확인하고 풀 성공 이벤트0회를 보장한다.
    function _assertCompletedPayment(uint256 assets, uint256 cash, uint256 debt) private view {
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(pool.debtOf(CHARLIE), 0);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.collateralOf(CHARLIE), 0);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(pool.debtOf(BOB), 30e6);
        assertEq(interestPool.storedDebt(BOB).principal, 30e6);
        assertEq(interestPool.storedDebt(BOB).interestNumerator, 0);
        assertEq(interestPool.storedDebt(BOB).updatedAt, block.timestamp);
        assertEq(pool.totalDebt(), debt);
        assertEq(interestPool.storedTotalDebt().updatedAt, block.timestamp);
        assertEq(pool.totalAssets(), assets);
        assertEq(interestPool.storedAssetsNumerator(), assets * InterestMath.DENOMINATOR);
        assertEq(usdc.balanceOf(address(pool)), cash);
        assertEq(pool.availableLiquidity(), cash);
        _assertNoPoolSuccessEvents(vm.getRecordedLogs());
    }

    /// @notice 상환 두 요청만 토큰 주소 자신의 기존 부채가 필요하다.
    function _needsOwnDebt(NestedAction action) private pure returns (bool) {
        return action == NestedAction.Repay || action == NestedAction.RepayAll;
    }

    /// @notice 토큰 주소의 두 자산·승인·지분·담보·현재 부채와 정확 저장 부채를 함께 보존한다.
    function _ownSnapshot() private view returns (bytes memory) {
        return abi.encode(_participant(address(callbackUSDC)), interestPool.storedDebt(address(callbackUSDC)));
    }

    /// @notice 콜백이 실행되어 자원 부족 오류가 아닌 정확한 공유 잠금 오류를 받았는지 확인한다.
    function _assertBlocked() private view {
        assertTrue(callbackUSDC.attempted());
        assertFalse(callbackUSDC.nestedSucceeded());
        assertEq(
            callbackUSDC.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    /// @notice 관측 대상은 지급자가 아닌 Bob이며 현재 부채·총부채·자산·현금·가용 현금 순으로 비교한다.
    function _assertObserved(uint256[5] memory expected) private view {
        assertEq(abi.encode(callbackUSDC.observed()), abi.encode(expected));
    }

    /// @notice 시험 전용 경로는 토큰 로그와 별개로 풀 emitter의 성공 이벤트를 남기지 않는다.
    function _assertNoPoolSuccessEvents(Vm.Log[] memory logs) private view {
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(pool));
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {InterestTestBase} from "./helpers/InterestTestBase.sol";
import {InterestReentrantMockUSDC} from "./mocks/InterestReentrantMockUSDC.sol";

/// @title 이자 상환 중 조회 순서와 전액 상환의 공통 잠금 검사
/// @notice 양수 중첩 요청의 정상 성공 대조로 다른 자원 부족 오류를 배제한다.
contract LendingPoolInterestReentrancyTest is InterestTestBase {
    InterestReentrantMockUSDC private callbackUSDC;

    /// @notice 새 전액 상환과 같은 잠금을 사용해야 하는 일곱 자금 이동 진입점이다.
    enum NestedAction {
        Supply,
        Withdraw,
        DepositCollateral,
        WithdrawCollateral,
        Borrow,
        Repay,
        RepayAll
    }

    /// @notice 공급100·대출40 뒤 반년을 지나 조회 부채42와 아직 저장하지 않은 이자2를 준비한다.
    function setUp() public override {
        callbackUSDC = new InterestReentrantMockUSDC();
        _prepareBorrowPool(callbackUSDC);
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.warp(block.timestamp + HALF_YEAR);
        price.setUpdatedAt(block.timestamp);
    }

    /// @notice 12 수령 직후에도 부채42·자산102·가용60을 보이고 완료 후에만 부채30·가용72가 된다.
    function test_RepayCallbackObservesCurrentDebtBeforeReduction() public {
        _prepareNestedBorrow();
        _armBorrow(false);
        vm.prank(BOB);
        usdc.approve(address(pool), 12e6);
        vm.recordLogs();
        vm.prank(BOB);
        pool.repay(12e6);

        _assertBlocked();
        _assertObserved([uint256(42e6), 42e6, 102e6, 72e6, 60e6]);
        assertEq(pool.debtOf(BOB), 30e6);
        assertEq(pool.totalDebt(), 30e6);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 72e6);
        assertEq(usdc.balanceOf(address(pool)), 72e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(pool.debtOf(address(callbackUSDC)), 0);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 12e6);
    }

    /// @notice 전액 수령 중에도 현재 부채42를 보존하고 완료 후 견적42만 차감해 완제한다.
    function test_RepayAllCallbackObservesCurrentDebtBeforeReduction() public {
        _prepareNestedBorrow();
        _armBorrow(false);
        usdc.mint(BOB, 2e6);
        vm.prank(BOB);
        usdc.approve(address(pool), 42e6);
        vm.recordLogs();
        vm.prank(BOB);
        pool.repayAll(50e6);

        _assertBlocked();
        _assertObserved([uint256(42e6), 42e6, 102e6, 102e6, 60e6]);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 102e6);
        assertEq(usdc.balanceOf(address(pool)), 102e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(pool.debtOf(address(callbackUSDC)), 0);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 42e6);
    }

    /// @notice 수령 뒤 중첩 오류를 전파하면 미저장 이자·토큰·승인·콜백 상태가 복구되고 재시도는 한 번 성공한다.
    function test_RepayCallbackPropagatesAndRestoresInterestAndTokenState() public {
        _prepareNestedBorrow();
        _armBorrow(true);
        vm.prank(BOB);
        usdc.approve(address(pool), 12e6);
        bytes memory beforeState = _interestSnapshot();
        bytes memory beforeCallback = callbackUSDC.callbackState();
        vm.recordLogs();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(BOB);
        pool.repay(12e6);

        _assertInterestUnchanged(beforeState);
        assertEq(callbackUSDC.callbackState(), beforeCallback);
        assertFalse(callbackUSDC.attempted());
        callbackUSDC.disableCallback();
        vm.recordLogs();
        vm.prank(BOB);
        pool.repay(12e6);
        assertEq(pool.debtOf(BOB), 30e6);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 72e6);
        assertEq(usdc.balanceOf(address(pool)), 72e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 12e6);
    }

    /// @notice 정상 실행 가능한 일곱 중첩 요청의 잠금 오류를 잡으면 바깥 전액 상환만 한 번 기록된다.
    function test_RepayAllCatchesEachOfSevenFundMovingEntryPoints() public {
        uint256 initial = vm.snapshotState();
        for (uint256 i; i < 7; ++i) {
            NestedAction action = NestedAction(i);
            bytes memory callData = _prepareNestedAction(action);
            _assertNormalCallSucceeds(callData);
            bytes memory ownBefore = _ownSnapshot();
            uint256 sharesBefore = pool.totalShares();
            callbackUSDC.arm(pool, InterestReentrantMockUSDC.CallbackOn.TransferFrom, callData, false, BOB);
            vm.recordLogs();
            vm.prank(BOB);
            pool.repayAll(50e6);

            _assertBlocked();
            bool withDebt = _needsOwnDebt(action);
            _assertObserved(
                [
                    uint256(44e6),
                    withDebt ? 45_050_000 : 44e6,
                    withDebt ? 106_050_000 : 106e6,
                    withDebt ? 105e6 : 106e6,
                    withDebt ? 61e6 : 62e6
                ]
            );
            _assertPreparedRepayAllResult(action, ownBefore, sharesBefore);
            assertTrue(vm.revertToState(initial));
        }
    }

    /// @notice 일곱 잠금 오류를 각각 전파하면 반년치 이자 저장·토큰 이동·승인·콜백 관측을 전부 복구한다.
    function test_RepayAllPropagatesEachOfSevenEntryPointsAndRestoresAllState() public {
        uint256 initial = vm.snapshotState();
        for (uint256 i; i < 7; ++i) {
            NestedAction action = NestedAction(i);
            bytes memory callData = _prepareNestedAction(action);
            _assertNormalCallSucceeds(callData);
            bytes memory ownBefore = _ownSnapshot();
            uint256 sharesBefore = pool.totalShares();
            callbackUSDC.arm(pool, InterestReentrantMockUSDC.CallbackOn.TransferFrom, callData, true, BOB);
            bytes memory beforeState = _interestSnapshot();
            bytes memory beforeCallback = callbackUSDC.callbackState();
            vm.recordLogs();
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            vm.prank(BOB);
            pool.repayAll(50e6);

            _assertInterestUnchanged(beforeState);
            assertEq(callbackUSDC.callbackState(), beforeCallback);
            assertFalse(callbackUSDC.attempted());
            callbackUSDC.disableCallback();
            vm.recordLogs();
            vm.prank(BOB);
            pool.repayAll(50e6);
            _assertPreparedRepayAllResult(action, ownBefore, sharesBefore);
            assertTrue(vm.revertToState(initial));
        }
    }

    /// @notice 공급2·담보1과 필요한 경우 부채1을 정상 준비한 뒤 반년 이자를 미저장으로 남긴다.
    /// @dev 담보 반환 대조에는 부채를 만들지 않으며 상환 대조에만 부채·이자1.05를 준비한다.
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
        vm.warp(block.timestamp + HALF_YEAR);
        price.setUpdatedAt(block.timestamp);
        assertEq(pool.debtOf(BOB), 44e6);
        assertLt(interestPool.storedTotalDebt().updatedAt, block.timestamp);
        usdc.mint(BOB, 4e6);
        vm.prank(BOB);
        usdc.approve(address(pool), 44e6);

        if (action == NestedAction.Supply) return abi.encodeCall(LendingPool.supply, (1e6));
        if (action == NestedAction.Withdraw) return abi.encodeCall(LendingPool.withdraw, (1e6));
        if (action == NestedAction.DepositCollateral) return abi.encodeCall(LendingPool.depositCollateral, (1));
        if (action == NestedAction.WithdrawCollateral) return abi.encodeCall(LendingPool.withdrawCollateral, (1));
        if (action == NestedAction.Borrow) return abi.encodeCall(LendingPool.borrow, (1e6));
        if (action == NestedAction.Repay) return abi.encodeCall(LendingPool.repay, (1e6));
        return abi.encodeCall(LendingPool.repayAll, (2e6));
    }

    /// @notice 콜백과 같은 주소·입력·상태의 정상 호출 성공을 확인한 뒤 그 대조의 변경만 되돌린다.
    function _assertNormalCallSucceeds(bytes memory callData) private {
        uint256 prepared = vm.snapshotState();
        bytes memory beforeState = _interestSnapshot();
        vm.prank(address(callbackUSDC));
        (bool success,) = address(pool).call(callData);
        assertTrue(success, "prepared nested action must succeed without the lock");
        assertNotEq(keccak256(_interestSnapshot()), keccak256(beforeState));
        assertTrue(vm.revertToState(prepared));
    }

    /// @notice 일곱 중첩 요청 중 어느 것도 반영되지 않고 Bob의 현재 견적44만 한 번 상환됐는지 확인한다.
    function _assertPreparedRepayAllResult(NestedAction action, bytes memory ownBefore, uint256 sharesBefore)
        private
        view
    {
        bool withDebt = _needsOwnDebt(action);
        assertEq(_ownSnapshot(), ownBefore);
        assertEq(pool.totalShares(), sharesBefore);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), withDebt ? 1_050_000 : 0);
        assertEq(pool.totalAssets(), withDebt ? 106_050_000 : 106e6);
        assertEq(pool.availableLiquidity(), withDebt ? 105e6 : 106e6);
        assertEq(usdc.balanceOf(address(pool)), withDebt ? 105e6 : 106e6);
        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(interestPool.storedDebt(BOB).principal, 0);
        assertEq(interestPool.storedDebt(BOB).interestNumerator, 0);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 44e6);
    }

    /// @notice 상환 경로만 기존 부채가 필요하며 담보 반환은 부채0 상태를 사용한다.
    function _needsOwnDebt(NestedAction action) private pure returns (bool) {
        return action == NestedAction.Repay || action == NestedAction.RepayAll;
    }

    /// @notice 중첩 호출자의 토큰·승인·지분·담보와 개인 저장 이자의 불변을 확인한다.
    function _ownSnapshot() private view returns (bytes memory) {
        return abi.encode(_participant(address(callbackUSDC)), interestPool.storedDebt(address(callbackUSDC)));
    }

    /// @notice 담보1·가격100의 정상 대출raw1 성공을 먼저 확인하고 대조 전 상태로 되돌린다.
    function _prepareNestedBorrow() private {
        _depositFor(address(callbackUSDC), 1e8);
        uint256 prepared = vm.snapshotState();
        vm.prank(address(callbackUSDC));
        pool.borrow(1);
        assertEq(pool.debtOf(address(callbackUSDC)), 1);
        assertTrue(vm.revertToState(prepared));
    }

    /// @notice 수령 후 콜백의 양수 대출과 오류 전파 방식을 선택한다.
    function _armBorrow(bool propagate) private {
        callbackUSDC.arm(
            pool,
            InterestReentrantMockUSDC.CallbackOn.TransferFrom,
            abi.encodeCall(LendingPool.borrow, (1)),
            propagate,
            BOB
        );
    }

    /// @notice 콜백이 실제 실행됐고 일반 오류가 아닌 공통 잠금 오류를 받았는지 확인한다.
    function _assertBlocked() private view {
        assertTrue(callbackUSDC.attempted());
        assertFalse(callbackUSDC.nestedSucceeded());
        assertEq(
            callbackUSDC.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    /// @notice 상환 도중 개인 부채·총부채·자산·현금·가용 현금의 명세 기대를 비교한다.
    function _assertObserved(uint256[5] memory expected) private view {
        assertEq(abi.encode(callbackUSDC.observed()), abi.encode(expected));
    }
}

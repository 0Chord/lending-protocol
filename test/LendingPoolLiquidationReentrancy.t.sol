// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DebtLedger} from "../src/accounting/DebtLedger.sol";
import {InterestMath} from "../src/libraries/InterestMath.sol";
import {InterestTestBase} from "./helpers/InterestTestBase.sol";
import {LendingPoolHarness} from "./mocks/LendingPoolHarness.sol";
import {MockCollateralPriceSource} from "./mocks/MockCollateralPriceSource.sol";
import {
    LiquidationCallback,
    LiquidationCallbackUSDC,
    LiquidationCallbackWBTC
} from "./mocks/LiquidationCallbackMocks.sol";

/// @title 전액 청산의 USDC 수령과 WBTC 지급 콜백 검사
/// @notice 실제 토큰 이동 뒤의 조회·정확 저장값과 공유 잠금 오류를 함께 관측한다.
contract LendingPoolLiquidationReentrancyTest is InterestTestBase {
    uint256 private constant T0 = 10_000;
    uint256 private constant REPAID = 73_500_000;
    uint256 private constant COLLATERAL_OUT = 96_468_750;
    address private constant DAVE = address(0xDA7E);
    LiquidationCallbackUSDC private callbackUSDC;
    LiquidationCallbackWBTC private callbackWBTC;

    /// @notice 공통 잠금을 공유하는 기존 일곱 자금 이동과 새 전액 청산이다.
    enum NestedAction {
        Supply,
        Withdraw,
        DepositCollateral,
        WithdrawCollateral,
        Borrow,
        Repay,
        RepayAll,
        Liquidate
    }

    /// @notice 두 콜백 토큰을 연결하고 대표 공급100·Bob담보1/차입70을 정상 API로 준비한다.
    function setUp() public override {
        vm.warp(T0);
        callbackUSDC = new LiquidationCallbackUSDC();
        callbackWBTC = new LiquidationCallbackWBTC();
        usdc = callbackUSDC;
        wbtc = callbackWBTC;
        price = new MockCollateralPriceSource(100e8, T0);
        interestPool = new LendingPoolHarness(usdc, wbtc, price);
        pool = interestPool;
        usdc.mint(ALICE, 100e6);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), 100e6);
        pool.supply(100e6);
        vm.stopPrank();
        _depositFor(BOB, 1e8);
        vm.prank(BOB);
        pool.borrow(70e6);
    }

    /// @notice USDC 수령 뒤 Bob73.5/담보1·자산/현금103.5·가용30이며 개인 저장 부채는 정산 전이다.
    function test_LiquidationUSDCCallbackObservesDebtBeforeSettlement() public {
        _assertRepresentativeObservation(callbackUSDC, false);
    }

    /// @notice WBTC 지급 뒤 Bob부채0/담보0.03531250·현금/가용103.5와 정산된 정확 장부를 보인다.
    function test_LiquidationWBTCCallbackObservesDebtAndCollateralAfterSettlement() public {
        _assertRepresentativeObservation(callbackWBTC, true);
    }

    /// @notice USDC 수령 중 여덟 양수 중첩의 오류를 잡으면 토큰 주소 권리는 보존하고 바깥 청산만 한 번 성공한다.
    function test_LiquidationUSDCCallbackCatchesAllEightEntryPoints() public {
        _assertCatchesAllEight(callbackUSDC, false);
    }

    /// @notice WBTC 지급 중 여덟 양수 중첩의 오류를 잡으면 정산과 담보 지급은 바깥 청산 한 번만 반영한다.
    function test_LiquidationWBTCCallbackCatchesAllEightEntryPoints() public {
        _assertCatchesAllEight(callbackWBTC, true);
    }

    /// @notice USDC 수령 중 여덟 잠금 오류를 전파하면 전체 상태와 두 콜백 저장값을 복구하고 해제 후 재시도한다.
    function test_LiquidationUSDCCallbackPropagatesAllEightAndRestoresBeforeRetry() public {
        _assertPropagatesAllEight(callbackUSDC);
    }

    /// @notice WBTC 지급 중 여덟 잠금 오류를 전파하면 앞선 USDC 수령/승인 소비와 부채 정산도 복구한다.
    function test_LiquidationWBTCCallbackPropagatesAllEightAndRestoresBeforeRetry() public {
        _assertPropagatesAllEight(callbackWBTC);
    }

    /// @notice 각 요청의 정상 성공 대조 뒤 공유 잠금 오류·단계별 관측·바깥 한 번 반영을 검증한다.
    function _assertCatchesAllEight(LiquidationCallback callback, bool afterSettlement) private {
        uint256 initial = vm.snapshotState();
        for (uint256 i; i < 8; ++i) {
            NestedAction action = NestedAction(i);
            bytes memory callData = _prepareNestedAction(action, address(callback));
            _assertNormalCallSucceeds(address(callback), callData);
            bytes memory resourcesBefore = _tokenResourcesSnapshot();
            bytes memory othersBefore = _otherParticipantsSnapshot();
            LiquidationCallback inactive = _inactiveCallback(callback);
            bytes memory inactiveBefore = inactive.callbackState();
            callback.arm(interestPool, callData, false, BOB);

            vm.recordLogs();
            vm.prank(CHARLIE);
            pool.liquidate(BOB, 74e6, 96_000_000);

            _assertBlocked(callback);
            _assertPreparedObservation(callback, afterSettlement, action);
            assertEq(callback.observedTokenResources(), resourcesBefore);
            assertEq(inactive.callbackState(), inactiveBefore);
            _assertPreparedCompleted(action, resourcesBefore, othersBefore);
            assertTrue(vm.revertToState(initial));
        }
    }

    /// @notice 실패 직전의 참여자·토큰·정확 장부·시각·콜백 설정을 비교하고 콜백만 끈 같은 요청을 재시도한다.
    function _assertPropagatesAllEight(LiquidationCallback callback) private {
        uint256 initial = vm.snapshotState();
        for (uint256 i; i < 8; ++i) {
            NestedAction action = NestedAction(i);
            bytes memory callData = _prepareNestedAction(action, address(callback));
            _assertNormalCallSucceeds(address(callback), callData);
            bytes memory resourcesBefore = _tokenResourcesSnapshot();
            bytes memory othersBefore = _otherParticipantsSnapshot();
            callback.arm(interestPool, callData, true, BOB);
            bytes memory beforeState = _liquidationSnapshot();

            vm.recordLogs();
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            vm.prank(CHARLIE);
            pool.liquidate(BOB, 74e6, 96_000_000);

            assertEq(_liquidationSnapshot(), beforeState);
            assertFalse(callbackUSDC.attempted());
            assertFalse(callbackWBTC.attempted());
            _assertNoPoolSuccessEvents(vm.getRecordedLogs());
            callback.disableCallback();
            bytes memory callbacksBeforeRetry = abi.encode(callbackUSDC.callbackState(), callbackWBTC.callbackState());
            vm.recordLogs();
            vm.prank(CHARLIE);
            pool.liquidate(BOB, 74e6, 96_000_000);

            _assertPreparedCompleted(action, resourcesBefore, othersBefore);
            assertEq(abi.encode(callbackUSDC.callbackState(), callbackWBTC.callbackState()), callbacksBeforeRetry);
            assertTrue(vm.revertToState(initial));
        }
    }

    /// @notice 두 토큰 주소에 공급1을 실행할 자금·유한 승인을 준비하되 대표 자산100은 보존한다.
    function _assertRepresentativeObservation(LiquidationCallback callback, bool afterSettlement) private {
        _prepareRepresentativeCaller(address(callbackUSDC));
        _prepareRepresentativeCaller(address(callbackWBTC));
        _advanceAndPrepareLiquidator();
        bytes memory callData = abi.encodeCall(LendingPool.supply, (1e6));
        _assertNormalCallSucceeds(address(callback), callData);
        bytes memory resourcesBefore = _tokenResourcesSnapshot();
        callback.arm(interestPool, callData, false, BOB);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 96_000_000);

        _assertBlocked(callback);
        uint256[7] memory expected = [
            afterSettlement ? 0 : REPAID,
            afterSettlement ? 3_531_250 : 1e8,
            afterSettlement ? 0 : REPAID,
            uint256(103_500_000),
            uint256(103_500_000),
            afterSettlement ? 3_531_250 : 1e8,
            afterSettlement ? 103_500_000 : 30e6
        ];
        assertEq(abi.encode(callback.observed()), abi.encode(expected));
        _assertObservedAccounting(callback, afterSettlement, 0, 0, 103_500_000);
        assertEq(callback.observedTokenResources(), resourcesBefore);
        assertEq(_tokenResourcesSnapshot(), resourcesBefore);
        _assertRepresentativeCompleted();
    }

    /// @notice 콜백 토큰 자신이 잠금 밖에서 공급할 수 있도록 실제 자금과 양 자산 유한 승인을 준비한다.
    function _prepareRepresentativeCaller(address own) private {
        usdc.mint(own, 2e6);
        wbtc.mint(own, 2);
        vm.startPrank(own);
        usdc.approve(address(pool), 2e6);
        wbtc.approve(address(pool), 2);
        vm.stopPrank();
    }

    /// @notice 두 토큰 자신의 공급2·담보1·잔고/유한 승인을 준비하고 필요한 부채만 정상 API로 추가한다.
    function _prepareNestedAction(NestedAction action, address caller) private returns (bytes memory) {
        _prepareTokenPosition(address(callbackUSDC), caller == address(callbackUSDC) && _needsOwnDebt(action));
        _prepareTokenPosition(address(callbackWBTC), caller == address(callbackWBTC) && _needsOwnDebt(action));
        if (action == NestedAction.Liquidate) {
            _depositFor(DAVE, 2_000_000);
            vm.prank(DAVE);
            pool.borrow(1_400_000);
        }
        _advanceAndPrepareLiquidator();
        _assertPreparedTokenResources(address(callbackUSDC), caller == address(callbackUSDC) && _needsOwnDebt(action));
        _assertPreparedTokenResources(address(callbackWBTC), caller == address(callbackWBTC) && _needsOwnDebt(action));

        if (action == NestedAction.Supply) return abi.encodeCall(LendingPool.supply, (1e6));
        if (action == NestedAction.Withdraw) return abi.encodeCall(LendingPool.withdraw, (1e6));
        if (action == NestedAction.DepositCollateral) return abi.encodeCall(LendingPool.depositCollateral, (1));
        if (action == NestedAction.WithdrawCollateral) return abi.encodeCall(LendingPool.withdrawCollateral, (1));
        if (action == NestedAction.Borrow) return abi.encodeCall(LendingPool.borrow, (1e6));
        if (action == NestedAction.Repay) return abi.encodeCall(LendingPool.repay, (1e6));
        if (action == NestedAction.RepayAll) return abi.encodeCall(LendingPool.repayAll, (2e6));
        return abi.encodeCall(LendingPool.liquidate, (DAVE, 1_500_000, 1_900_000));
    }

    /// @notice 콜백이 꺼진 준비 단계에서 토큰 주소 자신의 권리를 만들고 상환 계열에만 자기 부채1을 만든다.
    function _prepareTokenPosition(address own, bool withDebt) private {
        usdc.mint(own, 4e6);
        wbtc.mint(own, 1e8 + 1);
        vm.startPrank(own);
        usdc.approve(address(pool), 4e6);
        pool.supply(2e6);
        wbtc.approve(address(pool), 1e8 + 1);
        pool.depositCollateral(1e8);
        if (withDebt) pool.borrow(1e6);
        vm.stopPrank();
    }

    /// @notice 자원 부족이 잠금 검사로 오인되지 않게 각 토큰 주소의 실제 잔고·잔여 승인·권리·부채를 확인한다.
    function _assertPreparedTokenResources(address own, bool withDebt) private view {
        assertEq(usdc.balanceOf(own), withDebt ? 3e6 : 2e6);
        assertEq(usdc.allowance(own, address(pool)), 2e6);
        assertEq(wbtc.balanceOf(own), 1);
        assertEq(wbtc.allowance(own, address(pool)), 1);
        assertEq(pool.shares(own), 2e6);
        assertGt(pool.deposits(own), 2e6);
        assertEq(pool.collateralOf(own), 1e8);
        assertEq(pool.debtOf(own), withDebt ? 1_050_000 : 0);
        assertEq(interestPool.storedDebt(own).principal, withDebt ? 1e6 : 0);
        assertEq(interestPool.storedDebt(own).interestNumerator, 0);
        assertEq(interestPool.storedDebt(own).updatedAt, withDebt ? T0 : 0);
    }

    /// @notice 반년 이자를 조회 상태로 두고 가격80·Charlie잔고/유한승인74를 준비한다.
    function _advanceAndPrepareLiquidator() private {
        vm.warp(T0 + HALF_YEAR);
        price.setPrice(80e8);
        price.setUpdatedAt(block.timestamp);
        usdc.mint(CHARLIE, 74e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 74e6);
        assertEq(pool.debtOf(BOB), REPAID);
        assertEq(interestPool.storedDebt(BOB).updatedAt, T0);
    }

    /// @notice 같은 토큰 주소·양수 요청이 잠금 밖에서 실제 성공하고 상태를 바꾼 뒤 대조만 되돌린다.
    function _assertNormalCallSucceeds(address caller, bytes memory callData) private {
        uint256 prepared = vm.snapshotState();
        bytes memory beforeState = _liquidationSnapshot();
        vm.prank(caller);
        (bool success,) = address(pool).call(callData);
        assertTrue(success, "prepared nested action must succeed without the lock");
        assertNotEq(keccak256(_liquidationSnapshot()), keccak256(beforeState));
        assertTrue(vm.revertToState(prepared));
    }

    /// @notice 타 부채만 다른 여덟 fixture의 고정 원금/반년 이자로 각 콜백 단계의 조회와 원시 저장값을 비교한다.
    function _assertPreparedObservation(LiquidationCallback callback, bool afterSettlement, NestedAction action)
        private
        view
    {
        (uint256 otherPrincipal, uint256 otherInterest) = _otherDebt(action);
        uint256 assets = 107_500_000 + otherInterest;
        uint256 cashBefore = 34e6 - otherPrincipal;
        uint256 collateralBefore = 3e8 + (action == NestedAction.Liquidate ? 2_000_000 : 0);
        uint256[7] memory expected = [
            afterSettlement ? 0 : REPAID,
            afterSettlement ? 3_531_250 : 1e8,
            otherPrincipal + otherInterest + (afterSettlement ? 0 : REPAID),
            assets,
            cashBefore + REPAID,
            afterSettlement ? collateralBefore - COLLATERAL_OUT : collateralBefore,
            afterSettlement ? cashBefore + REPAID : cashBefore
        ];
        assertEq(abi.encode(callback.observed()), abi.encode(expected));
        _assertObservedAccounting(callback, afterSettlement, otherPrincipal, otherInterest, assets);
    }

    /// @notice 조회값뿐 아니라 전체/개인의 원금·정확 이자 분자·시각과 저장 자산을 독립 고정값으로 비교한다.
    function _assertObservedAccounting(
        LiquidationCallback callback,
        bool afterSettlement,
        uint256 otherPrincipal,
        uint256 otherInterest,
        uint256 assets
    ) private view {
        DebtLedger.Position memory total = DebtLedger.Position(
            afterSettlement ? otherPrincipal : 70e6 + otherPrincipal,
            (afterSettlement ? otherInterest : 3_500_000 + otherInterest) * InterestMath.DENOMINATOR,
            block.timestamp
        );
        DebtLedger.Position memory borrower =
            DebtLedger.Position(afterSettlement ? 0 : 70e6, 0, afterSettlement ? block.timestamp : T0);
        assertEq(callback.observedAccounting(), abi.encode(assets * InterestMath.DENOMINATOR, total, borrower));
    }

    /// @notice 중첩 호출이 실제 실행되고 자원 오류 대신 정확한 공유 잠금 오류를 받았는지 확인한다.
    function _assertBlocked(LiquidationCallback callback) private view {
        assertTrue(callback.attempted());
        assertFalse(callback.nestedSucceeded());
        assertEq(callback.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }

    /// @notice USDC/WBTC 두 토큰 주소의 자원과 정확 개인 장부를 모두 비교한다.
    function _tokenResourcesSnapshot() private view returns (bytes memory) {
        return abi.encode(
            _participant(address(callbackUSDC)),
            interestPool.storedDebt(address(callbackUSDC)),
            _participant(address(callbackWBTC)),
            interestPool.storedDebt(address(callbackWBTC))
        );
    }

    /// @notice 원래 스냅샷에 빠진 WBTC 주소와 별도 청산 대상 DAVE·양 콜백의 설정/관측 저장값을 포함한다.
    function _liquidationSnapshot() private view returns (bytes memory) {
        return abi.encode(
            _interestSnapshot(),
            _participant(DAVE),
            interestPool.storedDebt(DAVE),
            _participant(address(callbackWBTC)),
            interestPool.storedDebt(address(callbackWBTC)),
            callbackUSDC.callbackState(),
            callbackWBTC.callbackState()
        );
    }

    /// @notice Bob 외 공급자와 별도 차입자의 현재 권리 및 개인 원시 저장값이 청산으로 변하지 않아야 한다.
    function _otherParticipantsSnapshot() private view returns (bytes memory) {
        return abi.encode(
            _participant(ALICE), interestPool.storedDebt(ALICE), _participant(DAVE), interestPool.storedDebt(DAVE)
        );
    }

    /// @notice 상환 둘만 자기 부채를, 중첩 청산만 별도 차입자 부채를 준비한다.
    function _otherDebt(NestedAction action) private pure returns (uint256 principal, uint256 interest) {
        if (_needsOwnDebt(action)) return (1e6, 50_000);
        if (action == NestedAction.Liquidate) return (1_400_000, 70_000);
        return (0, 0);
    }

    /// @notice 자기 부채가 있으면 담보 반환 대조가 불가능하므로 상환 두 요청에서만 만든다.
    function _needsOwnDebt(NestedAction action) private pure returns (bool) {
        return action == NestedAction.Repay || action == NestedAction.RepayAll;
    }

    /// @notice 콜백을 실행하지 않은 다른 토큰의 설정/관측 저장값도 보존되는지 비교할 대상이다.
    function _inactiveCallback(LiquidationCallback callback) private view returns (LiquidationCallback) {
        return address(callback) == address(callbackUSDC)
            ? LiquidationCallback(callbackWBTC)
            : LiquidationCallback(callbackUSDC);
    }

    /// @notice 중첩 요청은 아무 자원도 쓰지 않고 Bob만 전액 정산되며 타 부채·권리와 양 토큰 총발행량은 보존한다.
    function _assertPreparedCompleted(NestedAction action, bytes memory resourcesBefore, bytes memory othersBefore)
        private
        view
    {
        (uint256 otherPrincipal, uint256 otherInterest) = _otherDebt(action);
        uint256 assets = 107_500_000 + otherInterest;
        uint256 cash = 107_500_000 - otherPrincipal;
        assertEq(_tokenResourcesSnapshot(), resourcesBefore);
        assertEq(_otherParticipantsSnapshot(), othersBefore);
        assertEq(usdc.balanceOf(CHARLIE), 500_000);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 500_000);
        assertEq(wbtc.balanceOf(CHARLIE), COLLATERAL_OUT);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.collateralOf(CHARLIE), 0);
        assertEq(pool.debtOf(CHARLIE), 0);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.collateralOf(BOB), 3_531_250);
        assertEq(interestPool.storedDebt(BOB).principal, 0);
        assertEq(interestPool.storedDebt(BOB).interestNumerator, 0);
        assertEq(interestPool.storedDebt(BOB).updatedAt, block.timestamp);
        assertEq(pool.totalDebt(), otherPrincipal + otherInterest);
        assertEq(interestPool.storedTotalDebt().principal, otherPrincipal);
        assertEq(interestPool.storedTotalDebt().interestNumerator, otherInterest * InterestMath.DENOMINATOR);
        assertEq(interestPool.storedTotalDebt().updatedAt, block.timestamp);
        assertEq(pool.totalAssets(), assets);
        assertEq(interestPool.storedAssetsNumerator(), assets * InterestMath.DENOMINATOR);
        assertEq(usdc.balanceOf(address(pool)), cash);
        assertEq(pool.availableLiquidity(), cash);
        assertEq(wbtc.balanceOf(address(pool)), 203_531_250 + (action == NestedAction.Liquidate ? 2_000_000 : 0));
        assertEq(pool.totalShares(), 104e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(usdc.totalSupply(), 182e6);
        assertEq(wbtc.totalSupply(), 300_000_002 + (action == NestedAction.Liquidate ? 2_000_000 : 0));
        _assertLiquidatedOnce(vm.getRecordedLogs());
    }

    /// @notice 대표 청산이 Charlie의 유한승인을 실제 수령액만 쓰고 한 번만 완료됐는지 확인한다.
    function _assertRepresentativeCompleted() private view {
        assertEq(usdc.balanceOf(CHARLIE), 500_000);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 500_000);
        assertEq(wbtc.balanceOf(CHARLIE), COLLATERAL_OUT);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.collateralOf(BOB), 3_531_250);
        assertEq(pool.totalAssets(), 103_500_000);
        assertEq(usdc.balanceOf(address(pool)), 103_500_000);
        assertEq(pool.availableLiquidity(), 103_500_000);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.deposits(ALICE), 103_500_000);
        _assertLiquidatedOnce(vm.getRecordedLogs());
    }

    /// @notice 풀 emitter는 Repaid/CollateralWithdrawn 없이 정확한 Liquidated 한 번만 남겨야 한다.
    function _assertLiquidatedOnce(Vm.Log[] memory logs) private view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool)) continue;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], keccak256("Liquidated(address,address,uint256,uint256)"));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(CHARLIE))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(BOB))));
            assertEq(logs[i].data, abi.encode(REPAID, COLLATERAL_OUT));
            ++count;
        }
        assertEq(count, 1);
    }

    /// @notice 전파 실패한 청산의 풀 성공 이벤트는 없어야 한다.
    function _assertNoPoolSuccessEvents(Vm.Log[] memory logs) private view {
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(pool));
        }
    }
}

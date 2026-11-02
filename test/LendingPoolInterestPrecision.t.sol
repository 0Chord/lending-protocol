// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {InterestTestBase} from "./helpers/InterestTestBase.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {DebtLedger} from "../src/accounting/DebtLedger.sol";
import {InterestMath} from "../src/libraries/InterestMath.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title 소수 자산·다인 부채의 정밀 환산과 범위 초과 복구
/// @notice raw 최소 단위의 고정 사례로 공개 내림값과 정확 저장 분자를 함께 검증한다.
contract LendingPoolInterestPrecisionTest is InterestTestBase {
    uint256 private constant Q = InterestMath.DENOMINATOR;

    /// @notice 정확 자산101.5·총지분203에서1 raw 공급은 내림한101을 사용하지 않고2지분을 만든다.
    function test_FractionalAssetsSupplyMintsTwoShares() public {
        _prepareFractionalRatio();
        usdc.mint(BOB, 1);
        vm.startPrank(BOB);
        usdc.approve(address(pool), 1);
        pool.supply(1);
        vm.stopPrank();

        assertEq(pool.shares(BOB), 2);
        assertEq(pool.shares(ALICE), 201);
        assertEq(pool.shares(CHARLIE), 2);
        assertEq(pool.totalShares(), 205);
        assertEq(interestPool.storedAssetsNumerator(), 32_324_400_000_000);
        assertEq(pool.totalAssets(), 102);
        assertEq(pool.deposits(BOB), 1);
        assertEq(usdc.balanceOf(address(pool)), 101);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertStoredConservation(101);
    }

    /// @notice 동일한101.5/203 비율의1 raw 출금은3개가 아니라2지분을 차감한다.
    function test_FractionalAssetsWithdrawalBurnsTwoShares() public {
        _prepareFractionalRatio();
        uint256 beforeBalance = usdc.balanceOf(ALICE);
        vm.prank(ALICE);
        pool.withdraw(1);

        assertEq(pool.shares(ALICE), 199);
        assertEq(pool.shares(CHARLIE), 2);
        assertEq(pool.totalShares(), 201);
        assertEq(interestPool.storedAssetsNumerator(), 31_693_680_000_000);
        assertEq(pool.totalAssets(), 100);
        assertEq(usdc.balanceOf(ALICE), beforeBalance + 1);
        assertEq(usdc.balanceOf(address(pool)), 99);
        _assertStoredConservation(99);
    }

    /// @notice 같은 준비 상태에서2지분의 정확 권리는1 raw이며 조회는 분자·시각을 저장하지 않는다.
    function test_FractionalAssetsClaimUsesExactRatioWithoutWrites() public {
        _prepareFractionalRatio();
        bytes memory beforeState = _interestSnapshot();
        vm.record();

        assertEq(pool.deposits(CHARLIE), 1);
        assertEq(pool.totalAssets(), 101);
        assertEq(pool.totalDebt(), 1);
        assertEq(pool.debtOf(BOB), 2);
        assertEq(pool.availableLiquidity(), 100);

        (, bytes32[] memory writes) = vm.accesses(address(pool));
        assertEq(writes.length, 0);
        assertEq(_interestSnapshot(), beforeState);
    }

    /// @notice 10.2·10.7 채권의11씩 완제는 올림 차이만 더해 자산102를 만들고 빈 풀 재시작을 허용한다.
    function test_TwoFractionalDebtsSettleToCashAndEmptyPoolRestarts() public {
        _resetShares(100, 0);
        interestPool.setAccountedAssetsNumeratorForTest(31_819_824_000_000);
        interestPool.setDebtPositionForTest(BOB, 10, 63_072_000_000, block.timestamp);
        interestPool.setDebtPositionForTest(CHARLIE, 10, 220_752_000_000, block.timestamp);
        interestPool.setTotalDebtForTest(20, 283_824_000_000, block.timestamp);
        deal(address(usdc), address(pool), 80, true);
        _fundRepayment(BOB, 11);
        _fundRepayment(CHARLIE, 11);
        _assertStoredConservation(80);
        assertEq(pool.totalAssets(), 100);
        assertEq(pool.totalDebt(), 20);
        assertEq(pool.debtOf(BOB), 11);
        assertEq(pool.debtOf(CHARLIE), 11);

        vm.recordLogs();
        vm.prank(BOB);
        pool.repayAll(11);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 11);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 10, 220_752_000_000, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 32_072_112_000_000);
        assertEq(pool.totalDebt(), 10);
        assertEq(pool.debtOf(CHARLIE), 11);
        _assertStoredConservation(91);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.repayAll(11);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", CHARLIE, 11);
        _assertPosition(interestPool.storedDebt(CHARLIE), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 102 * Q);
        assertEq(pool.deposits(ALICE), 102);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        _assertStoredConservation(102);

        vm.prank(ALICE);
        pool.withdraw(102);
        assertEq(interestPool.storedAssetsNumerator(), 0);
        assertEq(pool.totalShares(), 0);
        assertEq(pool.shares(ALICE), 0);
        _assertStoredConservation(0);
        vm.warp(block.timestamp + HALF_YEAR);
        _fundRepayment(CHARLIE, 7);
        vm.prank(CHARLIE);
        pool.supply(7);
        assertEq(pool.shares(CHARLIE), 7);
        assertEq(pool.totalShares(), 7);
        assertEq(pool.deposits(CHARLIE), 7);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.debtOf(CHARLIE), 0);
        _assertStoredConservation(7);
    }

    /// @notice raw원금100·미납0.4에서30을 받으면 원금71과 정산 차이0.6만 남기거나 더한다.
    function test_PartialRepaymentRecognizesOnlyFractionalSettlementSurplus() public {
        _resetShares(100, 0);
        interestPool.setAccountedAssetsNumeratorForTest(44_276_544_000_000);
        interestPool.setDebtPositionForTest(BOB, 100, 126_144_000_000, block.timestamp);
        interestPool.setTotalDebtForTest(100, 126_144_000_000, block.timestamp);
        deal(address(usdc), address(pool), 40, true);
        _fundRepayment(BOB, 30);
        _assertStoredConservation(40);
        uint256 beforeAssets = interestPool.storedAssetsNumerator();

        vm.recordLogs();
        vm.prank(BOB);
        pool.repay(30);

        _assertPosition(interestPool.storedDebt(BOB), 71, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 71, 0, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 44_465_760_000_000);
        assertEq(interestPool.storedAssetsNumerator() - beforeAssets, 189_216_000_000);
        assertEq(pool.totalAssets(), 141);
        assertEq(pool.totalDebt(), 71);
        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertStoredConservation(70);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 30);
    }

    /// @notice 완제 견적2는 유효해도 정산 차이가 최대 자산을 넘으면 수령과 새 이자 저장까지 복구한다.
    function test_SettlementSurplusOverflowRestoresTransferAllowanceAndAccrual() public {
        _resetShares(1, 0);
        uint256 maxNumerator = type(uint256).max;
        uint256 remainder = maxNumerator % Q;
        uint256 storedAt = block.timestamp;
        // 1초 뒤 새 이자1000분자를 더하면 정확 자산이 최대값이고 채권은1+나머지/Q다.
        interestPool.setAccountedAssetsNumeratorForTest(maxNumerator - 1_000);
        interestPool.setDebtPositionForTest(BOB, 1, remainder - 1_000, storedAt);
        interestPool.setTotalDebtForTest(1, remainder - 1_000, storedAt);
        uint256 cash = maxNumerator / Q - 1;
        deal(address(usdc), address(pool), cash, true);
        _fundRepayment(BOB, 2);
        _assertStoredConservation(cash);
        vm.warp(storedAt + 1);
        assertEq(pool.debtOf(BOB), 2);
        assertEq(pool.totalAssets(), maxNumerator / Q);
        assertEq(pool.availableLiquidity(), cash);
        bytes memory beforeState = _storedSnapshot();

        vm.recordLogs();
        vm.expectCall(
            address(usdc), abi.encodeWithSignature("transferFrom(address,address,uint256)", BOB, address(pool), 2)
        );
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        vm.prank(BOB);
        pool.repayAll(2);

        _assertStoredUnchanged(beforeState);
        _assertPosition(interestPool.storedDebt(BOB), 1, remainder - 1_000, storedAt);
        _assertPosition(interestPool.storedTotalDebt(), 1, remainder - 1_000, storedAt);
        assertEq(usdc.balanceOf(BOB), 2);
        assertEq(usdc.balanceOf(address(pool)), cash);
        assertEq(usdc.allowance(BOB, address(pool)), 2);
    }

    /// @notice 2초 누적으로 정확 자산이 범위를 넘으면 조회와 완제를 거절하고 토큰 수령 전 저장을 복구한다.
    function test_AccruedAssetsOverflowRejectsViewsAndRepaymentBeforeTransfer() public {
        _resetShares(1, 0);
        uint256 maxNumerator = type(uint256).max;
        uint256 remainder = maxNumerator % Q;
        uint256 storedAt = block.timestamp;
        interestPool.setAccountedAssetsNumeratorForTest(maxNumerator - 1_000);
        interestPool.setDebtPositionForTest(BOB, 1, remainder - 1_000, storedAt);
        interestPool.setTotalDebtForTest(1, remainder - 1_000, storedAt);
        uint256 cash = maxNumerator / Q - 1;
        deal(address(usdc), address(pool), cash, true);
        _fundRepayment(BOB, 2);
        _assertStoredConservation(cash);
        vm.warp(storedAt + 2);
        assertEq(pool.debtOf(BOB), 2);
        assertEq(pool.totalDebt(), 1);
        bytes memory beforeState = _storedSnapshot();
        bytes memory overflow = abi.encodeWithSignature("Panic(uint256)", uint256(0x11));
        // 수령이 먼저 실행되면 이 구별되는 오류가 전파되어 아래 산술 오류 기대를 통과할 수 없다.
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", BOB, address(pool), 2),
            abi.encodeWithSignature("UnexpectedRepaymentTransfer()")
        );

        vm.recordLogs();
        vm.expectRevert(overflow);
        pool.totalAssets();
        vm.expectRevert(overflow);
        pool.availableLiquidity();
        vm.expectRevert(overflow);
        vm.prank(BOB);
        pool.repayAll(2);

        _assertStoredUnchanged(beforeState);
        _assertPosition(interestPool.storedDebt(BOB), 1, remainder - 1_000, storedAt);
        _assertPosition(interestPool.storedTotalDebt(), 1, remainder - 1_000, storedAt);
        assertEq(usdc.balanceOf(BOB), 2);
        assertEq(usdc.balanceOf(address(pool)), cash);
        assertEq(usdc.allowance(BOB, address(pool)), 2);
    }

    /// @notice 같은 반년 이자의 개인 갱신 순서를 바꾸거나 전역을 다시 갱신해도 자산을 중복 인정하지 않는다.
    function test_SameTimestampUpdatesAndBorrowerOrderDoNotDuplicateInterest() public {
        _depositFor(CHARLIE, 1e8);
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.prank(CHARLIE);
        pool.borrow(20e6);
        vm.prank(BOB);
        usdc.approve(address(pool), 1e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 1e6);
        vm.warp(block.timestamp + HALF_YEAR);
        assertEq(pool.totalAssets(), 103e6);
        assertEq(pool.debtOf(BOB), 42e6);
        assertEq(pool.debtOf(CHARLIE), 21e6);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        uint256 checkpoint = vm.snapshotState();

        _repayOneEach(BOB, CHARLIE);
        bytes memory forwardOrder = _interestSnapshot();
        _assertPosition(interestPool.storedDebt(BOB), 40e6, 1e6 * Q, block.timestamp);
        _assertPosition(interestPool.storedDebt(CHARLIE), 20e6, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 60e6, 1e6 * Q, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 103e6 * Q);
        _assertStoredConservation(42e6);

        assertTrue(vm.revertToState(checkpoint));
        _repayOneEach(CHARLIE, BOB);
        assertEq(_interestSnapshot(), forwardOrder);

        _fundRepayment(ALICE, 103);
        vm.startPrank(ALICE);
        pool.supply(103);
        pool.withdraw(103);
        vm.stopPrank();
        assertEq(interestPool.storedAssetsNumerator(), 103e6 * Q);
        assertEq(pool.totalShares(), 100e6);
        _assertPosition(interestPool.storedTotalDebt(), 60e6, 1e6 * Q, block.timestamp);
        _assertStoredConservation(42e6);
    }

    /// @notice 마지막1지분의1 raw 출금 뒤0.5만 남아도 마지막 자산을 버리지 않고 전체 거절한다.
    function test_LastShareCannotLeaveOnlyFractionalAssets() public {
        _resetShares(1, 0);
        interestPool.setAccountedAssetsNumeratorForTest(473_040_000_000);
        // 정상 상환에서는 만들지 않는 미납 전용 경계지만 개인합·전체·현금의 보존식은 맞춘다.
        interestPool.setDebtPositionForTest(BOB, 0, 157_680_000_000, block.timestamp);
        interestPool.setTotalDebtForTest(0, 157_680_000_000, block.timestamp);
        _assertStoredConservation(1);
        assertEq(pool.deposits(ALICE), 1);
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.ResidualAssets.selector, 1));
        vm.prank(ALICE);
        pool.withdraw(1);
        _assertInterestUnchanged(beforeState);
    }

    /// @notice 정상 상환으로 도달하지 않는 원금0·미납0.5 경계도 부채1로 판단해 담보 반환을 막는다.
    function test_InterestOnlyDebtStillPreventsCollateralWithdrawal() public {
        _resetShares(1, 0);
        interestPool.setAccountedAssetsNumeratorForTest(473_040_000_000);
        interestPool.setDebtPositionForTest(BOB, 0, 157_680_000_000, block.timestamp);
        interestPool.setTotalDebtForTest(0, 157_680_000_000, block.timestamp);
        _assertStoredConservation(1);
        assertEq(pool.debtOf(BOB), 1);
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.collateralOf(BOB), 1e8);
        bytes memory beforeState = _interestSnapshot();

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.OutstandingDebt.selector, 1));
        vm.prank(BOB);
        pool.withdrawCollateral(1e8);

        _assertInterestUnchanged(beforeState);
        _assertPosition(interestPool.storedDebt(BOB), 0, 157_680_000_000, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 157_680_000_000, block.timestamp);
    }

    /// @notice 공개 자산·총부채가 모두100이어도 정확 채권이1분자 크면 유동성 조회와 지급을 거절한다.
    function test_OneNumeratorExcessDebtCannotHideBehindEqualRawValues() public {
        _resetShares(100, 0);
        interestPool.setDebtPositionForTest(BOB, 100, 1, block.timestamp);
        interestPool.setTotalDebtForTest(100, 1, block.timestamp);
        assertEq(pool.totalAssets(), 100);
        assertEq(pool.totalDebt(), 100);
        bytes memory beforeState = _storedSnapshot();
        bytes memory expected = abi.encodeWithSelector(LendingPool.InvalidDebtAccounting.selector, 100, 100);

        vm.recordLogs();
        vm.expectRevert(expected);
        pool.availableLiquidity();
        vm.expectRevert(expected);
        vm.prank(ALICE);
        pool.withdraw(1);
        vm.expectRevert(expected);
        vm.prank(BOB);
        pool.borrow(1);
        _assertStoredUnchanged(beforeState);
    }

    /// @dev Alice201·Charlie2지분에 A101.5−D1.5=현금100을 같은 시각으로 주입한다.
    function _prepareFractionalRatio() private {
        _resetShares(201, 2);
        interestPool.setAccountedAssetsNumeratorForTest(32_009_040_000_000);
        interestPool.setDebtPositionForTest(BOB, 1, 157_680_000_000, block.timestamp);
        interestPool.setTotalDebtForTest(1, 157_680_000_000, block.timestamp);
        deal(address(usdc), address(pool), 100, true);
        assertEq(pool.totalShares(), 203);
        assertEq(interestPool.storedAssetsNumerator(), 101 * Q + Q / 2);
        _assertStoredConservation(100);
    }

    /// @dev 기본 준비의 전액 출금 후 실제 공급으로 필요한 작은 지분 수만 만든다.
    function _resetShares(uint256 aliceShares, uint256 charlieShares) private {
        vm.startPrank(ALICE);
        pool.withdraw(100e6);
        usdc.approve(address(pool), aliceShares);
        pool.supply(aliceShares);
        vm.stopPrank();
        if (charlieShares != 0) {
            usdc.mint(CHARLIE, charlieShares);
            vm.startPrank(CHARLIE);
            usdc.approve(address(pool), charlieShares);
            pool.supply(charlieShares);
            vm.stopPrank();
        }
    }

    /// @dev 필요한 토큰만 시험에서 발행하고 같은 수량의 유한 승인을 준비한다.
    function _fundRepayment(address user, uint256 amount) private {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(pool), amount);
    }

    /// @dev 두 사용자의 원금은 유지하며 같은 시각에 각1 USDC를 이자에 먼저 배분한다.
    function _repayOneEach(address first, address second) private {
        vm.prank(first);
        pool.repay(1e6);
        vm.prank(second);
        pool.repay(1e6);
    }

    /// @dev 공개 반올림값 대신 원금·미납 분자·실제 저장 시각을 고정 기대값과 비교한다.
    function _assertPosition(
        DebtLedger.Position memory position,
        uint256 principal,
        uint256 interest,
        uint256 updatedAt
    ) private pure {
        assertEq(position.principal, principal);
        assertEq(position.interestNumerator, interest);
        assertEq(position.updatedAt, updatedAt);
    }

    /// @dev 손상·범위 경계에서도 계산형 조회 없이 실제 저장 장부·지분·토큰·승인을 관측한다.
    function _storedSnapshot() private view returns (bytes memory) {
        uint256[6] memory global = [
            interestPool.storedAssetsNumerator(),
            pool.totalShares(),
            usdc.balanceOf(address(pool)),
            wbtc.balanceOf(address(pool)),
            usdc.totalSupply(),
            wbtc.totalSupply()
        ];
        return abi.encode(
            global,
            interestPool.storedTotalDebt(),
            interestPool.storedDebt(ALICE),
            interestPool.storedDebt(BOB),
            interestPool.storedDebt(CHARLIE),
            _storedParticipant(ALICE),
            _storedParticipant(BOB),
            _storedParticipant(CHARLIE)
        );
    }

    /// @dev 손상된 부채·자산 조회를 호출하지 않고 사용자 소유량과 승인만 읽는다.
    function _storedParticipant(address user) private view returns (uint256[6] memory) {
        return [
            usdc.balanceOf(user),
            wbtc.balanceOf(user),
            usdc.allowance(user, address(pool)),
            wbtc.allowance(user, address(pool)),
            pool.shares(user),
            pool.collateralOf(user)
        ];
    }

    /// @dev 오류 후 실제 저장값을 비교하고 되돌아간 호출의 풀 성공 이벤트가 없음을 확인한다.
    function _assertStoredUnchanged(bytes memory beforeState) private view {
        assertEq(_storedSnapshot(), beforeState);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(pool));
        }
    }

    /// @dev 저장 시각이 현재인 fixture에서 개인합·전체 채권·정확 자산·인정 현금의 일관성을 확인한다.
    function _assertStoredConservation(uint256 cash) private view {
        DebtLedger.Position memory total = interestPool.storedTotalDebt();
        DebtLedger.Position memory bob = interestPool.storedDebt(BOB);
        DebtLedger.Position memory charlie = interestPool.storedDebt(CHARLIE);
        assertEq(total.principal, bob.principal + charlie.principal);
        assertEq(total.interestNumerator, bob.interestNumerator + charlie.interestNumerator);
        assertEq(interestPool.storedAssetsNumerator() - total.principal * Q - total.interestNumerator, cash * Q);
        assertEq(usdc.balanceOf(address(pool)), cash);
        assertEq(pool.availableLiquidity(), cash);
    }
}

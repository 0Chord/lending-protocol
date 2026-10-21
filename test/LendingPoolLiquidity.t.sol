// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BorrowTestBase} from "./helpers/BorrowTestBase.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICollateralPriceSource} from "../src/interfaces/ICollateralPriceSource.sol";

/// @title 정상 경로에서 만들 수 없는 총부채 초과 장부만 주입하는 시험 하네스
contract InvalidDebtAccountingHarness is LendingPool {
    /// @notice 생산 풀과 같은 자산·담보·가격 연결 검사를 거친다.
    constructor(IERC20 asset_, IERC20 collateral_, ICollateralPriceSource price_)
        LendingPool(asset_, collateral_, price_)
    {}

    /// @notice 시험에서만 사용자의 부채와 총부채를 같은 손상 값으로 맞춘다.
    function setDebtForTest(address user, uint256 amount) external {
        debtOf[user] = amount;
        totalDebt = amount;
    }
}

/// @title 원금 부채와 직접 유입을 함께 반영한 공통 현금 한도
contract LendingPoolLiquidityTest is BorrowTestBase {
    /// @notice 직접 transfer20은 공급 지분을 만들지 않고 대출·출금의 사용 가능 현금에서 제외한다.
    function test_DirectTransferSurplusStaysThroughBorrowWithdrawRepayAndNewSupply() public {
        _exerciseSurplusSequence(false);
    }

    /// @notice 풀에 직접 mint20한 경우에도 같은 공통 재원 한도를 적용한다.
    function test_DirectMintSurplusStaysThroughBorrowWithdrawRepayAndNewSupply() public {
        _exerciseSurplusSequence(true);
    }

    /// @notice 충분한 담보 한도140이 있어도 C50·A100·D70에서 추가40은 재원30을 넘는다.
    function test_AdditionalBorrowCannotSpendSurplusEvenWithEnoughCollateral() public {
        _depositFor(BOB, 1e8);
        _addSurplus(false);
        vm.prank(BOB);
        pool.borrow(70e6);
        _assertLiquidityState(50e6, 100e6, 70e6, 100e6, 100e6, 30e6);
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 30e6, 40e6));
        vm.prank(BOB);
        pool.borrow(40e6);
        _assertUnchanged(beforeState);
        assertEq(pool.collateralOf(BOB), 2e8);
    }

    /// @notice 원금 보유자가 USDC20을 직접 보내도 repay가 아니므로 부채70은 줄지 않는다.
    function test_BorrowerDirectTransferDoesNotRepayDebt() public {
        vm.prank(BOB);
        pool.borrow(70e6);
        vm.recordLogs();
        vm.prank(BOB);
        assertTrue(usdc.transfer(address(pool), 20e6));
        _assertLiquidityState(50e6, 100e6, 70e6, 100e6, 100e6, 30e6);
        assertEq(pool.debtOf(BOB), 70e6);
        assertEq(usdc.balanceOf(BOB), 50e6);
        assertEq(usdc.totalSupply(), 100e6);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(pool.shares(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertNoPoolLogs();
    }

    /// @notice 부채 없는 기존 공급도 잉여20을 권리에서 제외하고 다음 첫 공급10을1:1로 인정한다.
    function test_NoDebtFullWithdrawalKeepsSurplusAndNewSupplyOneToOne() public {
        _addSurplus(true);
        _assertLiquidityState(120e6, 100e6, 0, 100e6, 100e6, 100e6);
        vm.prank(ALICE);
        pool.withdraw(100e6);
        _assertLiquidityState(20e6, 0, 0, 0, 0, 0);
        _supplyCharlieTen();
        _assertLiquidityState(30e6, 10e6, 0, 10e6, 0, 10e6);
        assertEq(pool.shares(CHARLIE), 10e6);
        assertEq(pool.deposits(CHARLIE), 10e6);
        assertEq(pool.deposits(ALICE), 0);
        assertEq(usdc.totalSupply(), 130e6);
    }

    /// @notice 잉여20만 남은 빈 장부는 충분한 담보가 있어도 차입할 재원이0이다.
    function test_EmptyAccountingWithSurplusRejectsBorrowAndRecognizesOnlyNewSupply() public {
        vm.prank(ALICE);
        pool.withdraw(100e6);
        _addSurplus(false);
        _assertLiquidityState(20e6, 0, 0, 0, 0, 0);
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 0, 1));
        vm.prank(BOB);
        pool.borrow(1);
        _assertUnchanged(beforeState);
        _supplyCharlieTen();
        _assertLiquidityState(30e6, 10e6, 0, 10e6, 0, 10e6);
        assertEq(pool.shares(CHARLIE), 10e6);
        assertEq(pool.deposits(CHARLIE), 10e6);
    }

    /// @notice 직접 WBTC 전송도 보낸 사람의 담보로 기록되지 않아 대출 한도0을 유지한다.
    function test_DirectCollateralTransferDoesNotCreateBorrowingRights() public {
        wbtc.mint(CHARLIE, 1e8);
        vm.recordLogs();
        vm.prank(CHARLIE);
        assertTrue(wbtc.transfer(address(pool), 1e8));
        _assertNoPoolLogs();
        assertEq(wbtc.balanceOf(address(pool)), 2e8);
        assertEq(wbtc.balanceOf(CHARLIE), 0);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(pool.collateralOf(CHARLIE), 0);
        assertEq(wbtc.totalSupply(), 2e8);
        _assertLiquidityState(100e6, 100e6, 0, 100e6, 100e6, 100e6);
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, 0, 0, 1));
        vm.prank(CHARLIE);
        pool.borrow(1);
        _assertUnchanged(beforeState);
    }

    /// @notice 현금을10으로 줄인 손실 상태에서는 한도 여유가 있어도11을 거절하고10만 대출한다.
    function test_BorrowUsesLowerActualCashAfterLoss() public {
        _prepareCashLoss();
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 10e6, 11e6));
        vm.prank(BOB);
        pool.borrow(11e6);
        _assertUnchanged(beforeState);

        vm.recordLogs();
        vm.prank(BOB);
        pool.borrow(10e6);
        _assertLiquidityState(0, 100e6, 80e6, 100e6, 100e6, 0);
        assertEq(usdc.balanceOf(BOB), 80e6);
        assertEq(usdc.totalSupply(), 80e6);
        assertEq(pool.collateralOf(BOB), 2e8);
        _assertEvent(vm.getRecordedLogs(), "Borrowed(address,uint256)", BOB, 10e6);
    }

    /// @notice 같은 손실 상태에서 출금11은 거절하고10만 지급하며 손실을 자동 상각하지 않는다.
    function test_WithdrawalUsesLowerActualCashAfterLoss() public {
        _prepareCashLoss();
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 10e6, 11e6));
        vm.prank(ALICE);
        pool.withdraw(11e6);
        _assertUnchanged(beforeState);

        vm.recordLogs();
        vm.prank(ALICE);
        pool.withdraw(10e6);
        _assertLiquidityState(0, 90e6, 70e6, 90e6, 90e6, 0);
        assertEq(usdc.balanceOf(ALICE), 10e6);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(usdc.totalSupply(), 80e6);
        assertEq(pool.collateralOf(BOB), 2e8);
        _assertEvent(vm.getRecordedLogs(), "Withdrawn(address,uint256)", ALICE, 10e6);
    }

    /// @notice 재원도 부족한 출금이라도 본인 권리100을 넘는101은 기존 예치권리 오류가 먼저다.
    function test_WithdrawalRightsErrorPrecedesCommonLiquidityError() public {
        _prepareCashLoss();
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientDeposit.selector, 100e6, 101e6));
        vm.prank(ALICE);
        pool.withdraw(101e6);
        _assertUnchanged(beforeState);
    }

    /// @notice D101>A100은 재원0이나 뺄셈panic으로 숨기지 않고 손상 장부 오류로 드러낸다.
    function test_TotalDebtAboveAssetsRaisesAccountingErrorWithoutMutation() public {
        _prepareInvalidDebtAccounting();
        bytes memory beforeState = _snapshotWithoutLiquidity();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InvalidDebtAccounting.selector, 100e6, 101e6));
        pool.availableLiquidity();
        assertEq(_snapshotWithoutLiquidity(), beforeState);
        _assertNoPoolLogs();

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InvalidDebtAccounting.selector, 100e6, 101e6));
        vm.prank(ALICE);
        pool.withdraw(1);
        assertEq(_snapshotWithoutLiquidity(), beforeState);
        _assertNoPoolLogs();
    }

    /// @notice 담보2·부채70을 정상 생성한 뒤 현금만30에서10으로 조정하고 총발행량80을 고정한다.
    function _prepareCashLoss() internal {
        _depositFor(BOB, 1e8);
        vm.prank(BOB);
        pool.borrow(70e6);
        deal(address(usdc), address(pool), 10e6, true);
        _assertLiquidityState(10e6, 100e6, 70e6, 100e6, 100e6, 10e6);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(usdc.totalSupply(), 80e6);
        assertEq(pool.collateralOf(BOB), 2e8);
    }

    /// @notice 기존 토큰을 정상 반환받아 하네스에 공급·담보를 준비한 뒤 부채만 손상시킨다.
    function _prepareInvalidDebtAccounting() internal {
        vm.prank(ALICE);
        pool.withdraw(100e6);
        vm.prank(BOB);
        pool.withdrawCollateral(1e8);
        InvalidDebtAccountingHarness harness = new InvalidDebtAccountingHarness(usdc, wbtc, price);
        pool = harness;
        vm.startPrank(ALICE);
        usdc.approve(address(pool), 100e6);
        pool.supply(100e6);
        vm.stopPrank();
        vm.startPrank(BOB);
        wbtc.approve(address(pool), 1e8);
        pool.depositCollateral(1e8);
        vm.stopPrank();
        harness.setDebtForTest(BOB, 101e6);
    }

    /// @notice 지분 장부는 유효하고 부채만 손상된 사례에서 오류를 내는 유동성 조회를 제외한다.
    function _snapshotWithoutLiquidity() internal view returns (bytes memory) {
        uint256[7] memory global = [
            pool.totalAssets(),
            pool.totalShares(),
            pool.totalDebt(),
            usdc.balanceOf(address(pool)),
            wbtc.balanceOf(address(pool)),
            usdc.totalSupply(),
            wbtc.totalSupply()
        ];
        return
            abi.encode(
                global, _participant(ALICE), _participant(BOB), _participant(CHARLIE), _participant(address(usdc))
            );
    }

    /// @notice transfer와 mint를 별도 준비로 실행하고 명세의 각 단계 고정값을 대조한다.
    function _exerciseSurplusSequence(bool mintToPool) internal {
        _addSurplus(mintToPool);
        _assertLiquidityState(120e6, 100e6, 0, 100e6, 100e6, 100e6);
        assertEq(pool.shares(BOB), 0);
        assertEq(pool.shares(CHARLIE), 0);

        vm.recordLogs();
        vm.prank(BOB);
        pool.borrow(70e6);
        _assertLiquidityState(50e6, 100e6, 70e6, 100e6, 100e6, 30e6);
        assertEq(usdc.balanceOf(BOB), 70e6);
        _assertEvent(vm.getRecordedLogs(), "Borrowed(address,uint256)", BOB, 70e6);

        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 30e6, 40e6));
        vm.prank(ALICE);
        pool.withdraw(40e6);
        _assertUnchanged(beforeState);

        vm.recordLogs();
        vm.prank(ALICE);
        pool.withdraw(30e6);
        _assertLiquidityState(20e6, 70e6, 70e6, 70e6, 70e6, 0);
        assertEq(usdc.balanceOf(ALICE), 30e6);
        _assertEvent(vm.getRecordedLogs(), "Withdrawn(address,uint256)", ALICE, 30e6);

        vm.prank(BOB);
        usdc.approve(address(pool), 70e6);
        vm.recordLogs();
        vm.prank(BOB);
        pool.repay(70e6);
        _assertLiquidityState(90e6, 70e6, 0, 70e6, 70e6, 70e6);
        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 70e6);

        vm.recordLogs();
        vm.prank(ALICE);
        pool.withdraw(70e6);
        _assertLiquidityState(20e6, 0, 0, 0, 0, 0);
        assertEq(usdc.balanceOf(ALICE), 100e6);
        assertEq(usdc.totalSupply(), 120e6);
        _assertEvent(vm.getRecordedLogs(), "Withdrawn(address,uint256)", ALICE, 70e6);

        _supplyCharlieTen();
        _assertLiquidityState(30e6, 10e6, 0, 10e6, 0, 10e6);
        assertEq(pool.shares(CHARLIE), 10e6);
        assertEq(pool.deposits(CHARLIE), 10e6);
        assertEq(usdc.totalSupply(), 130e6);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(pool.collateralOf(CHARLIE), 0);
        assertEq(wbtc.balanceOf(address(pool)), 1e8);
        assertEq(wbtc.totalSupply(), 1e8);
    }

    /// @notice 직접 유입은 공급 호출 없이 넣으며 공급자·기부자 기록을 새로 만들지 않는다.
    function _addSurplus(bool mintToPool) internal {
        vm.recordLogs();
        if (mintToPool) {
            usdc.mint(address(pool), 20e6);
        } else {
            usdc.mint(CHARLIE, 20e6);
            vm.prank(CHARLIE);
            assertTrue(usdc.transfer(address(pool), 20e6));
        }
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.deposits(CHARLIE), 0);
        assertEq(pool.debtOf(CHARLIE), 0);
        assertEq(usdc.totalSupply(), 120e6);
        _assertNoPoolLogs();
    }

    /// @notice 장부가 빈 뒤 새 공급자의 정상 입금10만 공급 권리로 만든다.
    function _supplyCharlieTen() internal {
        usdc.mint(CHARLIE, 10e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 10e6);
        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.supply(10e6);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        _assertEvent(vm.getRecordedLogs(), "Supplied(address,uint256)", CHARLIE, 10e6);
    }

    /// @notice 현금·인정자산·총부채·지분·가용현금을 독립적인 단계별 숫자와 비교한다.
    function _assertLiquidityState(
        uint256 cash,
        uint256 assets,
        uint256 debt,
        uint256 totalShareAmount,
        uint256 aliceShares,
        uint256 available
    ) internal view {
        assertEq(usdc.balanceOf(address(pool)), cash);
        assertEq(pool.totalAssets(), assets);
        assertEq(pool.totalDebt(), debt);
        assertEq(pool.debtOf(BOB), debt);
        assertEq(pool.debtOf(ALICE), 0);
        assertEq(pool.debtOf(CHARLIE), 0);
        assertEq(pool.totalShares(), totalShareAmount);
        assertEq(pool.shares(ALICE), aliceShares);
        assertEq(pool.deposits(ALICE), aliceShares);
        assertEq(pool.shares(BOB), 0);
        assertEq(pool.availableLiquidity(), available);
    }

    /// @notice 직접 토큰 이동은 공급·상환 등 풀의 성공 이벤트를 발생시키지 않는다.
    function _assertNoPoolLogs() internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(pool));
        }
    }
}

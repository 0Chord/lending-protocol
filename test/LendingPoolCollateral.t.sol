// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {CollateralTestBase} from "./helpers/CollateralTestBase.sol";

/// @title 본인 WBTC 담보 입금·반환과 USDC 장부 분리 검증
/// @notice 토큰 이동과 기록의 연결을 고정 수량으로 비교한다.
contract LendingPoolCollateralTest is CollateralTestBase {
    /// @notice 두 자산 주소를 배포 입력대로 고정하고 담보를 빈 기록으로 시작한다.
    function test_ConstructorFixesSeparateAssets() public view {
        assertEq(address(pool.asset()), address(usdc));
        assertEq(address(pool.collateralAsset()), address(wbtc));
        assertEq(pool.collateralOf(ALICE), 0);
        assertEq(pool.collateralOf(BOB), 0);
    }

    /// @notice 정상 USDC를 전달해 담보 0 주소만의 오류를 확인한다.
    function test_ConstructorRejectsZeroCollateral() public {
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InvalidCollateralAsset.selector, address(0)));
        new LendingPool(usdc, IERC20(address(0)), priceSource);
    }

    /// @notice 정상 USDC와 구분해 코드 없는 담보 주소의 배포를 거절한다.
    function test_ConstructorRejectsCollateralWithoutCode() public {
        assertEq(BOB.code.length, 0);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InvalidCollateralAsset.selector, BOB));
        new LendingPool(usdc, IERC20(BOB), priceSource);
    }

    /// @notice 코드 있는 같은 계약을 두 자산으로 연결하면 주소 구분 오류를 낸다.
    function test_ConstructorRejectsIdenticalAssetContracts() public {
        vm.expectRevert(abi.encodeWithSelector(LendingPool.IdenticalAssets.selector, address(usdc)));
        new LendingPool(usdc, usdc, priceSource);
    }

    /// @notice 1 WBTC 승인 입금은 Bob·풀·기록에만 반영하고 USDC 상태를 보존한다.
    function test_DepositMovesWBTCAndCreditsOnlyCaller() public {
        uint256[12] memory beforeCash = _usdcState();
        vm.prank(BOB);
        wbtc.approve(address(pool), 100_000_000);

        vm.recordLogs();
        vm.prank(BOB);
        pool.depositCollateral(100_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(wbtc.balanceOf(BOB), 100_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 100_000_000);
        assertEq(pool.collateralOf(BOB), 100_000_000);
        assertEq(pool.collateralOf(ALICE), 0);
        assertEq(wbtc.allowance(BOB, address(pool)), 0);
        assertEq(wbtc.totalSupply(), 200_000_000);
        _assertUSDCUnchanged(beforeCash);
        _assertCollateralEvent(logs, DEPOSITED, BOB, 100_000_000);
    }

    /// @notice 담보가 비었거나 기존 입금이 있어도 0 입금은 먼저 거절하고 상태를 유지한다.
    function test_ZeroDepositRevertsForEmptyAndExistingCollateral() public {
        for (uint256 i; i < 2; ++i) {
            if (i == 1) _deposit(BOB, 100_000_000);
            uint256[20] memory beforeState = _state();
            vm.recordLogs();
            vm.expectRevert(LendingPool.ZeroAmount.selector);
            vm.prank(BOB);
            pool.depositCollateral(0);
            _assertUnchanged(beforeState);
            _assertNoProtocolEvents(vm.getRecordedLogs());
        }
    }

    /// @notice 잔고가 충분해도 승인량이 1 부족하면 정확한 승인 오류로 상태를 보존한다.
    function test_DepositRejectsInsufficientAllowance() public {
        vm.prank(BOB);
        wbtc.approve(address(pool), 99_999_999);
        uint256[20] memory beforeState = _state();
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(pool),
                uint256(99_999_999),
                uint256(100_000_000)
            )
        );
        vm.prank(BOB);
        pool.depositCollateral(100_000_000);
        _assertUnchanged(beforeState);
        _assertNoProtocolEvents(vm.getRecordedLogs());
    }

    /// @notice 추가 입금은 요청량만 누적하고 서로 다른 주소의 담보를 섞지 않는다.
    function test_AdditionalDepositsKeepUsersSeparate() public {
        uint256[12] memory beforeCash = _usdcState();
        _deposit(BOB, 100_000_000);
        vm.recordLogs();
        _deposit(BOB, 20_000_000);
        _assertCollateralEvent(vm.getRecordedLogs(), DEPOSITED, BOB, 20_000_000);
        assertEq(pool.collateralOf(BOB), 120_000_000);
        assertEq(wbtc.balanceOf(BOB), 80_000_000);
        wbtc.mint(ALICE, 30_000_000);
        _deposit(ALICE, 30_000_000);
        assertEq(pool.collateralOf(ALICE), 30_000_000);
        assertEq(pool.collateralOf(BOB), 120_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 150_000_000);
        assertEq(wbtc.balanceOf(ALICE), 0);
        assertEq(wbtc.totalSupply(), 230_000_000);
        _assertUSDCUnchanged(beforeCash);
    }

    /// @notice 양수 최소 단위 1도 단위 환산이나 반올림 없이 입금한다.
    function test_DepositAcceptsOneSmallestUnit() public {
        _deposit(BOB, 1);
        assertEq(wbtc.balanceOf(BOB), 199_999_999);
        assertEq(wbtc.balanceOf(address(pool)), 1);
        assertEq(pool.collateralOf(BOB), 1);
        assertEq(wbtc.allowance(BOB, address(pool)), 0);
    }

    /// @notice 무제한 승인 입금은 고정 ERC20의 max 승인 유지 규칙을 따른다.
    function test_DepositKeepsUnlimitedAllowance() public {
        vm.startPrank(BOB);
        wbtc.approve(address(pool), type(uint256).max);
        pool.depositCollateral(100_000_000);
        vm.stopPrank();
        assertEq(pool.collateralOf(BOB), 100_000_000);
        assertEq(wbtc.allowance(BOB, address(pool)), type(uint256).max);
        assertEq(wbtc.balanceOf(BOB), 100_000_000);
    }

    /// @notice 새 승인 없이 0.4와 남은0.6 WBTC를 본인에게 돌려주고 USDC 상태는 유지한다.
    function test_PartialAndFullReturnNeedNoNewApproval() public {
        _deposit(BOB, 100_000_000);
        uint256[12] memory beforeCash = _usdcState();
        assertEq(wbtc.allowance(BOB, address(pool)), 0);
        vm.recordLogs();
        vm.prank(BOB);
        pool.withdrawCollateral(40_000_000);
        _assertCollateralEvent(vm.getRecordedLogs(), RETURNED, BOB, 40_000_000);
        assertEq(wbtc.balanceOf(BOB), 140_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 60_000_000);
        assertEq(pool.collateralOf(BOB), 60_000_000);
        assertEq(pool.collateralOf(ALICE), 0);
        assertEq(wbtc.allowance(BOB, address(pool)), 0);
        assertEq(wbtc.totalSupply(), 200_000_000);
        _assertUSDCUnchanged(beforeCash);

        vm.recordLogs();
        vm.prank(BOB);
        pool.withdrawCollateral(60_000_000);
        _assertCollateralEvent(vm.getRecordedLogs(), RETURNED, BOB, 60_000_000);
        assertEq(wbtc.balanceOf(BOB), 200_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 0);
        assertEq(pool.collateralOf(BOB), 0);
        assertEq(wbtc.allowance(BOB, address(pool)), 0);
        assertEq(wbtc.totalSupply(), 200_000_000);
        _assertUSDCUnchanged(beforeCash);
    }

    /// @notice 빈 담보와 기존 담보 모두 0 반환은 권리·풀 잔고 검사보다 먼저 거절한다.
    function test_ZeroReturnRevertsForEmptyAndExistingCollateral() public {
        for (uint256 i; i < 2; ++i) {
            if (i == 1) _deposit(BOB, 100_000_000);
            uint256[20] memory beforeState = _state();
            vm.recordLogs();
            vm.expectRevert(LendingPool.ZeroAmount.selector);
            vm.prank(BOB);
            pool.withdrawCollateral(0);
            _assertUnchanged(beforeState);
            _assertNoProtocolEvents(vm.getRecordedLogs());
        }
    }

    /// @notice 풀 잔고가 충분해도 본인 기록 초과와 타인 담보 반환을 정확한 권리 오류로 거절한다.
    function test_ReturnRejectsAboveOwnRecordAndOtherUsersCollateral() public {
        _deposit(BOB, 100_000_000);
        vm.prank(BOB);
        pool.withdrawCollateral(40_000_000);
        wbtc.mint(address(pool), 100_000_000);
        uint256[20] memory beforeState = _state();
        assertEq(wbtc.balanceOf(address(pool)), 160_000_000);
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                LendingPool.InsufficientCollateral.selector, uint256(60_000_000), uint256(60_000_001)
            )
        );
        vm.prank(BOB);
        pool.withdrawCollateral(60_000_001);
        _assertUnchanged(beforeState);
        _assertNoProtocolEvents(vm.getRecordedLogs());

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCollateral.selector, uint256(0), uint256(1)));
        vm.prank(ALICE);
        pool.withdrawCollateral(1);
        _assertUnchanged(beforeState);
        _assertNoProtocolEvents(vm.getRecordedLogs());
    }

    /// @notice 반환은 남은 유한 승인과 무제한 승인을 모두 소비하지 않는다.
    function test_ReturnKeepsFiniteAndUnlimitedAllowances() public {
        _deposit(BOB, 100_000_000);
        uint256[12] memory beforeCash = _usdcState();
        uint256[2] memory approvals = [uint256(7_000_000), type(uint256).max];
        for (uint256 i; i < approvals.length; ++i) {
            vm.startPrank(BOB);
            wbtc.approve(address(pool), approvals[i]);
            pool.withdrawCollateral(40_000_000);
            vm.stopPrank();
            assertEq(wbtc.allowance(BOB, address(pool)), approvals[i]);
            _assertUSDCUnchanged(beforeCash);
        }
        assertEq(wbtc.balanceOf(BOB), 180_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 20_000_000);
        assertEq(pool.collateralOf(BOB), 20_000_000);
        assertEq(wbtc.totalSupply(), 200_000_000);
    }

    /// @notice 최소 단위1을 입금하고 그대로 반환해도 수량 손실이나 USDC 변화가 없다.
    function test_ReturnsOneSmallestUnitExactly() public {
        uint256[12] memory beforeCash = _usdcState();
        _deposit(BOB, 1);
        vm.prank(BOB);
        pool.withdrawCollateral(1);
        assertEq(wbtc.balanceOf(BOB), 200_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 0);
        assertEq(pool.collateralOf(BOB), 0);
        assertEq(wbtc.totalSupply(), 200_000_000);
        _assertUSDCUnchanged(beforeCash);
    }

    /// @notice 같은 사용자의 USDC 공급·출금도 Alice/Bob의 0이 아닌 WBTC 기록을 건드리지 않는다.
    function test_USDCSupplyAndWithdrawalPreserveNonzeroCollateral() public {
        _deposit(BOB, 120_000_000);
        wbtc.mint(ALICE, 30_000_000);
        _deposit(ALICE, 30_000_000);
        uint256[20] memory beforeState = _state();
        vm.recordLogs();
        vm.startPrank(ALICE);
        usdc.approve(address(pool), 10_000_000);
        pool.supply(10_000_000);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countEvents(logs, SUPPLIED), 1);
        assertEq(_countEvents(logs, DEPOSITED), 0);
        assertEq(_countEvents(logs, RETURNED), 0);
        assertEq(pool.deposits(ALICE), 110_000_000);
        assertEq(pool.totalAssets(), 110_000_000);
        assertEq(pool.totalShares(), 110_000_000);
        uint256[20] memory afterSupply = _state();
        for (uint256 i = 12; i < afterSupply.length; ++i) {
            assertEq(afterSupply[i], beforeState[i]);
        }

        vm.recordLogs();
        vm.prank(ALICE);
        pool.withdraw(10_000_000);
        logs = vm.getRecordedLogs();
        assertEq(_countEvents(logs, WITHDRAWN), 1);
        assertEq(_countEvents(logs, DEPOSITED), 0);
        assertEq(_countEvents(logs, RETURNED), 0);
        assertEq(pool.deposits(ALICE), 100_000_000);
        _assertUnchanged(beforeState);

        uint256[12] memory beforeCash = _usdcState();
        vm.prank(ALICE);
        pool.withdrawCollateral(30_000_000);
        assertEq(pool.collateralOf(ALICE), 0);
        assertEq(pool.collateralOf(BOB), 120_000_000);
        assertEq(wbtc.balanceOf(ALICE), 30_000_000);
        _assertUSDCUnchanged(beforeCash);
    }

    /// @notice 풀로 직접 송금한 WBTC는 전액 정상 반환 뒤에도 잉여로 남는다.
    function test_DirectTransferDoesNotCreateReturnRights() public {
        _assertDirectInflow(false);
    }

    /// @notice 풀로 직접 발행한 WBTC도 본인이나 다른 사람의 담보 기록이 되지 않는다.
    function test_DirectMintDoesNotCreateReturnRights() public {
        _assertDirectInflow(true);
    }

    /// @notice 직접 유입과 정상 입금을 분리해 기록 권리·발행량·잔여 잉여를 고정값으로 비교한다.
    function _assertDirectInflow(bool mintToPool) private {
        _deposit(BOB, 100_000_000);
        if (!mintToPool) wbtc.mint(ALICE, 20_000_000);
        uint256 supplyBefore = wbtc.totalSupply();
        uint256[12] memory beforeCash = _usdcState();
        vm.recordLogs();
        if (mintToPool) {
            wbtc.mint(address(pool), 20_000_000);
        } else {
            vm.prank(ALICE);
            assertTrue(wbtc.transfer(address(pool), 20_000_000));
        }
        _assertNoProtocolEvents(vm.getRecordedLogs());
        assertEq(wbtc.totalSupply(), mintToPool ? supplyBefore + 20_000_000 : supplyBefore);
        assertEq(pool.collateralOf(BOB), 100_000_000);
        assertEq(pool.collateralOf(ALICE), 0);
        assertEq(wbtc.balanceOf(address(pool)), 120_000_000);
        _assertUSDCUnchanged(beforeCash);
        vm.prank(BOB);
        pool.withdrawCollateral(100_000_000);
        assertEq(wbtc.balanceOf(BOB), 200_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 20_000_000);
        assertEq(pool.collateralOf(BOB), 0);
        assertEq(wbtc.totalSupply(), 220_000_000);
        _assertUSDCUnchanged(beforeCash);
        uint256[20] memory beforeState = _state();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCollateral.selector, uint256(0), uint256(1)));
        vm.prank(BOB);
        pool.withdrawCollateral(1);
        _assertUnchanged(beforeState);
        _assertNoProtocolEvents(vm.getRecordedLogs());
    }
}

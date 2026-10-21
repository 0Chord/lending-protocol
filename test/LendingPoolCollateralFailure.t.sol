// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockWBTC} from "../src/mocks/MockWBTC.sol";
import {CollateralTestBase} from "./helpers/CollateralTestBase.sol";
import {FailingMockWBTC} from "./mocks/FailingMockWBTC.sol";

/// @title 담보 장부 합산 범위만 검증하는 테스트 전용 풀
/// @notice 정상 토큰 전송으로 만들 수 없는 최대 기록을 산술 실패 사례에만 주입한다.
contract CollateralOverflowHarness is LendingPool {
    /// @notice 일반 풀과 같은 두 자산 검사를 거쳐 하네스를 배포한다.
    constructor(IERC20 asset_, IERC20 collateralAsset_) LendingPool(asset_, collateralAsset_) {}

    /// @notice 산술 실패 테스트에 한해 담보 기록을 직접 준비한다.
    function setCollateralForTest(address user, uint256 amount) external {
        _collateralBalances[user] = amount;
    }
}

/// @title 담보 전송 실패와 전체 복구의 고정 수량 검증
/// @notice 토큰 자체의 false와 풀의 revert를 구별하고 실패 뒤 같은 요청의 재시도를 확인한다.
contract LendingPoolCollateralFailureTest is CollateralTestBase {
    /// @notice 매 사례에서 Alice100 USDC 공급·Bob2 WBTC와 독립 장애 대역을 준비한다.
    function setUp() public override {
        _preparePool(new MockUSDC(), new FailingMockWBTC());
    }

    /// @notice raw false 자체는 revert가 아니므로 전송과 유한 승인 소비가 실제 남는지 확인한다.
    function testRawTransferFromFalseStillMovesWBTCAndConsumesFiniteAllowance() public {
        FailingMockWBTC token = FailingMockWBTC(address(wbtc));
        vm.prank(BOB);
        token.approve(address(pool), 100_000_000);
        uint256[12] memory cashBefore = _usdcState();
        token.setFailureMode(FailingMockWBTC.FailureMode.ReturnFalse);

        vm.recordLogs();
        vm.prank(address(pool));
        bool transferred = token.transferFrom(BOB, address(pool), 100_000_000);

        assertFalse(transferred);
        assertEq(token.balanceOf(BOB), 100_000_000);
        assertEq(token.balanceOf(address(pool)), 100_000_000);
        assertEq(token.allowance(BOB, address(pool)), 0);
        assertEq(token.totalSupply(), 200_000_000);
        assertEq(pool.collateralOf(BOB), 0);
        assertEq(pool.collateralOf(ALICE), 0);
        _assertUSDCUnchanged(cashBefore);
        _assertNoProtocolEvents(vm.getRecordedLogs());
    }

    /// @notice raw transfer의 false도 실제 이동을 남기며 transfer는 기존 승인을 소비하지 않는다.
    function testRawTransferFalseStillMovesWBTCWithoutConsumingAllowance() public {
        FailingMockWBTC token = FailingMockWBTC(address(wbtc));
        vm.prank(BOB);
        token.approve(address(pool), 77_000_000);
        uint256[12] memory cashBefore = _usdcState();
        token.setTransferFailureMode(FailingMockWBTC.FailureMode.ReturnFalse);

        vm.recordLogs();
        vm.prank(BOB);
        bool transferred = token.transfer(address(pool), 100_000_000);

        assertFalse(transferred);
        assertEq(token.balanceOf(BOB), 100_000_000);
        assertEq(token.balanceOf(address(pool)), 100_000_000);
        assertEq(token.allowance(BOB, address(pool)), 77_000_000);
        assertEq(token.totalSupply(), 200_000_000);
        assertEq(pool.collateralOf(BOB), 0);
        assertEq(pool.collateralOf(ALICE), 0);
        _assertUSDCUnchanged(cashBefore);
        _assertNoProtocolEvents(vm.getRecordedLogs());
    }

    /// @notice 실제 입금 뒤 false는 SafeERC20 오류로 전체 복구되고 같은 재시도는 한 번만 반영된다.
    function testDepositFalseRestoresAllStateAndRetryConsumesOnlyRequestedAllowance() public {
        _prepareOtherCollateralAndApprovals();
        FailingMockWBTC token = FailingMockWBTC(address(wbtc));
        token.setFailureMode(FailingMockWBTC.FailureMode.ReturnFalse);
        uint256[20] memory beforeState = _state();
        uint256[12] memory cashBefore = _usdcState();

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(BOB);
        pool.depositCollateral(20_000_000);
        _assertUnchanged(beforeState);
        _assertNoProtocolEvents(vm.getRecordedLogs());

        token.setFailureMode(FailingMockWBTC.FailureMode.None);
        _retryDepositAndAssert(cashBefore);
    }

    /// @notice 실제 입금 뒤 토큰의 고정 오류를 전파하고 승인·기록 복구 뒤 동일 입금을 허용한다.
    function testDepositRevertRestoresAllStateAndRetryConsumesOnlyRequestedAllowance() public {
        _prepareOtherCollateralAndApprovals();
        FailingMockWBTC token = FailingMockWBTC(address(wbtc));
        token.setFailureMode(FailingMockWBTC.FailureMode.Revert);
        uint256[20] memory beforeState = _state();
        uint256[12] memory cashBefore = _usdcState();

        vm.recordLogs();
        vm.expectRevert(FailingMockWBTC.InjectedCollateralTransferFailure.selector);
        vm.prank(BOB);
        pool.depositCollateral(20_000_000);
        _assertUnchanged(beforeState);
        _assertNoProtocolEvents(vm.getRecordedLogs());

        token.setFailureMode(FailingMockWBTC.FailureMode.None);
        _retryDepositAndAssert(cashBefore);
    }

    /// @notice 반환 전 선차감과 실제 이동 뒤 false를 함께 복구하고 재시도에서도 승인을 보존한다.
    function testWithdrawalFalseRestoresAllStateAndRetryDoesNotConsumeAllowance() public {
        _prepareOtherCollateralAndApprovals();
        FailingMockWBTC token = FailingMockWBTC(address(wbtc));
        token.setTransferFailureMode(FailingMockWBTC.FailureMode.ReturnFalse);
        uint256[20] memory beforeState = _state();
        uint256[12] memory cashBefore = _usdcState();

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(BOB);
        pool.withdrawCollateral(40_000_000);
        _assertUnchanged(beforeState);
        _assertNoProtocolEvents(vm.getRecordedLogs());

        token.setTransferFailureMode(FailingMockWBTC.FailureMode.None);
        _retryWithdrawalAndAssert(cashBefore);
    }

    /// @notice 반환 전 선차감과 실제 이동 뒤 토큰 오류를 함께 복구하고 동일 반환을 한 번 실행한다.
    function testWithdrawalRevertRestoresAllStateAndRetryDoesNotConsumeAllowance() public {
        _prepareOtherCollateralAndApprovals();
        FailingMockWBTC token = FailingMockWBTC(address(wbtc));
        token.setTransferFailureMode(FailingMockWBTC.FailureMode.Revert);
        uint256[20] memory beforeState = _state();
        uint256[12] memory cashBefore = _usdcState();

        vm.recordLogs();
        vm.expectRevert(FailingMockWBTC.InjectedCollateralTransferFailure.selector);
        vm.prank(BOB);
        pool.withdrawCollateral(40_000_000);
        _assertUnchanged(beforeState);
        _assertNoProtocolEvents(vm.getRecordedLogs());

        token.setTransferFailureMode(FailingMockWBTC.FailureMode.None);
        _retryWithdrawalAndAssert(cashBefore);
    }

    /// @notice 승인 소비 다음 잔고 부족이어도 새 승인100과 기존 담보40이 모두 복구되어야 한다.
    function testInsufficientBobBalanceRestoresConsumedAllowanceAndExistingCollateral() public {
        usdc = new MockUSDC();
        wbtc = new FailingMockWBTC();
        pool = new LendingPool(usdc, wbtc);
        usdc.mint(ALICE, 200_000_000);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), 100_000_000);
        pool.supply(100_000_000);
        vm.stopPrank();
        wbtc.mint(BOB, 139_000_000);
        _deposit(BOB, 40_000_000);
        vm.prank(BOB);
        wbtc.approve(address(pool), 100_000_000);
        assertEq(wbtc.balanceOf(BOB), 99_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 40_000_000);
        assertEq(pool.collateralOf(BOB), 40_000_000);
        assertEq(wbtc.totalSupply(), 139_000_000);
        uint256[20] memory beforeState = _state();

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 99_000_000, 100_000_000)
        );
        vm.prank(BOB);
        pool.depositCollateral(100_000_000);

        _assertUnchanged(beforeState);
        assertEq(wbtc.allowance(BOB, address(pool)), 100_000_000);
        _assertNoProtocolEvents(vm.getRecordedLogs());
    }

    /// @notice 시험에서 줄인 실제 풀 잔고 때문에 반환이 실패하면 장부를 복구하고 재원 복원 뒤 재시도한다.
    function testInsufficientPoolBalanceRestoresCollateralAndRetryAfterMintSucceeds() public {
        _deposit(BOB, 100_000_000);
        deal(address(wbtc), address(pool), 50_000_000, true);
        assertEq(wbtc.balanceOf(BOB), 100_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 50_000_000);
        assertEq(pool.collateralOf(BOB), 100_000_000);
        assertEq(wbtc.totalSupply(), 150_000_000);
        uint256[20] memory beforeState = _state();
        uint256[12] memory cashBefore = _usdcState();

        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(pool), 50_000_000, 60_000_000
            )
        );
        vm.prank(BOB);
        pool.withdrawCollateral(60_000_000);
        _assertUnchanged(beforeState);
        _assertNoProtocolEvents(vm.getRecordedLogs());

        wbtc.mint(address(pool), 50_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 100_000_000);
        assertEq(wbtc.totalSupply(), 200_000_000);
        vm.recordLogs();
        vm.prank(BOB);
        pool.withdrawCollateral(60_000_000);

        assertEq(wbtc.balanceOf(BOB), 160_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 40_000_000);
        assertEq(pool.collateralOf(BOB), 40_000_000);
        assertEq(pool.collateralOf(ALICE), 0);
        assertEq(wbtc.allowance(BOB, address(pool)), 0);
        assertEq(wbtc.totalSupply(), 200_000_000);
        _assertUSDCUnchanged(cashBefore);
        _assertCollateralEvent(vm.getRecordedLogs(), RETURNED, BOB, 60_000_000);
    }

    /// @notice 테스트 주입 최대 기록에 raw1을 더하면 전송·승인 소비까지 Panic0x11과 함께 복구된다.
    function testCollateralAdditionOverflowRestoresActualTransferAndAllowance() public {
        usdc = new MockUSDC();
        wbtc = new MockWBTC();
        CollateralOverflowHarness harness = new CollateralOverflowHarness(usdc, wbtc);
        pool = harness;
        usdc.mint(ALICE, 200_000_000);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), 100_000_000);
        pool.supply(100_000_000);
        vm.stopPrank();
        wbtc.mint(ALICE, 4);
        _deposit(ALICE, 3);
        wbtc.mint(BOB, 1);
        vm.prank(BOB);
        wbtc.approve(address(pool), 1);
        harness.setCollateralForTest(BOB, type(uint256).max);
        assertEq(wbtc.balanceOf(BOB), 1);
        assertEq(wbtc.balanceOf(ALICE), 1);
        assertEq(wbtc.balanceOf(address(pool)), 3);
        assertEq(wbtc.totalSupply(), 5);
        assertEq(pool.collateralOf(ALICE), 3);
        assertEq(pool.collateralOf(BOB), type(uint256).max);
        uint256[20] memory beforeState = _state();

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vm.prank(BOB);
        pool.depositCollateral(1);

        _assertUnchanged(beforeState);
        assertEq(wbtc.allowance(BOB, address(pool)), 1);
        _assertNoProtocolEvents(vm.getRecordedLogs());
    }

    /// @notice 타인 담보와 양 자산의 0이 아닌 유한 승인을 실패 복구의 보존 대상으로 준비한다.
    function _prepareOtherCollateralAndApprovals() internal {
        _deposit(BOB, 100_000_000);
        wbtc.mint(ALICE, 50_000_000);
        _deposit(ALICE, 30_000_000);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), 7_000_000);
        wbtc.approve(address(pool), 11_000_000);
        vm.stopPrank();
        vm.startPrank(BOB);
        usdc.approve(address(pool), 9_000_000);
        wbtc.approve(address(pool), 80_000_000);
        vm.stopPrank();
        assertEq(wbtc.balanceOf(BOB), 100_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 130_000_000);
        assertEq(pool.collateralOf(BOB), 100_000_000);
        assertEq(pool.collateralOf(ALICE), 30_000_000);
    }

    /// @notice 같은20 입금은 Bob 기록100→120·지갑100→80·유한 승인80→60으로 한 번만 반영된다.
    function _retryDepositAndAssert(uint256[12] memory cashBefore) internal {
        vm.recordLogs();
        vm.prank(BOB);
        pool.depositCollateral(20_000_000);

        assertEq(wbtc.balanceOf(BOB), 80_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 150_000_000);
        assertEq(pool.collateralOf(BOB), 120_000_000);
        assertEq(wbtc.allowance(BOB, address(pool)), 60_000_000);
        _assertOtherCollateralAndUSDC(cashBefore);
        _assertCollateralEvent(vm.getRecordedLogs(), DEPOSITED, BOB, 20_000_000);
    }

    /// @notice 같은40 반환은 Bob 기록100→60·지갑100→140이고 남은 유한 승인80은 그대로다.
    function _retryWithdrawalAndAssert(uint256[12] memory cashBefore) internal {
        vm.recordLogs();
        vm.prank(BOB);
        pool.withdrawCollateral(40_000_000);

        assertEq(wbtc.balanceOf(BOB), 140_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 90_000_000);
        assertEq(pool.collateralOf(BOB), 60_000_000);
        assertEq(wbtc.allowance(BOB, address(pool)), 80_000_000);
        _assertOtherCollateralAndUSDC(cashBefore);
        _assertCollateralEvent(vm.getRecordedLogs(), RETURNED, BOB, 40_000_000);
    }

    /// @notice 재시도에서도 Alice 담보·잔고·승인과 양쪽 USDC 승인·권리·총발행량을 보존한다.
    function _assertOtherCollateralAndUSDC(uint256[12] memory cashBefore) internal view {
        assertEq(wbtc.balanceOf(ALICE), 20_000_000);
        assertEq(pool.collateralOf(ALICE), 30_000_000);
        assertEq(wbtc.allowance(ALICE, address(pool)), 11_000_000);
        assertEq(wbtc.totalSupply(), 250_000_000);
        assertEq(usdc.allowance(ALICE, address(pool)), 7_000_000);
        assertEq(usdc.allowance(BOB, address(pool)), 9_000_000);
        _assertUSDCUnchanged(cashBefore);
    }
}

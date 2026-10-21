// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockWBTC} from "../src/mocks/MockWBTC.sol";
import {CollateralTestBase} from "./helpers/CollateralTestBase.sol";
import {
    CollateralCallback,
    CollateralReentrantMockWBTC,
    CollateralReentrantMockUSDC
} from "./mocks/CollateralReentrantMocks.sol";

/// @title 담보와 USDC의 공통 재진입 잠금 검사
/// @notice 중첩 호출자인 토큰 자신의 정상 권리를 갖춘 뒤 정확한 잠금 오류와 바깥 한 번 반영을 확인한다.
contract LendingPoolCollateralReentrancyTest is CollateralTestBase {
    CollateralReentrantMockWBTC private callbackWBTC;

    /// @notice WBTC 대역의 자기 명의 양 자산 잔고2·잔여 승인1·정상 권리1을 준비한다.
    function setUp() public override {
        callbackWBTC = new CollateralReentrantMockWBTC();
        _preparePool(new MockUSDC(), callbackWBTC);
        _prepareOwnPositions(callbackWBTC);
    }

    /// @notice 담보 입금 중 같은 입금 호출을 막고 바깥 담보만 한 번 기록한다.
    function testDepositCollateralBlocksNestedDepositCollateral() public {
        _assertDepositBlocks(CollateralCallback.NestedAction.DepositCollateral);
    }

    /// @notice 담보 반환 중 같은 반환 호출을 막고 바깥 담보만 한 번 돌려준다.
    function testWithdrawCollateralBlocksNestedWithdrawCollateral() public {
        _assertReturnBlocks(CollateralCallback.NestedAction.WithdrawCollateral);
    }

    /// @notice 담보 입금 중 토큰 자신의 반환 권리가 있어도 중첩 반환을 막는다.
    function testDepositCollateralBlocksNestedWithdrawCollateral() public {
        _assertDepositBlocks(CollateralCallback.NestedAction.WithdrawCollateral);
    }

    /// @notice 담보 반환 중 토큰 자신의 잔고·승인이 있어도 중첩 담보 입금을 막는다.
    function testWithdrawCollateralBlocksNestedDepositCollateral() public {
        _assertReturnBlocks(CollateralCallback.NestedAction.DepositCollateral);
    }

    /// @notice WBTC 입금 전송 중 기존 USDC 공급도 같은 잠금으로 거절한다.
    function testDepositCollateralBlocksNestedSupply() public {
        _assertDepositBlocks(CollateralCallback.NestedAction.Supply);
    }

    /// @notice WBTC 반환 전송 중 기존 USDC 출금도 같은 잠금으로 거절한다.
    function testWithdrawCollateralBlocksNestedWithdraw() public {
        _assertReturnBlocks(CollateralCallback.NestedAction.Withdraw);
    }

    /// @notice USDC 공급은 전송 뒤 아직 증가 전인 A/S/q를 관측하며 중첩 담보 입금을 막는다.
    function testSupplyBlocksNestedDepositCollateral() public {
        CollateralReentrantMockUSDC callbackUSDC = _prepareUSDCCallback();
        uint256[20] memory beforeState = _state();
        uint256[7] memory ownBefore = _participantState(address(callbackUSDC));
        vm.prank(ALICE);
        usdc.approve(address(pool), 10_000_000);
        callbackUSDC.arm(
            pool,
            CollateralCallback.CallbackOn.TransferFrom,
            CollateralCallback.NestedAction.DepositCollateral,
            false,
            ALICE
        );

        vm.recordLogs();
        vm.prank(ALICE);
        pool.supply(10_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertBlockedWithSufficientOwnRights(callbackUSDC, 110_000_001, 130_000_001);
        assertEq(callbackUSDC.observedAssets(), 100_000_001);
        assertEq(callbackUSDC.observedTotalShares(), 100_000_001);
        assertEq(callbackUSDC.observedShares(), 100_000_000);
        assertEq(callbackUSDC.observedDeposit(), 100_000_000);
        assertEq(callbackUSDC.observedCollateral(), 30_000_000);
        assertEq(usdc.balanceOf(ALICE), 90_000_000);
        assertEq(usdc.balanceOf(address(pool)), 110_000_001);
        assertEq(usdc.allowance(ALICE, address(pool)), 0);
        assertEq(pool.totalAssets(), 110_000_001);
        assertEq(pool.totalShares(), 110_000_001);
        assertEq(pool.shares(ALICE), 110_000_000);
        assertEq(pool.deposits(ALICE), 110_000_000);
        _assertOtherUSDCState();
        _assertCollateralSideUnchanged(beforeState);
        _assertParticipantUnchanged(address(callbackUSDC), ownBefore);
        _assertUSDCEvent(logs, SUPPLIED, 10_000_000);
    }

    /// @notice USDC 출금의 선차감 A/S/q를 관측하며 충분한 자기 담보의 중첩 반환을 막는다.
    function testWithdrawBlocksNestedWithdrawCollateral() public {
        CollateralReentrantMockUSDC callbackUSDC = _prepareUSDCCallback();
        uint256[20] memory beforeState = _state();
        uint256[7] memory ownBefore = _participantState(address(callbackUSDC));
        callbackUSDC.arm(
            pool,
            CollateralCallback.CallbackOn.Transfer,
            CollateralCallback.NestedAction.WithdrawCollateral,
            false,
            ALICE
        );

        vm.recordLogs();
        vm.prank(ALICE);
        pool.withdraw(40_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertBlockedWithSufficientOwnRights(callbackUSDC, 60_000_001, 130_000_001);
        assertEq(callbackUSDC.observedAssets(), 60_000_001);
        assertEq(callbackUSDC.observedTotalShares(), 60_000_001);
        assertEq(callbackUSDC.observedShares(), 60_000_000);
        assertEq(callbackUSDC.observedDeposit(), 60_000_000);
        assertEq(callbackUSDC.observedCollateral(), 30_000_000);
        assertEq(usdc.balanceOf(ALICE), 140_000_000);
        assertEq(usdc.balanceOf(address(pool)), 60_000_001);
        assertEq(usdc.allowance(ALICE, address(pool)), 0);
        assertEq(pool.totalAssets(), 60_000_001);
        assertEq(pool.totalShares(), 60_000_001);
        assertEq(pool.shares(ALICE), 60_000_000);
        assertEq(pool.deposits(ALICE), 60_000_000);
        _assertOtherUSDCState();
        _assertCollateralSideUnchanged(beforeState);
        _assertParticipantUnchanged(address(callbackUSDC), ownBefore);
        _assertUSDCEvent(logs, WITHDRAWN, 40_000_000);
    }

    /// @notice 입금 콜백 오류 전파는 실제 WBTC 이동·유한 승인·관측 저장까지 복구하고 재시도한다.
    function testDepositPropagatedReentryRestoresEverythingAndRetries() public {
        vm.prank(BOB);
        wbtc.approve(address(pool), 100_000_000);
        callbackWBTC.arm(
            pool,
            CollateralCallback.CallbackOn.TransferFrom,
            CollateralCallback.NestedAction.WithdrawCollateral,
            true,
            BOB
        );
        uint256[20] memory beforeState = _state();
        uint256[7] memory ownBefore = _participantState(address(callbackWBTC));
        bytes memory callbackBefore = callbackWBTC.callbackState();

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        vm.prank(BOB);
        pool.depositCollateral(100_000_000);

        _assertUnchanged(beforeState);
        _assertParticipantUnchanged(address(callbackWBTC), ownBefore);
        assertEq(callbackWBTC.callbackState(), callbackBefore);
        assertFalse(callbackWBTC.attempted());
        _assertNoProtocolEvents(vm.getRecordedLogs());

        callbackWBTC.disableCallback();
        vm.recordLogs();
        vm.prank(BOB);
        pool.depositCollateral(100_000_000);

        _assertSuccessfulBobDeposit();
        _assertUSDCUnchanged(_cashFrom(beforeState));
        _assertParticipantUnchanged(address(callbackWBTC), ownBefore);
        _assertCollateralEvent(vm.getRecordedLogs(), DEPOSITED, BOB, 100_000_000);
    }

    /// @notice 반환 콜백 오류 전파는 선차감·실제 전송·관측 저장을 복구하고 승인 없이 재시도한다.
    function testReturnPropagatedReentryRestoresEverythingAndRetries() public {
        _deposit(BOB, 100_000_000);
        vm.prank(BOB);
        wbtc.approve(address(pool), 7);
        callbackWBTC.arm(
            pool, CollateralCallback.CallbackOn.Transfer, CollateralCallback.NestedAction.DepositCollateral, true, BOB
        );
        uint256[20] memory beforeState = _state();
        uint256[7] memory ownBefore = _participantState(address(callbackWBTC));
        bytes memory callbackBefore = callbackWBTC.callbackState();

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        vm.prank(BOB);
        pool.withdrawCollateral(40_000_000);

        _assertUnchanged(beforeState);
        _assertParticipantUnchanged(address(callbackWBTC), ownBefore);
        assertEq(callbackWBTC.callbackState(), callbackBefore);
        assertFalse(callbackWBTC.attempted());
        _assertNoProtocolEvents(vm.getRecordedLogs());

        callbackWBTC.disableCallback();
        vm.recordLogs();
        vm.prank(BOB);
        pool.withdrawCollateral(40_000_000);

        _assertSuccessfulBobReturn();
        assertEq(wbtc.allowance(BOB, address(pool)), 7);
        _assertUSDCUnchanged(_cashFrom(beforeState));
        _assertParticipantUnchanged(address(callbackWBTC), ownBefore);
        _assertCollateralEvent(vm.getRecordedLogs(), RETURNED, BOB, 40_000_000);
    }

    /// @notice 중첩 종류만 바꾸어 같은 담보 입금의 기록 증가 전 관측과 한 번 성공을 대조한다.
    function _assertDepositBlocks(CollateralCallback.NestedAction action) private {
        vm.prank(BOB);
        wbtc.approve(address(pool), 100_000_000);
        uint256[12] memory cashBefore = _usdcState();
        uint256[7] memory ownBefore = _participantState(address(callbackWBTC));
        callbackWBTC.arm(pool, CollateralCallback.CallbackOn.TransferFrom, action, false, BOB);

        vm.recordLogs();
        vm.prank(BOB);
        pool.depositCollateral(100_000_000);

        _assertBlockedWithSufficientOwnRights(callbackWBTC, 100_000_001, 100_000_001);
        assertEq(callbackWBTC.observedCollateral(), 0);
        assertEq(callbackWBTC.observedAssets(), 100_000_001);
        assertEq(callbackWBTC.observedTotalShares(), 100_000_001);
        assertEq(callbackWBTC.observedShares(), 0);
        assertEq(callbackWBTC.observedDeposit(), 0);
        _assertSuccessfulBobDeposit();
        _assertUSDCUnchanged(cashBefore);
        _assertParticipantUnchanged(address(callbackWBTC), ownBefore);
        _assertCollateralEvent(vm.getRecordedLogs(), DEPOSITED, BOB, 100_000_000);
    }

    /// @notice 중첩 종류만 바꾸어 같은 담보 반환의 선차감 관측과 한 번 성공을 대조한다.
    function _assertReturnBlocks(CollateralCallback.NestedAction action) private {
        _deposit(BOB, 100_000_000);
        uint256[12] memory cashBefore = _usdcState();
        uint256[7] memory ownBefore = _participantState(address(callbackWBTC));
        callbackWBTC.arm(pool, CollateralCallback.CallbackOn.Transfer, action, false, BOB);

        vm.recordLogs();
        vm.prank(BOB);
        pool.withdrawCollateral(40_000_000);

        _assertBlockedWithSufficientOwnRights(callbackWBTC, 100_000_001, 60_000_001);
        assertEq(callbackWBTC.observedCollateral(), 60_000_000);
        assertEq(callbackWBTC.observedAssets(), 100_000_001);
        assertEq(callbackWBTC.observedTotalShares(), 100_000_001);
        assertEq(callbackWBTC.observedShares(), 0);
        assertEq(callbackWBTC.observedDeposit(), 0);
        _assertSuccessfulBobReturn();
        assertEq(wbtc.allowance(BOB, address(pool)), 0);
        _assertUSDCUnchanged(cashBefore);
        _assertParticipantUnchanged(address(callbackWBTC), ownBefore);
        _assertCollateralEvent(vm.getRecordedLogs(), RETURNED, BOB, 40_000_000);
    }

    /// @notice 모든 raw1 중첩 요청이 권리·잔고·승인·풀 현금 부족으로 우연히 실패하지 않았는지 확인한다.
    function _assertBlockedWithSufficientOwnRights(
        CollateralCallback callbackToken,
        uint256 expectedPoolCash,
        uint256 expectedPoolCollateral
    ) private view {
        assertTrue(callbackToken.attempted());
        assertFalse(callbackToken.nestedSucceeded());
        assertEq(
            callbackToken.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        uint256[7] memory own = callbackToken.observedOwnState();
        assertEq(own[0], 2);
        assertEq(own[1], 2);
        assertEq(own[2], 1);
        assertEq(own[3], 1);
        assertEq(own[4], 1);
        assertEq(own[5], 1);
        assertEq(own[6], 1);
        assertEq(callbackToken.observedPoolCash(), expectedPoolCash);
        assertEq(callbackToken.observedPoolCollateral(), expectedPoolCollateral);
    }

    /// @notice 양 자산 raw3을 지급하고 토큰 계약 자신이 정상 호출로 각 권리 raw1을 만든다.
    function _prepareOwnPositions(CollateralCallback callbackToken) private {
        usdc.mint(address(callbackToken), 3);
        wbtc.mint(address(callbackToken), 3);
        callbackToken.prepareOwnPositions(pool);
        uint256[7] memory own = _participantState(address(callbackToken));
        assertEq(own[0], 2);
        assertEq(own[1], 2);
        assertEq(own[2], 1);
        assertEq(own[3], 1);
        assertEq(own[4], 1);
        assertEq(own[5], 1);
        assertEq(own[6], 1);
    }

    /// @notice USDC 대역과 양 사용자의 0이 아닌 담보를 준비해 기존 경로의 담보 보존도 검사한다.
    function _prepareUSDCCallback() private returns (CollateralReentrantMockUSDC callbackUSDC) {
        callbackUSDC = new CollateralReentrantMockUSDC();
        _preparePool(callbackUSDC, new MockWBTC());
        _prepareOwnPositions(callbackUSDC);
        wbtc.mint(ALICE, 30_000_000);
        _deposit(ALICE, 30_000_000);
        _deposit(BOB, 100_000_000);
    }

    /// @notice 바깥 입금100_000_000만 한 번 반영된 raw 잔고·승인·담보를 대조한다.
    function _assertSuccessfulBobDeposit() private view {
        assertEq(wbtc.balanceOf(BOB), 100_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 100_000_001);
        assertEq(wbtc.allowance(BOB, address(pool)), 0);
        assertEq(pool.collateralOf(BOB), 100_000_000);
        assertEq(wbtc.balanceOf(ALICE), 0);
        assertEq(wbtc.allowance(ALICE, address(pool)), 0);
        assertEq(pool.collateralOf(ALICE), 0);
        assertEq(wbtc.totalSupply(), 200_000_003);
    }

    /// @notice 바깥 반환40_000_000만 한 번 반영된 raw 잔고·담보와 타인 상태를 대조한다.
    function _assertSuccessfulBobReturn() private view {
        assertEq(wbtc.balanceOf(BOB), 140_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 60_000_001);
        assertEq(pool.collateralOf(BOB), 60_000_000);
        assertEq(wbtc.balanceOf(ALICE), 0);
        assertEq(wbtc.allowance(ALICE, address(pool)), 0);
        assertEq(pool.collateralOf(ALICE), 0);
        assertEq(wbtc.totalSupply(), 200_000_003);
    }

    /// @notice 기존 USDC 동작이 두 사용자 WBTC 잔고·승인·담보와 총발행량을 보존했는지 비교한다.
    function _assertCollateralSideUnchanged(uint256[20] memory beforeState) private view {
        uint256[20] memory afterState = _state();
        for (uint256 i = 12; i < 20; ++i) {
            assertEq(afterState[i], beforeState[i]);
        }
    }

    /// @notice USDC 바깥 호출도 Bob의 잔고·승인·권리와 고정 발행량을 바꾸지 않는다.
    function _assertOtherUSDCState() private view {
        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(pool.shares(BOB), 0);
        assertEq(pool.deposits(BOB), 0);
        assertEq(usdc.totalSupply(), 200_000_003);
    }

    /// @notice 전체 복구 snapshot 중 USDC12값을 재시도의 담보 분리 검사에 넘긴다.
    function _cashFrom(uint256[20] memory state) private pure returns (uint256[12] memory cash) {
        for (uint256 i; i < cash.length; ++i) {
            cash[i] = state[i];
        }
    }

    /// @notice USDC 바깥 이벤트의 emitter·사용자·요청량·1회와 다른 성공 이벤트 부재를 확인한다.
    function _assertUSDCEvent(Vm.Log[] memory logs, bytes32 topic, uint256 amount) private view {
        assertEq(_countEvents(logs, topic), 1);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                assertEq(logs[i].topics.length, 2);
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(ALICE))));
                assertEq(abi.decode(logs[i].data, (uint256)), amount);
            }
        }
        assertEq(_countEvents(logs, topic == SUPPLIED ? WITHDRAWN : SUPPLIED), 0);
        assertEq(_countEvents(logs, DEPOSITED), 0);
        assertEq(_countEvents(logs, RETURNED), 0);
    }
}

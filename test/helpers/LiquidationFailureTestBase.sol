// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {InterestMath} from "../../src/libraries/InterestMath.sol";
import {LendingPoolHarness} from "../mocks/LendingPoolHarness.sol";
import {FailingMockUSDC} from "../mocks/FailingMockUSDC.sol";
import {FailingMockWBTC} from "../mocks/FailingMockWBTC.sol";
import {MockCollateralPriceSource} from "../mocks/MockCollateralPriceSource.sol";

/// @title 청산 거절과 전체 복구를 위한 독립 준비·관측
/// @notice 정상 포지션은 실제 공급·담보 입금·차입으로 만들고 원시 장부 주입은 정밀도 경계에만 쓴다.
abstract contract LiquidationFailureTestBase is Test {
    uint256 internal constant Q = InterestMath.DENOMINATOR;
    uint256 internal constant START = 10_000;
    uint256 internal constant HALF_YEAR = 365 days / 2;
    uint256 internal constant REPAYMENT = 73_500_000;
    uint256 internal constant PAYOUT = 96_468_750;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CHARLIE = address(0xCA11);
    address internal constant DAVE = address(0xDA7E);
    FailingMockUSDC internal usdc;
    FailingMockWBTC internal wbtc;
    MockCollateralPriceSource internal price;
    LendingPoolHarness internal pool;

    /// @notice 반년 이자를 아직 저장하지 않은 Bob73.5·Dave10.5와 Charlie의 유한 승인74를 준비한다.
    function setUp() public virtual {
        _prepareStandard(true);
    }

    /// @notice 같은 실패 대역을 장애 없이 배포해 모든 정상 준비를 실제 토큰 이동으로 수행한다.
    function _deployPool() internal {
        vm.warp(START);
        usdc = new FailingMockUSDC();
        wbtc = new FailingMockWBTC();
        price = new MockCollateralPriceSource(100e8, START);
        pool = new LendingPoolHarness(usdc, wbtc, price);
    }

    /// @notice 별도 차입자와 충분한 Bob 자원을 두어 Charlie 실패를 타인의 자금으로 숨길 수 없게 한다.
    function _prepareStandard(bool accrueHalfYear) internal {
        _deployPool();
        usdc.mint(ALICE, 100e6);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), 100e6);
        pool.supply(100e6);
        vm.stopPrank();
        _deposit(BOB, 1e8);
        _deposit(DAVE, 50_000_000);
        vm.prank(BOB);
        pool.borrow(70e6);
        vm.prank(DAVE);
        pool.borrow(10e6);
        usdc.mint(BOB, 4e6);
        vm.prank(BOB);
        usdc.approve(address(pool), 74e6);
        vm.prank(DAVE);
        usdc.approve(address(pool), 10e6);
        usdc.mint(CHARLIE, 74e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 74e6);
        if (accrueHalfYear) vm.warp(START + HALF_YEAR);
        price.setPrice(80e8);
        price.setUpdatedAt(block.timestamp);
    }

    /// @notice 담보 setter 없이 실제 WBTC를 발행·승인·입금해 기록과 보관량을 함께 만든다.
    function _deposit(address user, uint256 amount) internal {
        wbtc.mint(user, amount);
        vm.startPrank(user);
        wbtc.approve(address(pool), amount);
        pool.depositCollateral(amount);
        vm.stopPrank();
    }

    /// @notice 정상 차입으로 만들 수 없는 최소 단위의 소수·반올림 경계만 기존 장부 하네스로 준비한다.
    function _prepareRaw(uint256 principal, uint256 interest, uint256 collateral, int256 price8) internal {
        _deployPool();
        usdc.mint(ALICE, 1);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), 1);
        pool.supply(1);
        vm.stopPrank();
        _deposit(BOB, collateral);
        pool.setDebtPositionForTest(BOB, principal, interest, START);
        pool.setTotalDebtForTest(principal, interest, START);
        // 현금1과 정확 채권의 합을 인정자산에 맞춘다.
        pool.setAccountedAssetsNumeratorForTest(Q + principal * Q + interest);
        price.setPrice(price8);
        usdc.mint(CHARLIE, 3);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 3);
    }

    /// @notice 두 토큰 주소까지 포함해 잔고·유한 승인·지분·기록 담보를 범위 초과 없이 읽는다.
    function _storedParticipant(address user) internal view returns (uint256[6] memory) {
        return [
            usdc.balanceOf(user),
            wbtc.balanceOf(user),
            usdc.allowance(user, address(pool)),
            wbtc.allowance(user, address(pool)),
            pool.shares(user),
            pool.collateralOf(user)
        ];
    }

    /// @notice 공개 자산 조회가 실패하는 경계에서도 저장 자산·부채·시각과 양 토큰 상태를 비교한다.
    function _storedSnapshot() internal view returns (bytes memory) {
        uint256[6] memory global = [
            pool.storedAssetsNumerator(),
            pool.totalShares(),
            usdc.balanceOf(address(pool)),
            wbtc.balanceOf(address(pool)),
            usdc.totalSupply(),
            wbtc.totalSupply()
        ];
        return abi.encode(
            global,
            abi.encode(
                pool.storedTotalDebt(),
                pool.storedDebt(ALICE),
                pool.storedDebt(BOB),
                pool.storedDebt(CHARLIE),
                pool.storedDebt(DAVE),
                pool.storedDebt(address(usdc)),
                pool.storedDebt(address(wbtc))
            ),
            abi.encode(
                _storedParticipant(ALICE),
                _storedParticipant(BOB),
                _storedParticipant(CHARLIE),
                _storedParticipant(DAVE),
                _storedParticipant(address(usdc)),
                _storedParticipant(address(wbtc))
            )
        );
    }

    /// @notice 정상 범위에서는 공급자 권리와 현재 개인 부채도 함께 보존돼야 한다.
    function _queries(address user) internal view returns (uint256[2] memory) {
        return [pool.deposits(user), pool.debtOf(user)];
    }

    /// @notice 현재 표시값과 원시 저장값을 구분해 이자 저장만 잘못 진행되는 경우도 잡는다.
    function _snapshot() internal view returns (bytes memory) {
        return abi.encode(
            _storedSnapshot(),
            [pool.totalAssets(), pool.totalDebt(), pool.availableLiquidity()],
            abi.encode(
                _queries(ALICE),
                _queries(BOB),
                _queries(CHARLIE),
                _queries(DAVE),
                _queries(address(usdc)),
                _queries(address(wbtc))
            )
        );
    }

    /// @notice 해당 실패 호출에서 풀의 성공 이벤트가 남지 않았는지 검사한다.
    function _assertNoPoolLogs() internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(pool));
        }
    }

    /// @notice 사전 검사가 토큰 단계로 넘어가면 고유 오류를 내어 잘못된 실패 원인을 드러낸다.
    function _rejectTransfers() internal {
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)"),
            abi.encodeWithSignature("UnexpectedUSDCReceipt()")
        );
        vm.mockCallRevert(
            address(wbtc),
            abi.encodeWithSignature("transfer(address,uint256)"),
            abi.encodeWithSignature("UnexpectedWBTCPayout()")
        );
    }

    /// @notice 기대한 정확 오류·전송 미도달·모든 상태와 시각의 불변을 한 호출에 연결한다.
    function _assertRejected(address borrower, uint256 maximum, uint256 minimum, bytes memory expected) internal {
        bytes memory beforeState = _snapshot();
        _rejectTransfers();
        vm.recordLogs();
        vm.expectRevert(expected);
        vm.prank(CHARLIE);
        pool.liquidate(borrower, maximum, minimum);
        assertEq(_snapshot(), beforeState);
        _assertNoPoolLogs();
        vm.clearMockedCalls();
    }
}

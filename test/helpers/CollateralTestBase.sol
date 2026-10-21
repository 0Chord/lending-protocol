// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockWBTC} from "../../src/mocks/MockWBTC.sol";

/// @title 담보 테스트의 정상 준비와 양 자산 관측
/// @notice Alice의 USDC 공급과 Bob의 WBTC 잔고를 준비하고 서로 다른 장부를 비교한다.
abstract contract CollateralTestBase is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    bytes32 internal constant DEPOSITED = keccak256("CollateralDeposited(address,uint256)");
    bytes32 internal constant RETURNED = keccak256("CollateralWithdrawn(address,uint256)");
    bytes32 internal constant SUPPLIED = keccak256("Supplied(address,uint256)");
    bytes32 internal constant WITHDRAWN = keccak256("Withdrawn(address,uint256)");

    MockUSDC internal usdc;
    MockWBTC internal wbtc;
    LendingPool internal pool;

    /// @notice 매 사례를 정상 두 자산과 새로운 풀에서 시작한다.
    function setUp() public virtual {
        _preparePool(new MockUSDC(), new MockWBTC());
    }

    /// @notice Alice100 USDC 공급·Bob2 WBTC를 정상 경로로 준비하며 대역도 같은 단위를 사용한다.
    function _preparePool(MockUSDC usdc_, MockWBTC wbtc_) internal {
        usdc = usdc_;
        wbtc = wbtc_;
        pool = new LendingPool(usdc, wbtc);
        usdc.mint(ALICE, 200_000_000);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), 100_000_000);
        pool.supply(100_000_000);
        vm.stopPrank();
        wbtc.mint(BOB, 200_000_000);
    }

    /// @notice 별도 승인 뒤 지정 사용자 명의의 정상 담보 입금을 실행한다.
    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        wbtc.approve(address(pool), amount);
        pool.depositCollateral(amount);
        vm.stopPrank();
    }

    /// @notice 양 사용자의 USDC 잔고·승인·권리와 풀 현금·발행량·지분 장부12값이다.
    function _usdcState() internal view returns (uint256[12] memory) {
        return [
            usdc.balanceOf(ALICE),
            usdc.balanceOf(BOB),
            usdc.balanceOf(address(pool)),
            usdc.allowance(ALICE, address(pool)),
            usdc.allowance(BOB, address(pool)),
            usdc.totalSupply(),
            pool.totalAssets(),
            pool.totalShares(),
            pool.shares(ALICE),
            pool.shares(BOB),
            pool.deposits(ALICE),
            pool.deposits(BOB)
        ];
    }

    /// @notice USDC12값과 WBTC 잔고3·승인2·발행량1·담보2를 함께 관측한다.
    function _state() internal view returns (uint256[20] memory state) {
        uint256[12] memory cash = _usdcState();
        for (uint256 i; i < cash.length; ++i) {
            state[i] = cash[i];
        }
        state[12] = wbtc.balanceOf(ALICE);
        state[13] = wbtc.balanceOf(BOB);
        state[14] = wbtc.balanceOf(address(pool));
        state[15] = wbtc.allowance(ALICE, address(pool));
        state[16] = wbtc.allowance(BOB, address(pool));
        state[17] = wbtc.totalSupply();
        state[18] = pool.collateralOf(ALICE);
        state[19] = pool.collateralOf(BOB);
    }

    /// @notice 담보 동작이 USDC 장부를 건드리지 않았는지 모든 관측값을 비교한다.
    function _assertUSDCUnchanged(uint256[12] memory beforeState) internal view {
        uint256[12] memory afterState = _usdcState();
        for (uint256 i; i < beforeState.length; ++i) {
            assertEq(afterState[i], beforeState[i]);
        }
    }

    /// @notice 실패 직전 토큰·승인·발행량·담보·USDC 권리가 모두 복구됐는지 비교한다.
    function _assertUnchanged(uint256[20] memory beforeState) internal view {
        uint256[20] memory afterState = _state();
        for (uint256 i; i < beforeState.length; ++i) {
            assertEq(afterState[i], beforeState[i]);
        }
    }

    /// @notice 중첩 호출자인 토큰 주소 자체의 양 자산 잔고·승인·공급 권리·담보를 관측한다.
    function _participantState(address user) internal view returns (uint256[7] memory) {
        return [
            usdc.balanceOf(user),
            wbtc.balanceOf(user),
            usdc.allowance(user, address(pool)),
            wbtc.allowance(user, address(pool)),
            pool.shares(user),
            pool.deposits(user),
            pool.collateralOf(user)
        ];
    }

    /// @notice 바깥 호출과 무관한 중첩 호출자 자신의 권리와 승인도 보존되는지 비교한다.
    function _assertParticipantUnchanged(address user, uint256[7] memory beforeState) internal view {
        uint256[7] memory afterState = _participantState(user);
        for (uint256 i; i < beforeState.length; ++i) {
            assertEq(afterState[i], beforeState[i]);
        }
    }

    /// @notice 토큰 Transfer와 구별해 풀의 지정 이벤트 개수만 센다.
    function _countEvents(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics.length > 0 && logs[i].topics[0] == topic) ++count;
        }
    }

    /// @notice 담보 이벤트의 외부 호출자·이번 요청량·1회와 USDC/반대 담보 이벤트 부재를 확인한다.
    function _assertCollateralEvent(Vm.Log[] memory logs, bytes32 topic, address user, uint256 amount) internal view {
        assertEq(_countEvents(logs, topic), 1);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                assertEq(logs[i].topics.length, 2);
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
                assertEq(abi.decode(logs[i].data, (uint256)), amount);
            }
        }
        assertEq(_countEvents(logs, topic == DEPOSITED ? RETURNED : DEPOSITED), 0);
        assertEq(_countEvents(logs, SUPPLIED), 0);
        assertEq(_countEvents(logs, WITHDRAWN), 0);
    }

    /// @notice 거절 경로가 풀 성공 이벤트를 남기지 않았는지 네 종류를 함께 확인한다.
    function _assertNoProtocolEvents(Vm.Log[] memory logs) internal view {
        assertEq(_countEvents(logs, DEPOSITED), 0);
        assertEq(_countEvents(logs, RETURNED), 0);
        assertEq(_countEvents(logs, SUPPLIED), 0);
        assertEq(_countEvents(logs, WITHDRAWN), 0);
    }
}

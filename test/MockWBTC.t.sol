// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockWBTC} from "../src/mocks/MockWBTC.sol";

/// @title MockWBTC 단위·발행 검증
/// @notice 8자리 설정과 공개 발행의 정상·누적·거절 결과를 확인한다.
contract MockWBTCTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    MockWBTC private token;

    /// @notice 각 테스트는 새 토큰에서 독립적으로 시작한다.
    function setUp() public {
        token = new MockWBTC();
    }

    /// @notice 1 WBTC를 100,000,000 최소 단위로 표시하는 설정을 확인한다.
    function test_DecimalsAreEight() public view {
        assertEq(token.decimals(), 8);
    }

    /// @notice 1 WBTC 발행은 수령자 잔고·총발행량과 정확한 발행 이벤트 하나에 반영된다.
    function test_MintCreditsOnlyRecipientAndIncreasesTotalSupply() public {
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), 0);

        vm.recordLogs();
        token.mint(ALICE, 100_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(token.balanceOf(ALICE), 100_000_000);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), 100_000_000);

        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(0)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(ALICE))));
        assertEq(logs[0].data, abi.encode(uint256(100_000_000)));
    }

    /// @notice 추가 발행은 기존 잔고에 더해지며 다른 수령자의 잔고를 유지한다.
    function test_MintAddsToExistingBalances() public {
        token.mint(ALICE, 25_000_000);
        token.mint(BOB, 7_000_000);

        token.mint(ALICE, 100_000_000);

        assertEq(token.balanceOf(ALICE), 125_000_000);
        assertEq(token.balanceOf(BOB), 7_000_000);
        assertEq(token.totalSupply(), 132_000_000);
    }

    /// @notice 0 주소 발행은 정확한 오류로 거절되고 기존 상태를 유지하며 로그를 남기지 않는다.
    function test_MintToZeroAddressRevertsWithoutChangingSupply() public {
        token.mint(ALICE, 25_000_000);

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.mint(address(0), 100_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(token.balanceOf(ALICE), 25_000_000);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), 25_000_000);
        assertEq(logs.length, 0);
    }

    /// @notice 배포자가 아닌 Bob도 테스트 잔고를 발행할 수 있다.
    function test_NonDeployerCanMintTestBalance() public {
        vm.prank(BOB);
        token.mint(ALICE, 50_000_000);

        assertEq(token.balanceOf(ALICE), 50_000_000);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), 50_000_000);
    }
}

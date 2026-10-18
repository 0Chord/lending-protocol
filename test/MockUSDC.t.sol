// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @title MockUSDC 단위·지급 검증
/// @notice 실습용 토큰의 설정과 발행 결과를 확인한다.
contract MockUSDCTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    MockUSDC private token;

    /// @notice 각 테스트는 새 토큰에서 독립적으로 시작한다.
    function setUp() public {
        token = new MockUSDC();
    }

    /// @notice 1 USDC를 1,000,000 최소 단위로 표시하는 설정을 확인한다.
    function test_DecimalsAreSix() public view {
        assertEq(token.decimals(), 6);
    }

    /// @notice Alice에게 100 USDC를 발행하면 잔고·총발행량이 늘고 Bob의 잔고는 유지된다.
    function test_MintCreditsOnlyRecipientAndIncreasesTotalSupply() public {
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), 0);

        token.mint(ALICE, 100_000_000);

        assertEq(token.balanceOf(ALICE), 100_000_000);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), 100_000_000);
    }

    /// @notice 추가 발행은 기존 잔고를 덮어쓰지 않으며 다른 수령자의 잔고를 유지한다.
    function test_MintAddsToExistingBalances() public {
        token.mint(ALICE, 25_000_000);
        token.mint(BOB, 7_000_000);

        token.mint(ALICE, 100_000_000);

        assertEq(token.balanceOf(ALICE), 125_000_000);
        assertEq(token.balanceOf(BOB), 7_000_000);
        assertEq(token.totalSupply(), 132_000_000);
    }

    /// @notice 0 주소로 발행하면 지정된 오류로 거절되고 기존 잔고·총발행량이 유지된다.
    function test_MintToZeroAddressRevertsWithoutChangingSupply() public {
        token.mint(ALICE, 25_000_000);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.mint(address(0), 100_000_000);

        assertEq(token.balanceOf(ALICE), 25_000_000);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), 25_000_000);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title 이자 없는 MockUSDC 공급·출금 실습
/// @notice 호출자 본인의 토큰과 예치 권리를 같은 수량으로 교환한다.
/// @dev 표준 MockUSDC를 위한 로컬 학습 단계이며 이자·대출은 다루지 않는다.
contract LendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice 배포 때 고정한 공급 자산이다.
    IERC20 public immutable asset;
    /// @notice 직접 전송·발행과 구분한 주소별 공급 권리의 최소 단위 수량이다.
    mapping(address => uint256) public deposits;

    /// @notice 실제 전송에 성공한 공급의 주체와 최소 단위 수량을 알린다.
    event Supplied(address indexed user, uint256 amount);

    /// @notice 본인 지갑으로 반환한 출금의 주체와 최소 단위 수량을 알린다.
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice 0 금액 공급·출금은 유효한 동작으로 취급하지 않는다.
    error ZeroAmount();

    /// @notice 본인의 예치 권리를 초과하는 출금은 부분 지급 없이 거절한다.
    error InsufficientDeposit(uint256 available, uint256 requested);

    /// @notice 예치 권리가 있어도 풀 현금이 부족하면 요청 전체를 거절한다.
    error InsufficientLiquidity(uint256 available, uint256 requested);

    /// @notice 0 주소와 코드가 없는 주소는 자산으로 설정할 수 없다.
    error InvalidAsset(address asset);

    /// @notice 풀에서 사용할 자산을 고정한다.
    /// @dev 코드 존재 여부만 검사하며 임의의 ERC20 동작을 검증하지는 않는다.
    /// @param asset_ 공급 대상으로 사용할 배포된 MockUSDC
    constructor(IERC20 asset_) {
        if (address(asset_) == address(0) || address(asset_).code.length == 0) {
            revert InvalidAsset(address(asset_));
        }
        asset = asset_;
    }

    /// @notice 본인의 토큰을 풀로 옮긴 뒤 같은 수량의 예치 기록을 더한다.
    /// @dev 토큰 전송 실패를 전파하므로 실패한 공급의 상태 변경은 모두 복구된다.
    /// @param amount 소수점 6자리가 적용된 정수 최소 단위 수량
    function supply(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] += amount;
        emit Supplied(msg.sender, amount);
    }

    /// @notice 본인 예치 기록을 줄이고 같은 수량을 본인 지갑으로 돌려준다.
    /// @dev 공급과 잠금을 공유하며 전송 실패는 앞선 기록 차감까지 복구한다.
    /// @param amount 소수점 6자리가 적용된 정수 최소 단위 수량
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 deposited = deposits[msg.sender];
        if (amount > deposited) revert InsufficientDeposit(deposited, amount);
        uint256 cash = asset.balanceOf(address(this));
        if (amount > cash) revert InsufficientLiquidity(cash, amount);

        deposits[msg.sender] = deposited - amount;
        asset.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
}

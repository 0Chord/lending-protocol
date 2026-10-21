// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ShareMath} from "./libraries/ShareMath.sol";

/// @title 이자 없는 USDC 공급·출금과 WBTC 담보 보관 실습
/// @notice USDC 공급 권리는 지분으로, WBTC 반환 권리는 원시 수량으로 분리해 기록한다.
/// @dev 표준 Mock 자산의 로컬 학습 단계이며 이자·대출·가격 연결은 다루지 않는다.
contract LendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice 배포 때 고정한 공급 자산이다.
    IERC20 public immutable asset;
    /// @notice USDC 장부와 분리해 수량 그대로 보관할 고정 담보 자산이다.
    IERC20 public immutable collateralAsset;
    /// @notice 정상 담보 입금으로 인정한 주소별 원시 수량이다.
    mapping(address => uint256) internal _collateralBalances;
    /// @notice 직접 전송·발행과 구분해 장부에서 인정한 USDC 자산이다.
    uint256 internal _accountedAssets;
    /// @notice 공급자의 지분 최소 단위 수량의 합이다.
    uint256 public totalShares;
    /// @notice 전송 가능한 토큰과 구분한 주소별 내부 지분이다.
    mapping(address => uint256) public shares;

    /// @notice 실제 전송에 성공한 공급의 주체와 최소 단위 수량을 알린다.
    event Supplied(address indexed user, uint256 amount);

    /// @notice 본인 지갑으로 반환한 출금의 주체와 최소 단위 수량을 알린다.
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice 정상 담보 입금의 주체와 이번 WBTC 요청량을 알린다.
    event CollateralDeposited(address indexed user, uint256 amount);

    /// @notice 본인에게 반환한 담보의 주체와 이번 WBTC 요청량을 알린다.
    event CollateralWithdrawn(address indexed user, uint256 amount);

    /// @notice 공급·출금·담보 입금·반환의 0 요청은 유효한 동작으로 취급하지 않는다.
    error ZeroAmount();

    /// @notice 양수 공급으로 지분을 받지 못하면 토큰을 받지 않고 거절한다.
    error ZeroShares();

    /// @notice 마지막 총지분을 없애면서 인정자산을 남기는 출금은 거절한다.
    error ResidualAssets(uint256 remainingAssets);

    /// @notice 본인의 예치 권리를 초과하는 출금은 부분 지급 없이 거절한다.
    error InsufficientDeposit(uint256 available, uint256 requested);

    /// @notice 예치 권리가 있어도 풀 현금이 부족하면 요청 전체를 거절한다.
    error InsufficientLiquidity(uint256 available, uint256 requested);

    /// @notice 0 주소와 코드가 없는 주소는 자산으로 설정할 수 없다.
    error InvalidAsset(address asset);

    /// @notice 담보로 호출할 수 없는 0 주소와 코드 없는 주소를 거절한다.
    error InvalidCollateralAsset(address collateralAsset);

    /// @notice 공급 자산과 담보 자산은 서로 다른 계약이어야 한다.
    error IdenticalAssets(address asset);

    /// @notice 본인 기록보다 많은 담보 반환은 일부 지급 없이 거절한다.
    error InsufficientCollateral(uint256 available, uint256 requested);

    /// @notice 공급 자산과 담보 자산을 서로 다른 주소로 고정한다.
    /// @dev 코드 존재 여부만 검사하며 임의의 ERC20 동작을 검증하지는 않는다.
    /// @param asset_ 공급 대상으로 사용할 배포된 MockUSDC
    /// @param collateralAsset_ 원시 수량을 보관할 배포된 MockWBTC
    constructor(IERC20 asset_, IERC20 collateralAsset_) {
        if (address(asset_) == address(0) || address(asset_).code.length == 0) {
            revert InvalidAsset(address(asset_));
        }
        if (address(collateralAsset_) == address(0) || address(collateralAsset_).code.length == 0) {
            revert InvalidCollateralAsset(address(collateralAsset_));
        }
        if (address(asset_) == address(collateralAsset_)) revert IdenticalAssets(address(asset_));
        asset = asset_;
        collateralAsset = collateralAsset_;
    }

    /// @notice 지정 주소의 반환 권리인 담보 최소 단위 수량을 조회한다.
    /// @param user 담보 기록을 조회할 소유자
    function collateralOf(address user) external view returns (uint256) {
        return _collateralBalances[user];
    }

    /// @notice 본인 WBTC를 실제로 받은 뒤 같은 원시 수량을 담보에 기록한다.
    /// @dev 공급·출금과 잠금을 공유하며 전송 실패는 토큰·승인·기록을 함께 복구한다.
    /// @param amount 소수점 8자리 WBTC 최소 단위 수량
    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        collateralAsset.safeTransferFrom(msg.sender, address(this), amount);
        _collateralBalances[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);
    }

    /// @notice 기록을 먼저 차감하고 요청한 WBTC를 본인 지갑으로 반환한다.
    /// @dev 전송 실패는 선차감한 담보 기록과 토큰 이동을 함께 복구한다.
    /// @param amount 소수점 8자리 WBTC 최소 단위 수량
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 deposited = _collateralBalances[msg.sender];
        if (amount > deposited) revert InsufficientCollateral(deposited, amount);
        _collateralBalances[msg.sender] = deposited - amount;
        collateralAsset.safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount);
    }

    /// @notice 실제 토큰 현금과 구분한 인정자산의 최소 단위 수량을 반환한다.
    function totalAssets() external view returns (uint256) {
        return _accountedAssets;
    }

    /// @notice 본인 지분의 USDC 가치를 최소 단위에서 내려 반환한다.
    /// @dev 지분0 주소도 잘못된 장부를 숨기지 않고 계산 모듈의 오류를 전파한다.
    /// @param user 환산할 지분의 소유자
    function deposits(address user) public view returns (uint256) {
        return ShareMath.toAssetsDown(shares[user], _accountedAssets, totalShares);
    }

    /// @notice 공급 전 비율로 받을 지분을 계산하고 토큰 전송 뒤 기록한다.
    /// @dev 토큰 전송 실패를 전파하므로 실패한 공급의 상태 변경은 모두 복구된다.
    /// @param amount 소수점 6자리가 적용된 정수 최소 단위 수량
    function supply(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 mintedShares = ShareMath.toSharesDown(amount, _accountedAssets, totalShares);
        if (mintedShares == 0) revert ZeroShares();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        _accountedAssets += amount;
        totalShares += mintedShares;
        shares[msg.sender] += mintedShares;
        emit Supplied(msg.sender, amount);
    }

    /// @notice 요청한 USDC에 필요한 지분을 올림해 차감하고 본인에게 지급한다.
    /// @dev 공급과 잠금을 공유하며 전송 실패는 자산·총지분·본인 지분 차감까지 복구한다.
    /// @param amount 소수점 6자리가 적용된 정수 최소 단위 수량
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 deposited = deposits(msg.sender);
        if (amount > deposited) revert InsufficientDeposit(deposited, amount);
        uint256 cash = asset.balanceOf(address(this));
        if (amount > cash) revert InsufficientLiquidity(cash, amount);

        uint256 burnedShares = ShareMath.toSharesUp(amount, _accountedAssets, totalShares);
        uint256 remainingAssets = _accountedAssets - amount;
        if (burnedShares == totalShares && remainingAssets != 0) revert ResidualAssets(remainingAssets);
        _accountedAssets = remainingAssets;
        totalShares -= burnedShares;
        shares[msg.sender] -= burnedShares;
        asset.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
}

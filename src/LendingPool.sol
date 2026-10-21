// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ShareMath} from "./libraries/ShareMath.sol";
import {CollateralMath} from "./libraries/CollateralMath.sol";
import {ICollateralPriceSource} from "./interfaces/ICollateralPriceSource.sol";

/// @title WBTC 담보로 USDC 원금을 빌리고 갚는 학습 풀
/// @notice 공급 지분·WBTC 담보·USDC 부채를 분리하고 정상 공급분의 현금만 지급한다.
/// @dev 고정6/8/8 Mock 자산·가격의 로컬 학습 단계이며 이자·청산·실제 오라클은 제외한다.
contract LendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice 배포 때 고정한 공급 자산이다.
    IERC20 public immutable asset;
    /// @notice USDC 장부와 분리해 수량 그대로 보관할 고정 담보 자산이다.
    IERC20 public immutable collateralAsset;
    /// @notice 배포 때 고정한 WBTC의 USDC 가격 원천이다.
    ICollateralPriceSource public immutable priceSource;
    /// @notice 정상 담보 입금으로 인정한 주소별 원시 수량이다.
    mapping(address => uint256) internal _collateralBalances;
    /// @notice 직접 전송·발행과 구분해 장부에서 인정한 USDC 자산이다.
    uint256 internal _accountedAssets;
    /// @notice 공급자의 지분 최소 단위 수량의 합이다.
    uint256 public totalShares;
    /// @notice 전송 가능한 토큰과 구분한 주소별 내부 지분이다.
    mapping(address => uint256) public shares;
    /// @notice 주소별 미상환 USDC 원금이며 공급 지분·담보와 별도로 기록한다.
    mapping(address => uint256) public debtOf;
    /// @notice 모든 사용자의 미상환 USDC 원금 합계다.
    uint256 public totalDebt;

    /// @notice 실제 전송에 성공한 공급의 주체와 최소 단위 수량을 알린다.
    event Supplied(address indexed user, uint256 amount);

    /// @notice 본인 지갑으로 반환한 출금의 주체와 최소 단위 수량을 알린다.
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice 정상 담보 입금의 주체와 이번 WBTC 요청량을 알린다.
    event CollateralDeposited(address indexed user, uint256 amount);

    /// @notice 본인에게 반환한 담보의 주체와 이번 WBTC 요청량을 알린다.
    event CollateralWithdrawn(address indexed user, uint256 amount);

    /// @notice 본인에게 지급한 USDC 대출 원금을 알린다.
    event Borrowed(address indexed user, uint256 amount);

    /// @notice 실제 수령한 본인 USDC 상환 원금을 알린다.
    event Repaid(address indexed user, uint256 amount);

    /// @notice 본인 부채보다 많은 상환은 일부 수령 없이 거절한다.
    error RepayExceedsDebt(uint256 debt, uint256 requested);

    /// @notice 원금이 남은 동안 담보는 일부도 반환할 수 없다.
    error OutstandingDebt(uint256 debt);

    /// @notice 이번 요청까지 포함한 총부채가 담보 한도를 넘으면 거절한다.
    error BorrowLimitExceeded(uint256 limit, uint256 currentDebt, uint256 requested);

    /// @notice 총부채가 인정자산보다 큰 손상 장부를 현금 부족으로 숨기지 않는다.
    error InvalidDebtAccounting(uint256 accountedAssets, uint256 totalDebt);

    /// @notice 여섯 자금 이동 진입점 모두 0 요청을 유효한 동작으로 취급하지 않는다.
    error ZeroAmount();

    /// @notice 양수 공급으로 지분을 받지 못하면 토큰을 받지 않고 거절한다.
    error ZeroShares();

    /// @notice 마지막 총지분을 없애면서 인정자산을 남기는 출금은 거절한다.
    error ResidualAssets(uint256 remainingAssets);

    /// @notice 본인의 예치 권리를 초과하는 출금은 부분 지급 없이 거절한다.
    error InsufficientDeposit(uint256 available, uint256 requested);

    /// @notice 직접 잉여와 대출 원금을 제외한 현금이 부족하면 요청 전체를 거절한다.
    error InsufficientLiquidity(uint256 available, uint256 requested);

    /// @notice 0 주소와 코드가 없는 주소는 자산으로 설정할 수 없다.
    error InvalidAsset(address asset);

    /// @notice 담보로 호출할 수 없는 0 주소와 코드 없는 주소를 거절한다.
    error InvalidCollateralAsset(address collateralAsset);

    /// @notice 가격을 호출할 수 없는 주소는 원천으로 설정할 수 없다.
    error InvalidPriceSource(address priceSource);

    /// @notice 연결한 계약의 정밀도가 고정 계산의 단위와 다르면 배포를 거절한다.
    error UnsupportedDecimals(address target, uint8 expected, uint8 actual);

    /// @notice 정밀도를 읽지 못하거나 정상 uint8 응답이 아니면 배포를 거절한다.
    error InvalidDecimalsMetadata(address target);

    /// @notice 공급 자산과 담보 자산은 서로 다른 계약이어야 한다.
    error IdenticalAssets(address asset);

    /// @notice 본인 기록보다 많은 담보 반환은 일부 지급 없이 거절한다.
    error InsufficientCollateral(uint256 available, uint256 requested);

    /// @notice 서로 다른 두 자산과 가격 원천을 고정하고 실제 정밀도 6/8/8을 검사한다.
    /// @dev 가격값은 조회하지 않으며 metadata 일치가 임의 토큰의 신뢰성을 보장하지는 않는다.
    /// @param asset_ 공급 대상으로 사용할 배포된 MockUSDC
    /// @param collateralAsset_ 원시 수량을 보관할 배포된 MockWBTC
    /// @param priceSource_ WBTC의 USDC 직접호가를 제공할 가격 원천
    constructor(IERC20 asset_, IERC20 collateralAsset_, ICollateralPriceSource priceSource_) {
        if (address(asset_) == address(0) || address(asset_).code.length == 0) {
            revert InvalidAsset(address(asset_));
        }
        if (address(collateralAsset_) == address(0) || address(collateralAsset_).code.length == 0) {
            revert InvalidCollateralAsset(address(collateralAsset_));
        }
        if (address(asset_) == address(collateralAsset_)) revert IdenticalAssets(address(asset_));
        if (address(priceSource_) == address(0) || address(priceSource_).code.length == 0) {
            revert InvalidPriceSource(address(priceSource_));
        }
        _checkDecimals(address(asset_), 6);
        _checkDecimals(address(collateralAsset_), 8);
        _checkDecimals(address(priceSource_), 8);
        asset = asset_;
        collateralAsset = collateralAsset_;
        priceSource = priceSource_;
    }

    /// @notice 읽기 전용 응답의 길이와 uint8 범위를 확인한 뒤 기대 정밀도와 비교한다.
    function _checkDecimals(address target, uint8 expected) private view {
        (bool success, bytes memory data) = target.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (!success || data.length != 32) revert InvalidDecimalsMetadata(target);
        uint256 raw = abi.decode(data, (uint256));
        if (raw > type(uint8).max) revert InvalidDecimalsMetadata(target);
        // 위 범위 검사로 잘림 없이 변환할 수 있다.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 actual = uint8(raw);
        if (actual != expected) revert UnsupportedDecimals(target, expected, actual);
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

    /// @notice 본인 부채가0일 때만 기록을 먼저 차감하고 WBTC를 반환한다.
    /// @dev 가격을 읽지 않으며 전송 실패는 담보 기록과 토큰 이동을 함께 복구한다.
    /// @param amount 소수점 8자리 WBTC 최소 단위 수량
    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 debt = debtOf[msg.sender];
        if (debt != 0) revert OutstandingDebt(debt);
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

    /// @notice 직접 유입 잉여와 이미 빌려준 원금을 제외한 지급 가능 USDC를 반환한다.
    function availableLiquidity() public view returns (uint256) {
        if (totalDebt > _accountedAssets) revert InvalidDebtAccounting(_accountedAssets, totalDebt);
        uint256 remaining = _accountedAssets - totalDebt;
        uint256 cash = asset.balanceOf(address(this));
        return cash < remaining ? cash : remaining;
    }

    /// @notice 유효한 담보 한도와 지급 가능 현금 안에서 본인에게 원금을 빌려준다.
    /// @dev 부채를 먼저 늘리며 전송 실패는 그 기록과 토큰 이동을 함께 복구한다.
    /// @param amount 소수점6자리 USDC 최소 단위 수량
    function borrow(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        (int256 price, uint256 updatedAt) = priceSource.latestPrice();
        uint256 limit = CollateralMath.maxDebtDown(_collateralBalances[msg.sender], price, updatedAt, block.timestamp);
        uint256 debt = debtOf[msg.sender];
        if (debt > limit || amount > limit - debt) revert BorrowLimitExceeded(limit, debt, amount);
        uint256 available = availableLiquidity();
        if (amount > available) revert InsufficientLiquidity(available, amount);
        debtOf[msg.sender] = debt + amount;
        totalDebt += amount;
        asset.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    /// @notice 승인한 USDC를 실제 수령한 뒤 본인의 미상환 원금만 줄인다.
    /// @dev 가격을 읽지 않으며 전송 실패 시 승인·토큰·부채를 모두 복구한다.
    /// @param amount 소수점6자리 USDC 최소 단위 수량
    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 debt = debtOf[msg.sender];
        if (amount > debt) revert RepayExceedsDebt(debt, amount);
        asset.safeTransferFrom(msg.sender, address(this), amount);
        debtOf[msg.sender] = debt - amount;
        totalDebt -= amount;
        emit Repaid(msg.sender, amount);
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
    /// @dev 대출과 같은 현금 한도를 사용하며 전송 실패는 자산·총지분·본인 지분까지 복구한다.
    /// @param amount 소수점 6자리가 적용된 정수 최소 단위 수량
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 deposited = deposits(msg.sender);
        if (amount > deposited) revert InsufficientDeposit(deposited, amount);
        uint256 available = availableLiquidity();
        if (amount > available) revert InsufficientLiquidity(available, amount);

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

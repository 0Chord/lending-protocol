// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title 담보 실습용 MockWBTC
/// @notice 실제 BTC 보관·교환과 연결되지 않은 테스트용 ERC20이다.
/// @dev 누구나 발행할 수 있으므로 테스트 환경에서 잔고를 준비하는 용도로만 사용한다.
contract MockWBTC is ERC20 {
    /// @notice 테스트 토큰의 이름과 심볼을 정한다.
    constructor() ERC20("Mock WBTC", "mWBTC") {}

    /// @notice 토큰 표시 단위를 소수점 8자리로 정하며 잔고를 자동 환산하지 않는다.
    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /// @notice 수령자의 잔고와 총발행량을 입력한 최소 단위 수량만큼 늘린다.
    /// @dev 발행 권한은 제한하지 않으며 0 주소 수령자는 ERC20 규칙에 따라 거절한다.
    /// @param to 테스트 토큰을 지급받을 주소
    /// @param amount 소수점 8자리가 적용된 정수 최소 단위 수량
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

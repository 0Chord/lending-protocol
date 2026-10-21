# Lending Protocol 학습 프로젝트

Solidity·Foundry로 공급·출금부터 작은 단위로 만드는 개인 학습 프로젝트다.
현재 구현 범위는 [이슈 #1](https://github.com/0Chord/lending-protocol/issues/1)의 테스트 환경·MockUSDC와
[#2](https://github.com/0Chord/lending-protocol/issues/2)의 본인 공급·예치 기록과
[#3](https://github.com/0Chord/lending-protocol/issues/3)의 본인 출금과
[#7](https://github.com/0Chord/lending-protocol/issues/7)의 지분 환산 계산과
[#8](https://github.com/0Chord/lending-protocol/issues/8)의 공급·출금·조회 연결과
[#11](https://github.com/0Chord/lending-protocol/issues/11)의 테스트용 MockWBTC와
[#12](https://github.com/0Chord/lending-protocol/issues/12)의 Mock 가격·담보 가치/한도 계산이다. 테스트 전용 로컬 학습 프로젝트다.

## 실행 환경

Git과 Foundry가 설치된 환경에서 프로젝트 파일과 서브모듈 고정 정보를 받은 뒤 루트에서 실행한다.

```sh
git submodule update --init --recursive
forge fmt --check
forge build
forge test --match-contract MockUSDCTest -vv
forge test --match-contract MockWBTCTest -vv
forge test --match-contract LendingPoolTest -vv
forge test --match-contract LendingPoolSharesTest -vv
forge test --match-contract ShareMathTest -vv
forge test --match-contract CollateralMathTest -vv
forge test --match-contract CollateralPriceSourceTest -vv
forge test
```

첫 실행에는 의존성과 Solidity 컴파일러를 받기 위한 네트워크 연결이 필요하다.
테스트는 로컬 EVM에서 실행되며 지갑·RPC·실제 USDC가 필요하지 않다.

| 항목 | 고정한 값 |
| --- | --- |
| Solidity | `0.8.37` |
| EVM 대상 | `cancun` |
| forge-std | `v1.16.1`, `620536fa5277db4e3fd46772d5cbc1ea0696fb43` |
| OpenZeppelin Contracts | `v5.7.0`, `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` |
| 검증에 사용한 Foundry | `1.6.0-v1.7.0`, commit `f83bad912a9dba7bf0371def1e70bb1896048356` |

컴파일러·EVM 대상·import 연결은 [foundry.toml](foundry.toml)에 있다.
서브모듈의 Git 고정 커밋과 [foundry.lock](foundry.lock)에 같은 의존성 커밋을 기록한다.
다른 작업 사본에서도 `git submodule update --init --recursive`로 그 커밋을 복원한다.

forge-std는 현재 설치된 Foundry에서 사용할 조합으로 고정했다.
[v1.17.0 릴리스](https://github.com/foundry-rs/forge-std/releases/tag/v1.17.0)는 새 `Vm.Gas` 구조 때문에 Foundry v1.8.3 이상을 권고한다.
EVM 대상은 컴파일러 기본값 변화에 영향을 받지 않도록 명시했다.

## 이번에 읽을 동작: Mock 가격으로 담보 가치와 한도를 계산한다

#12는 가격과 갱신시각을 검증한 뒤 **WBTC 담보의 USDC 가치와 그 70% 한도**를 계산한다.
아직 풀에 담보를 맡기거나 대출하지 않는다. 아래 가격은 테스트 입력이며 실제 시장가격이 아니다.

첫 예시는 **1 WBTC·가격 100 USDC → 가치 100 USDC·한도 70 USDC**다.
테스트는 [CollateralMathTest](test/CollateralMath.t.sol)의 `test_OneWBTCAtOneHundredUSDC`부터 읽는다.

| 값 | 사람이 읽는 수량 | 함수에 전달하는 정수 |
| --- | --- | ---: |
| WBTC 수량 | 1 WBTC, 소수점 8자리 | `100_000_000` |
| 가격 | 1 WBTC당 100 USDC, 소수점 8자리 직접호가 | `10_000_000_000` |
| 가치 / 한도 | 100 / 70 USDC, 소수점 6자리 | `100_000_000` / `70_000_000` |

갱신시각·현재시각을 각각 `10_000`초로 준비한다. [CollateralMath](src/libraries/CollateralMath.sol)는
가격 → 갱신시각 → 지난 시간 순으로 검사하고, 수량과 가격을 곱해 `10^10`으로 나눈다.
8자리 두 개를 곱한 16자리에서 USDC 6자리를 남기기 위한 배율이다.
그 뒤 먼저 내린 가치에 `7000 / 10000`을 적용해 다시 내린다.
두 곱셈은 기존 고정 OpenZeppelin `Math.mulDiv`를 사용하므로 중간 곱이 크더라도 최종 결과가 맞으면 계산할 수 있다.

### 왜 두 번 내리나

이 명세는 **먼저 USDC 최소 단위로 확정한 담보 가치에 70%를 적용**한다.
WBTC 최소 단위 3과 가격 150 USDC를 준비하면 다음 차이가 드러난다.
아래 숫자는 USDC 개수가 아니라 **최소 단위**이며, 최소 단위 1은 0.000001 USDC다.

| 단계 | 계산 | 반환하는 정수 |
| --- | --- | ---: |
| 담보 가치 | WBTC raw 3 × 가격 raw 15,000,000,000 ÷ 10,000,000,000 = 4.5 | 4 |
| 대출 한도 | 먼저 내린 4 × 70% = 2.8 | 2 |

계산을 합쳐 마지막에만 내리면 `4.5 × 70% = 3.15 → 3`이어서 결과가 달라진다.
두 번 내리는 것이 모든 프로토콜의 필수 규칙이라는 뜻은 아니다. 이번 구현은 이슈의 두 단계 계약을 유지하며,
`test_ValueAndLimitRoundDownInTwoSteps`가 결과 4와 2를 각각 직접 비교한다.
100 USDC처럼 나누어떨어지는 예시에서는 두 방식의 차이가 없다.

### 계산과 가격 원천의 역할

| 역할 | 입력 → 결과 | 위치 |
| --- | --- | --- |
| 원시 가격 계약 | 8자리 부호 있는 가격·갱신시각 반환 | [ICollateralPriceSource](src/interfaces/ICollateralPriceSource.sol) |
| 테스트 가격 준비 | 가격만/시각만 독립 변경, 잘못된 값도 그대로 반환 | [MockCollateralPriceSource](test/mocks/MockCollateralPriceSource.sol) |
| 순수 계산 | 원시 가격·시각 검증 → 가치 내림 → 70% 한도 내림 | [CollateralMath](src/libraries/CollateralMath.sol)의 `collateralValueDown`, `maxDebtDown` |
| 시험 호출 경계 | 원천을 한 번 읽어 반환값과 현재시각을 계산기에 전달 | [CollateralPriceSourceTest](test/CollateralPriceSource.t.sol)의 테스트 전용 harness |
| 원천 장애 | 조회 즉시 `PriceSourceUnavailable()` 발생 | [RevertingCollateralPriceSource](test/mocks/RevertingCollateralPriceSource.sol) |

계산기는 `internal pure`이며 토큰·가격 원천·`block.timestamp`를 직접 읽지 않는다.
원천을 읽는 시험용 wrapper가 실제 현재시각을 전달한다. wrapper는 생산 풀 API가 아니다.
Mock 원천이 음수나 미래시각을 반환하는 것은 정상 동작이며, 그 값을 평가에 사용할 수 있는지는 계산기가 거절한다.
가격 설정 시 갱신시각을 자동으로 현재시각으로 바꿔 오래된 가격을 숨기지 않는다.

### 잘못된 입력은 계산 전에 거절한다

| 순서 | 입력 | 관측하는 오류/결과 |
| --- | --- | --- |
| 1 | 가격 0·음수·int256 최솟값 | `InvalidPrice(입력 가격)` |
| 2 | 갱신시각 0 또는 현재시각보다 미래 | `InvalidPriceTimestamp(갱신시각, 현재시각)` |
| 3 | 갱신 후 정확히 3600초 / 3601초 | 계산 허용 / `StalePrice(갱신시각, 현재시각)` |
| 4 | 각 단계의 최종 정수 결과가 uint256 범위 초과 | 정확한 `Panic(0x11)` 전파 |

담보가 0이어도 위 가격·시각 검사를 생략하지 않는다. 유효한 입력의 담보 0은 가치·한도가 모두 0이다.
양수를 확인한 뒤 가격을 uint256으로 변환하고, 미래시각을 거절한 뒤 경과시간을 뺀다.
`maxDebtDown`은 먼저 가치 계산을 호출하므로 동일한 오류 순서와 첫 단계 범위 제한을 유지한다.
실패는 오류를 잡아 0 한도로 바꾸지 않고 호출자에게 전파하며, 계산기 자체는 상태를 바꾸지 않는다.

<details>
<summary>#12 테스트의 준비·실행·실제 확인</summary>

[CollateralMathTest](test/CollateralMath.t.sol)는 매 테스트 새 외부 harness를 준비한다.
정상 값은 이슈의 고정 정수와 비교하고, 오류는 `vm.expectRevert` 다음에 harness의 external 메서드를 실제 호출한다.
같은 기대 오류를 가치·한도 두 함수에서 각각 전체 인수까지 비교한다.

| 테스트 묶음 | 준비·실행 | 실제 확인 |
| --- | --- | --- |
| 1 WBTC·0.5 WBTC·최소 단위 3·담보 0 | 유효한 가격·시각, 고정 수량 입력 | 가치/한도 각각 100m/70m, 50m/35m, 4/2, 0/0 |
| 비양수 가격·오류 순서 | 가격 0/-1/int256.min, 담보0+가격0+시각0 포함 | 각 가격의 `InvalidPrice`, 담보0도 가격 오류를 우선 |
| 시간과 우선순위 | 현재10000, 갱신6400/6399/0/10001, 담보0도 별도 준비 | 3600초 허용·3601초 거절, 0/미래시각은 timestamp 오류. 두 함수 모두 같은 인수 |
| 큰 중간 곱과 최종 범위 | 담보 uint256.max, 가격10,000,000,000 / 10,000,000,001 | 첫 입력의 가치 max와 고정 70% 한도 성공, 두 번째는 가치부터 범위 초과해 두 함수 모두 Panic(0x11) |

[CollateralPriceSourceTest](test/CollateralPriceSource.t.sol)는 다음 원천/연결 사례를 별도로 확인한다.

| 준비·실행 | 실제 확인 |
| --- | --- |
| 생성자에서 가격10b·시각6400 주입 후 interface 조회 | 주입한 두 정수 그대로 반환 |
| 가격만15b로 변경 / 이어 시각만0으로 변경 | 바꾸지 않은 나머지 값 보존 |
| 생성자·setter의 잘못된 원시값 표 | (0,0), (-1,6400), (int256.min,10001), (15b,10001)을 현재10000에서도 그대로 반환 |
| 100·150 USDC 가격의 원천을 wrapper로 각각 조회해 1 WBTC 한도 계산 | 70m·105m, 각 원천의 실제 `latestPrice()` 호출 대상·calldata·정확히1회 확인 |
| 오래된 시각6399의 원천을 wrapper에 연결 | StalePrice(6399,10000), 원시 가격·시각 보존. 소비자가 시각을 덮어쓰지 않음 |
| 조회 시 오류를 내는 원천을 wrapper에 연결 | 실제 조회와 정확한 원천 오류 전파. 0 반환이나 오류 삼킴으로 통과하지 않음 |

이 검사는 로컬 원천 모형·계산·시험 wrapper의 연결이다. 실제 Chainlink·시장가격·RPC를 호출하지 않는다.
토큰 이동·승인·부채·담보 기록은 없고, 외부 연동이나 가격 조회의 재진입 방어를 검증한 것으로 확대하지 않는다.
계산기의 getter가 테스트에 존재하는 것과 생산 풀에 가격 기능을 붙인 것은 다르다.

</details>

## MockWBTC를 읽는 순서

#11은 **소수점 8자리 토큰과 테스트 잔고 발행**만 추가한다.
실제 BTC를 보관하거나 BTC와 교환하는 기능은 없다. 기존 LendingPool은 계속 MockUSDC만 사용한다.
WBTC 담보 입금·반환은 후속 [#13](https://github.com/0Chord/lending-protocol/issues/13)에서 연결한다.

먼저 [MockWBTC](src/mocks/MockWBTC.sol)의 `decimals()`를 읽고,
[MockWBTCTest](test/MockWBTC.t.sol)의 `test_DecimalsAreEight`에서 고정값 `8`과 비교하는 검증문을 확인한다.
같은 정수 `100_000_000`도 MockWBTC에서는 **1 WBTC**, 기존 MockUSDC에서는 **100 USDC**다.
소수점 설정은 표시 방법만 정하며, `mint` 입력이나 잔고를 자동으로 환산하지 않는다.

다음은 새 토큰에서 Alice에게 1 WBTC를 발행하는 흐름이다.

```solidity
function mint(address to, uint256 amount) external {
    _mint(to, amount);
}
```

호출자가 `mint(Alice, 100_000_000)`을 실행하면 상속한 ERC20의 `_mint`가 수령자를 검사한다.
정상 주소라면 Alice 잔고와 총발행량을 각각 `100_000_000` 늘리고,
0 주소에서 Alice에게 발행했다는 `Transfer` 이벤트를 남긴다. Bob의 잔고는 그대로다.
이 함수는 누구나 호출하는 테스트 잔고 준비 수단이며, 승인·실제 BTC 입금·풀 예치 기록과는 별개다.

각 테스트의 `setUp()`은 새 토큰을 배포하므로 다른 테스트의 잔고를 이어받지 않는다.
Alice와 Bob은 테스트용 주소다. 아래 기대값은 모두 이슈에서 정한 **WBTC 정수 최소 단위**다.

| 테스트 | 준비 → 실행 | 실제 비교하는 결과 |
| --- | --- | --- |
| `test_DecimalsAreEight` | 새 토큰 → `decimals()` 조회 | `8` |
| `test_MintCreditsOnlyRecipientAndIncreasesTotalSupply` | Alice·Bob·총발행량 0 → Alice에게 `100_000_000` 발행 | Alice `100_000_000`, Bob `0`, 총발행량 `100_000_000`. 토큰 주소의 Transfer가 정확히 1회이며 from 0·to Alice·수량도 일치 |
| `test_MintAddsToExistingBalances` | Alice `25_000_000`·Bob `7_000_000` → Alice에게 `100_000_000` 추가 | Alice `125_000_000`, Bob `7_000_000`, 총발행량 `132_000_000` |
| `test_MintToZeroAddressRevertsWithoutChangingSupply` | Alice `25_000_000` → 0 주소에 `100_000_000` 발행 시도 | `ERC20InvalidReceiver(address(0))`. Alice `25_000_000`, Bob·0 주소 `0`, 총발행량 `25_000_000` 유지, 실패 요청의 로그 0개 |
| `test_NonDeployerCanMintTestBalance` | 새 토큰 → 배포자가 아닌 Bob이 Alice에게 `50_000_000` 발행 | Alice `50_000_000`, Bob `0`, 총발행량 `50_000_000` |

0 주소 발행은 `_mint`가 장부를 바꾸기 전에 거절한다. 예외를 잡고 성공으로 진행하지 않는다.
이 실패 시험은 기존 값 보존을 확인하며, 이미 이동한 토큰의 복구를 시험하는 것은 아니다.
성공 테스트는 실제 로그의 발행 주소·서명·수령자·수량·횟수를 비교한다.
테스트에서 쓰는 Bob 호출자 설정은 새 토큰을 발행하는 것이 아니라 호출 주체를 바꾼다.

위 검사는 로컬 Mock의 단위·발행 연결을 확인한다. 실제 WBTC의 BTC 준비금·발행 권한·교환 서비스 연동이나
후속 담보·가격·대출 기능을 검증하지 않는다. 기존 MockUSDC·풀·지분 테스트도 별도로 유지한다.

## 먼저 읽을 동작: 지분을 저장하고 예치금을 계산한다

#7 계산기를 실제 공급·출금에 연결했다. 저장하는 값은 **내 지분 수량**, 예치금 조회가 보여주는 값은 **그 지분의 USDC 가치**다.
구현은 [LendingPool](src/LendingPool.sol)의 `shares`, `supply`, `withdraw`, `deposits`다.

```solidity
mapping(address => uint256) public shares;

function deposits(address user) public view returns (uint256) {
    return ShareMath.toAssetsDown(shares[user], _accountedAssets, totalShares);
}
```

공급하면 계산한 지분을 더하고, 출금하면 필요한 지분을 줄인다. `deposits`는 저장된 지분을 읽어 USDC로 환산하며 상태를 바꾸지 않는다.
예를 들어 내 지분3개·전체6개·인정자산10 USDC라면 조회 결과는5 USDC다.
인정자산은 정상 공급·출금으로 기록한 금액이며, 실제 풀 현금과 구분한다. 직접 송금은 현금만 늘린다.

먼저 새 풀에서 Alice200 → 공급100 → 출금40을 읽는다. 첫 비율은1:1이고 아래 표는 사람이 읽는 USDC/지분 단위다.

| 확인할 값 | 공급 후 | 출금 후 |
| --- | ---: | ---: |
| Alice 토큰 | 100 USDC | 140 USDC |
| 풀 현금 | 100 USDC | 60 USDC |
| Alice 지분 / 전체 지분 | 각각100개 | 각각60개 |
| 인정자산 / 조회한 Alice 예치금 | 각각100 USDC | 각각60 USDC |

[첫 출금 테스트](test/LendingPool.t.sol)의 `test_WithdrawMovesTokensAndDebitsOnlyCallerWithoutNewApproval`은 두 시점의 자산·총지분·Alice 지분과 토큰·승인0·총발행량200·Bob 상태0을 직접 비교한다.
첫 공급 테스트도 같은 기록과 USDC 성공 이벤트1회를 확인한다. `amount`와 이벤트 금액은 계속 USDC다.
비율이 다른 상황은 [새 연결 테스트](test/LendingPoolShares.t.sol)에서만 준비하며, 현재 풀에 수익·손실을 인정하는 기능은 없다.

아래 공급·출금의 기존 예시는 첫1:1 상태다. 그 예시의 예치금은 `deposits`가 계산한 USDC 값이며 별도 금액 원장을 저장하는 뜻이 아니다.
다른 비율의 반올림·거절·복구는 뒤의 접이식 테스트 안내에서 필요한 사례를 읽는다.

## MockUSDC를 읽는 순서

| 흐름 | 시작과 결과 | 코드·검증 위치 |
| --- | --- | --- |
| 소수점 설정 | `decimals()` 조회 → `6` | [MockUSDC](src/mocks/MockUSDC.sol), `test_DecimalsAreSix` |
| 테스트 토큰 지급 | `mint(Alice, 100_000_000)` → Alice 잔고·총발행량 증가 | `mint`, `test_MintCreditsOnlyRecipientAndIncreasesTotalSupply` |
| 추가 지급 | 기존 잔고에 수량을 더하고 다른 주소의 잔고 유지 | `test_MintAddsToExistingBalances` |
| 잘못된 수령자 | 0 주소로 발행 → 오류, 기존 잔고·총발행량 유지 | `test_MintToZeroAddressRevertsWithoutChangingSupply` |

테스트는 모두 [test/MockUSDC.t.sol](test/MockUSDC.t.sol)에 있다.
`setUp()`은 각 테스트마다 새 MockUSDC를 배포한다. 테스트 사이에 잔고를 공유하지 않는다.
`ALICE`와 `BOB`은 테스트용 주소이며 별도 지갑은 필요하지 않다.

### 첫 단위: 소수점 6자리

새 토큰에서 `decimals()`를 조회하고 그 반환값이 `6`인지 직접 비교한다.
MockUSDC는 ERC20의 설정을 다음과 같이 바꾼다.

```solidity
function decimals() public pure override returns (uint8) {
    return 6;
}
```

이 함수는 표시할 소수점 자릿수를 반환한다. 잔고를 자동으로 곱하거나 나누지 않는다.
따라서 100 USDC 지급 시 호출자가 `100_000_000`이라는 정수 최소 단위를 전달한다.

### 지급 테스트의 준비·실행·확인

| 테스트 | 준비 | 실행 | 실제 확인하는 결과 |
| --- | --- | --- | --- |
| `test_MintCreditsOnlyRecipientAndIncreasesTotalSupply` | 새 토큰, Alice 잔고·총발행량 0 | Alice에게 `100_000_000` 발행 | Alice `100_000_000`, Bob `0`, 총발행량 `100_000_000` |
| `test_MintAddsToExistingBalances` | Alice `25_000_000`, Bob `7_000_000` 지급 | Alice에게 `100_000_000` 추가 발행 | Alice `125_000_000`, Bob `7_000_000`, 총발행량 `132_000_000` |
| `test_MintToZeroAddressRevertsWithoutChangingSupply` | Alice에게 `25_000_000` 지급 | 0 주소에 `100_000_000` 발행 시도 | `ERC20InvalidReceiver(address(0))` 오류, Alice `25_000_000`, 0 주소 `0`, 총발행량 `25_000_000` 유지 |

기대 금액은 명세의 고정 예시에서 정했다. 실제 함수의 반환값이나 `decimals()`로 예상 금액을 다시 계산하지 않는다.
지급 함수의 핵심은 OpenZeppelin ERC20의 `_mint(to, amount)` 호출이다.
정상 호출에서는 수령자의 잔고와 총발행량이 늘어난다. 0 주소는 ERC20이 상태 변경 전에 거절한다.

## 공급 기능을 읽는 순서

공급은 새 토큰을 발행하지 않는다. Alice가 가진 토큰을 풀로 옮기고 그 사람의 공급 권리를 별도 장부에 더한다.
구현은 [LendingPool](src/LendingPool.sol), 테스트는 [LendingPoolTest](test/LendingPool.t.sol)에 있다.
먼저 아래 정상 공급 하나를 읽고, 나머지 흐름은 표에서 필요한 부분으로 내려간다.

### Alice의 토큰 이동과 예치 기록은 같은 공급 호출에 묶인다

준비: 새 토큰·풀을 만들고 Alice에게만 200 USDC를 발행한다. Alice는 풀에 100 USDC의 유한 승인을 준다.
`approve`는 토큰 이동이나 예치 기록 증가를 일으키지 않는다. 그다음 Alice가 `supply(100_000_000)`을 호출한다.

| 관측값 | 공급 직전 | 공급 성공 후 |
| --- | ---: | ---: |
| Alice 토큰 | 200 USDC | 100 USDC |
| 풀 토큰 | 0 | 100 USDC |
| Alice 예치 기록 | 0 | 100 USDC |
| Alice → 풀 승인량 | 100 USDC | 0 |
| 총발행량 | 200 USDC | 200 USDC |
| Bob 토큰·예치 기록 | 각각 0 | 각각 0 |

실제 핵심 코드는 다음과 같다. 100 USDC의 정수 최소 단위는 `100_000_000`이다.

```solidity
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
```

Alice의 호출에서 `msg.sender`는 Alice이고 `address(this)`는 풀이다.
토큰 계약에서는 풀이 승인 사용 주체(spender)로 호출한다. Alice가 풀에 준 승인을 사용해 Alice의 잔고를 줄이고 풀의 잔고를 늘린다.
공급 전 비율로 지분을 계산하고 전송 성공 후 인정자산에 USDC 금액, 총지분·Alice 지분에 계산한 지분을 더한다.
`deposits(Alice)`는 그 기록의 환산 결과다. 내부 지분은 새 ERC20이나 토큰 발행량이 아니다.

`test_SupplyMovesTokensAndCreditsOnlyCaller`는 위 표의 값을 실제 검증문으로 비교한다.
`_assertOneSupplyEvent`는 토큰의 Transfer 로그와 구분해 풀에서 발생한 `Supplied(Alice, 100_000_000)`가 정확히 한 번인지 확인한다.

### 공급이 실패하면 직전 상태가 남는다

승인과 공급은 사용자의 별도 거래다. 공급 실패가 이미 성공한 approve를 취소하는 것은 아니다.
실패한 supply 안에서 차감한 승인량은 supply 직전 값으로 돌아간다.

예를 들어 잔고 99·승인 100에서 공급 100을 요청하면, ERC20은 승인을 먼저 차감한 뒤 잔고 부족 오류를 낸다.
그 오류가 전파되어 해당 공급의 변경을 복구하므로 잔고 99·승인 100과 기존 예치 기록이 유지된다.
풀은 토큰 오류를 잡고 성공으로 진행하지 않는다. false 반환은 SafeERC20이 오류로 바꾸고, 토큰의 명시적 오류는 그대로 전파한다.

전송 실패 테스트는 먼저 40 USDC 공급을 완료하고 새 승인 100을 준 상태에서 시작한다.
[실패 토큰](test/mocks/FailingMockUSDC.sol)은 실제 전송·승인 차감 후 false를 반환하거나 지정 오류를 낸다.
공급 실패 뒤 Alice 토큰 160·풀 토큰 40·Alice 예치 40·승인 100이 유지되는지 검사한다.
`test_FalseTokenControlActuallyMovesTokensBeforeReturningFalse`는 풀 밖에서 모형을 직접 호출해 false와 실제 잔고 변경이 함께 발생함을 대조한다.
따라서 아무것도 하지 않는 모형을 보고 복구를 검증했다고 해석하지 않는다.

### 새 테스트의 준비·실행·실제 확인

공통 `setUp()`은 각 테스트마다 새 토큰·풀과 Alice의 200 USDC만 준비한다. 서로 다른 테스트의 상태를 공유하지 않는다.
`_approveAndSupply`는 지정한 사용자의 승인과 공급을 준비하는 함수다.
`_snapshot`과 `_assertStateUnchanged`는 검사할 호출 직전의 Alice·Bob 토큰, 풀 토큰, 양쪽 예치 기록·승인, 총발행량을 비교한다.
실패 보존 검사는 기존8개에 인정자산·총지분·두 사용자 지분을 더한12개 값을 확인한다.
아래 숫자는 별도 표시가 없으면 USDC이며, 실제 입력과 기대값은 고정한 정수 최소 단위로 작성했다.

| 테스트 | 준비 → 실행 | 실제 확인 |
| --- | --- | --- |
| `test_SupplyMovesTokensAndCreditsOnlyCaller` | Alice 200·승인 100 → 공급 100 | 위 표의 7개 관측값과 풀의 공급 이벤트 1회 |
| `test_ConstructorFixesAsset` | 토큰 주소로 풀 생성 → 자산 조회 | 설정한 토큰 주소와 같음 |
| `test_ConstructorRejectsZeroAsset` | 0 주소 → 풀 생성 시도 | `InvalidAsset(0)` 오류 |
| `test_ConstructorRejectsAssetWithoutCode` | 코드 없는 Alice 주소 → 풀 생성 시도 | `InvalidAsset(Alice)` 오류 |
| `test_AdditionalSupplyAddsToExistingDeposit` | 100 공급 → 추가 승인·공급 20 | Alice 80·풀/예치 120·승인 0·발행량 200·Bob 예치 0, 두 번째 공급 이벤트는 누적 120이 아닌 요청 20으로 1회 |
| `test_DifferentUsersKeepSeparateDeposits` | Alice 200·Bob 30 → Alice 100, Bob 30 공급 | 예치 각각 100/30·풀 130, Alice 토큰 100·Bob 0, 양쪽 승인 0·발행량 230 |
| `test_SupplyAcceptsOneSmallestUnit` | Alice 200 → 최소 단위 1 승인·공급 | Alice 199_999_999·풀/예치 1·승인 0·발행량 200_000_000 |
| `test_ZeroSupplyRevertsWithoutChangingState` | 기존 예치 40·새 승인 100 → 공급 0 | `ZeroAmount()`와 호출 직전12개 상태 보존 |
| `test_InsufficientAllowanceRevertsWithoutChangingState` | 기존 예치 40, Alice 토큰을 200으로 준비·승인 99 → 공급 100 | `ERC20InsufficientAllowance(pool, 99, 100)`와 직전 상태 보존 |
| `test_InsufficientBalanceRestoresSpentAllowanceAndExistingDeposit` | 기존 공급 101 후 잔고 99·승인 100 → 공급 100 | `ERC20InsufficientBalance(Alice, 99, 100)`, 승인 100·기존 예치 101을 포함한 직전 상태 보존 |
| `test_FalseTokenControlActuallyMovesTokensBeforeReturningFalse` | 장애 토큰 Alice 200·테스트 주소에 승인 100 → Bob에게 직접 전송 | 반환 false, Alice/Bob 각각 100·승인 0·발행량 200. 풀 공급을 거치지 않는 모형 대조 |
| `test_FalseTransferRollsBackTokenChangesAndKeepsExistingDeposit` | 기존 공급 40·승인 100 → 전송 뒤 false | 정확한 `SafeERC20FailedOperation(token)`과 직전 상태 보존, 기존 예치 40 |
| `test_RevertingTransferBubblesExactErrorAndPreservesState` | 기존 공급 40·승인 100 → 전송 중 지정 오류 | `InjectedTransferFailure()` 전파와 직전 상태 보존 |
| `test_DirectTransferDoesNotCreateDepositOrInflateLaterSupply` | Alice 200 → 풀로 직접 전송 10 → 공급 100 | 직접 전송 직후 예치 0·풀 10·공급 이벤트 없음, 이후 Alice 90·풀 110·예치 100·발행량 200 |
| `test_DirectMintDoesNotChangeExistingDeposits` | 기존 공급 40 → 풀에 직접 발행 10 | Alice 토큰 160·풀 50·예치 40·Bob 예치 0·발행량 210·공급 이벤트 없음 |
| `test_ReentryIsRejectedWhileOuterSupplySucceedsOnce` | 콜백 토큰에 자체 잔고·승인 최소 단위 1, Alice 200·승인 100 → 공급 100 중 재호출 | 콜백 시도·정확한 guard 오류·바깥 공급만 1회 성공, 토큰 주소의 잔고·승인 1·예치 0 유지 |

전송 전 공급→공급 모형은 [ReentrantMockUSDC](test/mocks/ReentrantMockUSDC.sol)다. 전송 후 다른 경로·장부 관측은 아래의 Cross 모형으로 구분한다.
토큰이 중첩 호출하면 그 호출자는 Alice가 아니라 토큰 주소다. 충분한 자체 잔고·승인과 양수 금액을 준비해 승인·잔고 부족으로 인한 거짓 통과를 막는다.
중첩 오류를 잡아 바깥 전송을 계속하므로 테스트는 콜백 실행과 오류를 조회할 수 있다.
재진입 실패와 별도로 Alice의 토큰/예치 100·풀 토큰 100·승인 0·Bob 상태 0, 총발행량 200_000_001, 공급 이벤트 1회를 확인한다.
추가된 최소 단위 1은 준비에서 발행한 토큰이며 공급이 새로 발행한 수량이 아니다.

## 출금 기능을 읽는 순서

출금은 요청한 USDC를 본인에게 돌려주면서 그 금액에 필요한 지분을 올림해 차감한다.
제품 코드는 [LendingPool.withdraw](src/LendingPool.sol#L87), 검증 코드는 [LendingPoolTest](test/LendingPool.t.sol)에 있다.
먼저 첫 40 출금과 실패 복구를 읽고, 나머지 경계는 아래 테스트 표로 이어간다.

| 흐름 | 시작 → 결과 |
| --- | --- |
| 정상 출금 | 본인 예치·현금이 충분함 → 기록 차감·토큰 반환·출금 이벤트 1회 |
| 요청 거절 | 0 → 본인 예치 부족 → 현금 부족 순으로 검사 → 정확한 오류, 상태 보존 |
| 토큰 실패 | 기록을 줄인 뒤 transfer에서 false/revert → 해당 출금의 모든 변경 복구 |
| 중첩 호출 | 전송 중 supply/withdraw 재호출 → 공통 잠금으로 중첩 동작 거절 |
| 직접 유입 | 풀에 직접 transfer/mint → 현금만 증가, 출금 권리는 생기지 않음 |

### 첫 40 출금: 새 승인이 없어도 토큰을 돌려받는다

준비(Given): Alice 초기 토큰 200에서 정상 승인·공급 100을 마친다. Alice 토큰·예치·풀 현금은 각각 100이고 공급 승인은 0이다.
실행(When): Alice가 새 approve 없이 `withdraw(40_000_000)`을 호출한다.
확인(Then): `test_WithdrawMovesTokensAndDebitsOnlyCallerWithoutNewApproval`이 다음 고정값을 비교한다.

| 관측값 | 출금 직전 | 성공 후 |
| --- | ---: | ---: |
| Alice 토큰 | 100 | 140 |
| Alice 예치 | 100 | 60 |
| 풀 토큰 | 100 | 60 |
| Alice → 풀 승인 | 0 | 0 |
| 총발행량 | 200 | 200 |
| Bob 토큰·예치 | 각각 0 | 각각 0 |

표는 USDC 단위이며 실제 테스트에서는 6자리 정수 최소 단위를 사용한다.
풀 emitter·출금 서명·indexed Alice·요청액 40·정확히 1회도 별도로 검사한다. 준비 공급의 이벤트는 로그 기록 전에 끝낸다.

```solidity
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
```

`msg.sender`는 출금을 요청한 Alice다. 풀은 자기 토큰을 보내므로 사용자의 승인을 쓰는 transferFrom 대신 transfer를 호출한다.
`safeTransfer`는 그 transfer가 false를 반환하면 오류로 바꾸고, 토큰이 낸 오류도 전파한다.
기록은 외부 토큰 호출 전에 차감한다. 공급·출금은 같은 `nonReentrant` 잠금을 사용한다.

### 왜 먼저 줄인 예치가 전송 실패 때 복구되는가

사용자가 먼저 함께 확인하고 싶다고 답한 부분은 전송 실패 시 예치 복구다.
예치 차감과 토큰 호출은 하나의 withdraw 실행 안에 있다. 풀에서 오류를 잡고 성공으로 바꾸지 않으므로
오류가 호출자까지 전파되면 그 출금에서 바뀐 예치 기록과 하위 토큰 호출의 상태가 모두 되돌아간다.
앞선 별도 거래의 공급 100은 취소되지 않는다.

`test_FalseWithdrawalTokenControlActuallyTransfersBeforeReturningFalse`는 풀 밖에서 실패 모형을 직접 호출한다.
Alice 200에서 Bob에게 40을 보내면 반환값은 false이지만 Alice 160·Bob 40이 남는다. 모형이 실제 전송을 하는 대조다.

`test_FalseWithdrawalRestoresDebitedDepositAndTransferredTokensThenAllowsRetry`는 이를 풀에 연결한다.

1. 준비: 장애를 끈 모형으로 정상 공급 100을 완료하고 양쪽 승인을 7/9 최소 단위로 남긴다.
2. 실패 실행: transfer 장애를 켜고 40 출금한다. 모형은 실제로 토큰을 보낸 뒤 false를 반환한다.
3. 실패 확인: 정확한 `SafeERC20FailedOperation(token)` 오류와 함께 Alice 토큰 100·예치 100·풀 100, 양쪽 승인·Bob 상태·총량이 직전 값으로 돌아온다.
4. 재시도: 장애를 끄고 다시 40 출금한다. Alice 140·예치 60·풀 60·승인 7/9·총량 200과 출금 이벤트 1회를 확인한다.

명시적 revert도 별도 테스트에서 `InjectedTransferFailure()` 원문과 직전12개 상태 보존을 확인한다.
[FailingMockUSDC](test/mocks/FailingMockUSDC.sol)의 transferFrom 장애는 기존 공급용, transfer 장애는 출금용으로 따로 설정한다.
장애 설정은 테스트 모형에만 있다.

### 출금 테스트의 준비·실행·실제 확인

공통 준비는 위 공급 테스트와 같으며 출금 권리는 정상 `_approveAndSupply`로 만든다.
아래 숫자는 USDC 단위이고 최소 단위·승인 7/9는 별도로 표시했다. 각 테스트는 새 토큰·풀에서 독립적으로 시작한다.

| 테스트 | 준비 → 실행 | 실제 확인 |
| --- | --- | --- |
| `test_WithdrawMovesTokensAndDebitsOnlyCallerWithoutNewApproval` | 공급 100·승인 0 → 40 출금 | 위 첫 출금 표와 요청액 40 이벤트 1회 |
| `test_AdditionalWithdrawalDebitsRemainingDepositAndEmitsRequestedAmount` | 100 공급·40 출금 → 추가 20 | Alice 160·예치/풀 40·총량 200·승인 0, 두 번째 이벤트는 요청 20으로 1회 |
| `test_WithdrawAcceptsFullDeposit` | 공급 100 → 100 출금 | Alice 200·예치/풀 0·승인 0·총량 200 |
| `test_WithdrawAcceptsExactlyRemainingDepositAndCash` | 공급 100·40 출금 → 남은 60 출금 | 직전 예치/현금 60 확인 후 Alice 200·예치/풀 0·총량 200 |
| `test_WithdrawAcceptsOneSmallestUnit` | 공급 100 → 최소 단위 1 출금 | Alice 100_000_001·예치/풀 99_999_999·승인 0·총량 200_000_000 |
| `test_ZeroWithdrawalTakesPriorityWhenDepositAndCashAreZero` | 예치/현금 0 → 0 출금 | `ZeroAmount()` 우선, 직전12개 상태 유지 |
| `test_ZeroWithdrawalKeepsPreviousWithdrawalAndApprovals` | 공급 100·출금 40·양쪽 승인 7/9 → 0 출금 | 금액 오류와 기존 출금 결과·승인 보존 |
| `test_ExcessWithdrawalRejectsDepositBeforeLiquidityAndPreservesState` | 예치/현금 60 → 61 출금 | `InsufficientDeposit(60, 61)` 우선, 직전 상태 유지 |
| `test_IlliquidWithdrawalRejectsWholeRequestAndPreservesAdjustedState` | 공급 100 후 현금만 50으로 조정 → 60 요청 | `InsufficientLiquidity(50, 60)`와 조정 후 상태 보존, 부분 지급 없음 |
| `test_WithdrawAcceptsExactCashLimitBelowDeposit` | 예치 100·조정된 현금 50 → 50 출금 | Alice 150·예치 50·풀 0·승인 0·조정 총량 150 |
| `test_WithdrawalWithoutOwnDepositPreservesOtherUserFunds` | Alice 예치 100·Bob 예치 0 → Bob이 1 요청 | `InsufficientDeposit(0, 1)`, 직전 상태 유지 |
| `test_WithdrawalKeepsOtherDepositorAndExistingApprovals` | Alice/Bob 100/30 공급·승인 7/9 → Alice 40 출금 | Alice 토큰140·예치60, Bob 토큰0·예치30, 풀90·승인7/9·총량230 |
| `test_DirectDonorCannotWithdrawWithoutDeposit` | Alice 공급100·Bob 직접 송금10 → Bob이1 요청 | 풀110·총량210·Bob 권리0 먼저 확인 후 예치금 오류·상태 보존 |
| `test_DirectMintCannotCreateWithdrawalRight` | Alice 공급100·풀에 직접 발행10 → Bob이1 요청 | 위와 같은 권리 부재·정확한 오류·상태 보존 |
| `test_FalseWithdrawalTokenControlActuallyTransfersBeforeReturningFalse` | 모형 Alice200 → Bob에게40 직접 전송 | false와 실제 Alice160·Bob40·총량200 |
| `test_FalseWithdrawalRestoresDebitedDepositAndTransferredTokensThenAllowsRetry` | 정상 공급100 → false 출금40 → 장애 해제·재시도40 | 실패 직전 상태 복구 후 정상 출금 결과·이벤트1회 |
| `test_RevertingWithdrawalBubblesExactErrorAndPreservesState` | 정상 공급100 → transfer의 지정 오류 | 정확한 토큰 오류 전파·직전12개 상태 보존 |

현금 부족 준비의 `deal(token, pool, 50_000_000, true)`는 테스트 도구의 ERC20 저장소 조정이다.
예치 100은 유지하지만 풀 잔고 100→50의 차이만큼 총발행량도 200→150이 된다. 조정 직후 값을 먼저 확인하고
그 시점을 snapshot으로 삼는다. 정상 공급·출금으로 현금 부족을 만들었다고 주장하지 않는다.

### 중첩 호출을 잡는 경우와 전파하는 경우

기존 `ReentrantMockUSDC`는 공급 → 공급을 확인한다. 새 [CrossReentrantMockUSDC](test/mocks/CrossReentrantMockUSDC.sol)는
실제 transferFrom/transfer를 마친 뒤 토큰 주소가 최소 단위 1의 공급 또는 출금을 한 번 재호출한다.
테스트 모형이며 생산 토큰에 이런 콜백을 추가하지 않는다.

준비: 토큰 주소에 최소 단위 2를 발행하고 콜백을 끈 정상 supply로 1을 예치한다.
따라서 자체 잔고1·예치1이 남고, 콜백을 켤 때 자체 승인1을 준다.
중첩 호출자는 Alice가 아니라 토큰 주소다. 권리·잔고·승인이 모두 있어야 잠금 대신 다른 부족 오류로 통과하는 일을 막을 수 있다.
총발행량은 200_000_002이며 Alice 100 공급 후 풀은 자체 예치 1을 포함해 100_000_001이다.

| 테스트 | 실행 | 실제 확인 |
| --- | --- | --- |
| `test_SupplyRejectsNestedWithdrawalWithFundedDeposit` | Alice 공급100 중 토큰이 출금1 최소 단위 재호출 | 시도·정확한 guard 오류, Alice 토큰/예치100·풀100_000_001·공급 이벤트1회·출금 이벤트 없음, 자체 잔고/예치/승인1 보존 |
| `test_WithdrawRejectsNestedSupplyAndExposesDebitedDeposit` | Alice 출금40 중 토큰이 공급1 재호출 | guard 오류를 잡아 Alice140·예치60·풀60_000_001·출금 이벤트1회·공급 이벤트 없음, 콜백이 읽은 Alice 예치60 |
| `test_WithdrawRejectsNestedWithdrawalWhileOuterSucceedsOnce` | Alice 출금40 중 토큰이 출금1 재호출 | 중첩만 정확한 guard 오류, 바깥 출금40만 반영·이벤트1회·자체 잔고/권리/승인1 유지 |
| `test_PropagatedNestedWithdrawalRestoresTokensDepositAndCallbackState` | 실제 전송 후 중첩 출금 오류를 바깥으로 전파 | 바깥도 같은 guard 오류, Alice100·예치100·풀100_000_001·직전12개 상태·자체 잔고/예치/승인1 복구, attempted=false·오류 기록/관측값도 초기화 |
| `test_PropagatedNestedWithdrawalDuringSupplyRestoresTokensAllowanceAccountingAndCallbackState` | 정상 공급40·유한 승인100 뒤 실제 transferFrom 후 중첩 출금 오류 전파 | A/S40_000_001·Alice q40_000_000·유한 승인100_000_000·실제 토큰 이동과 관측값 복구 |

표의 Alice·예치 정수는 USDC, 풀 값의 언더스코어 표기는 최소 단위다.
오류를 잡는 세 사례는 attempted·nestedSucceeded=false·오류 bytes와 바깥 1회분을 함께 확인한다.
공급 중 콜백은 바깥 지분 증가 전 장부를 관측한다. 출금 중 콜백은 A/S/q가 모두 차감된 장부를 관측한다.
Cross 모형은 환산 예치뿐 아니라 인정자산·총지분·관측 사용자 지분·토큰 자체 지분도 기록한다. 전파 실패 뒤 이 관측값들도0으로 복구된다.

오류를 전파한 마지막 사례는 그 콜백의 attempted 저장까지 취소된다. 실패 후 attempted=true를 기대하면 EVM 복구와 모순된다.
정확한 guard 오류가 바깥으로 나오는 것과 직전 상태 복구를 확인하며, 오류를 잡는 사례의 관측과 구분한다.

## 지분 환산을 읽는 순서

[#7](https://github.com/0Chord/lending-protocol/issues/7)은 USDC와 지분을 환산하는 계산기다.
[ShareMath](src/libraries/ShareMath.sol)는 internal pure 라이브러리이며 토큰 이동·지분 발행·저장소 변경을 하지 않는다.
LendingPool은 [#8](https://github.com/0Chord/lending-protocol/issues/8)에서 이 internal 계산을 공급·출금·조회에 연결한다. 별도 라이브러리 배포는 필요 없다.

A는 풀에서 인정한 USDC 자산, S는 총지분이다. 모든 인수·반환값은 정수 최소 단위다.
USDC·지분을 소수점 6자리로 표현하면 자산 10 USDC·총지분 6개는 A=10_000_000, S=6_000_000이다.
이 비율은 계산 테스트의 가정이며 현재 풀에 수익을 만드는 기능이 있다는 뜻은 아니다.

| 읽을 흐름 | 계산·코드 | 확인할 결과 |
| --- | --- | --- |
| USDC → 지분 | `toSharesDown` / `toSharesUp`: 금액×S÷A | 공급 지분 내림 / 출금 차감 지분 올림 |
| 지분 → USDC | `toAssetsDown`: 지분×A÷S | USDC 가치 내림 |
| 장부·정수 경계 | `_isEmptyAccounting`, 고정 OpenZeppelin `Math.mulDiv` | 초기 1:1 / 잘못된 장부 오류 / 최종 정수 범위 초과 오류 |

### 첫 테스트는 실제 계산 결과를 미리 정한 정답과 비교한다

준비: A=10_000_000, S=6_000_000이고 환산할 USDC는 1_000_001이다.
실행: 공급용 내림과 출금용 올림 함수를 각각 호출한다.
확인: [첫 테스트](test/ShareMath.t.sol)의 `test_ShareConversionsRoundInOppositeDirections`는 아래 두 값을 비교한다.

```solidity
assertEq(ShareMath.toSharesDown(1_000_001, 10_000_000, 6_000_000), 600_000);
assertEq(ShareMath.toSharesUp(1_000_001, 10_000_000, 6_000_000), 600_001);
```

`assertEq(실제 결과, 기대값)`는 두 값이 다르면 실패한다.
정확한 계산은 600_000.6이므로 내림은 600_000, 올림은 600_001이다. 지분 개수로는 0.600000개·0.600001개다.
핵심 구현은 `Math.mulDiv(assets, totalShares, accountedAssets, Math.Rounding.Floor)`이며 올림 함수는 `Ceil`을 사용한다.
이 테스트의 통과는 두 계산 결과가 정답과 같았다는 뜻이다. 실제 USDC 공급·출금이나 토큰 이동을 실행한 것은 아니다.
4 USDC처럼 정확히 나누어떨어지면 두 방향 모두 2.4지분(2_400_000)이며 3지분으로 올리지 않는다.

### 장부 검사와 계산 범위

세 함수 모두 입력 수량 처리 전에 장부를 검사한다. A/S 중 한쪽만 0이면 입력이 0이어도
`InvalidAccountingState(A, S)`로 거절한다. 둘 다 0이면 초기 1:1 계산으로 입력을 그대로 반환한다.
빈 장부의 수학적 반환값이 실제 보유 지분·출금 권리를 만들지는 않는다. 두 장부 값이 양수이면 입력 0은 0이다.

`Math.mulDiv`는 중간 곱이 uint256을 넘더라도 최종 정수 결과가 범위 안이면 계산한다.
최종 내림 또는 올림 결과가 uint256 범위를 넘으면 정확한 `Panic(uint256)` 코드 `0x11`이 전파된다.
지분0이나 총지분 전체가 반환되는 계산은 성공한다. 실제 거래의0 금액·개인 권리·현금·잔여 자산 검사는 이를 호출하는 LendingPool이 수행한다.

<details>
<summary>나머지 테스트의 준비·실행·실제 확인 결과</summary>

테스트는 [ShareMathTest](test/ShareMath.t.sol)에 있다. 아래 D/U/V는 각각 `toSharesDown` / `toSharesUp` / `toAssetsDown`이고 M은 `type(uint256).max`다.
정상 계산은 internal 함수를 직접 사용한다. 오류는 같은 라이브러리를 호출하는 시험 전용 `ShareMathHarness`를 새로 배포해 외부 호출에서 관측한다.
이 wrapper는 계산을 복제하지 않는다. 다른 테스트용 토큰·외부 서비스·RPC는 사용하지 않는다.
각 행의 숫자는 전부 정수 최소 단위이며 기대값은 명세의 고정 예시다.

| 테스트 | 준비·실행 | 실제 assertion |
| --- | --- | --- |
| `test_AssetConversionRoundsDown` | A10_000_000/S6_000_000에서 지분2_400_000, A10/S6에서 지분1을 V로 환산 | 각각4_000_000·1 |
| `test_EmptyAccountingUsesOneToOneForAllInputs` | A=S=0, 입력0/1/100_000_000/M을 D/U/V에 적용 | 세 함수 모두 입력 그대로 |
| `test_ZeroInputWithValidAccountingReturnsZero` | A10/S6, 입력0을 D/U/V에 적용 | 모두0 |
| `test_MissingAssetsRevertsEvenForZeroInput` | A0/S1, 입력0·1을 D/U/V에 적용 | 정확한 오류 종류와 인수(0,1) |
| `test_MissingSharesRevertsEvenForZeroInput` | A1/S0, 입력0·1을 D/U/V에 적용 | 정확한 오류 종류와 인수(1,0) |
| `test_ExactShareConversionsPreserveFractionalShares` | A=S=100_000_000에서 금액40_000_000, A10_000_000/S6_000_000에서 금액4_000_000을 D/U로 환산 | 각각40_000_000·2_400_000 |
| `test_SmallestAssetMayConvertToZeroShares` | A10/S6에서 금액1을 D/U로 환산 | D0·U1, 계산 자체 성공 |
| `test_LastTotalSharesIsACalculationResult` | A10_000_000/S6_000_000에서 금액9_999_999를 U로 환산 | 총지분과 같은6_000_000 반환 |
| `test_IntermediateProductCanOverflowWhenResultFits` | A=S=2에서 입력M을 D/U/V로 환산 | 중간 곱2M에도 모두M |
| `test_FloorCanReturnMaxBeforeCeilOverflows` | A=M−2/S=M−1에서 금액M−1을 D/U로 환산 | D=M 성공, U만 정확한 Panic(0x11) |
| `test_ShareConversionsRejectOverflowingResults` | A=M−1/S=M에서 금액M을 D/U로 환산 | 둘 다 정확한 Panic(0x11) |
| `test_AssetConversionRejectsOverflowingResult` | A=M/S=M−1에서 지분M을 V로 환산 | 정확한 Panic(0x11) |

첫 테스트를 포함해 테스트 함수는 13개다. 빈 장부·잘못된 장부의 고정 반복 입력을 별도 테스트 함수 수로 세지 않는다.
오류 테스트는 아무 revert나 인정하지 않고 전체 오류 데이터와 Panic 코드를 비교한다.
순수 계산 검증이며 #8의 토큰 전송·장부 저장·재진입 방어를 미리 검증한 것이 아니다.

</details>

## 풀에 연결한 뒤 확인할 나머지 상황

공급·출금은 기존 USDC 입력을 유지하고 `shares`로 권리를 기록한다. 전송 실패가 전파되면 자산·총지분·개인 지분과 토큰 상태가 함께 복구된다.
정수 반올림 때문에 지분 합은 총지분과 같아도, 내림한 USDC 권리의 합은 인정자산보다 작을 수 있다.
첫1:1 상태에서 정상 공급·출금만 하면1:1이 유지된다. 아래의 다른 비율은 시험용 준비이며 실제 수익·손실 인정 API는 없다.

<details>
<summary>직접 송금·반올림·거절·실패 복구 테스트의 입력과 실제 확인</summary>

새 사례는 [LendingPoolSharesTest](test/LendingPoolShares.t.sol) 23개다. 기존 [LendingPoolTest](test/LendingPool.t.sol) 37개에도 자산·지분 관측을 더하고 공급 오류 전파 대표1개를 추가했다.
`_state`는 자산·총지분·두 지분·두 환산권리·두 토큰 잔고·현금·두 승인·총발행량12개를 비교한다. 잘못된 장부는 권리 조회도 오류이므로 `_rawState`의 권리를 제외한10개를 비교한다.

비1:1의 `_prepareRatio`는 총발행량0인 새 토큰에서 정상 공급으로 지분을 만든다. 직접 mint가 인정자산을 바꾸지 않았는지 먼저 검사한 다음,
[시험용 풀](test/mocks/LendingPoolHarness.sol)의 `setAccountedAssetsForTest`로만 가정 비율을 준비한다. setter는 일반 LendingPool에 없다.
재진입 모형 역시 로컬 EVM의 실제 토큰 이동 후 콜백이며 외부 네트워크·실제 USDC 연동 검증은 아니다.
표의 언더스코어 없는 작은 수와 M도 모두 정수 최소 단위다. M은 uint256 최댓값이다.

| 테스트 | 준비·실행 | 실제 확인 |
| --- | --- | --- |
| `test_ZeroShareSupplyPreservesAllState` | A10/S1에서 Bob1 공급 | 정확한 ZeroShares, 승인1을 포함한12값 유지 |
| `test_LastSharesWithResidualAssetRevert` | A10_000_000/S6_000_000의 전 소유자가9_999_999 출금 | ResidualAssets(1),12값 유지 |
| `test_DirectTransferLeavesSurplusAcrossExitAndRestart` | 100 공급→직접 transfer20→기부자1 출금 거절→기존 소유자 전액 출금→새10 공급 | 권리100 유지, 전액 출금 뒤 잉여20·빈 장부, 새 권리10·현금30 |
| `test_DirectMintLeavesSurplusAcrossExitAndRestart` | 같은 순서에서 직접 mint20 | 같은 권리·거절·재시작 결과와 총발행량230 |
| `test_InitialDonationDoesNotBelongToFirstSupplier` | 빈 풀 직접 mint20→Alice100 공급 | 인정자산/총지분/Alice 지분/권리100, 현금120 |
| `test_NonUnitSupplyUsesPreTransferRate` | A10_000_000/S6_000_000에서 Bob4_000_000 공급 | Bob q2_400_000,A14_000_000/S8_400_000, 권리Alice10_000_000/Bob4_000_000, USDC 이벤트1회 |
| `test_RoundedSupplyPreservesSharesAndFloorsClaims` | 같은 비율에서 Bob1_000_001 공급 | q600_000,A11_000_001/S6_600_000, 권리 합11_000_000, 이벤트는1_000_001 |
| `test_NonUnitWithdrawalBurnsExactFractionalShares` | A10_000_000/S6_000_000에서4_000_000 출금 | A/현금6_000_000,S/q3_600_000, 지급·이벤트4_000_000 |
| `test_SmallestWithdrawalRoundsShareBurnUp` | 같은 비율에서1 출금 | q1 차감, A/현금9_999_999,S/q5_999_999, 지급1 |
| `test_FullNonUnitWithdrawalClearsAccounting` | 같은 비율에서10_000_000 전액 출금 | A/S/q/현금0, 지급10_000_000 |
| `test_InsufficientCashTakesPriorityOverResidualAssets` | 현금만9_000_000으로 낮춘 뒤9_999_999 출금 | 정확한 현금 부족 오류, 조정 총량을 포함한12값 유지 |
| `test_PersonalClaimIsCheckedInsteadOfTotalShares` | A10_000_000/S6_000_000, 두 사람 q각3_000_000에서Alice6_000_000 출금 | 개인 권리5_000_000 오류,12값 유지 |
| `test_OtherSharesStayFixedWhileConvertedClaimChanges` | A10/S6/q각3에서 Alice2 출금 | A8/S4/qAlice1/qBob3, Bob 환산권리5→6 |
| `test_RoundedClaimsNeedNotSumToAccountedAssets` | A10/S6/qAlice1/qBob5 | 지분 합6, 권리Alice1/Bob8·합9, A10 |
| `test_ZeroSharesTakesPriorityOverMissingAllowance` | 지분0 공급과 승인0이 겹침 | ZeroShares가 먼저,12값 유지 |
| `test_ZeroSharesTakesPriorityOverTokenFailure` | 지분0 공급과 실제 전송 뒤 revert 모형이 겹침 | 토큰 오류 대신 ZeroShares,12값 유지 |
| `test_MissingAssetsRejectsPositiveCallsAndAllClaimQueries` | A0/S1·Alice q1/Bob q0 | 양수 공급/출금·두 권리 조회는 정확한 장부 오류,0 요청은 ZeroAmount 우선·원시10값 유지 |
| `test_MissingSharesRejectsPositiveCallsAndAllClaimQueries` | A1/S0·두 q0 | 같은 오류 우선순위와 원시 상태 보존 |
| `test_SupplyAccountingOverflowRestoresTransferAndAllowance` | 정상 M 공급 뒤 현금/총량0으로 조정→Alice mint1·유한 승인1→공급1 | 정확한 Panic(0x11), A/S/q/권리M·현금0·Alice1·승인1·총량1 복구 |
| `test_NonUnitFalseSupplyRestoresStateAndAllowsRetry` | 비1:1 공급 전송 후 false→장애 해제·같은 공급 재시도 | 첫 시도 정확한 토큰 오류·12값 복구, 재시도 Bob q2_400_000·승인0 |
| `test_NonUnitFalseWithdrawalRestoresStateAndAllowsRetry` | 비1:1 선차감·전송 후 false→장애 해제·같은 출금 | 복구 후 재시도 A6_000_000/S/q3_600_000·지급4_000_000 |
| `test_NonUnitCaughtReentryLeavesOneOuterWithdrawal` | A10/S6/qAlice5/qToken1에서 외부 출금2 중 중첩 출금1 | 중첩만 잠금 오류, A8/S4/qAlice3/qToken1·권리Alice6·실제 지급2·이벤트1회 |
| `test_NonUnitPropagatedReentryRestoresAccountingAndCallbackState` | 같은 모형이 중첩 오류를 전파 | 바깥도 잠금 오류,12값과 토큰 주소 권리·지분·잔고·승인 및 모든 공개 콜백 기록 복구 |

마지막 두 모형은 토큰 주소 자체의 지분1·환산권리1·승인1·잔고1과 풀 현금10을 먼저 확인한다. 중첩 출금1은 잠금이 없다면 실행할 수 있으므로 다른 부족 오류를 방어로 오해하지 않는다.
정상 재진입 모형의 전송 전/후 시점을 구분하고, 오류를 전파하면 `attempted`와 관측값 저장도 함께 취소됨을 확인한다.
공급 중 전파 대표는 기존 회귀 파일에서 유한 승인100_000_000과 새 회계·토큰·콜백 상태의 복구를 확인한다.
테스트 기대값은 명세 고정 예시이며 실제 환산 함수를 정답 생성에 재사용하지 않는다.

</details>

## 이번 코드의 경계

MockUSDC의 `mint`는 누구나 호출할 수 있는 테스트 준비 기능이다.
토큰 발행에는 실제 자산 입금이 없으며, 풀의 예치 권리를 만들지 않는다.
풀은 배포한 자산 하나를 고정하며 본인 공급과 본인 지갑으로의 출금만 받는다. 자산 변경·타인 대신 공급·수령자 지정·이자·대출·구제 함수는 없다.
실제 USDC의 운영 기능, 전송 수수료, 리베이스도 구현하지 않는다. 배포는 이번 작업 범위에 포함하지 않는다.

풀에 직접 전송·발행한 토큰은 예치 권리를 만들지 않는다. 직접 전송 10 후 정상 공급 100이면 풀 현금은 110이고 예치 권리는 100이다.
따라서 직접 송금이 있는 경우까지 풀 현금과 예치 합이 항상 같다고 가정하지 않는다.
생성자의 코드 존재 검사는 모든 ERC20의 안전성을 보장하지 않는다. 재진입 검증도 임의의 악성 자산 지원을 의미하지 않는다.

테스트는 소수점 설정·지급 연결 및 공급·출금의 정상·거절·전송 실패 결과를 확인한다.
OpenZeppelin의 모든 ERC20 동작이나 실제 USDC 연동을 검증하는 범위는 아니다.
생성되는 `out/`, `cache/`, `broadcast/`는 버전 관리에서 제외한다.

구현·검증·독립 리뷰와 사용자의 코드 이해 확인은 각각 구분한다.
PR은 사용자가 주요 동작과 실패 흐름, 설명 자료를 확인한 뒤 게시한다.

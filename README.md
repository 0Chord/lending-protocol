# Lending Protocol 학습 프로젝트

Solidity·Foundry로 공급·출금부터 작은 단위로 만드는 개인 학습 프로젝트다.
현재 구현 범위는 [이슈 #1](https://github.com/0Chord/lending-protocol/issues/1)의 테스트 환경과 MockUSDC다.
공급과 예치 기록은 [#2](https://github.com/0Chord/lending-protocol/issues/2), 출금은 [#3](https://github.com/0Chord/lending-protocol/issues/3)에서 이어간다.

## 실행 환경

Git과 Foundry가 설치된 환경에서 프로젝트 파일과 서브모듈 고정 정보를 받은 뒤 루트에서 실행한다.

```sh
git submodule update --init --recursive
forge fmt --check
forge build
forge test --match-contract MockUSDCTest -vv
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

## 구현을 읽는 순서

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

## 이번 코드의 경계

MockUSDC의 `mint`는 누구나 호출할 수 있는 테스트 준비 기능이다.
토큰 발행에는 실제 자산 입금이 없으며, 풀의 예치 권리를 만들지 않는다.
아직 풀 계약·공급·출금은 구현하지 않았다. 실제 USDC의 운영 기능, 전송 수수료, 리베이스도 구현하지 않는다.

테스트는 추가한 소수점 설정과 지급 연결의 정상·거절 결과를 확인한다.
OpenZeppelin의 모든 ERC20 동작이나 실제 USDC 연동을 검증하는 범위는 아니다.
생성되는 `out/`, `cache/`, `broadcast/`는 버전 관리에서 제외한다.

구현·검증·독립 리뷰와 사용자의 코드 이해 확인은 각각 구분한다.
PR은 사용자가 주요 동작과 실패 흐름, 설명 자료를 확인한 뒤 게시한다.

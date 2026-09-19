# SERIES9DEX

Series9 탈중앙화 거래소. ANY/ANY ERC-20 페어에 대한 AMM 현물 풀, 완전 온체인 오더북, 선물(perp) 풀을 제공합니다.

설계 명세는 [`docs/DEX.md`](docs/DEX.md) 참고.

## 컨트랙트

| 컨트랙트 | 파일 | 역할 |
|----------|------|------|
| `DexRegistry` | [`src/DexRegistry.sol`](src/DexRegistry.sol) | 페어 등록·조회, 팩토리 배선 (UUPS) |
| `Pair` | [`src/Pair.sol`](src/Pair.sol) | 페어당 1개. 풀 생성 + 온체인 지정가 오더북 |
| `SpotPool` | [`src/SpotPool.sol`](src/SpotPool.sol) | AMM 현물 풀, LP 지분 원장 |
| `SpotPoolFactory` | [`src/SpotPoolFactory.sol`](src/SpotPoolFactory.sol) | 현물 풀 배포 |
| `PerpPool` | [`src/PerpPool.sol`](src/PerpPool.sol) | 선물 포지션/담보 |
| `PerpPoolFactory` | [`src/PerpPoolFactory.sol`](src/PerpPoolFactory.sol) | 선물 풀 배포 |
| `DexPositionManager` | [`src/DexPositionManager.sol`](src/DexPositionManager.sol) | LP 지분을 ERC-721 포지션으로 래핑 |
| `DexRouter` | [`src/DexRouter.sol`](src/DexRouter.sol) | 멀티홉 스왑 + deadline (주변부, 무상태) |
| `ProtocolTreasury` | [`src/ProtocolTreasury.sol`](src/ProtocolTreasury.sol) | 프로토콜 수수료 수취 (UUPS, 타임락 소유) |

### 금고 인출

`ProtocolTreasury` 의 owner 는 Safe 가 아니라 **`TimelockController`** 입니다. Safe 가 인출을 큐에
올리고 48시간 뒤 **누구나** 실행할 수 있습니다(검열 불가). guardian 은 그 사이 **취소**할 수 있어,
키가 털려도 즉시 전액이 나가지 않습니다. 금고 업그레이드도 같은 지연을 거칩니다.

수수료는 급히 뺄 이유가 없으므로 지연 비용이 사실상 0인 반면, 정지는 즉시여야 하므로
`DexRegistry` 의 owner 는 Safe 로 남습니다. 근거는 [`docs/DEX.md` §10](docs/DEX.md).

### 비상 정지

`DexRegistry.paused` 플래그 하나를 모든 풀·페어가 읽습니다. **진입만 막고 출구는 항상 열려 있습니다** —
정지 중에도 유동성 인출·포지션 청산·주문 취소가 됩니다. 자금이 갇히지 않으므로 만료 타이머가 없습니다.

- `pause()` — owner(Safe) 또는 guardian
- `unpause()` — owner 전용
- guardian 은 **멈추는 것만** 가능. `GUARDIAN_ADDRESS` 환경변수로 배포 시 설정(선택)

청산도 정지 중 차단됩니다. 정지 사유가 대개 마크 가격 이상인데, 잘못된 마크로 도는 청산은
되돌릴 수 없기 때문입니다. 자세한 근거는 [`docs/DEX.md` §8](docs/DEX.md) 참고.

수수료: 풀 생성자가 `lpFee`를 설정하고, 그중 0.1%가 `ProtocolTreasury`로, 나머지 99.9%가 LP에게 분배됩니다.

### 페어당 풀 구성

현물 풀은 수수료율당 1개입니다. 정규 티어 4개(100 / 500 / 3,000 / 10,000 ppm)는
언제나 생성 가능하고, 그 외 1~10,000ppm 값은 커스텀 슬롯 12개를 나눠 씁니다.
정규 티어를 누가 먼저 만들든 그 풀이 곧 그 티어의 정식 풀이라 아무나 유동성을
넣고 라우팅할 수 있습니다 — 커스텀 슬롯이 전부 소진돼도 페어는 계속 쓸 수 있습니다.

주문 가격은 페어별 `tickSize` 대신 **유효숫자 6자리 십진 그리드**를 씁니다.
`Pair.priceIsValid(priceX18)` / `Pair.tickSizeAt(priceX18)` 로 조회합니다.
비율 기준이라 토큰 데시멀 차이가 큰 페어에도 그대로 맞고, 선착순으로 고정되는
페어 전역 값이 없습니다.

## 개발

```bash
git clone --recurse-submodules https://github.com/PIXELZX0/SERIES9DEX.git
foundryup --install v1.8.3   # CI와 같은 버전 (아래 참고)
forge build
forge test
forge fmt --check        # CI 차단 조건
forge snapshot --check   # CI 차단 조건
```

**Foundry 버전을 맞춰야 합니다.** CI는 `foundry-toolchain`에 `v1.8.3`을 고정해 두었고
(`.github/workflows/ci.yml`), `forge fmt --check` 와 `forge snapshot --check` 는 둘 다
잡을 실패시킵니다. 가스 집계는 forge 버전마다 달라서, **다른 버전으로 `forge snapshot` 을
다시 만들면 코드가 멀쩡해도 CI가 빨갛게 됩니다.**

컴파일러는 `foundry.toml` 에 `solc_version = "0.8.33"` 으로 고정돼 있습니다. 덕분에
배포 바이트코드는 누가 어떤 forge 로 빌드하든 동일하며 (v1.5.1 / v1.8.3 에서 배포 대상
9개 컨트랙트 전부 대조 확인), Sourcify 검증도 재현 가능합니다.

## 배포

```bash
export PRIVATE_KEY=<PRIVATE_KEY>
export SAFE_ADDRESS=<SAFE_MULTISIG_ADDRESS>   # 배포 후 최종 owner
export GUARDIAN_ADDRESS=<GUARDIAN_ADDRESS>    # 선택. 정지만 가능한 빠른 키

forge script script/DeployDex.s.sol:DeployDex \
  --rpc-url "$MONAD_RPC_URL" --broadcast
```

배포 스크립트는 ProtocolTreasury/DexRegistry 프록시와 팩토리·DexPositionManager·DexRouter를
배포하고, 레지스트리에 연결한 뒤 소유권을 Safe로 이관합니다. 페어와 풀은 배포 대상이
아니며 런타임에 `DexRegistry.createPair` / `Pair.createSpotPool` 로 만듭니다.

## GitHub Actions

| 워크플로 | 트리거 | 하는 일 |
|---|---|---|
| `.github/workflows/ci.yml` | push(main) / PR | `forge build` + `forge test` + gas snapshot 대조 |
| `.github/workflows/deploy.yml` | 수동(`workflow_dispatch`) / release published | 프리플라이트 → DEX 스택 배포 → 배선·소유권 온체인 검증 → Sourcify/SocialScan 검증 → 주소 JSON/ABI 첨부 |

`deploy.yml`은 `network` 입력으로 대상 체인을 고릅니다. `release` 이벤트는 항상 mainnet.

| network | chain id | 필요한 Secrets |
|---|---|---|
| `testnet` | 10143 | `MONAD_TESTNET_RPC_URL`, `TESTNET_PRIVATE_KEY`, `TESTNET_SAFE_ADDRESS` |
| `mainnet` | 143 | `MONAD_RPC_URL`, `PRIVATE_KEY`, `SAFE_ADDRESS` |

선택 GitHub Variables:

| 변수 | 기본 | 설명 |
|---|---|---|
| `SKIP_VERIFY` | `false` | Sourcify 검증 생략. 실행 시 입력으로도 덮어쓸 수 있습니다 |
| `GUARDIAN_ADDRESS` | 없음 | mainnet guardian — **정지만** 가능한 빠른 키. 금고 타임락의 canceller 도 겸함 |
| `TREASURY_TIMELOCK_DELAY` | `172800` (48h) | 금고 인출 지연(초). 배포 후에는 타임락 스스로 변경 |
| `TESTNET_GUARDIAN_ADDRESS` | 없음 | testnet guardian |

guardian 은 온체인에 공개되는 값이라 secret 이 아니라 **variable** 입니다. 비워두면 Safe 만
정지할 수 있고(동작은 정상, 비상시 서명 모으는 시간이 걸림), 배포 잡이 경고를 남깁니다.
배포 후 Safe 가 `setGuardian` 으로 추가·교체할 수 있습니다.

프리플라이트에서 걸러지는 것: 형식이 20바이트 hex 가 아니거나 배포자 키와 같으면 **실패**
(배포 키는 CI 에서 쓰이는 hot key). Safe 주소와 같으면 경고 — 빠른 경로가 없다는 뜻이므로.

잡은 `network` 이름의 GitHub Environment에서 실행됩니다. **레포 설정에서 `mainnet` 환경에
required reviewer를 걸어두면 실제 배포가 수동 승인 뒤에만 나갑니다.**

안전장치:
- RPC가 보고한 chain id가 대상 체인과 다르면 배포 전에 실패 (RPC 시크릿 오설정 방지)
- 배포자 잔액 0 또는 `SAFE_ADDRESS == 배포자`면 배포 전에 실패
- 배포 후 `registry`/`treasury` 소유권과 팩토리·주변부 배선을 온체인 조회로 대조,
  하나라도 어긋나면 잡 실패 (풀과 페어는 배포 후 불변이라 재배포 외 복구 불가)

> 배포 워크플로는 **스택 전체를 새로 배포**합니다. 업그레이드가 아니라 신규 배포이므로
> 이미 운영 중인 배포가 있으면 실행 전에 의도한 동작인지 확인하세요.

## 관련 레포

- [SERIES9](https://github.com/PIXELZX0/SERIES9) — SER9 토큰 + 스테이킹
- [SERIES9Identity](https://github.com/PIXELZX0/SERIES9Identity) — Identity NFT + 지갑
- [SERIES9_Front](https://github.com/PIXELZX0/SERIES9_Front) — 웹 프론트엔드

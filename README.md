# SERIES9DEX

Series9 탈중앙화 거래소. ANY/ANY ERC-20 페어에 대한 AMM 현물 풀, 완전 온체인 오더북, 선물(perp) 풀을 제공합니다.

설계 명세는 [`docs/DEX.md`](docs/DEX.md) 참고.

## 컨트랙트

| 컨트랙트 | 파일 | 역할 |
|----------|------|------|
| `DexRegistry` | [`src/DexRegistry.sol`](src/DexRegistry.sol) | 페어/풀 등록 및 조회 (UUPS) |
| `SpotPool` | [`src/SpotPool.sol`](src/SpotPool.sol) | AMM 현물 풀, LP 토큰 |
| `SpotPoolFactory` | [`src/SpotPoolFactory.sol`](src/SpotPoolFactory.sol) | 현물 풀 배포 |
| `Orderbook` | [`src/Orderbook.sol`](src/Orderbook.sol) | 온체인 지정가 오더북 |
| `PerpPool` | [`src/PerpPool.sol`](src/PerpPool.sol) | 선물 포지션/담보 |
| `PerpPoolFactory` | [`src/PerpPoolFactory.sol`](src/PerpPoolFactory.sol) | 선물 풀 배포 |
| `ProtocolTreasury` | [`src/ProtocolTreasury.sol`](src/ProtocolTreasury.sol) | 프로토콜 수수료 수취 (UUPS) |

수수료: 풀 생성자가 `lpFee`를 설정하고, 그중 0.1%가 `ProtocolTreasury`로, 나머지 99.9%가 LP에게 분배됩니다.

## 개발

```bash
git clone --recurse-submodules https://github.com/PIXELZX0/SERIES9DEX.git
forge build
forge test
forge snapshot --check   # .gas-snapshot 대조
```

## 배포

```bash
export PRIVATE_KEY=<PRIVATE_KEY>
export SAFE_ADDRESS=<SAFE_MULTISIG_ADDRESS>   # 배포 후 최종 owner

forge script script/DeployDex.s.sol:DeployDex \
  --rpc-url "$MONAD_RPC_URL" --broadcast
```

배포 스크립트는 ProtocolTreasury/DexRegistry 프록시와 Orderbook + 팩토리를 배포하고,
레지스트리에 연결한 뒤 소유권을 Safe로 이관합니다.

## GitHub Actions

| 워크플로 | 트리거 | 하는 일 |
|---|---|---|
| `.github/workflows/ci.yml` | push(main) / PR | `forge build` + `forge test` + gas snapshot 대조 |
| `.github/workflows/release-monad-mainnet-deploy.yml` | release published / 수동 | DEX 스택 배포 + Sourcify/SocialScan 검증 + 주소 JSON/ABI 릴리즈 첨부 |

필수 GitHub Secrets: `MONAD_RPC_URL`, `PRIVATE_KEY`, `SAFE_ADDRESS`
선택 GitHub Variables: `SKIP_VERIFY` (`true`/`false`, 기본 `false`)

> 릴리즈 워크플로는 **스택 전체를 새로 배포**합니다. 업그레이드가 아니라 신규 배포이므로
> 이미 운영 중인 배포가 있으면 릴리즈를 발행하기 전에 의도한 동작인지 확인하세요.

## 관련 레포

- [SERIES9](https://github.com/PIXELZX0/SERIES9) — SER9 토큰 + 스테이킹
- [SERIES9Identity](https://github.com/PIXELZX0/SERIES9Identity) — Identity NFT + 지갑
- [SERIES9_Front](https://github.com/PIXELZX0/SERIES9_Front) — 웹 프론트엔드

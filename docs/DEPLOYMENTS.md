# 배포 주소

> 워크플로가 쓰는 `deployments/<chainid>.json` 은 `.gitignore` 에 있고 GitHub
> 아티팩트는 만료됩니다. 이 파일이 배포 주소의 **정본** 입니다.
>
> 새로 배포할 때마다 갱신하세요. 배포 잡은 매번 **스택 전체를 새로 배포**하므로
> (업그레이드가 아님) 기존 항목은 지우지 말고 아래 "지난 배포" 로 옮깁니다.

## Monad Mainnet — chain 143

2026-09-19 배포 · [run 35431614578](https://github.com/PIXELZX0/SERIES9DEX/actions/runs/35431614578) · 커밋 `a5cf1c2`

통합에 쓰는 주소는 **Proxy** 입니다. 구현체는 직접 호출하지 마세요.

| 컨트랙트 | 주소 |
|---|---|
| `DexRegistry` (Proxy) | `0xE8249f2626605c7E063acf90f8E356a93c2968AC` |
| `ProtocolTreasury` (Proxy) | `0xc660d7E0d72bF75B6D37156AD2395b6E45a75f21` |
| `TimelockController` (treasury owner) | `0x622C3FC5EeCDf03eF3a7436d86Dd27379b75C6E3` |
| `SpotPoolFactory` | `0x24B9a7b864e26a5f04d5Db4d668b2067345173aE` |
| `PerpPoolFactory` | `0x0E8555e82c90306180ed768E55a5103F4432D411` |
| `DexPositionManager` | `0x2D3C06bCa14c06Bf35763CA6bEBBb80C84B70374` |
| `DexRouter` | `0x7149bBC0e7530Cd881841C5C6918f12911150C88` |

구현체 (검증·업그레이드 참조용)

| | |
|---|---|
| `DexRegistry` Impl | `0x57d11ef244CcD9E2829337AfF37D56DDB46D503A` |
| `ProtocolTreasury` Impl | `0x7223D16809900Af3d1A39B9D3E845c6407760539` |

### 권한

| 역할 | 주소 | 비고 |
|---|---|---|
| Safe | (2-of-2) | `registry.owner()`, 타임락 proposer·canceller |
| └ 서명자 | `0x4496c7a6c2eB9D081b6cfEA5f6816959D724eE1e` | |
| └ 서명자 | `0xD2cF3765C2e600f13470Ed71aaAb0ee3aa37F90a` | guardian 과 동일 |
| Guardian | `0xD2cF3765C2e600f13470Ed71aaAb0ee3aa37F90a` | `pause()` + 타임락 `cancel()` |
| Deployer | `0x48f23CcCc20C5415C669a18DDd1064aae9Ed8495` | 배포 후 권한 없음 |

- 타임락 지연 **172,800초 (48h)**, self-administered (Safe 는 admin 이 아님)
- `registry.paused()` = `false`
- **guardian 이 Safe 서명자 2명 중 1명과 같은 키입니다.** 2-of-2 라 단독으로 인출을
  통과시키지는 못하지만, 그 키 하나가 정지·타임락 취소·Safe 서명 1표를 동시에
  갖습니다. 의도된 구성인지 확인해 두세요.

배포 시점에 페어·풀은 없습니다. `DexRegistry.createPair` → `Pair.createSpotPool`
로 런타임에 생성합니다.

## Monad Testnet — chain 10143

2026-09-19 배포 · [run 35431033774](https://github.com/PIXELZX0/SERIES9DEX/actions/runs/35431033774)

| 컨트랙트 | 주소 |
|---|---|
| `DexRegistry` (Proxy) | `0x146918654D0249DeB09F2D3a8Dd652A647C6A8E1` |
| `ProtocolTreasury` (Proxy) | `0xE2F163b60cc49b50AFf0535e28D0EBeb5A0fa941` |
| `TimelockController` | `0xE4c586EF625E0f80DF83E3C0AB69cDBDEaCa70E8` |
| `SpotPoolFactory` | `0xf7758F53D71EA7E644405203A97EF63F5017a15C` |
| `PerpPoolFactory` | `0x66AB8Edfc1E2c3F5579f4e42AFb4a14B64268e2b` |
| `DexPositionManager` | `0x121aac2934e226c774785DCDc89eE4f11aF8233F` |
| `DexRouter` | `0x03228Aa49888e218dF8a494FAC90Ab995d375c80` |

구현체: `DexRegistry` `0x281f128cA9e4cA3d925C260885f1809b8e665eBE` ·
`ProtocolTreasury` `0x789730664502DfD4AB3cAFe17Af8a569BE885400`

리허설 배포입니다. owner 는 EOA `0x55cdB1fE965f65F819b88D6F37DAD4D8dCa0E7D8`
(테스트넷 한정으로 허용 — 메인넷은 여전히 컨트랙트를 요구), guardian 없음,
배포자 `0xfAa357be0A8Ce6b84143336b367525B175e9506e` 는 일회용 키입니다.

## 지난 배포

없음.

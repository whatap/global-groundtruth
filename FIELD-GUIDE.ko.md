# WhaTap Groundtruth — 필드 가이드

> **Languages:** [English (canonical)](FIELD-GUIDE.md) · [Bahasa Indonesia](FIELD-GUIDE.id.md) · [ไทย](FIELD-GUIDE.th.md) · 한국어

이 가이드는 고객 시스템 바로 옆에 있는 **필드 엔지니어**를 위한 문서입니다.
WhaTap이 왜 *collector* 실행을 요청하는지, 그리고 정확히 어떻게 실행하는지를
설명합니다. WhaTap 내부 지식은 필요 없으며, 결과를 해석해 달라는 요청도 받지
않습니다.

## 1. 배경 — 왜 이 스크립트를 실행해 달라고 하는가

지원 케이스가 WhaTap 에이전트 개발팀까지 올라가면, 증상을 해석할 수 있는
개발자는 원격지(대개 다른 시간대)에 있고, 환경에 대한 사실 — 어떤 런타임인지,
로그가 실제로 어디에 쌓이는지, 프로세스가 어떤 플래그로 떠 있는지 — 이
필요합니다. 이것을 이메일이나 채팅으로 하나씩 물어보면 질문마다 왕복 시간이
들고, 답이 10개 필요한 케이스는 이 왕복만으로 2주를 잃을 수 있습니다.

**collector**는 이 문답을 대체합니다. 스크립트 하나를 실행하면 리포트 파일
하나가 만들어지고, 그 파일을 회신하면 됩니다. 리포트에는 개발자가 물었을
질문 — 그리고 그다음에 물었을 질문 — 의 답이 이미 들어 있습니다.

이 스크립트가 하는 것과 하지 않는 것:

- **기본 실행은 읽기 전용입니다.** 설정을 바꾸지 않고, 아무것도 재시작하지
  않으며, 프로세스에 붙지도 않습니다. 이미 상태가 나쁜 서버에서도 안전하게
  돌도록 설계되어 있습니다.
- **사실만 수집하고, 진단하지 않습니다.** 리포트에는 결론이나 권고가 의도적으로
  없으며, 마지막 줄은 문자 그대로
  `==== END OF COLLECTION (no diagnosis by design) ====` 입니다. 해석은 WhaTap
  쪽에서 합니다.
- **판단할 일이 없습니다.** `n/a (permission denied: ...)` 같은 줄은 정상입니다 —
  읽을 수 없었다는 것 자체가 유용한 사실입니다. 보내기 전에 "고치려" 하지
  마십시오.

## 2. collector 받기

collector는 Git 저장소에 있습니다:

```sh
git clone https://github.com/whatap/global-groundtruth.git
```

이미 받아 둔 사본을 갱신하려면:

```sh
cd global-groundtruth && git pull
```

대상 서버에 인터넷 접근이 없으면, 워크스테이션에서 clone한 뒤 collector
스크립트 한 개만 서버로 복사하면 됩니다 (scp/SFTP/파일 전송 — 필요한 것은
`.sh` 파일 하나입니다).

## 3. 어떤 collector를 언제 쓰는가

실행할 collector는 WhaTap 담당자가 지정해 줍니다. 현재 두 개가 있습니다:

| WhaTap이 묻는 대상 | 스크립트 | 실행 위치 |
|---|---|---|
| **백엔드 / 수집 서버** (yard, proxy, gateway, ...) | `collectors/collection-server/collect-collserver.sh` | 백엔드 호스트에서 직접 |
| **Kubernetes** 모니터링 (operator, node agent, master agent, ...) | `collectors/k8s/collect-k8s.sh` | `kubectl`(또는 `oc`)로 클러스터에 접근되는 아무 장비 — bastion 또는 워크스테이션. 클러스터 노드 위가 **아님** |

## 4. 실행하기

collector를 **인자 없이 실행하면 도움말만 출력**됩니다 — 실수로 수집이
시작되는 일은 없습니다. 수집에는 항상 명시적 플래그가 필요하며, 표준은
`--file`입니다.

### 4.1 수집 서버 (백엔드 호스트)

```sh
cd global-groundtruth/collectors/collection-server
./collect-collserver.sh --file
# -> whatap-collserver-<host>-<timestamp>.txt
```

생성됐다고 표시되는 `.txt` 파일을 회신하십시오. WhaTap이 **전체 번들**(실제
로그 + 설정, 더 큰 파일)을 요청하면:

```sh
./collect-collserver.sh --bundle
# -> whatap-collserver-<host>-<timestamp>.tar.gz
```

참고:

- root는 **필수가 아닙니다**. 운영 정책이 허용하는 가장 높은 권한으로
  실행하십시오 — 권한이 낮아도 리포트는 유효하며, `n/a (permission denied)`
  줄이 늘어날 뿐입니다.
- 리포트에 WhaTap 홈 디렉토리가 `n/a`로 나오면 `--home <경로>`를 붙여 다시
  실행하십시오. 예: `./collect-collserver.sh --file --home /whatap`

### 4.2 Kubernetes (bastion / 워크스테이션)

```sh
cd global-groundtruth/collectors/k8s
./collect-k8s.sh --file
# -> whatap-k8s-<host>-<timestamp>.txt
```

생성됐다고 표시되는 `.txt` 파일을 회신하십시오. WhaTap이 **전체 번들**(YAML +
로그, 더 큰 파일)을 요청하면:

```sh
./collect-k8s.sh --bundle
# -> whatap-k8s-<host>-<timestamp>.tar.gz
```

참고:

- kubeconfig가 특정 네임스페이스로 제한되어 있으면
  `--namespace <whatap-네임스페이스>`를 붙이십시오.
- 여러 클러스터에 접근되는 bastion에서는 `--context <컨텍스트명>`을 붙이십시오.

### 4.3 실행 중에 보이는 것

- `>> `로 시작하는 진행 표시가 터미널에 출력되어 동작 중임을 확인할 수
  있습니다. 이 줄들은 리포트에 포함되지 않습니다.
- 실행은 수 초에서, 느린 호스트에서는 몇 분까지 걸립니다. 끝까지 기다리십시오 —
  리포트는 항상 `==== END OF COLLECTION ... ====` 줄로 끝납니다.
- 리포트의 `n/a (...)` 줄은 정상입니다. 파일을 그대로 보내십시오.

## 5. 회신하기

- 생성된 **파일 전체**를 그대로 첨부하십시오 (`.txt`, 번들이면 `.tar.gz`).
  편집·발췌·이름 변경·일부 붙여넣기는 하지 마십시오.
- 여러 호스트/클러스터에서 수집을 요청받았다면 호스트당 파일 하나씩입니다 —
  파일명에 이미 호스트명과 UTC 타임스탬프가 들어 있어 서로 충돌하지 않습니다.

## 6. 보안 주의사항

- **collection-server** 리포트와 번들에는 설정 파일이 **원문 그대로**
  들어갑니다 — 라이선스 키, `secure.conf`, 관리자 암호 포함. 케이스 종료 후
  로컬 사본을 삭제하십시오.
- **k8s** collector는 라이선스/암호/인증서 값을 마스킹하며 Kubernetes Secret
  내용을 읽지 않습니다 — 다만 번들에는 실제 로그가 들어 있으므로 같은 수준으로
  주의해서 다루십시오.

## 7. 언어

- 이 가이드는 영어(기준), 인도네시아어, 태국어, 한국어로 관리됩니다. 번역본이
  서로 다르면 영어판이 우선합니다.
- **리포트 출력과 스크립트 메시지는 설계상 항상 영어입니다** — 도구가 정확한
  문자열을 파싱합니다. 스크립트 출력을 번역하거나 수정하지 마십시오.

## 8. 문의

불명확한 점이 있거나 collector 실행이 실패하면, 터미널 출력의 스크린샷 또는
복사본과 함께 WhaTap Global 팀(평소 WhaTap 지원 창구)에 연락하십시오 — 그
출력 자체가 유용한 증거입니다.

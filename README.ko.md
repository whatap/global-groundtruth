# WhaTap Global Groundtruth

> **Languages:** [English (canonical)](README.md) · [Bahasa Indonesia](README.id.md) · [ไทย](README.th.md) · 한국어
>
> **필드 엔지니어이신가요?** 이 페이지 전체를 읽을 필요는 없습니다.
> **[필드 가이드](FIELD-GUIDE.ko.md)**
> ([English](FIELD-GUIDE.md) · [Bahasa Indonesia](FIELD-GUIDE.id.md) · [ไทย](FIELD-GUIDE.th.md))
> 를 읽으십시오 — 배경, 정확한 명령어, 회신 방법이 담겨 있습니다.

WhaTap 지원을 위한 다중 도메인 **진단 collector 프레임워크**입니다.

각 *collector*는 원격지의 WhaTap 에이전트 개발자에게 필요한 숨은 환경
사실(fact)을 수집합니다. 필드 엔지니어는 **명령 하나**를 실행하고 **완결된
리포트**를 회신하면 됩니다. 이것으로 K8s·server·APM·DB 도메인의 지원 케이스를
지연시키는 진단 문답 왕복 — "스무고개" 문제 — 을 없앱니다.

## 배경

원격 지원 케이스가 지연되는 지점은 대개 분석이 아니라 환경 사실입니다. 증상을
해석할 수 있는 개발자는 시스템에서 멀리 있고, 시스템 옆의 엔지니어는 수많은
사실 중 개발자에게 어떤 것이 필요할지 미리 알 수 없습니다. 그래서 케이스는
하루에 질문 하나씩 진행됩니다 — "런타임이 뭔가요?", "로그가 실제로 어디에
쌓이나요?", "JVM이 어떤 플래그로 떠 있나요?" — 여기에 시차와 채팅 중계가
겹치면 질문 10개가 실제 작업 1시간을 위해 달력 기준 2주를 잡아먹을 수
있습니다.

collector는 이 문답을 산출물 하나로 대체합니다. 필드 엔지니어가 스크립트
하나를 실행하고 파일 하나를 회신하면, 그 안에 개발자가 물었을 질문 — 그리고
그다음에 물었을 질문 — 의 답이 이미 들어 있습니다. 이름이 목표를 말해 줍니다:
모든 리포트는 환경에 대한 **ground truth** — 관측된 사실이며, 해석이 없습니다.

## 왜 프레임워크인가

진단 패턴은 도메인을 넘어 일반화되지만, 수집 **코드**는 그렇지 않습니다.
그래서 이 저장소는 공유 **계약(contract) + 포맷 + 템플릿 + 검증기**와, 도메인
팀이 소유하는 **도메인별 구현**으로 구성됩니다. 필드 엔지니어 한 명, 명령
하나, 붙여넣기 한 번 — 그러면 읽는 사람(에이전트 개발자)은 질문지 대신
ground-truth 사실을 받습니다.

## 계약 요약

[CONTRACT.md](CONTRACT.md)를 읽으십시오 — 규칙 4개이며 타협 불가입니다:

1. **사실만** — 진단·추정 원인·권고·수정 제시 금지.
2. **추정하지 말고 발견하라** — 심링크/마운트/설정을 해석(resolve)한다. 새로운
   환경에도 코드 변경이 필요 없어야 한다.
3. **필드 명령 하나 → 출력 붙여넣기** — 엔지니어는 하나만 실행하고 전체를
   복사한다.
4. **도메인 팀 소유** — 프레임워크 소유자는 뼈대를 제공하고, 각 collector는 그
   도메인 개발자의 것이다.

모든 리포트는 하나의 형태(헤더 → 번호 붙은 사실 섹션 → 고정 푸터)를
공유합니다: [docs/output-format.md](docs/output-format.md).

## 저장소 레이아웃

```
global-groundtruth/
├── README.md                     # this charter (.id/.th/.ko translations alongside)
├── FIELD-GUIDE.md                # field-engineer guide (.id/.th/.ko translations alongside)
├── CONTRACT.md                   # the 4 non-negotiable rules
├── docs/
│   ├── output-format.md          # shared report format spec
│   ├── authoring-guide.md        # how to add a collector
│   ├── collector-engineering.md  # design guidelines: MECE, load tiers, portability, reasoned absence
│   └── coverage-kb/              # environment-specific facts (discover, don't hardcode)
│       └── k8s-huawei-cce.md     # seed entry: Huawei CCE
├── collectors/
│   ├── k8s/                      # SEEDED v0 — cluster-level collector (operator/CR/agents)
│   ├── nms/                      # SEEDED v0 — NMS Control Manager host collector
│   ├── server/                   # STUB (README only)
│   ├── apm/                      # STUB (README only) — one per language: nodejs/java/python/php/dotnet
│   ├── db/                       # STUB (README only)
│   └── collection-server/        # SEEDED v0 — WhaTap backend (yard/proxy/...) collector
├── templates/
│   └── collector-skeleton/       # copy this to start a collector
└── tools/
    └── validate.sh               # lint: enforces facts-only + header + footer
```

## Collector 현황

| 도메인   | 상태          | 비고                                              |
|----------|-----------------|----------------------------------------------------|
| `k8s`               | SEEDED v0       | bastion에서 실행하는 클러스터 collector; `collectors/k8s/` 참조 |
| `nms`               | SEEDED v0       | NMS Control Manager 호스트 스크립트; `collectors/nms/` 참조 |
| `server`            | NOT IMPLEMENTED | 호스트 셸 스크립트; `collectors/server/` 참조          |
| `apm`               | NOT IMPLEMENTED | 언어별 패밀리; `collectors/apm/` 참조            |
| `db`                | NOT IMPLEMENTED | SQL + 에이전트 설정 덤프; `collectors/db/` 참조         |
| `collection-server` | SEEDED v0       | 백엔드 호스트 스크립트; `collectors/collection-server/` 참조 |

이 저장소는 **프레임워크**(계약, 포맷, 템플릿, 검증기, 문서), 도메인별
**스텁**, 그리고 핸드오버 전까지 Global 팀이 소유하는 **seeded v0** collector
3개(`collection-server`, `k8s`, `nms`)를 담고 있습니다. collector는 작성된 뒤 해당
도메인 팀이 소유합니다.

## collector 실행 (필드 엔지니어)

**[필드 가이드](FIELD-GUIDE.ko.md)**부터 읽으십시오 — collector별 정확한
명령어가 있습니다. 형태는 항상 같습니다: 하나를 실행하고, 출력 전체를
회신합니다. 해석은 요구되지 않습니다. collector별 상세는
`collectors/<domain>/README.md`에 있습니다.

## collector 추가 (도메인 개발자)

1. [templates/collector-skeleton/](templates/collector-skeleton/)을
   `collectors/<domain>/`으로 복사합니다.
2. [CONTRACT.md](CONTRACT.md)와 [docs/output-format.md](docs/output-format.md)를
   지키며 사실 섹션을 채웁니다.
3. 검증:
   ```sh
   tools/validate.sh collectors/<domain>/<your-collector>.sh
   ```

전체 안내: [docs/authoring-guide.md](docs/authoring-guide.md). 견고한
collector — MECE 섹션, 부하 안전 티어, 미지의 호스트 이식성, 사유가 달린
`n/a` — 는 [docs/collector-engineering.md](docs/collector-engineering.md)를
따르십시오.

## 문서 언어 정책

- **스크립트는 영문 전용입니다** — 코드, 주석, usage/help 텍스트, 진행 표시,
  그리고 리포트 출력의 모든 줄. 리포트는 도구가 파싱하고 여러 지역의 개발자가
  읽습니다. `tools/validate.sh`와 고정 푸터 sentinel이 정확한 영문 문자열에
  의존합니다. 리포트 출력을 절대 번역하지 마십시오.
- **필드 대면 문서** — [FIELD-GUIDE.md](FIELD-GUIDE.md)와 이 README — 는 4개
  언어로 관리합니다: 영어에 더해 인도네시아어(`.id.md`), 태국어(`.th.md`),
  한국어(`.ko.md`).
- **영어판이 기준(canonical)입니다.** 번역이 뒤처지거나 다르면 영어 파일이
  우선합니다. 영어 파일을 수정한 사람이 같은 변경에서 번역 3종을 함께
  갱신합니다 — 그 비용이 작도록 이 문서들은 의도적으로 짧게 유지합니다.
- 개발자 문서([CONTRACT.md](CONTRACT.md), [docs/](docs/) 이하 전부, collector
  README)는 영문 전용입니다.

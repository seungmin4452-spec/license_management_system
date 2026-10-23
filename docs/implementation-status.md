# 구현 범위·검증 결과·알려진 제한사항

작성 시점: 2026-10-23. 개발은 Windows PC에서 진행했고 이 PC에는 Swift·macOS SDK가 없어 **Swift 코드를 아직 한 번도 빌드·실행하지 못했습니다.** 맥에서 해야 할 확인 항목을 아래에 정리했습니다.

## 구현한 범위(CLAUDE.md 기준)

| 영역 | 내용 | 위치 |
|---|---|---|
| 생성기 | `LicenseGenerator` 프로토콜, 내장 3종(`lms-license-v1`, `reviewcut-legacy`, `rentaldesk-legacy`), 입력 검증·기능 정보·검증 함수 | `Sources/LicenseCore/Generators` |
| 정규화 JSON | `JSONEncoder` 미사용, 직접 파서·직렬화(키 코드포인트 정렬, 규격 이스케이프, 숫자 원문 보존) | `Sources/LicenseCore/JSON` |
| 키 | Ed25519 seed/공개키, PKCS#8 PEM·JSON(`private_key_hex`)·hex 가져오기, SPKI PEM, 알려진 고객 앱 공개키 대조 | `Keys/Ed25519Keys.swift` |
| PC 번호 | 4개 체계, 정규화·표시 형식·자동 제안, 공통 PC 번호 계산(테스트용) | `PcNumber.swift` |
| 시각 | UTC 저장, 서울(UTC+9) 표시, `[시작, 만료)`, 마지막 사용일 ↔ 만료 시각, N개월 규칙 | `Util/LicenseTime.swift` |
| DB | GRDB 마이그레이션, 외래키·고유·CHECK 제약, 트리거(라이선스 고객=PC 소유자, 발급 내용 불변, 상태 전이, 삭제 금지, PC 번호 잠금, 감사 기록 추가 전용) | `Sources/LicenseStore/Database` |
| 업무 규칙 | 제품·키·고객·PC·자동 발급·수동 등록·일괄 등록·갱신·PC 교체·취소, 기간 중복 검사(트랜잭션 안), 요청 토큰으로 중복 클릭 방지, 발급 직후 자체 검증 | `Services/` |
| 검색·대시보드 | 통합 검색(PC 번호는 하이픈·대소문자 무관), 제품·처리 상태·유효 상태·만료 예정 필터, 집계 | `QueryService.swift` |
| CSV | 파서·작성기(수식 위험 처리), 양식, 컬럼 연결, 미리보기, 전체 성공/취소 저장, RentalDesk 발급 내역 연결, 중복 건너뜀, 내보내기 | `Sources/LicenseStore/CSV` |
| 백업 | 온라인 백업, 종료 시 자동 백업(실패 시 선택), 보존 개수, 복원 전 검증·안전 백업·롤백, 업그레이드 전 백업 | `Backup/BackupService.swift` |
| 운영 | 데이터 위치, 단일 실행 잠금, 민감 값 가림 로그(크기·개수 제한), 데모 DB 분리 | `Support/` |
| 화면 | 대시보드 / 고객·PC / 제품 / 라이선스 / 가져오기·내보내기 / 백업·설정, 상단 통합 검색·발급 버튼, 발급 창(자동·수동·갱신·교체), 상세 화면, 빈 목록·결과 없음·로딩·실패 상태 | `Sources/LicenseManager` |
| 배포 | `scripts/build_app.sh`(.app, .dmg, 선택적 Developer ID 서명·공증) | |

## 이 PC에서 확인한 것

- 이전 형식 고정 예제(`docs/legacy-fixtures/`)를 **각 앱 저장소의 실제 코드**로 만들고 검증 통과를 확인했습니다.
  - ReviewCut: `core.ts`의 `signLicense`로 서명 → `verifyLicense` 통과(3건: 표시명 있음/없음/특수 문자)
  - RentalDesk: `licensing.py`의 `issue_license`로 서명 → `verify_license` VALID(3건: 영구/기간제/특수 문자)
- 교차 검증 스크립트의 앱 측 검증 호출(`--verify`)이 동작함을 확인했습니다.

## 맥에서 해야 할 확인(아직 하지 않음)

1. `swift build` — 컴파일 오류가 있으면 수정. (컴파일러 없이 작성했으므로 사소한 타입·API 오류가 있을 수 있음)
2. `swift test` — 특히
   - `LicenseV1VectorTests`: `docs/license-v1-test-vectors.json` 전체(PC 번호, 서명 대상 바이트, 결과 코드)
   - `LegacyFormatTests`: 이전 형식 서명 대상 바이트·파일 바이트 일치, 새로 서명한 파일 검증
   - `LicenseRulesTests`, `RegistrationImportBackupTests`: 10절 업무 규칙(중복 기간, 경계 시각, 갱신·교체 추적, 실패 시 롤백, 중복 클릭, 취소·대체 제외, 미검증 표시, 키 불일치 거부, 비밀키 비유출, CSV 전체 취소·재가져오기, 백업 복원·손상 거부, 재실행 후 유지)
3. `tools/verify_generated_with_apps.sh` — Swift가 새로 서명한 이전 형식 파일을 두 앱의 검증 코드로 확인
4. `swift run LicenseManager` 또는 `scripts/build_app.sh` 후 앱 실행, 대표 시나리오 수동 확인:
   고객 등록 → PC 번호 등록 → 제품 선택 → 자동 발급 → 복사/저장 → PC 번호로 검색 → 갱신/PC 교체 → 이력 확인
5. 키체인 저장 확인(임시 서명 앱에서 데이터 보호 키체인이 안 되면 로그인 키체인으로 저장하도록 구현됨)
6. 첫 빌드 후 `Package.resolved` 커밋

## 판매자 환경에서만 가능한 확인

- **운영 키로 발급한 라이선스를 실제 고객 앱 설치판에 등록해 보는 검증은 하지 않았습니다.** 운영 비밀키 가져오기(ReviewCut `prod-2026`, RentalDesk) 후 테스트 PC에서 확인이 필요합니다.

## 알려진 제한사항·설계 판단

- 시각 계산은 서울을 UTC+9 고정으로 합니다(1988년 이후 한국은 일광절약시간 없음).
- 발급 창의 날짜 선택기는 서울 시간대로 표시하도록 설정했고, 선택 결과를 '포함되는 마지막 날짜'·'실제 만료 시각'·저장될 UTC로 함께 보여줍니다.
- 수동 등록에서 서명이 확인된 파일의 PC 번호가 선택한 PC와 다르면 등록을 막습니다(해당 PC를 먼저 등록). 서명이 확인되지 않은 파일은 PC 일치를 강제하지 않고 '호환성 미검증'으로 둡니다.
- 미검증 파일의 라이선스 ID는 고유 제약에 쓰지 않습니다(위조 ID가 정상 파일 등록을 막지 않도록). 조건 스냅샷에만 남깁니다.
- CSV 가져오기는 DB에 이미 있는 '발급됨' 기록과 기간이 겹치면 오류로 처리합니다. 파일 안의 겹침만 옵션으로 '대체됨' 처리합니다. 이미 취소·대체 상태인 과거 기록은 기간 중복 검사 없이 가져옵니다.
- 일괄 파일 등록은 서명 확인된 파일만 받습니다. 미검증 파일은 개별 수동 등록을 쓰세요.
- 로컬 DB의 감사 기록은 위변조 방지 증거가 아닙니다. 기본 DB는 암호화하지 않습니다.
- 목록은 한 번에 최대 2,000건(검색은 500건)까지 보여줍니다.
- MVP 제외 범위(온라인 활성화, 고객 포털, 결제, 자동 발송, 다중 관리자, 클라우드 동기화, 원격 회수, 자동 업데이트)는 구현하지 않았습니다.

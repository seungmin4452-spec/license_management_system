# 공통 오프라인 라이선스 형식 v1 (`lms-license` v1)

판매하는 모든 프로그램이 같은 방식으로 라이선스를 발급·검증하기 위한 규격이다.
라이선스 관리 프로그램은 이 규격 하나로 모든 제품을 발급한다. 새 제품을 추가해도 관리 프로그램 코드를 고치지 않는다.

- 참조 구현: ReviewCut(`cut_review/src/main/license/v1.ts`), RentalDesk(`rental_management_system/src/rentdesk/services/license_v1.py`), 테스트 벡터 생성기(`tools/gen_license_v1_vectors.py`)
- 테스트 벡터: `docs/license-v1-test-vectors.json` — 새 구현은 이 파일의 모든 항목을 통과해야 한다.
- 이 규격을 바꾸려면 `version`을 올리고 서명 접두어(`lms-license-v2:`)도 바꾼다. v1의 의미를 바꾸지 않는다.

## 1. 기본 원칙

- 서명: **Ed25519**(RFC 8032). 판매자 비밀키로 서명하고, 고객 앱에는 공개키만 넣는다.
- 키: **제품마다 별도 키 쌍**. 한 제품 키가 유출되어도 다른 제품에 영향이 없다. 한 제품이 여러 키를 가질 수 있고(`key_id`로 구분) 키 교체 시 이전 공개키를 앱에 남겨 기존 라이선스를 계속 인정한다.
- 오프라인: 인터넷 확인 없이 파일만으로 검증한다. 이미 전달한 라이선스를 원격으로 취소할 수 없다.
- 복제 방지 기술이 아니라 기본적인 구매 확인 수단이다.

## 2. PC 번호 (`pc_id`, 번호 체계 `lms-pc-v1`)

모든 제품이 같은 규칙으로 PC 번호를 만든다. **같은 PC는 어느 제품에서나 같은 PC 번호가 나온다.** 관리 프로그램에서는 PC를 한 번만 등록하면 여러 제품에 쓸 수 있다.

1. 운영체제 기기 식별자 원문(`raw`)을 읽는다.
   - Windows: 레지스트리 `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography` 의 `MachineGuid` (64비트 보기)
   - macOS: `ioreg -rd1 -c IOPlatformExpertDevice` 출력의 `IOPlatformUUID`
   - 그 외 운영체제는 지원하지 않는다(PC 번호를 확인할 수 없음으로 처리).
2. `device_hash = lowercase_hex(SHA-256(UTF-8(trim(raw))))`
3. `digest = SHA-256(UTF-8("LMS-PC-ID:v1:" + device_hash))`
4. `pc_id = RFC 4648 Base32(digest)` 의 **앞 25자** (대문자 `A–Z`, 숫자 `2–7`)
5. 화면 표시: 5자씩 하이픈으로 묶는다. 예) `ABCDE-FGHIJ-KLMNO-PQRST-UVWXY`

입력받은 PC 번호의 정규화: 공백·하이픈 제거 → 대문자 변환 → `^[A-Z2-7]{25}$` 이어야 한다.
라이선스 파일에는 정규화 값(하이픈 없음)을 넣는다.

- 원본 하드웨어 식별자는 화면·파일·로그 어디에도 남기지 않는다(해시만 사용).
- 운영체제 재설치, 메인보드 교체, Mac ↔ Windows 변경 시 PC 번호가 바뀔 수 있다 → PC 교체(재발급) 절차로 처리한다.
- 기존 형식과 길이로 구분된다: RentalDesk 기존 기기 코드는 20자, ReviewCut 기존 설치 ID는 `VRN-` 로 시작한다. v1 PC 번호는 25자다.

## 3. 라이선스 파일

UTF-8 JSON 파일. 확장자 `.json`, 최대 16 KiB. 들여쓰기·공백은 자유(검증은 파싱 후 수행).

```json
{
  "format": "lms-license",
  "version": 1,
  "key_id": "rentaldesk-2026",
  "payload": {
    "edition": "standard",
    "expires_at": "2026-11-24T15:00:00Z",
    "issued_at": "2026-10-23T05:00:00Z",
    "license_id": "6f1c2a4e-1b7d-4c55-9a51-0f2d3c4b5a69",
    "licensee": "OO렌탈",
    "max_version": "1.0",
    "options": {},
    "pc_id": "ABCDEFGHIJKLMNOPQRSTUVWXY",
    "product_code": "RENTALDESK",
    "starts_at": "2026-10-23T05:00:00Z"
  },
  "signature": "<Base64>"
}
```

### 봉투(서명 대상 아님)

| 필드 | 값 |
|---|---|
| `format` | 반드시 `"lms-license"` |
| `version` | 숫자 `1` (`1.0`도 같은 값으로 본다 — JavaScript가 구분하지 못하므로) |
| `key_id` | `^[a-z0-9][a-z0-9._-]{0,63}$`. 제품 안에서 서명 키를 고르는 이름 |
| `payload` | 아래 객체 |
| `signature` | 표준 Base64(패딩 포함) Ed25519 서명 64바이트. 디코딩 후 다시 인코딩한 값과 같아야 한다(비정규 표기 거부) |

위 다섯 필드 외의 최상위 필드가 있으면 형식 오류다.

### payload (서명 대상)

모든 필드가 반드시 있어야 하며, 정의되지 않은 필드가 있으면 형식 오류다. 값은 **문자열 또는 null**(그리고 `options` 객체)만 쓴다. 숫자·불리언·배열은 쓰지 않는다.

| 필드 | 형식 | 의미 |
|---|---|---|
| `license_id` | UUID 소문자 `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$` | 라이선스 고유 번호 |
| `product_code` | `^[A-Z][A-Z0-9_]{1,31}$` | 제품 코드. 예) `REVIEWCUT`, `RENTALDESK` |
| `pc_id` | `^[A-Z2-7]{25}$` | 정규화된 PC 번호 |
| `issued_at` | UTC `YYYY-MM-DDTHH:MM:SSZ` | 발급 시각 |
| `starts_at` | UTC `YYYY-MM-DDTHH:MM:SSZ` | 사용 시작 시각(포함). 미래 시각 가능 |
| `expires_at` | UTC `YYYY-MM-DDTHH:MM:SSZ` 또는 `null` | 사용 종료 시각(**미포함**). `null`이면 영구. `starts_at`보다 늦어야 함 |
| `edition` | `^[a-z][a-z0-9_-]{0,31}$` | 에디션. 예) `full`, `standard` |
| `max_version` | `^(0\|[1-9][0-9]{0,3})\.(0\|[1-9][0-9]{0,3})$` 또는 `null` | 사용 가능한 최고 `주.부` 버전. `null`이면 버전 제한 없음 |
| `licensee` | 1~100자 문자열 또는 `null` | 고객 표시명(상호 등). **연락처·이메일을 넣지 않는다** |
| `options` | 객체(최대 20개). 키 `^[a-z][a-z0-9_]{0,31}$`, 값은 0~200자 문자열 | 제품별 추가 조건. 없으면 `{}` |

- 모든 문자열에 제어 문자(U+0000–U+001F, U+007F)와 짝 없는 서로게이트를 쓰지 않는다.
- `licensee` 의 처음과 끝 문자는 다음 공백 문자가 아니어야 한다(언어별 trim 차이를 피하려고 직접 정의): U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF. 문자 수는 유니코드 코드 포인트 기준.
- 시각은 초 단위까지만 쓴다(밀리초 없음). 연도는 0001–9999, 실제로 있는 날짜여야 한다(예: 2월 30일 거부).
- 날짜 단위로 기간을 정할 때(관리 프로그램 정책): 시작일 서울 00:00:00, 만료는 **마지막 사용일 다음 날 서울 00:00:00**. 예) 2026-11-24까지 사용 → `expires_at = 2026-11-24T15:00:00Z`.

### 유효 판정

- 기간: `starts_at <= 현재 < expires_at` (`expires_at` 이 `null` 이면 끝이 없음)
- 버전: 앱 버전 `주.부.수` 의 `(주, 부)` 가 `max_version` 의 `(주, 부)` 이하. `max_version` 이 `null` 이면 항상 통과. 수(패치) 번호는 비교하지 않는다.

## 4. 서명 대상 바이트

```
message = UTF-8("lms-license-v1:") ++ UTF-8(canonical_json(payload))
signature = Ed25519_Sign(private_key, message)
```

`lms-license-v1:` 접두어는 기존 형식(ReviewCut·RentalDesk 구형식)의 서명과 섞이지 않게 한다. 그래서 기존 제품 키를 v1에 그대로 써도 안전하다.

`canonical_json` (RFC 8785 JCS의 부분집합 — 이 규격의 값 종류에서는 JCS와 같은 결과):

- 공백 없음. 객체 키는 유니코드 코드 포인트 순 정렬(키는 ASCII만 허용하므로 바이트 순과 같다).
- `null` → `null`
- 문자열 → `"` 로 감싸고 다음만 이스케이프: `"` → `\"`, `\` → `\\`, U+0008 `\b`, U+0009 `\t`, U+000A `\n`, U+000C `\f`, U+000D `\r`, 그 밖의 U+0000–U+001F → `\u00xx`(소문자 16진). **그 외 모든 문자(한글, `/` 포함)는 이스케이프하지 않고 UTF-8 그대로.**
- 객체 → `{` + `"키":값` 을 `,` 로 이어서 + `}`

언어별 주의:

- Python: `json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)` 가 위 규칙과 같다.
- JavaScript: `JSON.stringify` 의 문자열 이스케이프는 위 규칙과 같다. 키 정렬은 직접 해야 한다.
- Swift: `JSONEncoder` 는 `/` 를 `\/` 로 바꾸는 등 결과가 다르다. **직접 직렬화 함수를 작성**한다.
- Apple CryptoKit의 Ed25519 서명은 매번 값이 달라질 수 있다(유효한 서명이다). 구현 검증은 서명 문자열 비교가 아니라 **message 바이트 일치 + 서명 검증 통과**로 판정한다.

## 5. 검증 순서와 결과 코드

고객 앱은 아래 순서로 검사하고, 처음 실패한 코드를 사용자 안내 문구로 바꿔 보여준다.

| 순서 | 코드 | 실패 조건 |
|---|---|---|
| 1 | `format` | 크기 초과, JSON 아님, 봉투·payload 필드/형식 규칙 위반, Base64 오류 |
| 2 | `unknown_key` | 앱에 해당 `key_id` 공개키가 없음 |
| 3 | `bad_signature` | 서명 검증 실패 |
| 4 | `product` | `product_code` 가 이 앱의 제품 코드와 다름 |
| 5 | `pc_id` | `pc_id` 가 이 PC의 PC 번호와 다름 |
| 6 | `not_yet_valid` | 현재 < `starts_at` |
| 7 | `expired` | 현재 >= `expires_at` |
| 8 | `version` | 앱 버전이 `max_version` 을 넘음 |

payload 필드 형식 검사는 서명 검사 **전**(1번)에 한다. 형식이 틀린 payload는 서명이 맞아도 거부한다.
PC 번호를 확인할 수 없으면(지원하지 않는 OS 등) 5번에서 실패로 처리하고, 앱은 그 사실을 따로 안내한다.

## 6. 키 관리

- 키 쌍: Ed25519 32바이트 비밀 seed / 32바이트 공개키.
- 앱에는 `(key_id, 공개키)` 목록만 넣는다(공개키 표기는 hex 또는 SPKI PEM 등 앱 편의대로).
- 비밀키는 저장소·설치 파일·로그·일반 백업에 넣지 않는다. 판매자 Mac의 키체인 또는 저장소 밖 권한 600 파일에 둔다.
- 기존 제품 키 재사용(서명 접두어로 분리되므로 안전):

| 제품 코드 | key_id | 비밀키(기존) | 앱의 공개키 위치 |
|---|---|---|---|
| `REVIEWCUT` | `prod-2026` | `%USERPROFILE%\ReviewCut-license-keys\prod-2026.private.pem` (PKCS#8 PEM) | `cut_review/src/main/license/public-keys.ts` |
| `RENTALDESK` | `rentaldesk-2026` | `~/RentDeskSellerKeys/signing_key.json` 의 `private_key_hex` | `rental_management_system/src/rentdesk/license_public_key.py` |

- 새 제품: 관리 프로그램(또는 발급 도구)에서 새 키 쌍을 만들고, 공개키와 `key_id` 를 새 앱에 넣는다.

## 7. 기존 형식과의 관계

- 기존 형식(ReviewCut `{payload, signature, keyId}`, RentalDesk `{license, signature}`)은 **이미 판매한 앱 버전용**으로 계속 발급·검증한다.
- v1을 지원하는 새 앱 버전은 두 형식을 모두 인식한다. 화면에는 v1 PC 번호를 보여준다.
- 발급 도구는 고객이 보낸 번호 형태로 형식을 고른다: 25자 PC 번호 → v1, 기존 기기 코드/설치 ID → 기존 형식.

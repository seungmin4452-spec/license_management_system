#!/bin/bash
# 관리 프로그램(Swift)이 새로 서명한 이전 형식 파일을 각 고객 앱 저장소의 실제 검증 코드로 확인한다.
#   ReviewCut  : ../cut_review/src/main/license/core.ts 의 verifyLicense (Node 22.6+)
#   RentalDesk : ../rental_management_system/src/rentdesk/services/licensing.py 의 verify_license (PyNaCl)
# 테스트 전용 키(docs/legacy-fixtures)를 쓴다. 운영 키는 쓰지 않는다.
#
# 사용: tools/verify_generated_with_apps.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PUB_HEX="6175f38c001ee447066d27d79f28d68f2a4d1d331f9356f67e90cb83ad0897aa"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "1) Swift 생성기로 예제 파일 만들기 → $OUT"
LMS_EXPORT_FIXTURES_DIR="$OUT" swift test --filter "LegacyFormatTests/testExportGeneratedFilesForAppVerification"
test -s "$OUT/reviewcut.json" && test -s "$OUT/rentaldesk.json"

echo "2) ReviewCut verifyLicense"
node tools/gen_legacy_fixtures_reviewcut.mjs --verify "$OUT/reviewcut.json" \
  --install-id VRN-7KQ2-M9XA-3PDF --public-key-hex "$PUB_HEX" --key-id test-legacy

echo "3) RentalDesk verify_license"
PY="../rental_management_system/.venv/bin/python"
[ -x "$PY" ] || PY="python3"
"$PY" tools/gen_legacy_fixtures_rentaldesk.py --verify "$OUT/rentaldesk.json" \
  --machine-code ABCD2EFGH3IJKL4MNOP5 --public-key-hex "$PUB_HEX" --now 2026-10-25T00:00:00Z

echo "모두 통과: 관리 프로그램이 만든 이전 형식 파일을 두 앱의 검증 코드가 인정합니다."

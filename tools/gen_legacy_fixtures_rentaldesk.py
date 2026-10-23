#!/usr/bin/env python3
"""RentalDesk 이전 형식(rentaldesk-legacy) 고정 예제 파일 생성기.

RentalDesk 저장소의 실제 발급·검증 코드(`../rental_management_system/src/rentdesk/services/licensing.py`)를
그대로 써서 테스트 전용 키로 예제 파일을 만들고, 같은 코드의 `verify_license`로 통과하는지 확인한다.

실행(RentalDesk 가상환경의 Python, PyNaCl 필요):
  ../rental_management_system/.venv/bin/python tools/gen_legacy_fixtures_rentaldesk.py > docs/legacy-fixtures/rentaldesk-legacy.json
Ed25519(RFC 8032) 서명은 결정적이므로 다시 실행해도 같은 파일이 나온다.

관리 프로그램이 만든 파일을 앱 코드로 검사하려면:
  python tools/gen_legacy_fixtures_rentaldesk.py --verify <license.json> --machine-code XXXX-... --public-key-hex <hex>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "rental_management_system" / "src"))

from nacl.signing import SigningKey, VerifyKey  # noqa: E402

from rentdesk.domain.license_terms import expiry_end_utc  # noqa: E402
from rentdesk.services.licensing import LicenseStatus, canonical_payload, issue_license, verify_license  # noqa: E402

SEED = hashlib.sha256(b"lms legacy TEST KEY - never use in a product").digest()
MACHINE = "ABCD2EFGH3IJKL4MNOP5"  # 20자(A-Z, 2-7)


def utc(text: str) -> datetime:
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify")
    parser.add_argument("--machine-code")
    parser.add_argument("--public-key-hex")
    parser.add_argument("--now")
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")

    if args.verify:
        text = Path(args.verify).read_text(encoding="utf-8")
        now = utc(args.now) if args.now else datetime.now(UTC)
        result = verify_license(text, public_key=VerifyKey(bytes.fromhex(args.public_key_hex)),
                                machine_code=args.machine_code, now=now, app_version="1.0.0")
        print(result.status.value)
        return 0 if result.valid else 1

    key = SigningKey(SEED)
    public = key.verify_key
    cases = []

    def add(name: str, *, label: str, expires_day: str | None, license_id: str, now: str, issued: str,
            updates_through: str = "1.0") -> None:
        expires = expiry_end_utc(datetime.strptime(expires_day, "%Y-%m-%d").date()) if expires_day else None
        text = issue_license(key, machine_code=MACHINE, customer_label=label, issued_at=utc(issued),
                             expires_at=expires, updates_through=updates_through, license_id=license_id)
        check = verify_license(text, public_key=public, machine_code=MACHINE, now=utc(now), app_version="1.0.0")
        if check.status != LicenseStatus.VALID:
            raise SystemExit(f"앱 검증 실패: {name} {check.status}")
        payload = json.loads(text)["license"]
        cases.append({
            "name": name,
            "file_text": text,
            "message_utf8": canonical_payload(payload).decode("utf-8"),
            "machine_code": MACHINE,
            "verify_now": now,
            "app_verify": "VALID",
        })

    add("영구", label="OO렌탈", expires_day=None, license_id="3d6e8f10-2b4c-4d5e-8f90-1a2b3c4d5e6f",
        now="2026-10-25T00:00:00Z", issued="2026-10-23T05:00:00Z")
    add("기간제(마지막 사용일 2026-11-23)", label="OO렌탈", expires_day="2026-11-23",
        license_id="5a7b9c1d-3e4f-4a5b-9c6d-7e8f9a0b1c2d", now="2026-11-23T14:59:58Z",
        issued="2026-10-23T05:00:00Z")
    add("특수 문자 표시명", label='한글 "따옴표" \\ 역슬래시 / 슬래시 ☕ 😀 A\tB', expires_day=None,
        license_id="7c9d1e2f-4a5b-4c6d-8e7f-9a0b1c2d3e4f", now="2026-10-25T00:00:00Z",
        issued="2026-10-23T05:00:00Z", updates_through="1.2")

    out = {
        "description": ("RentalDesk 이전 형식(rentaldesk-legacy) 고정 예제. RentalDesk licensing.py의 issue_license로 "
                        "만들고 verify_license로 확인했다. 테스트 전용 키 — 제품에 넣지 말 것."),
        "generator": "tools/gen_legacy_fixtures_rentaldesk.py",
        "test_key": {"key_id": None, "seed_hex": SEED.hex(), "public_key_hex": public.encode().hex()},
        "cases": cases,
    }
    sys.stdout.write(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

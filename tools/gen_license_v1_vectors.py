#!/usr/bin/env python3
"""공통 라이선스 형식 v1 테스트 벡터 생성기 (docs/license-format-v1.md).

각 제품 구현(TypeScript·Python·Swift)이 같은 결과를 내는지 확인하기 위한 기준 파일을 만든다.
앱 코드와 독립된 최소 구현이다. 테스트 전용 고정 키를 쓰며, 이 키는 어떤 제품에도 넣지 않는다.

실행(PyNaCl 필요):  python tools/gen_license_v1_vectors.py > docs/license-v1-test-vectors.json
Ed25519(RFC 8032) 서명은 결정적이므로 다시 실행해도 같은 파일이 나온다.
"""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import sys

from nacl.signing import SigningKey

PREFIX = "lms-license-v1:"
PRODUCT = "TESTPRODUCT"
KEY_ID = "test-2026"
TEST_SEED = hashlib.sha256(b"lms-license-v1 TEST KEY - never use in a product").digest()
OTHER_SEED = hashlib.sha256(b"lms-license-v1 OTHER TEST KEY").digest()


def canonical_json(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def message(payload: dict) -> bytes:
    return (PREFIX + canonical_json(payload)).encode("utf-8")


def device_hash(raw: str) -> str:
    return hashlib.sha256(raw.strip().encode("utf-8")).hexdigest()


def pc_id(raw: str) -> str:
    digest = hashlib.sha256(("LMS-PC-ID:v1:" + device_hash(raw)).encode("utf-8")).digest()
    return base64.b32encode(digest).decode("ascii")[:25]


def display(code: str) -> str:
    return "-".join(code[i:i + 5] for i in range(0, 25, 5))


def sign(payload: dict, seed: bytes = TEST_SEED, key_id: str = KEY_ID, raw_message: bytes | None = None) -> dict:
    payload = copy.deepcopy(payload)  # 케이스마다 독립 객체(변조 케이스가 다른 케이스를 바꾸지 않게)
    sig = SigningKey(seed).sign(raw_message if raw_message is not None else message(payload)).signature
    return {"format": "lms-license", "version": 1, "key_id": key_id, "payload": payload,
            "signature": base64.b64encode(sig).decode("ascii")}


def main() -> None:
    key = SigningKey(TEST_SEED)
    raws = ["4C4C4544-0042-3510-8058-B4C04F4A4E32",
            "  6f3b2a10-1234-4abc-9def-0123456789ab \r\n",
            "{8E0B7C2D-3F4A-4B5C-9D6E-7F8091A2B3C4}"]
    pcs = [{"raw": r, "device_hash": device_hash(r), "pc_id": pc_id(r), "display": display(pc_id(r))} for r in raws]
    me, other_pc = pcs[0]["pc_id"], pcs[1]["pc_id"]

    base = {
        "license_id": "6f1c2a4e-1b7d-4c55-9a51-0f2d3c4b5a69",
        "product_code": PRODUCT,
        "pc_id": me,
        "issued_at": "2026-10-23T05:00:00Z",
        "starts_at": "2026-10-23T05:00:00Z",
        "expires_at": None,
        "edition": "standard",
        "max_version": None,
        "licensee": "OO렌탈",
        "options": {},
    }

    def p(**over) -> dict:
        d = copy.deepcopy(base)
        d.update(over)
        return d

    term = p(expires_at="2026-11-24T15:00:00Z", max_version="1.0")
    ctx = {"product_code": PRODUCT, "pc_id": me, "now": "2026-10-25T00:00:00Z", "app_version": "1.0.3"}
    cases: list[dict] = []

    def case(name: str, file: dict, expect: str, **ctx_over) -> None:
        c = dict(ctx)
        c.update(ctx_over)
        cases.append({"name": name, "file": file, "context": c, "expect": expect})

    case("영구, 버전 제한 없음", sign(base), "valid")
    case("기간제 기간 안", sign(term), "valid")
    case("시작 시각 정각은 유효", sign(term), "valid", now="2026-10-23T05:00:00Z")
    case("시작 1초 전", sign(term), "not_yet_valid", now="2026-10-23T04:59:59Z")
    case("만료 1초 전은 유효", sign(term), "valid", now="2026-11-24T14:59:59Z")
    case("만료 시각 정각은 만료", sign(term), "expired", now="2026-11-24T15:00:00Z")
    case("미래 시작 라이선스", sign(p(starts_at="2026-12-01T15:00:00Z")), "not_yet_valid")
    case("패치 버전은 허용", sign(term), "valid", app_version="1.0.99")
    case("다음 부 버전은 거부", sign(term), "version", app_version="1.1.0")
    case("이전 주 버전은 허용", sign(term), "valid", app_version="0.9.0")
    case("다른 PC", sign(base), "pc_id", pc_id=other_pc)
    case("다른 제품", sign(p(product_code="OTHERPRODUCT")), "product")
    tampered = sign(base)
    tampered["payload"]["licensee"] = "다른 고객"
    case("서명 후 내용 변경", tampered, "bad_signature")
    case("알 수 없는 key_id", sign(base, key_id="unknown-key"), "unknown_key")
    case("같은 key_id, 다른 키로 서명", sign(base, seed=OTHER_SEED), "bad_signature")
    case("접두어 없이 서명(구형식 서명 재사용 시도)",
         sign(base, raw_message=canonical_json(base).encode("utf-8")), "bad_signature")
    special = p(licensee='한글 "따옴표" \\ 역슬래시 / 슬래시 ☕', options={"seats": "3", "z_note": "a/b"})
    case("특수 문자 정규화", sign(special), "valid")
    case("payload에 정의되지 않은 필드", sign(p(extra="x")), "format")
    missing = sign(base)
    del missing["payload"]["options"]
    case("payload 필드 누락", missing, "format")
    case("숫자 값 사용", sign(p(max_version=1)), "format")
    case("만료가 시작보다 이르거나 같음", sign(p(expires_at="2026-10-23T05:00:00Z")), "format")
    case("소문자 pc_id", sign(p(pc_id=me.lower())), "format")
    case("밀리초가 있는 시각", sign(p(issued_at="2026-10-23T05:00:00.000Z")), "format")
    case("licensee 앞뒤 공백", sign(p(licensee=" OO렌탈")), "format")
    case("licensee 제어 문자", sign(p(licensee="OO\n렌탈")), "format")
    case("licensee 앞 BOM", sign(p(licensee=chr(0xFEFF) + "OO렌탈")), "format")
    case("licensee 끝 전각 공백", sign(p(licensee="OO렌탈" + chr(0x3000))), "format")
    case("licensee 가운데 공백은 허용", sign(p(licensee="OO 렌탈")), "valid")
    case("licensee 100자(이모지 포함, 코드 포인트 기준)", sign(p(licensee="😀" * 100)), "valid")
    case("licensee 101자", sign(p(licensee="가" * 101)), "format")
    case("없는 날짜", sign(p(issued_at="2026-02-30T00:00:00Z")), "format")
    case("0000년", sign(p(issued_at="0000-01-01T00:00:00Z")), "format")
    v2 = sign(base)
    v2["version"] = 2
    case("봉투 version 2", v2, "format")
    extra_top = sign(base)
    extra_top["note"] = "x"
    case("봉투에 정의되지 않은 필드", extra_top, "format")
    bad_b64 = sign(base)
    bad_b64["signature"] = "not base64!!"
    case("서명 Base64 오류", bad_b64, "format")
    # 64바이트 서명의 86번째 문자는 하위 4비트를 쓰지 않는다 → 같은 바이트로 풀리는 다른 표기
    loose = sign(base)
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    s = loose["signature"]
    loose["signature"] = s[:85] + alphabet[alphabet.index(s[85]) ^ 1] + s[86:]
    assert base64.b64decode(loose["signature"]) == base64.b64decode(s)
    case("비정규 Base64 표기", loose, "format")
    float_version = sign(term)
    float_version["version"] = 1.0
    case("봉투 version 1.0은 1과 같음", float_version, "valid")

    for c in cases:
        payload = c["file"].get("payload")
        if isinstance(payload, dict):
            c["message_utf8"] = PREFIX + canonical_json(payload)

    out = {
        "description": "lms-license v1 테스트 벡터 (docs/license-format-v1.md). 테스트 전용 키 — 제품에 넣지 말 것.",
        "test_key": {
            "key_id": KEY_ID,
            "seed_hex": TEST_SEED.hex(),
            "public_key_hex": key.verify_key.encode().hex(),
        },
        "pc_id_cases": pcs,
        "license_cases": cases,
    }
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stdout.write(json.dumps(out, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()

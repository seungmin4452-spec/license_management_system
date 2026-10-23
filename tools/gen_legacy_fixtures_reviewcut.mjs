#!/usr/bin/env node
// ReviewCut 이전 형식(reviewcut-legacy) 고정 예제 파일 생성기.
// ReviewCut 저장소의 실제 서명·검증 코드(../cut_review/src/main/license/core.ts)를 그대로 써서
// 테스트 전용 키로 예제 파일을 만들고, 같은 코드의 verifyLicense로 통과하는지 확인한다.
//
// 실행(Node 22.6+ 타입 제거 기능 필요, Node 24는 기본):
//   node tools/gen_legacy_fixtures_reviewcut.mjs > docs/legacy-fixtures/reviewcut-legacy.json
// Ed25519(RFC 8032) 서명은 결정적이므로 다시 실행해도 같은 파일이 나온다.
//
// 관리 프로그램이 만든 파일을 앱 코드로 검사하려면:
//   node tools/gen_legacy_fixtures_reviewcut.mjs --verify <license.json> --install-id VRN-... --public-key-hex <hex> --key-id <id>
import { createHash, createPrivateKey, createPublicKey } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const corePath = resolve(here, '../../cut_review/src/main/license/core.ts');
const core = await import(pathToFileURL(corePath).href);

const KEY_ID = 'test-legacy';
const SEED = createHash('sha256').update('lms legacy TEST KEY - never use in a product').digest();
const PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

function privateKeyFromSeed(seed) {
  return createPrivateKey({ key: Buffer.concat([PKCS8_PREFIX, seed]), format: 'der', type: 'pkcs8' });
}

function publicPemFromHex(hex) {
  const der = Buffer.concat([SPKI_PREFIX, Buffer.from(hex, 'hex')]);
  return createPublicKey({ key: der, format: 'der', type: 'spki' }).export({ type: 'spki', format: 'pem' }).toString();
}

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

if (arg('verify')) {
  const text = readFileSync(resolve(arg('verify')), 'utf8');
  const result = core.verifyLicense(JSON.parse(text), {
    publicKeys: [{ keyId: arg('key-id') ?? KEY_ID, pem: publicPemFromHex(arg('public-key-hex')) }],
    installId: arg('install-id'),
  });
  console.log(JSON.stringify(result));
  process.exit(result.ok ? 0 : 1);
}

const privateKey = privateKeyFromSeed(SEED);
const privatePem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const publicKey = createPublicKey(privateKey);
const publicPem = publicKey.export({ type: 'spki', format: 'pem' }).toString();
const publicHex = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('hex');

function payload(over) {
  const p = {
    schema: core.LICENSE_SCHEMA,
    productId: core.PRODUCT_ID,
    productMajor: core.PRODUCT_MAJOR,
    licenseId: '0b7f3a52-5d0e-4c1a-9a8e-3f6b2d1c4e5a',
    installId: 'VRN-7KQ2-M9XA-3PDF',
    edition: 'full',
    licensee: 'OO스튜디오',
    issuedAt: '2026-10-23T05:00:00.000Z',
  };
  for (const [k, v] of Object.entries(over)) {
    if (v === undefined) delete p[k];
    else p[k] = v;
  }
  return p;
}

const cases = [];
function addCase(name, p) {
  const file = core.signLicense(p, privatePem, KEY_ID);
  const fileText = JSON.stringify(file, null, 2) + '\n'; // issue.ts와 같은 저장 형식
  const check = core.verifyLicense(JSON.parse(fileText), {
    publicKeys: [{ keyId: KEY_ID, pem: publicPem }],
    installId: p.installId,
  });
  if (!check.ok) throw new Error(`앱 검증 실패: ${name} ${check.reason}`);
  cases.push({
    name,
    file_text: fileText,
    message_utf8: core.canonicalJson(p),
    install_id: p.installId,
    app_verify: 'ok',
  });
}

addCase('표시명 있음', payload({}));
addCase('표시명 없음(필드 생략)', payload({ licensee: undefined }));
addCase('특수 문자 표시명', payload({
  licenseId: '9c2e4f61-7a3b-4d8c-b1e2-5f6a7b8c9d0e',
  licensee: '한글 "따옴표" \\ 역슬래시 / 슬래시 ☕ 😀 A\tB',
  issuedAt: '2026-10-23T05:00:00.123Z',
}));

const out = {
  description:
    'ReviewCut 이전 형식(reviewcut-legacy) 고정 예제. ReviewCut core.ts의 signLicense로 만들고 verifyLicense로 확인했다. 테스트 전용 키 — 제품에 넣지 말 것.',
  generator: 'tools/gen_legacy_fixtures_reviewcut.mjs',
  test_key: { key_id: KEY_ID, seed_hex: SEED.toString('hex'), public_key_hex: publicHex },
  cases,
};
process.stdout.write(JSON.stringify(out, null, 2) + '\n');

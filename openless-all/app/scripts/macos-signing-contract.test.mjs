import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// 这个脚本只在 macOS 上有意义：其余平台只做静态合同检查。
const appRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));
const scriptPath = join(appRoot, 'scripts', 'build-mac-signed.sh');
const examplePath = join(appRoot, 'scripts', 'macos-signing.env.example');

const script = readFileSync(scriptPath, 'utf8');
const example = readFileSync(examplePath, 'utf8');
const gitignore = readFileSync(join(appRoot, '.gitignore'), 'utf8');

// ── 静态合同 ────────────────────────────────────────────────────
assert.match(script, /^#!\/usr\/bin\/env bash/);
assert.match(script, /set -euo pipefail/);
// 必须复用 build-mac.sh，不能自己拼 tauri build / codesign 流程
assert.match(script, /scripts\/build-mac\.sh/);
assert.doesNotMatch(script, /tauri build/);
assert.doesNotMatch(script, /codesign --force/);
// 只接受 Developer ID Application，且显式拒绝 ad-hoc
assert.match(script, /Developer ID Application/);
assert.match(script, /APPLE_SIGNING_IDENTITY" = "-"/);
// Team ID 与证书（钥匙串与 p12 两处）都必须交叉校验，否则公证会 401
assert.match(script, /CERT_TEAM/);
assert.match(script, /P12_TEAM/);
assert.ok(
  script.includes('[A-Z0-9]\\{10\\}'),
  'Team ID must be parsed out of the certificate name',
);
assert.ok(script.includes('grep -F'), 'identity lookup must match the certificate name literally');
assert.match(script, /Team ID 不匹配/);
// 未替换的 <...> 占位符必须被当成未填写
assert.match(script, /MISSING/);
// 凭据文件不能被 git 跟踪
assert.match(script, /ls-files --error-unmatch/);

const permissions = statSync(scriptPath).mode & 0o111;
assert.notEqual(permissions, 0, 'build-mac-signed.sh must be executable');

// ── 配置文件合同 ────────────────────────────────────────────────
// 模板里不能出现真实凭据，只能是 <...> 占位符
for (const key of ['APPLE_ID', 'APPLE_PASSWORD', 'APPLE_TEAM_ID']) {
  const line = example.split('\n').find((entry) => entry.startsWith(`${key}=`));
  assert.ok(line, `${key} must be present in the template`);
  assert.match(line, /"<[^"]+>"/, `${key} must stay a placeholder, never a real credential`);
}
const identityLine = example.split('\n').find((entry) => entry.startsWith('APPLE_SIGNING_IDENTITY='));
assert.match(identityLine, /<Your Name> \(<TEAMID>\)/);
// 真正的风险在赋值行：注释里的 ABCDE12345 只是示意，赋值行绝不能出现真实 Team ID 形状的值
const exampleAssignments = example
  .split('\n')
  .filter((entry) => entry.trim() !== '' && !entry.startsWith('#'))
  .join('\n');
assert.doesNotMatch(exampleAssignments, /[A-Z0-9]{10}\)/);

// 真实凭据文件必须被忽略
assert.match(gitignore, /^scripts\/macos-signing\.env$/m);

// ── 功能合同（仅 macOS）─────────────────────────────────────────
if (process.platform !== 'darwin') {
  console.log('macOS signing script contract tests passed (functional checks skipped)');
  process.exit(0);
}

const root = mkdtempSync(join(tmpdir(), 'openless-signing-test-'));

function run(args) {
  return spawnSync('bash', [scriptPath, ...args], {
    cwd: appRoot,
    encoding: 'utf8',
    // 清掉外部环境变量，避免宿主机上的凭据影响断言
    env: { PATH: process.env.PATH, HOME: process.env.HOME },
  });
}

function writeEnv(name, lines) {
  const path = join(root, `${name}.env`);
  writeFileSync(path, `${lines.join('\n')}\n`, { mode: 0o600 });
  return path;
}

// 用自签名证书伪造一张 Developer ID p12，这样 CI Secrets 的校验路径可测。
const P12_PASSWORD = 'test-pass';
const TEAM_ID = 'ZZZZZZZZZZ';

function makeP12({ name, subject, withKey = true }) {
  const keyPath = join(root, `${name}.key.pem`);
  const certPath = join(root, `${name}.cert.pem`);
  const p12Path = join(root, `${name}.p12`);
  const args = [
    'req',
    '-x509',
    '-newkey',
    'rsa:2048',
    '-nodes',
    '-keyout',
    keyPath,
    '-out',
    certPath,
    '-days',
    '1',
    '-subj',
    subject,
  ];
  execFileSync('openssl', args, { stdio: 'pipe' });

  const exportArgs = [
    'pkcs12',
    '-export',
    '-in',
    certPath,
    '-out',
    p12Path,
    '-passout',
    `pass:${P12_PASSWORD}`,
  ];
  if (withKey) {
    exportArgs.push('-inkey', keyPath);
  } else {
    exportArgs.push('-nokeys');
  }
  execFileSync('openssl', exportArgs, { stdio: 'pipe' });
  return p12Path;
}

const developerIdP12 = makeP12({
  name: 'developer-id',
  subject: `/CN=Developer ID Application: Test Signer (${TEAM_ID})/OU=${TEAM_ID}/O=Test Co`,
});
const certOnlyP12 = makeP12({
  name: 'cert-only',
  subject: `/CN=Developer ID Application: Test Signer (${TEAM_ID})/OU=${TEAM_ID}/O=Test Co`,
  withKey: false,
});
const wrongTypeP12 = makeP12({
  name: 'wrong-type',
  subject: `/CN=Apple Development: Test Signer (${TEAM_ID})/OU=${TEAM_ID}/O=Test Co`,
});

const baseCreds = [
  'APPLE_SIGNING_IDENTITY="Developer ID Application: Nobody (ZZZZZZZZZZ)"',
  'APPLE_ID="nobody@example.com"',
  'APPLE_PASSWORD="abcd-efgh-ijkl-mnop"',
  'APPLE_TEAM_ID="ZZZZZZZZZZ"',
];

try {
  // ── 参数与帮助 ──
  const help = run(['--help']);
  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /--print-ci-secrets/);
  assert.match(help.stdout, /--check/);

  const unknown = run(['--nope']);
  assert.equal(unknown.status, 2);

  // ── 凭据校验 ──
  const placeholder = run(['--check', '--env-file', examplePath]);
  assert.notEqual(placeholder.status, 0);
  assert.match(placeholder.stderr, /占位符|缺失/);

  const adhoc = writeEnv('adhoc', [
    'APPLE_SIGNING_IDENTITY="-"',
    'APPLE_ID="a@b.com"',
    'APPLE_PASSWORD="abcd-efgh-ijkl-mnop"',
    'APPLE_TEAM_ID="ZZZZZZZZZZ"',
  ]);
  const adhocResult = run(['--check', '--env-file', adhoc]);
  assert.notEqual(adhocResult.status, 0);
  assert.match(adhocResult.stderr, /ad-hoc/);

  const development = writeEnv('development', [
    'APPLE_SIGNING_IDENTITY="Apple Development: Someone (ZZZZZZZZZZ)"',
    'APPLE_ID="a@b.com"',
    'APPLE_PASSWORD="abcd-efgh-ijkl-mnop"',
    'APPLE_TEAM_ID="ZZZZZZZZZZ"',
  ]);
  const developmentResult = run(['--check', '--env-file', development]);
  assert.notEqual(developmentResult.status, 0);
  assert.match(developmentResult.stderr, /Developer ID Application/);

  const emailPassword = writeEnv('email-password', [
    baseCreds[0],
    'APPLE_ID="a@b.com"',
    'APPLE_PASSWORD="a@b.com"',
    'APPLE_TEAM_ID="ZZZZZZZZZZ"',
  ]);
  const emailPasswordResult = run(['--check', '--env-file', emailPassword]);
  assert.notEqual(emailPasswordResult.status, 0);
  assert.match(emailPasswordResult.stderr, /App 专用密码/);

  // 证书不在钥匙串里 → 列出可用身份后失败
  const missingCert = run(['--check', '--env-file', writeEnv('valid', baseCreds)]);
  assert.notEqual(missingCert.status, 0);
  assert.match(missingCert.stderr, /钥匙串里找不到该证书/);

  // ── CI Secrets ──
  const noP12 = run(['--print-ci-secrets', '--env-file', writeEnv('no-p12', baseCreds)]);
  assert.notEqual(noP12.status, 0);
  assert.match(noP12.stderr, /\.p12/);

  // 有效 p12 → 输出可用的 base64（与文件字节一致）
  const goodEnv = writeEnv('ci-good', [
    ...baseCreds,
    `APPLE_P12_PATH="${developerIdP12}"`,
    `APPLE_CERTIFICATE_PASSWORD="${P12_PASSWORD}"`,
  ]);
  const good = run(['--print-ci-secrets', '--env-file', goodEnv]);
  assert.equal(good.status, 0, good.stderr);
  const certificateLine = good.stdout.split('\n').find((line) => line.startsWith('APPLE_CERTIFICATE='));
  assert.ok(certificateLine, 'APPLE_CERTIFICATE must be printed');
  const certificateBase64 = certificateLine.slice('APPLE_CERTIFICATE='.length);
  assert.deepEqual(
    Buffer.from(certificateBase64, 'base64'),
    readFileSync(developerIdP12),
    'printed base64 must decode back to the p12 bytes',
  );
  assert.match(good.stdout, /APPLE_TEAM_ID=ZZZZZZZZZZ/);

  // Team ID 与 p12 不一致 → 拒绝，避免 CI 到公证阶段才 401
  const wrongTeamEnv = writeEnv('ci-wrong-team', [
    'APPLE_SIGNING_IDENTITY="Developer ID Application: Nobody (WRONGTEAM1)"',
    'APPLE_ID="nobody@example.com"',
    'APPLE_PASSWORD="abcd-efgh-ijkl-mnop"',
    'APPLE_TEAM_ID="WRONGTEAM1"',
    `APPLE_P12_PATH="${developerIdP12}"`,
    `APPLE_CERTIFICATE_PASSWORD="${P12_PASSWORD}"`,
  ]);
  const wrongTeam = run(['--print-ci-secrets', '--env-file', wrongTeamEnv]);
  assert.notEqual(wrongTeam.status, 0);
  assert.match(wrongTeam.stderr, /ZZZZZZZZZZ/);
  assert.match(wrongTeam.stderr, /401/);

  // p12 密码错误 → 明确指出，而不是笼统失败
  const wrongPasswordEnv = writeEnv('ci-wrong-password', [
    ...baseCreds,
    `APPLE_P12_PATH="${developerIdP12}"`,
    'APPLE_CERTIFICATE_PASSWORD="not-the-password"',
  ]);
  const wrongPassword = run(['--print-ci-secrets', '--env-file', wrongPasswordEnv]);
  assert.notEqual(wrongPassword.status, 0);
  assert.match(wrongPassword.stderr, /无法解析 \.p12/);

  // 只有证书没有私钥 → 拒绝
  const certOnlyEnv = writeEnv('ci-cert-only', [
    ...baseCreds,
    `APPLE_P12_PATH="${certOnlyP12}"`,
    `APPLE_CERTIFICATE_PASSWORD="${P12_PASSWORD}"`,
  ]);
  const certOnly = run(['--print-ci-secrets', '--env-file', certOnlyEnv]);
  assert.notEqual(certOnly.status, 0);
  assert.match(certOnly.stderr, /没有私钥/);

  // 证书类型不对 → 拒绝
  const wrongTypeEnv = writeEnv('ci-wrong-type', [
    ...baseCreds,
    `APPLE_P12_PATH="${wrongTypeP12}"`,
    `APPLE_CERTIFICATE_PASSWORD="${P12_PASSWORD}"`,
  ]);
  const wrongType = run(['--print-ci-secrets', '--env-file', wrongTypeEnv]);
  assert.notEqual(wrongType.status, 0);
  assert.match(wrongType.stderr, /不是 Developer ID Application/);

  // 生成 CI Secrets 不应要求本机钥匙串里有该证书
  assert.doesNotMatch(good.stderr, /钥匙串/);

  // 配置文件必须能承载 INSTALL 开关
  assert.match(example, /^INSTALL=/m);
} finally {
  rmSync(root, { recursive: true, force: true });
}

console.log('macOS signing script contract tests passed');

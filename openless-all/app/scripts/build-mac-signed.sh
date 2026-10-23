#!/usr/bin/env bash
# 本地 macOS Developer ID 签名 + 公证构建入口。
#
# 先用配置模板填好凭据，再跑本脚本：
#   cp scripts/macos-signing.env.example scripts/macos-signing.env
#   $EDITOR scripts/macos-signing.env
#   ./scripts/build-mac-signed.sh --check              # 只做配置自检
#   ./scripts/build-mac-signed.sh                      # 构建 + 签名 + 公证
#   ./scripts/build-mac-signed.sh --install            # 构建并装到 /Applications
#   ./scripts/build-mac-signed.sh --print-ci-secrets   # 打印 GitHub Secrets 需要的值
#   ./scripts/build-mac-signed.sh --push-secrets       # 用 gh 写入仓库 Secrets
#
# 凭据也可以不落盘，直接走环境变量（此时无需 env 文件）：
#   APPLE_SIGNING_IDENTITY=... APPLE_ID=... APPLE_PASSWORD=... APPLE_TEAM_ID=... \
#     ./scripts/build-mac-signed.sh
#
# 任何一项校验不通过就退出，不会产出未签名的包。
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_ROOT"

DEFAULT_ENV_FILE="$APP_ROOT/scripts/macos-signing.env"
ENV_FILE="${OPENLESS_MACOS_SIGN_ENV:-$DEFAULT_ENV_FILE}"

MODE="build"
INSTALL_OVERRIDE=""
P12_PATH=""
PUSH_YES=0

usage() {
  cat << 'EOF'
用法：build-mac-signed.sh [选项]

  默认            构建 + Developer ID 签名 + 公证（INSTALL 由配置决定，模板为 0）
  --check         只校验配置（证书、Team ID、专用密码格式），不构建
  --install       构建后装到 /Applications（会替换旧应用并重置 TCC 授权）
  --no-install    只构建，不安装
  --print-ci-secrets
                  打印 GitHub Actions 需要的 Secrets（含 .p12 的 base64）
  --push-secrets  用 gh CLI 直接写入仓库 Secrets（需 admin 权限）
  --env-file PATH 指定配置文件（默认 scripts/macos-signing.env）
  --p12 PATH      指定导出好的 .p12（默认取配置里的 APPLE_P12_PATH）
  --yes           跳过确认提示（配合 --push-secrets）
  -h, --help      显示本帮助

配置文件写法见 scripts/macos-signing.env.example；文档见 docs/macos-signing.md。
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --print-ci-secrets) MODE="print-ci-secrets" ;;
    --push-secrets) MODE="push-secrets" ;;
    --install) INSTALL_OVERRIDE="1" ;;
    --no-install) INSTALL_OVERRIDE="0" ;;
    --env-file)
      [ $# -ge 2 ] || { echo "✗ --env-file 需要一个参数" >&2; exit 2; }
      ENV_FILE="$2"
      shift
      ;;
    --p12)
      [ $# -ge 2 ] || { echo "✗ --p12 需要一个参数" >&2; exit 2; }
      P12_PATH="$2"
      shift
      ;;
    --yes) PUSH_YES=1 ;;
    -h | --help) usage 0 ;;
    *)
      echo "✗ 未知参数：$1" >&2
      usage 2
      ;;
  esac
  shift
done

die() {
  echo "✗ $*" >&2
  exit 1
}

warn() {
  echo "⚠ $*" >&2
}

# ── 载入配置 ────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  # 真正的凭据只放在默认的 macos-signing.env。模板和测试用的 --env-file
  # 可以入库或保持 644，不能在自检时被改权限或当成泄密文件拒绝。
  if [ "$ENV_FILE" = "$DEFAULT_ENV_FILE" ]; then
    PERMS="$(stat -f '%Lp' "$ENV_FILE" 2> /dev/null || echo '')"
    if [ "$PERMS" != "600" ]; then
      warn "$ENV_FILE 权限是 ${PERMS:-未知}，正在收窄为 600（内含签名与公证凭据）"
      chmod 600 "$ENV_FILE" || warn "chmod 600 失败，请手动处理"
    fi
    if git -C "$APP_ROOT" ls-files --error-unmatch "$ENV_FILE" > /dev/null 2>&1; then
      die "$ENV_FILE 已被 git 跟踪；先执行 git rm --cached '$ENV_FILE'，并确认 .gitignore 忽略了它"
    fi
  fi
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
  echo "▶ 配置来源：$ENV_FILE"
else
  if [ "$ENV_FILE" != "$DEFAULT_ENV_FILE" ]; then
    die "找不到配置来源：$ENV_FILE"
  fi
  echo "▶ 未找到 ${DEFAULT_ENV_FILE}，改用当前环境变量"
fi

# 命令行开关优先于配置文件里的 INSTALL
if [ -n "$INSTALL_OVERRIDE" ]; then
  INSTALL="$INSTALL_OVERRIDE"
fi
INSTALL="${INSTALL:-1}"
export INSTALL

# ── 校验：必需变量 ──────────────────────────────────────────────
REQUIRED_VARS=(APPLE_SIGNING_IDENTITY APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID)
MISSING=()
for name in "${REQUIRED_VARS[@]}"; do
  value="${!name:-}"
  # 未替换的占位符（<...>）视为未填写
  case "$value" in
    "" | *"<"*">"*) MISSING+=("$name") ;;
  esac
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  die "以下配置缺失或仍是模板占位符：${MISSING[*]}（检查 ${ENV_FILE}）"
fi

# 名字带引号或不带引号都接受，统一去掉首尾引号
APPLE_SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY#\"}"
APPLE_SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY%\"}"

echo "▶ 签名身份：$APPLE_SIGNING_IDENTITY"
echo "▶ Team ID：$APPLE_TEAM_ID"

# ── 校验：App 专用密码（廉价检查放前面）──────────────────────────
if [ "$APPLE_PASSWORD" = "$APPLE_ID" ]; then
  die "APPLE_PASSWORD 不能是 Apple ID 本身，必须是 App 专用密码（xxxx-xxxx-xxxx-xxxx）"
fi
if ! printf '%s' "$APPLE_PASSWORD" | grep -Eq '^[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}-[a-zA-Z0-9]{4}$'; then
  if printf '%s' "$APPLE_PASSWORD" | grep -q '@'; then
    die "APPLE_PASSWORD 看起来是邮箱，不是 App 专用密码。生成入口：https://appleid.apple.com → 登录与安全 → App 专用密码"
  fi
  warn "APPLE_PASSWORD 不是常见的 xxxx-xxxx-xxxx-xxxx 形式；若公证报 401 请重新生成 App 专用密码"
fi

# ── 校验：签名身份形态（廉价检查，先做）────────────────────────
if [ "$APPLE_SIGNING_IDENTITY" = "-" ]; then
  die "APPLE_SIGNING_IDENTITY 是 ad-hoc（\"-\"）；正式分发必须用 Developer ID 证书，见 docs/macos-signing.md"
fi

case "$APPLE_SIGNING_IDENTITY" in
  "Developer ID Application"*) ;;
  *) die "签名身份必须是 Developer ID Application 证书（当前：${APPLE_SIGNING_IDENTITY}）。Apple Development / Apple Distribution 不能用于站外分发" ;;
esac

# ── 校验：签名身份在钥匙串里 ────────────────────────────────────
# 只有构建与自检才需要钥匙串；生成 CI Secrets 时只依赖 .p12 文件本身。
check_keychain() {
  IDENTITIES="$(security find-identity -v -p codesigning 2> /dev/null || true)"
  MATCHED="$(printf '%s\n' "$IDENTITIES" | grep -F "\"$APPLE_SIGNING_IDENTITY\"" | head -n 1 || true)"
  if [ -z "$MATCHED" ]; then
    echo "── 钥匙串中的签名身份 ──" >&2
    printf '%s\n' "$IDENTITIES" >&2
    die "钥匙串里找不到该证书：${APPLE_SIGNING_IDENTITY}（证书必须与私钥配对，且安装在当前用户的钥匙串里）"
  fi

  CERT_TEAM="$(printf '%s\n' "$MATCHED" | sed -n 's/.*(\([A-Z0-9]\{10\}\))".*/\1/p')"
  if [ -n "$CERT_TEAM" ] && [ "$CERT_TEAM" != "$APPLE_TEAM_ID" ]; then
    die "Team ID 不匹配：证书属于 ${CERT_TEAM}，但 APPLE_TEAM_ID=${APPLE_TEAM_ID}。公证会返回 401，请改成证书所属团队的 ID"
  fi
  echo "✓ 证书已就绪（Team ID ${CERT_TEAM:-未知}）"
}

# ── 校验：p12（生成 CI Secrets，或自检时已配置才需要）────────────
P12_PATH="${P12_PATH:-${APPLE_P12_PATH:-}}"

# macOS 导出的 p12 可能是旧式 RC2/3DES 加密，openssl 3 需要 -legacy 才能读
P12_LEGACY=()

p12_cmd() {
  if [ "${#P12_LEGACY[@]}" -gt 0 ]; then
    openssl pkcs12 -legacy "$@" -passin "pass:$APPLE_CERTIFICATE_PASSWORD"
  else
    openssl pkcs12 "$@" -passin "pass:$APPLE_CERTIFICATE_PASSWORD"
  fi
}

check_p12() {
  [ -n "$P12_PATH" ] || die "缺少 .p12 路径：在配置里填 APPLE_P12_PATH，或用 --p12 <path> 指定"
  [ -f "$P12_PATH" ] || die "找不到 .p12 文件：$P12_PATH"
  [ -n "${APPLE_CERTIFICATE_PASSWORD:-}" ] || die "缺少 APPLE_CERTIFICATE_PASSWORD（导出 .p12 时设置的密码）"

  P12_LEGACY=()
  P12_LEGACY_SUPPORTED=0
  if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
    P12_LEGACY_SUPPORTED=1
  fi

  if openssl pkcs12 -info -noout -in "$P12_PATH" -passin "pass:$APPLE_CERTIFICATE_PASSWORD" > /dev/null 2>&1; then
    :
  elif [ "$P12_LEGACY_SUPPORTED" = "1" ] &&
    openssl pkcs12 -info -noout -legacy -in "$P12_PATH" -passin "pass:$APPLE_CERTIFICATE_PASSWORD" > /dev/null 2>&1; then
    P12_LEGACY=(-legacy)
    echo "  （该 .p12 使用 legacy 加密，已用 openssl -legacy 读取）"
  else
    P12_ERR="$(openssl pkcs12 -info -noout -in "$P12_PATH" -passin "pass:$APPLE_CERTIFICATE_PASSWORD" 2>&1 | tail -n 2 || true)"
    die "无法解析 .p12：密码错误或文件损坏（${P12_ERR}）。密码是导出时设置的那个，不是 Apple ID 密码"
  fi

  if ! p12_cmd -in "$P12_PATH" -nodes -nocerts | grep -q 'BEGIN PRIVATE KEY'; then
    die "$P12_PATH 里没有私钥。必须从「钥匙串访问 → 我的证书」导出——只在门户重新下载 .cer 补不出私钥"
  fi

  P12_SUBJECT="$(p12_cmd -in "$P12_PATH" -nodes -nokeys 2> /dev/null | openssl x509 -noout -subject 2> /dev/null || true)"
  if ! printf '%s' "$P12_SUBJECT" | grep -q 'Developer ID Application'; then
    die "$P12_PATH 里的证书不是 Developer ID Application（subject：${P12_SUBJECT:-读取失败}）"
  fi

  P12_TEAM="$(printf '%s\n' "$P12_SUBJECT" | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')"
  if [ -n "$P12_TEAM" ] && [ "$P12_TEAM" != "$APPLE_TEAM_ID" ]; then
    die ".p12 的证书属于团队 ${P12_TEAM}，但 APPLE_TEAM_ID=${APPLE_TEAM_ID}；CI 公证会返回 401"
  fi
  echo "✓ .p12 含私钥、密码可解、证书为 Developer ID Application（Team ID ${P12_TEAM:-未知}）"
}

print_ci_secrets() {
  check_p12
  CERT_B64="$(base64 -i "$P12_PATH" | tr -d '\n')"
  echo
  echo "── GitHub Secrets（仓库 Settings → Secrets and variables → Actions）──"
  echo "APPLE_CERTIFICATE=$CERT_B64"
  echo "APPLE_CERTIFICATE_PASSWORD=$APPLE_CERTIFICATE_PASSWORD"
  echo "APPLE_ID=$APPLE_ID"
  echo "APPLE_PASSWORD=$APPLE_PASSWORD"
  echo "APPLE_TEAM_ID=$APPLE_TEAM_ID"
  if [ -n "${APPLE_PROVIDER_SHORT_NAME:-}" ]; then
    echo "APPLE_PROVIDER_SHORT_NAME=$APPLE_PROVIDER_SHORT_NAME"
  fi
  if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
    echo "KEYCHAIN_PASSWORD=$KEYCHAIN_PASSWORD"
  fi
  echo
  echo "  可选的两个可留空：APPLE_PROVIDER_SHORT_NAME、KEYCHAIN_PASSWORD"
  if command -v pbcopy > /dev/null 2>&1; then
    printf '%s' "$CERT_B64" | pbcopy
    echo "  APPLE_CERTIFICATE 的 base64 已复制到剪贴板。"
  fi
  echo "  逐个粘贴嫌麻烦就跑：$0 --push-secrets"
}

push_ci_secrets() {
  check_p12
  command -v gh > /dev/null 2>&1 || die "未安装 gh CLI：brew install gh"
  gh auth status > /dev/null 2>&1 || die "gh 未登录：gh auth login"

  REMOTE="$(git -C "$APP_ROOT" remote get-url origin 2> /dev/null || true)"
  REPO="$(printf '%s\n' "$REMOTE" | sed -n 's#.*github\.com[:/]\(.*\)\.git$#\1#p;s#.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p' | head -n 1)"
  REPO="${OPENLESS_GITHUB_REPO:-${REPO:-Open-Less/openless}}"

  CERT_B64="$(base64 -i "$P12_PATH" | tr -d '\n')"
  echo "▶ 将写入 $REPO 的 Secrets："
  echo "    APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID"
  if [ "$PUSH_YES" != "1" ]; then
    printf '  确认继续？[y/N] '
    read -r reply
    case "$reply" in
      y | Y | yes | YES) ;;
      *)
        echo "已取消"
        return 0
        ;;
    esac
  fi

  gh secret set APPLE_CERTIFICATE --repo "$REPO" --body "$CERT_B64"
  gh secret set APPLE_CERTIFICATE_PASSWORD --repo "$REPO" --body "$APPLE_CERTIFICATE_PASSWORD"
  gh secret set APPLE_ID --repo "$REPO" --body "$APPLE_ID"
  gh secret set APPLE_PASSWORD --repo "$REPO" --body "$APPLE_PASSWORD"
  gh secret set APPLE_TEAM_ID --repo "$REPO" --body "$APPLE_TEAM_ID"
  if [ -n "${APPLE_PROVIDER_SHORT_NAME:-}" ]; then
    gh secret set APPLE_PROVIDER_SHORT_NAME --repo "$REPO" --body "$APPLE_PROVIDER_SHORT_NAME"
  fi
  if [ -n "${KEYCHAIN_PASSWORD:-}" ]; then
    gh secret set KEYCHAIN_PASSWORD --repo "$REPO" --body "$KEYCHAIN_PASSWORD"
  fi
  echo "✓ Secrets 已写入 ${REPO}；下一步打 v*-tauri tag 触发签名发布（见 docs/macos-signing.md）"
}

# ── 分发 ────────────────────────────────────────────────────────
if [ "$MODE" = "check" ]; then
  check_keychain
  if [ -f "$P12_PATH" ]; then
    check_p12
  else
    echo "▶ 未配置可用的 .p12（${P12_PATH:-未设置}），跳过 CI Secrets 校验"
  fi
  echo "✓ 配置自检通过（未构建）。"
  if [ "$INSTALL" = "1" ]; then
    echo "  下一步：$0（会替换 /Applications/OpenLess.app）"
  else
    echo "  下一步：$0 --install（装到 /Applications）或 $0（只构建）"
  fi
  exit 0
fi

if [ "$MODE" = "print-ci-secrets" ]; then
  print_ci_secrets
  exit 0
fi

if [ "$MODE" = "push-secrets" ]; then
  push_ci_secrets
  exit 0
fi

# ── 构建 + 签名 + 公证 ───────────────────────────────────────────
check_keychain

echo "▶ 交给 scripts/build-mac.sh（INSTALL=${INSTALL}）"
if [ "$INSTALL" = "1" ]; then
  echo "  注意：会替换 /Applications/OpenLess.app 并重置 Accessibility / Microphone 授权"
else
  echo "  只构建不安装；产物在 src-tauri/target/release/bundle/"
fi

PASSTHROUGH=(
  "APPLE_SIGNING_IDENTITY=$APPLE_SIGNING_IDENTITY"
  "APPLE_ID=$APPLE_ID"
  "APPLE_PASSWORD=$APPLE_PASSWORD"
  "APPLE_TEAM_ID=$APPLE_TEAM_ID"
  "INSTALL=$INSTALL"
)
if [ -n "${APPLE_PROVIDER_SHORT_NAME:-}" ]; then
  PASSTHROUGH+=("APPLE_PROVIDER_SHORT_NAME=$APPLE_PROVIDER_SHORT_NAME")
fi
if [ -n "${APPLE_API_KEY:-}" ]; then
  PASSTHROUGH+=("APPLE_API_KEY=$APPLE_API_KEY")
fi
if [ -n "${APPLE_API_ISSUER:-}" ]; then
  PASSTHROUGH+=("APPLE_API_ISSUER=$APPLE_API_ISSUER")
fi

exec env "${PASSTHROUGH[@]}" bash "$APP_ROOT/scripts/build-mac.sh"

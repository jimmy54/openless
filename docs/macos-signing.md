# macOS 签名与公证（Developer ID）

状态：canonical（以 `openless-all/app/scripts/build-mac.sh` 与 `.github/workflows/release-tauri.yml` 的实际行为核对）；更新：2026-09-11。
本文只讲 macOS 分发签名。Android 签名见 [android-apk.yml](../.github/workflows/android-apk.yml)，Linux 的 minisign 见 [release-linux-egui.yml](../.github/workflows/release-linux-egui.yml)。

## 1. 为什么需要

macOS 上从浏览器下载的 `.dmg` 会被打上 `com.apple.quarantine`。要让用户双击即开、不用手工清属性：

| 做法 | 效果 |
| --- | --- |
| `xattr -cr /Applications/OpenLess.app` | 只在本机一次性绕过，每个下载者都要自己做 |
| ad-hoc 签名（`APPLE_SIGNING_IDENTITY="-"`） | 本机构建可运行，分发后 Gatekeeper 仍报「已损坏」 |
| 只公证 `.app`、不公证 `.dmg` | 拖出的应用可用，但**双击下载来的 DMG 仍被拦**（DMG 是 `Unnotarized Developer ID`） |
| **Developer ID 签名 + `.app` 与 `.dmg` 都公证** | 下载即开，这才是正式方案 |

只清 `xattr` 或只做 ad-hoc 签名都不解决问题：quarantine 由下载方浏览器重新附加，ad-hoc 签名没有 Apple 信任链。

**两个对象都要公证**。Tauri 只会公证 `.app`（`Notarizing` / `Stapling app`），DMG 是之后才打出来的，从未提交公证。`build-mac.sh` 因此在打完 DMG 后补做一次 `notarytool submit` + `stapler staple`；少了这步，`spctl -a -t open --context context:primary-signature`（用户双击磁盘映像时 Gatekeeper 实际执行的检查）会返回 `rejected / source=Unnotarized Developer ID`。

## 2. 涉及的环境变量

| 变量 | 用途 | 必需 | 说明 |
| --- | --- | --- | --- |
| `APPLE_CERTIFICATE` | 证书 `.p12` 的 base64 | 是 | 签名身份来源 |
| `APPLE_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设的密码 | 是 | 不是 Apple ID 密码 |
| `APPLE_SIGNING_IDENTITY` | 钥匙串中的证书全名 | 本地构建需要 | CI 里由 `security import` 后自动推导并写入 `GITHUB_ENV` |
| `APPLE_ID` | Apple ID 邮箱 | 是 | 必须是证书所属团队的成员 |
| `APPLE_PASSWORD` | **App 专用密码** | 是 | 不是登录密码，见第 5 节 |
| `APPLE_TEAM_ID` | 10 位 Team ID | 是 | 必须与证书所属团队一致 |
| `APPLE_PROVIDER_SHORT_NAME` | 多团队时的 provider | 否 | 单团队不需要 |
| `KEYCHAIN_PASSWORD` | CI 临时钥匙串密码 | 否 | 默认随机生成 |
| `APPLE_API_KEY` / `APPLE_API_ISSUER` | App Store Connect API Key | 否 | `build-mac.sh` 支持，可替代 `APPLE_ID` 三件套；当前 release workflow 未使用 |
| `APPLE_API_KEY_ID` | API Key 的 Key ID | 否 | 仅在使用 `APPLE_API_KEY` 且密钥文件名不是 `AuthKey_<KEYID>.p8` 时需要 |

注意：`TAURI_SIGNING_PRIVATE_KEY` 是**自动更新**（updater）签名，与 Gatekeeper 无关，不能替代上面任何一项。

## 3. 前提

- 付费 **Apple Developer Program** 会员（个人 688 元/年；免费账号后台没有 Developer ID 证书类型）。
- 账号角色为 **Account Holder / Admin / App Manager** 之一，才能签发 Developer ID 证书。
- [developer.apple.com/account](https://developer.apple.com/account) → **Membership** 页面确认状态 Active 并记下 Team ID。

## 4. 生成 Developer ID Application 证书

证书类型必须是 **Developer ID Application**。不要用 Apple Development（仅本机调试）或 Apple Distribution（仅 App Store）。

用下面这条命令自查当前有哪些可用身份；没有 `Developer ID Application` 一行就说明还没生成或私钥未配对：

```bash
security find-identity -v -p codesigning
```

### 方式 A：Xcode 一键生成

1. Xcode → Settings → Accounts → `+` 登录 Apple ID。
2. 选中该 Team → **Manage Certificates** → 左下 `+` → **Developer ID Application**。
3. 证书与私钥自动进入「登录」钥匙串，跳到第 5 节。

### 方式 B：门户签发 + CSR

1. 钥匙串访问 → 菜单「钥匙串访问」→ 证书助理 → **从证书颁发机构请求证书…**：
   - 用户电子邮件地址：Apple ID
   - 常用名称：例如 `OpenLess Developer ID`
   - CA 电子邮件地址：留空
   - 选择「存储到磁盘」，得到 `.certSigningRequest`
2. 或直接用命令行生成（`developerID.key` 必须自己保管，后面导出 p12 依赖它）：

   ```bash
   openssl req -new -newkey rsa:2048 -nodes \
     -keyout developerID.key \
     -out developerID.certSigningRequest \
     -subj "/emailAddress=<AppleID>/CN=OpenLess Developer ID/C=CN"
   ```

3. 门户 Certificates → `+` → **Developer ID Application** → 上传 CSR → 下载 `developerid_application.cer`。
4. 双击 `.cer` 导入「登录」钥匙串（命令行路径则先导入私钥：`security import developerID.key -k login.keychain-db -T /usr/bin/codesign`），证书会与私钥配对。
5. 确认配对成功——「钥匙串访问 → 我的证书」里该条目应可展开出私钥。

**关键限制**：证书由门户签发，但私钥只存在于提交 CSR 的那台机器上。换机器必须在原机器导出 `.p12` 拷过去，**不能**在门户重新下载证书补齐私钥。

### 验证

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

出现 `1) <SHA1> "Developer ID Application: Your Name (TEAMID)"` 即成功。只要私钥没配对，这里就不会列出该项。

## 5. 导出 p12、转 base64、生成专用密码

### 导出 p12

钥匙串访问 → **我的证书**（必须选这个分类，导出才会带私钥）→ 右键该证书 → 导出… → 格式 **.p12** → 设密码（即 `APPLE_CERTIFICATE_PASSWORD`）。

```bash
# 校验 p12 完好、且包含私钥
openssl pkcs12 -info -in DeveloperID.p12 -noout
```

### 转 base64

```bash
base64 -i DeveloperID.p12 | pbcopy
```

macOS 的 `base64` 默认不换行，输出可直接作为 `APPLE_CERTIFICATE`（CI 侧用 `base64 --decode`，macOS 版本已支持该长选项）。

### App 专用密码

[appleid.apple.com](https://appleid.apple.com) → 登录与安全 → **App 专用密码** → 生成，得到 `xxxx-xxxx-xxxx-xxxx`，作为 `APPLE_PASSWORD`。

- 用的是 Apple ID 登录密码会被 `notarytool` 拒绝（401）。
- 该 Apple ID 必须是证书所属团队的成员。

## 6. 配置与构建

### 本地（推荐：填一次配置，之后直接跑脚本）

```bash
cd openless-all/app
cp scripts/macos-signing.env.example scripts/macos-signing.env
$EDITOR scripts/macos-signing.env    # 填 APPLE_SIGNING_IDENTITY / APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID

./scripts/build-mac-signed.sh --check           # 自检：证书、Team ID、专用密码、p12
./scripts/build-mac-signed.sh                   # 构建 + 签名 + 公证（按配置决定是否安装）
./scripts/build-mac-signed.sh --install         # 构建并装到 /Applications
```

生成的 `scripts/macos-signing.env` 已被 `.gitignore` 忽略，脚本还会强制把它收窄为 `600`，并拒绝在文件被 git 跟踪时继续。

也可以不落盘，直接用环境变量（等价于原先手写 `export` 的写法）：

```bash
cd openless-all/app
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export APPLE_ID="you@example.com"
export APPLE_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export APPLE_TEAM_ID="TEAMID"
INSTALL=0 ./scripts/build-mac-signed.sh
```

`build-mac-signed.sh` 在调用 `build-mac.sh` 之前会拒绝以下情况：凭据缺失或仍是模板占位符、身份是 ad-hoc、身份不是 Developer ID Application、证书不在钥匙串里、证书 Team ID 与 `APPLE_TEAM_ID` 不一致、`APPLE_PASSWORD` 是邮箱。`build-mac.sh` 拿到完整凭据后会额外执行 `spctl --assess` 与 `xcrun stapler validate`；只配一半则退化为 ad-hoc 路径。

### 生成 CI 需要的 Secrets

`--print-ci-secrets` 会校验 `.p12`（密码可解、含私钥、证书为 Developer ID Application、Team ID 与 `APPLE_TEAM_ID` 一致）后打印全部值，并把证书 base64 复制到剪贴板：

```bash
./scripts/build-mac-signed.sh --print-ci-secrets
./scripts/build-mac-signed.sh --push-secrets      # 或者直接用 gh 写入仓库
```

### GitHub Actions

仓库 Settings → Secrets and variables → Actions，添加 `APPLE_CERTIFICATE`、`APPLE_CERTIFICATE_PASSWORD`、`APPLE_ID`、`APPLE_PASSWORD`、`APPLE_TEAM_ID`（可选 `APPLE_PROVIDER_SHORT_NAME`、`KEYCHAIN_PASSWORD`）。

推送 `v*-tauri` tag 后，`release-tauri.yml` 会：导入证书 → 设 `APPLE_SIGNING_IDENTITY` → 注入公证凭据 → 调 `build-mac.sh` 完成签名、`.app` 公证、DMG 公证（Tauri 不做，脚本补做）与两处 staple。tag 发布缺必需 secret 会直接失败（见第 10 节）。

各 secret 的用途和权限边界见 [openless-all/README.md](../openless-all/README.md) 的 Release Signing 一节。

## 7. 验证

```bash
# 签名与 entitlements（麦克风权限必须仍在）
codesign -d --entitlements :- /Applications/OpenLess.app | grep audio-input
codesign --verify --deep --strict --verbose=2 /Applications/OpenLess.app

# .app 的 Gatekeeper 判定与公证票据
spctl --assess --type execute --verbose=2 /Applications/OpenLess.app
xcrun stapler validate /Applications/OpenLess.app

# .dmg 的票据，以及双击磁盘映像时 Gatekeeper 真正执行的检查
# （必须带 --context context:primary-signature，否则测不出 DMG 的问题）
xcrun stapler validate <path>/OpenLess_<version>_aarch64.dmg
spctl -a -t open --context context:primary-signature -v <path>/OpenLess_<version>_aarch64.dmg
```

预期输出：`.app` 为 `accepted / source=Notarized Developer ID`；DMG 的 `spctl` 同样是 `accepted / source=Notarized Developer ID`，且两条 `stapler validate` 都打印 `The validate action worked!`。

端到端复核（模拟浏览器下载：打上 quarantine 后挂载、拖出、再判定）：

```bash
cp OpenLess_<version>_aarch64.dmg /tmp/dl-test.dmg
xattr -w com.apple.quarantine "0083;00000000;Safari;" /tmp/dl-test.dmg
spctl -a -t open --context context:primary-signature -v /tmp/dl-test.dmg   # accepted

MNT=$(mktemp -d); hdiutil attach /tmp/dl-test.dmg -readonly -nobrowse -mountpoint "$MNT"
DEST=$(mktemp -d); ditto "$MNT/OpenLess.app" "$DEST/OpenLess.app"    # ditto 会保留 quarantine
spctl -a -t exec -vv "$DEST/OpenLess.app"                            # accepted
hdiutil detach "$MNT"; rm -rf "$MNT" "$DEST"
```

`src-tauri/Entitlements.plist` 里的 `com.apple.security.device.audio-input` 不能删：公证要求 hardened runtime，缺这条权限则公证后麦克风不可用。

## 8. 证书续期与轮换

- Developer ID 证书有效期约 3 年，且属于**签发时**的 Apple 账号。到期后新构建会退回失败/未签名状态，用户端表现为 Gatekeeper 再次拦截。
- 到期前：门户（或 Xcode）重新签发 → 重新导出 `.p12` → 更新 `APPLE_CERTIFICATE` / `APPLE_CERTIFICATE_PASSWORD`。`APPLE_ID` 那组凭据通常无需改动。
- 一张 Developer ID Application 证书可用于同一团队下的所有 App，不必每个应用一张。

## 9. 故障排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| CI 日志 `::error::macOS tag release requires Developer ID signing and notarization secrets` | tag 发布缺 secrets 或名字拼错 | 补齐第 2 节变量 |
| CI 日志 `No Apple certificate secrets configured` / `ad-hoc signing` | 手动 dispatch 构建，未配证书 | 属预期；dispatch 不要求签名（见第 10 节） |
| `security find-identity` 列不出 Developer ID | p12 里没有私钥，或导入了错误的钥匙串 | 从「我的证书」重新导出；确认私钥与其配对 |
| `errSecInternalComponent` | CI 钥匙串未解锁或 `set-key-partition-list` 未生效 | 检查 workflow 中 `security unlock-keychain` / `set-key-partition-list` 两步 |
| `unable to build chain to self-signed root` | 缺 Developer ID 中间证书，或未授权 codesign | 用 `-T /usr/bin/codesign` 导入；确认 runner 的 Xcode 环境含中间证书 |
| `build-mac-signed.sh` 报 `无法解析 .p12：密码错误或文件损坏` | `APPLE_CERTIFICATE_PASSWORD` 不是导出 `.p12` 时设的密码 | 重新导出 `.p12` 并同步更新配置 |
| `build-mac-signed.sh` 报 `.p12 里没有私钥` | 从门户下载的 `.cer` 没有私钥，或导出时选错了分类 | 在持有私钥的机器上从「钥匙串访问 → 我的证书」重新导出 |
| `build-mac-signed.sh` 报 `Team ID 不匹配` / `.p12 的证书属于团队 X` | 证书与 `APPLE_TEAM_ID` 不是同一个团队 | 改成证书所属团队的 10 位 Team ID |
| `notarytool` 返回 401 / `Invalid credentials` | 用了登录密码而非 App 专用密码，或 Team ID 与证书团队不一致 | 重新生成 App 专用密码；核对 Membership 页 Team ID |
| 公证成功但 `stapler validate` 失败 | 公证未完成就打包，或未执行 staple | 等公证返回 `Accepted`；确认 Tauri 走的是签名+公证链路而非手搓 DMG |
| `...dmg does not have a ticket stapled to it` | Tauri 只公证 `.app`，DMG 从未提交公证 | 已由 `build-mac.sh` 自动补做；若手工构建请确认这一步没被跳过 |
| DMG 的 `spctl -t open --context context:primary-signature` 报 `Unnotarized Developer ID` | DMG 只有签名、没有公证票据 | 同上；`stapler validate` 不带 `--context` 时测不出这个问题 |
| 签名通过，用户仍被拦 | 只签名未公证，或证书已过期 | 检查 `spctl`/`stapler`，并核对证书有效期 |
| 公证报嵌套二进制问题 | `Contents/MacOS` 下有非 Mach-O 文件（如 `mlx.metallib`） | `build-mac.sh` 已强制 `mlx.metallib` 只放 `Contents/Resources`，不要绕过该检查 |

## 10. tag 发布与 dispatch 的差异

- **tag 发布**（`v*-tauri`）：`Check Apple signing availability` 在缺任一必需 secret 时打印 `::error::` 并 `exit 1`，macOS job 直接失败。这与 [openless-all/README.md](../openless-all/README.md) 中「tagged macOS releases fail if signing/notarization secrets are missing」一致。
- **手动 dispatch**：不要求签名，缺证书时回退 ad-hoc 出包，供测试使用。
- `.app`/`.dmg` 上传前会执行一次 `xattr -cr`（只保证云端产物干净，不能阻止下载方浏览器重新打 quarantine）。
- release notes 里的 `xattr -cr` 提示已按是否配置 Apple 凭据分支生成：配了凭据的 tag 发布不再要求用户做任何手工操作，只有未配置凭据（或手动 dispatch）的 ad-hoc 构建才附上该提示。

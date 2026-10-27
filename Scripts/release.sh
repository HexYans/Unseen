#!/usr/bin/env bash
#
# Unseen → DMG，一条命令。
#
#   ./Scripts/release.sh                 # 版本 patch +1，通用二进制，签名，出 DMG
#   VERSION=1.2.0 ./Scripts/release.sh   # 手动指定版本（必须比当前大）
#   KEEP_DMGS=0 ./Scripts/release.sh     # 不清理旧 DMG（默认只保留最新 3 个）
#   CODESIGN_IDENTITY="..." ...          # 指定签名证书（默认用钥匙串里第一个）
#
# 产物：
#   dist/Unseen-<版本>.dmg   分发包（卷名 Unseen，内含 App + Applications 软链）
#   dist/Unseen.app          本机可直接运行的通用 App
#
# 版本号唯一来源是 Resources/Info.plist；脚本自动 +1，构建失败会回滚。
# 流程：通用构建（arm64 + x86_64）→ 组 Unseen.app → 签名 → staging → DMG →
#       校验签名/架构/卷名 → 清理 staging → 报告大小和 SHA-256。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Unseen"
PRODUCT="Unseen"
DISPLAY_NAME="Unseen"
BUNDLE_ID="com.hexyans.unseen"
PLIST="$ROOT/Resources/Info.plist"
ICON="$ROOT/Resources/AppIcon.icns"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
STAGE="$DIST/dmg-staging"

KEEP_DMGS="${KEEP_DMGS:-3}"

usage() {
  # 打印文件头部的注释块（到第一行非注释为止）。
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
}

for arg in "$@"; do
  case "$arg" in
    --help|-h)    usage; exit 0 ;;
    *)            echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

die()  { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }
note() { echo "    $*"; }

PLIST_BACKUP=""
PLIST_TMP=""
MOUNTED_VOLUME=""
MOUNT_POINT=""
DMG_READY=""

cleanup() {
  local status=$?
  if [ -n "$MOUNTED_VOLUME" ] && [ -d "$MOUNTED_VOLUME" ]; then
    hdiutil detach "$MOUNTED_VOLUME" >/dev/null 2>&1 || true
  fi
  if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
    rmdir "$MOUNT_POINT" 2>/dev/null || true
  fi
  if [ "$status" -ne 0 ] && [ -n "$PLIST_BACKUP" ] && [ -f "$PLIST_BACKUP" ]; then
    cp "$PLIST_BACKUP" "$PLIST"
    echo "    rolled back Resources/Info.plist (release did not finish)" >&2
  fi
  if [ -n "$PLIST_BACKUP" ]; then rm -f "$PLIST_BACKUP"; fi
  if [ -n "$PLIST_TMP" ]; then rm -f "$PLIST_TMP"; fi
  # 还没校验通过的半成品 DMG 不要留在 dist/ 里，免得下次运行被它挡住。
  if [ "$status" -ne 0 ] && [ -z "$DMG_READY" ] && [ -n "${DMG:-}" ] && [ -f "$DMG" ]; then
    rm -f "$DMG"
    echo "    removed unfinished $(basename "$DMG")" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------
# 1. 环境与版本
# ---------------------------------------------------------------------------
step "check"
command -v swift >/dev/null 2>&1 || die "swift not found (install Xcode Command Line Tools)"
command -v hdiutil >/dev/null 2>&1 || die "hdiutil not found"
[ -f "$PLIST" ] || die "missing $PLIST"
[ -f "$ICON" ] || die "missing $ICON"

SHORT="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
[[ "$SHORT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "CFBundleShortVersionString '$SHORT' is not x.y.z"
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "CFBundleVersion '$BUILD' is not an integer"

if [ -n "${VERSION:-}" ]; then
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION='$VERSION' is not x.y.z"
  NEW_SHORT="$VERSION"
  if [ "$(printf '%s\n%s\n' "$SHORT" "$NEW_SHORT" | sort -V | tail -1)" != "$NEW_SHORT" ] \
     || [ "$NEW_SHORT" = "$SHORT" ]; then
    die "VERSION=$NEW_SHORT must be greater than the current $SHORT"
  fi
else
  IFS=. read -r MAJOR MINOR PATCH <<< "$SHORT"
  NEW_SHORT="${MAJOR}.${MINOR}.$((PATCH + 1))"
fi
NEW_BUILD=$((BUILD + 1))
DMG="$DIST/$APP_NAME-$NEW_SHORT.dmg"

[ -e "$DMG" ] && die "$DMG already exists; bump again or remove it"
note "version: $SHORT ($BUILD) -> $NEW_SHORT ($NEW_BUILD)"

# ---------------------------------------------------------------------------
# 2. 写入新版本（失败则回滚）
# ---------------------------------------------------------------------------
step "update Resources/Info.plist"
PLIST_BACKUP="$(mktemp -t unseen-plist)"
cp "$PLIST" "$PLIST_BACKUP"

# 只改两个版本字符串，保留 key 顺序和注释（plutil -replace 会重排整个文件）。
PLIST_TMP="$PLIST.release-tmp.$$"
awk -v short="$NEW_SHORT" -v build="$NEW_BUILD" '
  function set_version(v) { sub(/<string>[^<]*<\/string>/, "<string>" v "</string>") }
  prev ~ /<key>CFBundleShortVersionString<\/key>/ { set_version(short) }
  prev ~ /<key>CFBundleVersion<\/key>/            { set_version(build) }
  { print; prev = $0 }
' "$PLIST" > "$PLIST_TMP"
if [ "$(plutil -extract CFBundleShortVersionString raw "$PLIST_TMP" 2>/dev/null || true)" != "$NEW_SHORT" ] \
   || [ "$(plutil -extract CFBundleVersion raw "$PLIST_TMP" 2>/dev/null || true)" != "$NEW_BUILD" ]; then
  die "could not rewrite the version keys in $PLIST"
fi
mv "$PLIST_TMP" "$PLIST"
PLIST_TMP=""
plutil -lint "$PLIST" >/dev/null
note "$NEW_SHORT (build $NEW_BUILD)"

# ---------------------------------------------------------------------------
# 3. 通用构建
# ---------------------------------------------------------------------------
step "universal build (arm64 + x86_64)"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/caches/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

SWIFT_BUILD=(swift build -c release --arch arm64 --arch x86_64 --disable-sandbox)
"${SWIFT_BUILD[@]}" 2>&1 | tail -n 3
BIN="$("${SWIFT_BUILD[@]}" --show-bin-path)/$PRODUCT"
[ -x "$BIN" ] || die "build produced no binary at $BIN"
ARCHS="$(lipo -archs "$BIN")"
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) note "archs: $ARCHS" ;;
  *) die "expected a universal binary, got: $ARCHS" ;;
esac

# ---------------------------------------------------------------------------
# 4. 组装 .app 并签名
# ---------------------------------------------------------------------------
sign_app() {
  local target="$1" identity
  identity="${CODESIGN_IDENTITY:-}"
  if [ -z "$identity" ]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"
  fi
  if [ -n "$identity" ] && codesign --force --deep --sign "$identity" --timestamp=none "$target" >/dev/null 2>&1; then
    note "signed with: $identity"
    return 0
  fi
  if [ -n "$identity" ]; then
    echo "warning: signing with '$identity' failed; falling back to ad-hoc" >&2
  fi
  codesign --force --deep --sign - --timestamp=none "$target" >/dev/null 2>&1 \
    || die "code signing failed"
  note "signed: ad-hoc (Accessibility grants must be re-added after each install)"
}

step "assemble $APP_NAME.app"
rm -rf "$STAGE"
STAGED_APP="$STAGE/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN" "$STAGED_APP/Contents/MacOS/$APP_NAME"
cp "$PLIST" "$STAGED_APP/Contents/Info.plist"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"
cp "$ICON" "$STAGED_APP/Contents/Resources/AppIcon.icns"
xattr -cr "$STAGED_APP" 2>/dev/null || true
chmod +x "$STAGED_APP/Contents/MacOS/$APP_NAME"

sign_app "$STAGED_APP"
codesign --verify --deep --strict --all-architectures "$STAGED_APP" \
  || die "code signature verification failed"

# 身份不变量逐条核对（防止发出去的包名字/ID 漂移）。
APP_PLIST="$STAGED_APP/Contents/Info.plist"
check() { # key expected
  local actual
  actual="$(plutil -extract "$1" raw "$APP_PLIST")"
  [ "$actual" = "$2" ] || die "$1 changed: expected '$2', got '$actual'"
  note "$1 = $actual"
}
check CFBundleShortVersionString "$NEW_SHORT"
check CFBundleVersion "$NEW_BUILD"
check CFBundleName "$DISPLAY_NAME"
check CFBundleDisplayName "$DISPLAY_NAME"
check CFBundleIdentifier "$BUNDLE_ID"
check CFBundleExecutable "$APP_NAME"

# ---------------------------------------------------------------------------
# 5. 准备 DMG 内容：app + Applications 软链
# ---------------------------------------------------------------------------
step "stage DMG contents"
ln -s /Applications "$STAGE/Applications"

note "$(basename "$STAGE")/"

# ---------------------------------------------------------------------------
# 6. 打 DMG 并校验
# ---------------------------------------------------------------------------
step "create DMG"
mkdir -p "$DIST"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null || die "hdiutil verify failed"
note "hdiutil verify: VALID"

# 挂到私有挂载点校验卷名和内容。不挂到 /Volumes 是为了避开同名的旧卷
# （比如桌面上还开着一个 Unseen 的 DMG，系统会把新卷命名成 “Unseen 1”）。
MOUNT_POINT="$(mktemp -d -t unseen-dmg)"
hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" >/dev/null \
  || die "could not mount $DMG"
MOUNTED_VOLUME="$MOUNT_POINT"
VOLUME_NAME="$(diskutil info -plist "$MOUNT_POINT" 2>/dev/null \
  | plutil -extract VolumeName raw - 2>/dev/null || true)"
[ "$VOLUME_NAME" = "$DISPLAY_NAME" ] \
  || die "DMG volume name changed: expected '$DISPLAY_NAME', got '${VOLUME_NAME:-?}'"
[ -d "$MOUNT_POINT/$APP_NAME.app" ] \
  || die "$APP_NAME.app is missing from the DMG"
note "volume name = $VOLUME_NAME, app present"
hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
MOUNTED_VOLUME=""

# DMG 已验证通过：从这一刻起版本号不再回滚（包是真的发出去了）。
DMG_READY=1
rm -f "$PLIST_BACKUP"
PLIST_BACKUP=""

# ---------------------------------------------------------------------------
# 7. 本机副本（可直接 open，不用装）
# ---------------------------------------------------------------------------
step "keep local copy"
rm -rf "$APP"
ditto "$STAGED_APP" "$APP"
codesign --verify --deep --strict "$APP" || die "local copy lost its signature"
note "$APP"

# ---------------------------------------------------------------------------
# 8. 只保留最新 KEEP_DMGS 个版本包
# ---------------------------------------------------------------------------
step "retention (KEEP_DMGS=$KEEP_DMGS)"
if [ "$KEEP_DMGS" -gt 0 ] 2>/dev/null; then
  kept=0
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    kept=$((kept + 1))
    if [ "$kept" -gt "$KEEP_DMGS" ]; then
      rm -f "$old"
      note "pruned: $(basename "$old")"
    fi
  done < <(ls -t "$DIST"/"$APP_NAME"-*.dmg 2>/dev/null \
             | grep -E "/$APP_NAME-[0-9]+\.[0-9]+\.[0-9]+\.dmg$" || true)
else
  note "disabled; all DMGs kept"
fi

# ---------------------------------------------------------------------------
# 9. 清理 staging，报告
# ---------------------------------------------------------------------------
rm -rf "$STAGE"

SIZE_BYTES="$(stat -f%z "$DMG")"
SIZE_HUMAN="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

echo
echo "Done: $DMG"
echo "      size:    $SIZE_HUMAN ($SIZE_BYTES bytes)"
echo "      sha256:  $SHA"
echo "      version: $NEW_SHORT (build $NEW_BUILD)"
echo "      app:     $APP"
echo
echo "Next: git add Resources/Info.plist && git commit -m \"release: $NEW_SHORT\""

#!/usr/bin/env bash
# XbUme macOS 分发包构建（.app + .dmg）。
#
#   tool/package/macos/build.sh [--sign "Developer ID Application: xxx"] \
#                               [--out dist] [--no-vendor] [--no-dmg] [--version 1.2.3]
#
# 产物：
#   build/package/macos/XbUme.app                     可直接双击（先看「首次打开」）
#   dist/XbUme-<version>.dmg                          分发给测试人员
#
# 说明：
#   - 四个入口（ide / ide_gui / mcp / hotkey_listener）分别 AOT 编译成
#     Contents/MacOS 下的 xbume-ide / xbume-gui / xbume-mcp / xbume-hotkey。
#     运行期靠「同目录存在兄弟可执行文件」判定为分发版（见
#     bin/src/control/svc_control.dart），不需要环境变量；
#   - 转发工具（adb / hdc / iproxy / idevice_id）连同它们的 dylib 一起放进
#     Contents/Resources/bin，并把依赖重定位到 @executable_path，测试人员
#     机器上不需要装 Android platform-tools / DevEco / libimobiledevice；
#   - 默认 ad-hoc 签名；拿到 Developer ID 后用 --sign 传证书名即可出正式包
#     （再加 notarytool 公证，见 PACKAGING.md）。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
APP_NAME="XbUme"
SIGN_ID="-"
OUT_DIR="$ROOT/dist"
DO_VENDOR=1
DO_DMG=1
VERSION=""
TOOL_DIR="${XBUME_TOOL_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) SIGN_ID="${2:?缺少证书名}"; shift 2 ;;
    --out) OUT_DIR="${2:?缺少输出目录}"; shift 2 ;;
    --version) VERSION="${2:?缺少版本号}"; shift 2 ;;
    --tool-dir) TOOL_DIR="${2:?缺少工具目录}"; shift 2 ;;
    --no-vendor) DO_VENDOR=0; shift ;;
    --no-dmg) DO_DMG=0; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$VERSION" ]] || VERSION="$(awk '/^version:/{print $2; exit}' "$ROOT/pubspec.yaml")"
[[ -n "$VERSION" ]] || { echo "读不到 pubspec.yaml 的 version" >&2; exit 1; }
[[ "$(uname -s)" == "Darwin" ]] || { echo "只能在 macOS 上构建 .app/.dmg" >&2; exit 1; }
command -v dart >/dev/null || { echo "需要 dart（Flutter SDK 自带）" >&2; exit 1; }

BUILD="$ROOT/build/package/macos"
APP="$BUILD/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
BINDIR="$RES/bin"

step() { printf '\n\033[1m[%s]\033[0m %s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
# 1. AOT 编译三个入口
# ---------------------------------------------------------------------------
step 1/7 "AOT 编译（dart compile exe）"
rm -rf "$APP"
mkdir -p "$MACOS" "$BINDIR"
(cd "$ROOT" && dart compile exe bin/ide.dart     -o "$MACOS/xbume-ide")
(cd "$ROOT" && dart compile exe bin/ide_gui.dart -o "$MACOS/xbume-gui")
(cd "$ROOT" && dart compile exe bin/mcp.dart     -o "$MACOS/xbume-mcp")
# 全局快捷键监听器：主 isolate 阻塞在 Carbon/GetMessage 上，必须单进程，
# 与源码部署同一个入口（bin/src/hotkeys/hotkey_listener.dart）。
(cd "$ROOT" && dart compile exe bin/src/hotkeys/hotkey_listener.dart \
  -o "$MACOS/xbume-hotkey")

# ---------------------------------------------------------------------------
# 2. 版本与图标
# ---------------------------------------------------------------------------
step 2/7 "版本与图标"
printf '%s\n' "$VERSION" >"$RES/version.txt"
# version.txt 不能放进 Contents/MacOS：codesign 会把同目录的非 Mach-O 文件
# 当成 bundle 子组件而拒绝（In subcomponent: .../version.txt）。mcp 的
# _readVersion 已经在读不到同目录版本时回落到 ../Resources/version.txt。

ICON_PNG="$HERE/icon.png"
if [[ -f "$ICON_PNG" ]]; then
  ICONSET="$BUILD/icon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$RES/icon.icns"
  rm -rf "$ICONSET"
else
  echo "  未找到 ${ICON_PNG}，跳过图标（Finder 显示默认图标）"
fi

# ---------------------------------------------------------------------------
# 3. 内嵌转发工具（adb / hdc / iproxy / idevice_id）及其 dylib
# ---------------------------------------------------------------------------
step 3/7 "内嵌转发工具"

# 工具来源：--tool-dir 优先，其次 PATH / 常见安装位置。
find_tool() {
  local name="$1"
  if [[ -n "$TOOL_DIR" && -x "$TOOL_DIR/$name" ]]; then
    printf '%s' "$TOOL_DIR/$name"; return 0
  fi
  local p
  p="$(command -v "$name" 2>/dev/null || true)"
  [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
  local deveco="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
  for cand in \
    "$deveco"/default/openharmony/toolchains/$name \
    "$deveco"/*/openharmony/toolchains/$name \
    "$HOME/Library/Android/sdk/platform-tools/$name" \
    /opt/homebrew/bin/$name /usr/local/bin/$name; do
    [[ -x "$cand" ]] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

# 递归把二进制依赖的第三方 dylib 拷进来，并把引用改成 @executable_path/<名>。
# 只处理非系统路径（/usr/lib、/System 由系统提供）。
declare -a SEEN_LIBS=()
relocate_deps() {
  local bin="$1"
  local dir; dir="$(dirname "$bin")"
  local lib
  while IFS= read -r lib; do
    [[ -z "$lib" ]] && continue
    case "$lib" in
      /usr/lib/*|/System/*) continue ;;
    esac
    local base; base="$(basename "$lib")"
    case " ${SEEN_LIBS[*]-} " in *" $base "*) continue ;; esac
    SEEN_LIBS+=("$base")

    if [[ "$lib" == @rpath/* ]]; then
      # @rpath 依赖：先看工具自带目录，再找 SDK / brew 目录里的同名文件。
      local found=""
      for cand in "$dir/$base" "$TOOL_DIR/$base" \
                  "${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"/default/openharmony/toolchains/"$base" \
                  /opt/homebrew/lib/"$base" /usr/local/lib/"$base"; do
        [[ -f "$cand" ]] && { found="$cand"; break; }
      done
      [[ -n "$found" ]] || { echo "  ! 找不到 ${lib}（${bin}）" >&2; continue; }
      [[ -f "$dir/$base" ]] || cp -f "$found" "$dir/$base"
      chmod u+w "$dir/$base" 2>/dev/null || true
      install_name_tool -change "$lib" "@executable_path/$base" "$bin"
      relocate_deps "$dir/$base"
      continue
    fi

    [[ -f "$lib" ]] || { echo "  ! 依赖不存在: ${lib}（${bin}）" >&2; continue; }
    [[ -f "$dir/$base" ]] || cp -f "$lib" "$dir/$base"
    chmod u+w "$dir/$base" 2>/dev/null || true
    install_name_tool -change "$lib" "@executable_path/$base" "$bin"
    relocate_deps "$dir/$base"
  done < <(otool -L "$bin" | tail -n +2 | awk '{print $1}')
}

if [[ $DO_VENDOR -eq 1 ]]; then
  for tool in adb hdc iproxy idevice_id; do
    src="$(find_tool "$tool" || true)"
    if [[ -z "$src" ]]; then
      echo "  - $tool: 未找到，跳过（目标机器需自行安装）"
      continue
    fi
    cp -f "$src" "$BINDIR/$tool"
    chmod u+w "$BINDIR/$tool"
    relocate_deps "$BINDIR/$tool"
    archs="$(lipo -archs "$BINDIR/$tool" 2>/dev/null || echo '?')"
    echo "  - $tool: $(basename "$src") → Resources/bin（架构: ${archs}）"
    case "$archs" in
      *arm64*) ;;
      *) echo "    ! 只有 ${archs}：Intel Mac 上不可用" ;;
    esac
  done
else
  echo "  已跳过（--no-vendor）"
fi

# ---------------------------------------------------------------------------
# 4. Info.plist + 使用说明
# ---------------------------------------------------------------------------
step 4/7 "Info.plist"
sed "s/@VERSION@/$VERSION/g" "$HERE/Info.plist" >"$CONTENTS/Info.plist"
if [[ -f "$HERE/使用说明.txt" ]]; then
  cp -f "$HERE/使用说明.txt" "$RES/使用说明.txt"
fi

# ---------------------------------------------------------------------------
# 5. 签名（先 dylib，再可执行文件，最后 bundle）
# ---------------------------------------------------------------------------
step 5/7 "签名（${SIGN_ID}）"
SIGN_ARGS=(--force --sign "$SIGN_ID")
[[ "$SIGN_ID" != "-" ]] && SIGN_ARGS+=(--options runtime --timestamp)
sign_one() {
  codesign "${SIGN_ARGS[@]}" "$1" 2>&1 || {
    echo "  ! 签名失败: $1" >&2; return 1; }
}
# 先 dylib、再工具二进制：两者都被 install_name_tool 改过，原签名已失效；
# arm64 上签名无效会被内核直接 kill（现象是 `killed`，没有任何输出）。
while IFS= read -r f; do sign_one "$f"; done < <(find "$BINDIR" -type f -name '*.dylib')
while IFS= read -r f; do
  case "$f" in *.dylib) continue ;; esac
  sign_one "$f"
done < <(find "$BINDIR" -type f)
for exe in xbume-ide xbume-gui xbume-mcp xbume-hotkey; do sign_one "$MACOS/$exe"; done
sign_one "$APP"
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 \
  && echo "  校验通过" \
  || echo "  ! codesign --verify 未通过（ad-hoc 下个别情况可忽略，实测能启动即可）"

# ---------------------------------------------------------------------------
# 6. 组 dmg
# ---------------------------------------------------------------------------
step 6/7 "生成 dmg"
mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"
if [[ $DO_DMG -eq 1 ]]; then
  STAGE="$BUILD/dmg"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  # ad-hoc 包首次打开会被 Gatekeeper 拦住：附一个一键去隔离脚本。
  cat >"$STAGE/首次打开.command" <<'EOS'
#!/bin/bash
# 双击运行：解除 Gatekeeper 隔离标记，之后即可正常双击 XbUme.app。
cd "$(dirname "$0")" || exit 1
xattr -dr com.apple.quarantine "XbUme.app" 2>/dev/null
echo "已解除隔离：把 XbUme.app 拖到 Applications 后双击打开。"
echo
read -n 1 -s -r -p "按任意键关闭…"
EOS
  chmod +x "$STAGE/首次打开.command"
  rm -f "$DMG"
  hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
  echo "  $DMG"
else
  echo "  已跳过（--no-dmg）"
fi

# ---------------------------------------------------------------------------
# 7. 汇总
# ---------------------------------------------------------------------------
step 7/7 "完成"
du -sh "$APP" | sed 's/^/  app: /'
[[ $DO_DMG -eq 1 ]] && du -sh "$DMG" | sed 's/^/  dmg: /'
echo
echo "  本地试运行：open \"$APP\"   （或直接双击）"
echo "  分发：$DMG"
echo
echo "  注意：被测 app 必须以 --dart-define=XBUME_AGENT=1 构建，否则"
echo "        直连（不依赖 VM）通道不会开启，本工具看不到任何会话。"

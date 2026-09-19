#!/usr/bin/env bash
#
# 编译 sing-box 的 Libbox.xcframework（默认只编 iOS + iOS 模拟器）。
#
# 这个脚本固化了两个本次实际踩到的坑，别删注释：
#
#   1. gomobile 必须用 sagernet 分支，不是官方的 golang.org/x/mobile。
#      sing-box 的 build_libbox 里写着 `_ "github.com/sagernet/gomobile"`，
#      且版本必须与 sing-box go.mod 里钉住的版本一致（v1.14.0 对应 v0.1.12）。
#
#   2. gomobile 用 PATH 查找 gobind，源码为 exec.LookPath("gobind")，
#      而 macOS 默认 PATH 不含 ~/go/bin —— 不前置就会报
#      "gobind was not found. Please run gomobile init before trying again"。
#
# 另外：Go 缓存强制指向外接盘，若外接盘未挂载则直接失败退出，
# 避免 Go 静默把几个 GB 写回内置盘。
#
set -euo pipefail

SING_BOX_VERSION="${SING_BOX_VERSION:-v1.14.0}"
GOMOBILE_VERSION="${GOMOBILE_VERSION:-v0.1.12}"
TARGET_PLATFORM="${TARGET_PLATFORM:-ios,iossimulator}"
EXTERNAL_ROOT="${EXTERNAL_ROOT:-$HOME/nestlink-build}"   # 可覆盖；这是默认工作目录

SRC_DIR="$EXTERNAL_ROOT/src/sing-box"
APPLE_DIR="$EXTERNAL_ROOT/src/sing-box-for-apple"

export GOMODCACHE="$EXTERNAL_ROOT/Go/mod"
export GOCACHE="$EXTERNAL_ROOT/Go/build"
export PATH="$HOME/go/bin:$PATH"

log() { printf '\n=== %s ===\n' "$*"; }

log "前置检查"
if [ ! -d "$EXTERNAL_ROOT" ]; then
    echo "错误：外接盘 $EXTERNAL_ROOT 未挂载，中止以免污染内置盘。" >&2
    exit 1
fi
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "错误：找不到 sing-box 源码，请先克隆到 $SRC_DIR。" >&2
    exit 1
fi

for tool in gobind gomobile; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "错误：缺少 $tool。请先执行：" >&2
        echo "  go install github.com/sagernet/gomobile/cmd/$tool@$GOMOBILE_VERSION" >&2
        exit 1
    fi
done

echo "gobind   -> $(command -v gobind)"
echo "gomobile -> $(command -v gomobile)"
echo "Xcode    -> $(xcodebuild -version 2>/dev/null | head -1)"
echo "缓存     -> GOCACHE=$GOCACHE"

log "切换到 sing-box $SING_BOX_VERSION"
cd "$SRC_DIR"
git fetch --depth 1 origin tag "$SING_BOX_VERSION" 2>/dev/null || true
git checkout -q "$SING_BOX_VERSION"
echo "当前版本：$(git describe --tags 2>/dev/null || echo unknown)"

log "开始编译（平台：$TARGET_PLATFORM）"
echo "注意：全量编译 sing-box（含 gvisor/quic-go/tailscale 等）在 M2 上通常需要 5-15 分钟。"
date
go run ./cmd/internal/build_libbox -target apple -platform "$TARGET_PLATFORM"
date

log "产物"
OUTPUT="$APPLE_DIR/Libbox.xcframework"
if [ -d "$OUTPUT" ]; then
    du -sh "$OUTPUT"
    ls "$OUTPUT"
    # 确认是静态库：静态库不需要（也不应该）嵌入 App
    echo
    echo "库类型检查（static archive 才是预期结果）："
    find "$OUTPUT" -name "Libbox" -type f -exec file {} \; 2>/dev/null | head -5
else
    echo "未找到产物 $OUTPUT" >&2
    exit 1
fi

log "完成"
echo "下一步："
echo "  ln -sfn \"$OUTPUT\" \"$(cd "$(dirname "$0")/.." && pwd)/Frameworks/Libbox.xcframework\""
echo "  xcodegen generate"

#!/usr/bin/env bash
# Linux 构建环境一次性准备（Ubuntu 22.04 系：本机 WSL / DGX Spark 通用）。
# 以**构建用户自己**跑（Flutter 装进 $HOME/flutter；apt 段自动走 sudo）：
#   bash packaging/linux/wsl-setup.sh
# WSL 里若 apt 段已由 root 侧完成（wsl -u root），可 SKIP_APT=1 只装 Flutter。
set -euo pipefail

if [ "${SKIP_APT:-0}" != 1 ]; then
  SUDO=""
  [ "$(id -u)" != 0 ] && SUDO="sudo"
  echo "== apt 构建依赖 =="
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq \
    git unzip xz-utils curl \
    cmake ninja-build clang pkg-config \
    libgtk-3-dev libsecret-1-dev dpkg-dev rsync \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libunwind-dev \
    libayatana-appindicator3-dev
  # ^ GStreamer dev：audioplayers_linux 的 pkg_check_modules 硬需求；
  #   libunwind-dev：gstreamer-1.0.pc 在 arm64 上 Requires 它（DGX 实锤，
  #   缺了 pkg_check_modules 报「gstreamer-1.0 not found」误导性错误）；
  #   appindicator dev：tray_manager（Dart 侧 Windows-only 守卫，但插件 .so
  #   链接期就要它，缺了 cmake 直接拒配）。
fi

# 目标版本与 Windows 开发机严格一致；FLUTTER_DIR 可指到别处（DGX 上机主有
# 自用的 ~/flutter@3.29，构建必须 3.27 就 FLUTTER_DIR=$HOME/flutter-3.27.0，
# 绝不动人家现有安装——版本不符的既有目录挪 .bak 而非覆盖）。
FLUTTER_VER="${FLUTTER_VER:-3.27.0}"
FLUTTER_DIR="${FLUTTER_DIR:-$HOME/flutter}"
mkdir -p "$FLUTTER_DIR" 2>/dev/null || true
if [ -x "$FLUTTER_DIR/bin/flutter" ] && \
   "$FLUTTER_DIR/bin/flutter" --version 2>/dev/null | head -1 | grep -q "Flutter $FLUTTER_VER"; then
  echo "== Flutter $FLUTTER_VER 已在 $FLUTTER_DIR，跳过安装 =="
else
  echo "== Flutter $FLUTTER_VER（Linux）安装到 $FLUTTER_DIR =="
  if [ -n "$(ls -A "$FLUTTER_DIR" 2>/dev/null)" ]; then
    bak="$FLUTTER_DIR.bak-$(date +%s)"
    echo "WARN: $FLUTTER_DIR 非空且版本不符，挪到 $bak"
    mv "$FLUTTER_DIR" "$bak"
  fi
  mkdir -p "$FLUTTER_DIR"
  ok=0
  for U in \
    "${FLUTTER_MIRROR:-https://storage.flutter-io.cn}/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VER}-stable.tar.xz" \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VER}-stable.tar.xz"; do
    echo "-- 试源 $U"
    curl -fsSL --connect-timeout 15 -o /tmp/flutter.tar.xz "$U" && { ok=1; break; }
  done
  [ "$ok" = 1 ] || { echo "ERROR: Flutter $FLUTTER_VER 双源都拉不下来" >&2; exit 1; }
  tar -xJf /tmp/flutter.tar.xz --strip-components=1 -C "$FLUTTER_DIR"
  rm -f /tmp/flutter.tar.xz
  git config --global --add safe.directory "$FLUTTER_DIR"
fi

export PATH="$FLUTTER_DIR/bin:$PATH"

echo "== precache Linux 桌面产物 =="
flutter config --no-analytics >/dev/null 2>&1 || true
flutter precache --linux
flutter --version
echo "SETUP_DONE"

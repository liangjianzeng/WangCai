#!/usr/bin/env bash
# 一次性：以 root 在 WSL 里装 Linux 构建依赖（wsl-setup.sh 的 apt 段替身，
# 规避 Git Bash→wsl.exe→bash -c 三层引号注入）。
set -x
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git unzip xz-utils cmake ninja-build clang pkg-config \
  libgtk-3-dev libsecret-1-dev dpkg-dev rsync \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libunwind-dev \
  libayatana-appindicator3-dev
echo "INSTALL_RC=$?"
dpkg -l git unzip cmake ninja-build clang pkg-config libgtk-3-dev libsecret-1-dev dpkg-dev rsync 2>/dev/null | grep -c '^ii'

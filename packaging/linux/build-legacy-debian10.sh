#!/usr/bin/env bash
# 老发行版兼容构建通道：Debian 10 (buster) chroot 内编译汪柴 Linux 产物。
#
# 为什么（2026-11-11 UOS Desktop 20 实测翻车 → triage 实锤）：
#   Ubuntu 22.04 编的 runner/插件要 GLIBC_2.34 + GLIBCXX_3.4.29，UOS（Debian 10
#   系，glibc 2.28/GLIBCXX 3.4.25）动态链接期即死（点击无反应：Terminal=false
#   吞 stderr）。readelf 实测：Google 预编译件（flutter 引擎 GLIBC_2.18、
#   onnxruntime 2.16、libapp.so 无版本化）在 2.28 上全兼容——死因全部是
#   「本地新工具链编的」那批。在 buster（glibc 2.28 = UOS 同代）重编即完整解。
#
# 用法（WSL/Ubuntu 宿主，root）：
#   sudo ./build-legacy-debian10.sh              # 全量：建 chroot→装工具链→编译→换料重出 deb+tar
#   sudo CHROOT=/srv/buster FLUTTER_DIR=/opt/flutter ./build-legacy-debian10.sh
#   SKIP_BOOTSTRAP=1 ...                          # chroot 已就绪时跳过 debootstrap/apt
# 产物：packaging/dist/WangCai-<ver>-linux-amd64{-legacy}.deb/.tar.gz + 版本闸报告。
#
# 纪律：产物出厂前过 readelf 版本闸（GLIBC>2.28 / GLIBCXX>3.4.25 直接 fail），
# 不再让「本机绿、UOS 死」的包出门。
set -euo pipefail

CHROOT="${CHROOT:-/srv/buster}"
FLUTTER_VER="${FLUTTER_VER:-3.27.0}"
FLUTTER_MIRROR="${FLUTTER_MIRROR:-https://storage.flutter-io.cn}"
# buster 已 EOL 进 archive；tuna/ustc 均未镜像 debian-archive（2026-11-11 实测 404），
# aliyun 有货且国内快——直连 archive.debian.org 为兜底。
DEBIAN_MIRROR="${DEBIAN_MIRROR:-https://mirrors.aliyun.com/debian-archive/debian}"
REPO="${REPO:-/mnt/e/DTXY/WangCai}"
APP="$REPO/app"
DIST="$REPO/packaging/dist"
LOG_PREFIX="[legacy-build]"

[ "$(id -u)" -eq 0 ] || { echo "$LOG_PREFIX 需要 root（debootstrap/chroot/mount）"; exit 1; }
command -v debootstrap >/dev/null || { echo "$LOG_PREFIX apt-get install -y debootstrap 先"; exit 1; }
[ -d "$APP/linux" ] || { echo "$LOG_PREFIX 找不到 $APP/linux"; exit 1; }

VER=$(grep -m1 '^version:' "$APP/pubspec.yaml" | sed 's/^version:[[:space:]]*//; s/+.*//')
echo "$LOG_PREFIX 版本 $VER · chroot=$CHROOT"

# ---------------------------------------------------------------- 1 bootstrap
# debootstrap 与工具链两闸独立：debootstrap 崩过一次的半截现场（dpkg 已就位、
# postinst 未配）可 SKIP_BOOTSTRAP=1 续跑，工具链以 chroot 内 clang 存在与否幂等判定。
if [ "${SKIP_BOOTSTRAP:-0}" != "1" ] && [ ! -x "$CHROOT/bin/bash" ]; then
  echo "$LOG_PREFIX debootstrap buster（archive 源，首次较久）…"
  rm -rf "$CHROOT"
  debootstrap --variant=minbase --include=ca-certificates,curl,wget,gnupg,apt-transport-https \
    buster "$CHROOT" "$DEBIAN_MIRROR"
fi
[ -x "$CHROOT/bin/bash" ] || { echo "$LOG_PREFIX chroot 不可用（$CHROOT/bin/bash 缺失）"; exit 1; }
# buster 已 EOL：关过期校验 + 固定 archive 源
cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb [check-valid-until=no trusted=yes] $DEBIAN_MIRROR buster main
EOF
mount --bind /proc "$CHROOT/proc" 2>/dev/null || true
mount --bind /sys  "$CHROOT/sys"  2>/dev/null || true
chroot "$CHROOT" dpkg --configure -a   # 半截现场自愈（debootstrap 崩过也能续）
if ! chroot "$CHROOT" command -v clang >/dev/null 2>&1; then
  echo "$LOG_PREFIX chroot 内装工具链（clang/ninja/cmake/GTK/gstreamer…）…"
  chroot "$CHROOT" apt-get update -qq
  chroot "$CHROOT" apt-get install -y -qq --no-install-recommends \
    git curl unzip xz-utils ca-certificates python3 python3-pip \
    clang ninja-build cmake pkg-config libgtk-3-dev libsecret-1-dev \
    libblkid-dev liblzma-dev libunwind-dev libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev libayatana-appindicator3-dev
fi
# buster 自带 cmake 3.13 过不了插件门槛（sqlite3_flutter_libs 要 ≥3.14，
# 2026-11-11 首跑实锤）。buster pip 18.1（pytoml 代）连 cmake 的 pyproject
# 都解析不了（二跑实锤）→ 官方自包含 tarball（自带 openssl，零系统依赖）。
CMAKE_OK=$(chroot "$CHROOT" /bin/bash -c 'cmake --version 2>/dev/null | head -1' | grep -oE "[0-9]+\.[0-9]+" | head -1 || true)
if [ -z "$CMAKE_OK" ] || [ "$(printf '%s\n3.14\n' "$CMAKE_OK" | sort -V | tail -1)" != "$CMAKE_OK" ]; then
  echo "$LOG_PREFIX 升级 chroot cmake（$CMAKE_OK → 官方 3.28 自包含 tarball）…"
  CV=3.28.6
  chroot "$CHROOT" wget -nv -T 60 -t 3 -O "/tmp/cmk.tar.gz" \
    "https://github.com/Kitware/CMake/releases/download/v${CV}/cmake-${CV}-linux-x86_64.tar.gz" \
    || chroot "$CHROOT" wget -nv -T 60 -t 3 -O "/tmp/cmk.tar.gz" \
    "https://mirrors.nju.edu.cn/github-release/Kitware/CMake/LatestRelease/cmake-${CV}-linux-x86_64.tar.gz" \
    || { echo "$LOG_PREFIX cmake tarball 下载失败（两个源都不通）"; exit 1; }
  chroot "$CHROOT" tar -xzf /tmp/cmk.tar.gz -C /opt
  chroot "$CHROOT" ln -sf "/opt/cmake-${CV}-linux-x86_64/bin/cmake" /usr/local/bin/cmake
  chroot "$CHROOT" rm -f /tmp/cmk.tar.gz
  chroot "$CHROOT" cmake --version | head -1
fi

# ---------------------------------------------------------------- 2 flutter
if [ ! -x "$CHROOT/opt/flutter/bin/flutter" ]; then
  echo "$LOG_PREFIX chroot 内装 Flutter $FLUTTER_VER（$FLUTTER_MIRROR）…"
  TB="flutter_linux_${FLUTTER_VER}-stable.tar.xz"
  chroot "$CHROOT" wget -q -O "/tmp/$TB" "$FLUTTER_MIRROR/flutter_infra_release/releases/stable/linux/$TB"
  chroot "$CHROOT" tar -xJf "/tmp/$TB" -C /opt
  chroot "$CHROOT" rm -f "/tmp/$TB"
fi

# ---------------------------------------------------------------- 3 编译
# 项目经 bind 进 chroot（drvfs 直接进 chroot 有权限/属性坑，拷进 chroot 最稳）
SRC="$CHROOT/root/wcbuild"
echo "$LOG_PREFIX 同步源码进 chroot（rsync 排除 build/、.dart_tool 本机产物）…"
chroot "$CHROOT" apt-get install -y -qq rsync >/dev/null 2>&1 || true
mkdir -p "$SRC"
rsync -a --delete --exclude 'build/' --exclude '.dart_tool/' --exclude '.idea/' \
  "$APP/" "$SRC/app/"
chroot "$CHROOT" bash -c "
  set -e
  export PUB_CACHE=/root/.pub-cache
  export FLUTTER_ROOT=/opt/flutter
  export PATH=/opt/flutter/bin:\$PATH
  export FLUTTER_STORAGE_BASE_URL=$FLUTTER_MIRROR
  export PUB_HOSTED_URL=https://pub.flutter-io.cn
  cd /root/wcbuild/app
  # 构建前清场（build-linux.sh 同款纪律）：上一轮 cmake configure 失败会留下
  # 半成品 CMakeCache 污染 bundle/，下一轮「✓ Built」照样出货错料（2026-11-11 实锤）。
  rm -rf build/linux
  flutter --version
  flutter config --no-analytics >/dev/null 2>&1 || true
  flutter pub get
  flutter build linux --release
"
OUT="$SRC/app/build/linux/x64/release/bundle"
[ -f "$OUT/wangcai" ] || { echo "$LOG_PREFIX 编译失败：$OUT/wangcai 不存在"; exit 1; }

# ---------------------------------------------------------------- 4 版本闸
echo "$LOG_PREFIX readelf 版本闸（上限 GLIBC_2.28 / GLIBCXX_3.4.25）…"
chroot "$CHROOT" apt-get install -y -qq binutils >/dev/null 2>&1 || true
FAIL=0
for f in $(cd "$OUT" && find . -name "*.so" -o -name "wangcai" | sed 's|^\./||'); do
  # 两路独立取最大（GLIBC_ 与 GLIBCXX_ 混合串排序会互相压制致漏检；
  # 模式 "GLIBC_[0-9.]+" 不会误吃 GLIBCXX_ ——X 不是下划线）。
  # || true 必备：libapp.so（Dart AOT）压根没有 GLIBC 版本化依赖，grep 空匹配
  # 在 pipefail 下会把「最干净的文件」变成杀脚本的凶手（2026-11-11 九跑实锤）。
  g=$(readelf -V "$OUT/$f" 2>/dev/null | grep -oE "GLIBC_[0-9.]+" | sed 's/GLIBC_//' | sort -V | tail -1 || true)
  c=$(readelf -V "$OUT/$f" 2>/dev/null | grep -oE "GLIBCXX_[0-9.]+" | sed 's/GLIBCXX_//' | sort -V | tail -1 || true)
  if [ -n "$g" ] && [ "$g" != "2.28" ] && [ "$(printf '%s\n2.28\n' "$g" | sort -V | tail -1)" != "2.28" ]; then
    echo "  ❌ $f 需要 GLIBC_$g"; FAIL=1
  fi
  if [ -n "$c" ] && [ "$c" != "3.4.25" ] && [ "$(printf '%s\n3.4.25\n' "$c" | sort -V | tail -1)" != "3.4.25" ]; then
    echo "  ❌ $f 需要 GLIBCXX_$c"; FAIL=1
  fi
done
[ "$FAIL" -eq 0 ] || { echo "$LOG_PREFIX 版本闸未过——老产物拒出厂"; exit 1; }
echo "$LOG_PREFIX 版本闸 ✅（全部 ≤ glibc 2.28 / GLIBCXX 3.4.25）"

# ---------------------------------------------------------------- 5 换料重出包
# glibc 向前兼容：buster 基线产物在 Ubuntu 22.04/24.04/DGX 上照跑（新系统跑老
# 基线无碍，反之即本次 UOS 事故）——官方 Linux 渠道统一走本通道，正式名出货。
echo "$LOG_PREFIX 用 buster bundle 重出官方 deb + tar…"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/opt/wangcai" "$STAGE/usr/bin" "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/icons/hicolor/512x512/apps" "$STAGE/DEBIAN"
cp -a "$OUT/." "$STAGE/opt/wangcai/"
ln -s /opt/wangcai/wangcai "$STAGE/usr/bin/wangcai"
# 启动黑匣子：Terminal=false 时启动器吞 stderr——动态链接期错误全落 launch.log
# （推理期 app.log 的启动期同族；本次 UOS「点击无反应」的直接元凶补眼）。
cat > "$STAGE/opt/wangcai/wangcai-launch.sh" <<'EOF'
#!/bin/sh
# 启动包装：stderr 落 launch.log（启动失败取证），stdout 留给终端调试。
d="${XDG_STATE_HOME:-$HOME/.local/state}/wangcai"
mkdir -p "$d" 2>/dev/null
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$dir/wangcai" "$@" 2>>"$d/launch.log"
EOF
chmod 755 "$STAGE/opt/wangcai/wangcai-launch.sh"
sed 's#Exec=/opt/wangcai/wangcai#Exec=/opt/wangcai/wangcai-launch.sh#' \
  "$REPO/packaging/linux/wangcai.desktop" > "$STAGE/usr/share/applications/wangcai.desktop"
cp "$REPO/app/assets/wangchai_logo.png" "$STAGE/usr/share/icons/hicolor/512x512/apps/wangcai.png"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: wangcai
Version: $VER
Section: utils
Priority: optional
Architecture: amd64
Depends: libgtk-3-0 | libgtk-3-0t64, libsecret-1-0, xclip | wl-clipboard, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, libayatana-appindicator3-1, libsqlite3-0 | libsqlite3-0t64, fonts-noto-cjk, fonts-noto-color-emoji
Maintainer: WangCai Team <wangcai@localhost>
Description: 汪柴 WangCai 端侧大模型聊天客户端
 汪柴（WangCai）端侧大模型聊天客户端。Linux 包为客户壳形态：
 模型引擎与生图服务走局域网/远端 HTTP，本地 NPU/OpenVINO 路径守卫降级。
 本包为 Debian 10 (glibc 2.28) 基线构建，兼容 UOS/Deepin 等老发行版。
EOF
dpkg-deb --root-owner-group --build "$STAGE" "$DIST/WangCai-$VER-linux-amd64.deb"
tar -C "$STAGE" -czf "$DIST/WangCai-$VER-linux-amd64.tar.gz" opt
sha256sum "$DIST/WangCai-$VER-linux-amd64.deb" "$DIST/WangCai-$VER-linux-amd64.tar.gz"
echo "$LOG_PREFIX DONE：dist 双产物（buster 基线，UOS/Deepin/Ubuntu/DGX 通用）"

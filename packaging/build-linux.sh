#!/usr/bin/env bash
# 汪柴 Linux 打包（deb + tar.gz 双产物，对齐 Windows 双产物口径）。
# WSL Ubuntu-22.04（x64）与 DGX Spark（arm64）通用：产物名按 dpkg 架构。
#
# 用法（推荐 ext4 工作区——/mnt/c、/mnt/e 跨 fs 构建慢一个数量级）：
#   rsync -a --delete --exclude .git --exclude /src --exclude build \
#         --exclude .dart_tool --exclude .acl-reports /mnt/e/DTXY/WangCai/ ~/wc-build/
#   注：/src 必须带斜杠锚定根目录——裸 src 会连 packages/*/lib/src 一起排掉
#   （2026-11-10 首包实案：plugin_kernel/lib/src 全缺 → 编译报一屏假错误）。
#   bash ~/wc-build/packaging/build-linux.sh
#   # 产物拷回：cp ~/wc-build/packaging/dist/WangCai-* /mnt/e/DTXY/WangCai/packaging/dist/
#
# 前置（一次性）：packaging/linux/wsl-setup.sh（apt 依赖 + Flutter 3.27）。
# 引擎不进 Linux 包：NPU/OpenVINO 按仓内口径 Linux 守卫降级，生图/引擎走
# LAN HTTP（docs/image-gen-integration-plan.md）。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/app"
ver="$(grep -m1 '^version:' "$app/pubspec.yaml" | sed -E 's/^version:[[:space:]]*([0-9.]+).*/\1/')"
arch="$(dpkg --print-architecture)"          # amd64 / arm64
case "$(uname -m)" in
  x86_64)  flarch=x64 ;;
  aarch64) flarch=arm64 ;;
  *)       flarch="$(uname -m)" ;;
esac
bundle="$app/build/linux/$flarch/release/bundle"
dist="$root/packaging/dist"

export PATH="${FLUTTER_DIR:-$HOME/flutter}/bin:$PATH"
command -v flutter >/dev/null || {
  echo "ERROR: flutter 不在 PATH（跑 packaging/linux/wsl-setup.sh 或 export PATH=\$HOME/flutter/bin:\$PATH）" >&2
  exit 1
}

echo "== 1/4 flutter build linux --release =="
# 清原生构建目录强走干净 configure：插件 configure 中途失败（如缺 -dev 包）会把
# CMakeCache 以默认 prefix=/usr/local 落盘，且 CMakeLists 里「prefix 默认 bundle」
# 分支位于 include(generated_plugins) 之后——污染缓存后续跑永远跳过该分支，
# install 直接往 /usr/local 写（2026-11-10 首包实案）。
rm -rf "$app/build/linux"
( cd "$app" && flutter pub get >/dev/null && flutter build linux --release ) ||
  { echo "ERROR: flutter build linux 失败" >&2; exit 1; }
[ -x "$bundle/wangcai" ] || { echo "ERROR: bundle 未产出：$bundle" >&2; exit 1; }

echo "== 2/4 tar.gz 便携包 =="
mkdir -p "$dist"
stage_t="$(mktemp -d)"
cp -a "$bundle" "$stage_t/WangCai-$ver-linux-$arch"
cat > "$stage_t/WangCai-$ver-linux-$arch/README-便携包.txt" <<EOF
汪柴 v$ver Linux 便携包（$arch）：解压后运行 WangCai-$ver-linux-$arch/wangcai。
首次运行需系统依赖：libgtk-3-0、libsecret-1-0、xclip 或 wl-clipboard、
gstreamer1.0-plugins-base/good（TTS/音频）、libayatana-appindicator3-1、libsqlite3-0、
fonts-noto-cjk（中文字体——缺了整个 UI 全是豆腐块，Ubuntu 基础镜像不带 CJK 字体）、
fonts-noto-color-emoji（emoji 字体——设置页分节头 🧠🧩⚡🤖 全用 emoji，缺了同样豆腐块）。
Linux 端为远端客户壳形态：本地 NPU/OpenVINO 引擎不支持（守卫降级），
模型引擎与生图服务请指向局域网/远端 HTTP（设置页配置）。
EOF
tar -C "$stage_t" -czf "$dist/WangCai-$ver-linux-$arch.tar.gz" "WangCai-$ver-linux-$arch"
rm -rf "$stage_t"

echo "== 3/4 deb =="
pkg="$(mktemp -d)"
mkdir -p "$pkg/opt/wangcai" "$pkg/usr/bin" "$pkg/usr/share/applications" \
         "$pkg/usr/share/icons/hicolor" "$pkg/DEBIAN"
cp -a "$bundle/." "$pkg/opt/wangcai/"
ln -s /opt/wangcai/wangcai "$pkg/usr/bin/wangcai"
cp "$root/packaging/linux/wangcai.desktop" "$pkg/usr/share/applications/wangcai.desktop"

# 图标：源 logo 按真实宽高挑 hicolor 档位（PNG IHDR 宽在偏移 16 起 4 字节，大端）。
logo="$app/assets/wangchai_logo.png"
if [ -f "$logo" ]; then
  w_hex="$(od -An -tx1 -j16 -N4 "$logo" | tr -d ' \n')"
  w=$((16#$w_hex))
  size=256
  for s in 16 24 32 48 64 96 128 256 512; do
    [ "$w" -le "$s" ] && { size=$s; break; }
    size=512
  done
  mkdir -p "$pkg/usr/share/icons/hicolor/${size}x${size}/apps"
  cp "$logo" "$pkg/usr/share/icons/hicolor/${size}x${size}/apps/wangcai.png"
fi

# Depends 用 t64 备选语法兼容 Ubuntu 22.04/24.04（DGX 24.04 实锤：libgtk-3-0
# 已改名 libgtk-3-0t64，只写旧名在 24.04 客户机 apt 解不开依赖装不上）。
cat > "$pkg/DEBIAN/control" <<EOF
Package: wangcai
Version: $ver
Section: utils
Priority: optional
Architecture: $arch
Depends: libgtk-3-0 | libgtk-3-0t64, libsecret-1-0, xclip | wl-clipboard, gstreamer1.0-plugins-base, gstreamer1.0-plugins-good, libayatana-appindicator3-1, libsqlite3-0 | libsqlite3-0t64, fonts-noto-cjk, fonts-noto-color-emoji
Maintainer: WangCai Team <wangcai@localhost>
Description: 汪柴 WangCai 端侧大模型聊天客户端
 汪柴（WangCai）端侧大模型聊天客户端。Linux 包为客户壳形态：
 模型引擎与生图服务走局域网/远端 HTTP，本地 NPU/OpenVINO 路径守卫降级。
EOF
dpkg-deb --build --root-owner-group "$pkg" "$dist/WangCai-$ver-linux-$arch.deb"
rm -rf "$pkg"

echo "== 4/4 校验和 =="
for f in "$dist/WangCai-$ver-linux-$arch.deb" "$dist/WangCai-$ver-linux-$arch.tar.gz"; do
  printf '%s  %s (%s MB)\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f" \
    "$(du -m "$f" | cut -f1)"
done
echo "DONE"

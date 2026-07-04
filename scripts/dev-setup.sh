#!/usr/bin/env bash
# 下载 OpenWrt SDK 并将本包链接进 SDK，用于编译 ipk。
# 需在 Linux 环境运行（物理机、虚拟机或 CI）。macOS 上请用 Linux VM / GitHub Actions。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.3}"
TARGET_PATH="${TARGET_PATH:-x86/64}"
SDK_DIR="${SDK_DIR:-$ROOT_DIR/openwrt-sdk}"

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "当前为 macOS，OpenWrt SDK 无法在本地直接编译。"
  echo "可选方案："
  echo "  1. 使用 scripts/deploy-to-router.sh 在路由器上热部署测试"
  echo "  2. 在 Linux VM / GitHub Actions 中运行本脚本"
  exit 1
fi

release_version="${OPENWRT_VERSION#v}"
sdk_url_prefix="https://downloads.openwrt.org/releases/${release_version}/targets/${TARGET_PATH}"

echo "查找 SDK: ${sdk_url_prefix}/"
sdk_filename="$(
  curl -fsSL "${sdk_url_prefix}/" \
    | grep -oE 'openwrt-sdk-[^"]+\.(tar\.xz|tar\.zst)' \
    | head -n1
)"

if [[ -z "${sdk_filename}" ]]; then
  echo "未找到 SDK，请检查 OPENWRT_VERSION / TARGET_PATH"
  exit 1
fi

tmp_archive="/tmp/${sdk_filename}"
if [[ ! -d "${SDK_DIR}" ]]; then
  echo "下载 ${sdk_filename} ..."
  curl -fSL "${sdk_url_prefix}/${sdk_filename}" -o "${tmp_archive}"
  mkdir -p "${SDK_DIR%/*}"
  case "${sdk_filename}" in
    *.tar.zst) tar --zstd -xf "${tmp_archive}" -C "${SDK_DIR%/*}" ;;
    *.tar.xz) tar -xf "${tmp_archive}" -C "${SDK_DIR%/*}" ;;
  esac
  extracted="$(find "${SDK_DIR%/*}" -maxdepth 1 -type d -name 'openwrt-sdk-*' | head -n1)"
  mv "${extracted}" "${SDK_DIR}"
  rm -f "${tmp_archive}"
fi

cd "${SDK_DIR}"

if [[ ! -d feeds/luci ]]; then
  ./scripts/feeds update luci
  ./scripts/feeds install -a -p luci
fi

pkg_link="${SDK_DIR}/package/luci-app-tailscale"
rm -rf "${pkg_link}"
ln -sfn "${ROOT_DIR}" "${pkg_link}"

cat <<EOF

SDK 已就绪: ${SDK_DIR}

下一步:
  cd ${SDK_DIR}
  make menuconfig   # 选中 LuCI -> Applications -> luci-app-tailscale
  make package/luci-app-tailscale/compile V=s

产物路径:
  bin/packages/*/luci/luci-app-tailscale_*.ipk

EOF

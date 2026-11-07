#!/usr/bin/env bash
# DIY part1：在 feeds update 之前执行
# 追加 feed、改默认 LAN IP、注入 Turbo ACC、预置 Clash Meta 内核
set -euo pipefail

SRC="${1:-.}"
cd "$SRC"

LAN_IP="${LAN_IP:-192.168.2.1}"
ENABLE_QUICKSTART="${ENABLE_QUICKSTART:-true}"
TURBOACC_MODE="${TURBOACC_MODE:-none}"
PREBUILT_CLASH_CORE="${PREBUILT_CLASH_CORE:-true}"
ROOTFS_PARTSIZE_MIB="${ROOTFS_PARTSIZE_MIB:-6144}"

echo "==================================================="
echo " DIY part1  源码: $SRC"
echo " LAN_IP=$LAN_IP  ENABLE_QUICKSTART=$ENABLE_QUICKSTART"
echo " TURBOACC_MODE=$TURBOACC_MODE  PREBUILT_CLASH_CORE=$PREBUILT_CLASH_CORE"
echo "==================================================="

# ------------------------------------------------------------------
# 1. feeds：官方 4 个 feed 保持 v24.10.6 锁定的 commit 不动
#    SmartDNS / OpenClash 已在官方 luci+packages feed 中，无需第三方源
#    iStore 商店与 quickstart 来自 linkease 三个 feed
# ------------------------------------------------------------------
echo "== [1/4] 追加 feeds =="
if grep -q 'src-git istore ' feeds.conf.default; then
  echo "  istore feed 已存在，跳过"
else
  {
    echo ""
    echo "# --- iStore 商店 / quickstart (linkease) ---"
    echo "src-git istore https://github.com/linkease/istore;main"
    if [ "$ENABLE_QUICKSTART" = "true" ]; then
      echo "src-git nas https://github.com/linkease/nas-packages.git;master"
      echo "src-git nas_luci https://github.com/linkease/nas-packages-luci.git;main"
    fi
  } >> feeds.conf.default
fi
cat feeds.conf.default

# ------------------------------------------------------------------
# 2. 默认 LAN IP（24.10 的 config_generate 里 lan 默认 192.168.1.1）
# ------------------------------------------------------------------
echo "== [2/4] 默认 LAN IP -> $LAN_IP =="
CFG_GEN="package/base-files/files/bin/config_generate"
[ -f "$CFG_GEN" ] || { echo "ERROR: $CFG_GEN 不存在"; exit 1; }
sed -i "s/192\.168\.1\.1/${LAN_IP}/g" "$CFG_GEN"
grep -n "lan) ipad" "$CFG_GEN" || { echo "ERROR: LAN IP 替换后未找到目标行"; exit 1; }

# ------------------------------------------------------------------
# 3. Turbo ACC 注入
#    - chenmozhijin-no-sfe：24.10 / 内核 6.6 / fw4 专用，--no-sfe 避开
#      Shortcut-FE 与 nftables 的已知不兼容；会替换 firewall4 / nftables /
#      libnftnl 三个核心包（见 README 冲突清单）
#    - mufeng05：面向 2026 年 snapshot/25.12 的新版组件，补丁版本与
#      24.10.6 的 firewall4 2024-12-18 / nftables 1.1.1 / libnftnl 1.2.8
#      不匹配，仅作为对照实验选项
#    - none：本次不内置
# ------------------------------------------------------------------
echo "== [3/4] Turbo ACC 注入模式: $TURBOACC_MODE =="
echo "  注入前组件版本："
for f in package/network/config/firewall4/Makefile \
         package/network/utils/nftables/Makefile \
         package/libs/libnftnl/Makefile; do
  echo "  --- $f"
  grep -E '^PKG_(SOURCE_DATE|SOURCE_VERSION|VERSION|RELEASE):=' "$f" || true
done

case "$TURBOACC_MODE" in
  chenmozhijin-no-sfe)
    if ! grep -q '^PKG_SOURCE_VERSION:=' package/network/config/firewall4/Makefile; then
      echo "  WARNING: 24.10.6 的 firewall4 Makefile 无 PKG_SOURCE_VERSION，"
      echo "           第三方脚本会 fallback 到它自带的 latest 版本，需重点核对编译日志。"
    fi
    curl -fsSL "https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh" \
      -o /tmp/add_turboacc.sh
    bash /tmp/add_turboacc.sh --no-sfe
    ;;
  mufeng05)
    curl -fsSL "https://raw.githubusercontent.com/mufeng05/turboacc/main/add_turboacc.sh" \
      -o /tmp/add_turboacc.sh
    bash /tmp/add_turboacc.sh
    ;;
  none)
    echo "  跳过 Turbo ACC 注入"
    ;;
  *)
    echo "ERROR: 未知 turboacc_mode=$TURBOACC_MODE"
    exit 1
    ;;
esac

# ------------------------------------------------------------------
# 4. 预置 Clash Meta(mihomo) 内核到 files/，随固件打包
#    取官方 latest release 中标准 amd64 包（排除 compatible / go120 / go123）
# ------------------------------------------------------------------
echo "== [4/4] 预置 Clash Meta 内核 =="
if [ "$PREBUILT_CLASH_CORE" = "true" ]; then
  API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
  ASSET=$(curl -fsSL "$API" | jq -r \
    '[.assets[].browser_download_url | select(test("mihomo-linux-amd64-v[0-9]+\\.[0-9]+\\.[0-9]+\\.gz$"))][0] // empty')
  if [ -z "$ASSET" ]; then
    ASSET=$(curl -fsSL "$API" | jq -r \
      '[.assets[].browser_download_url | select(test("mihomo-linux-amd64-v.*\\.gz$"))][0] // empty')
  fi
  if [ -z "$ASSET" ]; then
    echo "  WARNING: 未找到 mihomo amd64 资产，跳过预置（首次启动会自行下载）"
  else
    echo "  下载: $ASSET"
    mkdir -p files/etc/openclash/core
    curl -fsSL "$ASSET" -o /tmp/mihomo.gz
    gzip -dc /tmp/mihomo.gz > files/etc/openclash/core/clash_meta
    chmod 755 files/etc/openclash/core/clash_meta
    echo "  已预置: $(ls -lh files/etc/openclash/core/clash_meta)"
    file files/etc/openclash/core/clash_meta || true
  fi
else
  echo "  按输入开关跳过"
fi

# ------------------------------------------------------------------
# 把本次输入写给 part2，用于生成预检报告
# ------------------------------------------------------------------
cat > .diy_inputs <<EOF
LAN_IP=$LAN_IP
ENABLE_QUICKSTART=$ENABLE_QUICKSTART
TURBOACC_MODE=$TURBOACC_MODE
PREBUILT_CLASH_CORE=$PREBUILT_CLASH_CORE
ROOTFS_PARTSIZE_MIB=$ROOTFS_PARTSIZE_MIB
SOURCE_REF=${SOURCE_REF:-v24.10.6}
EOF

echo "== DIY part1 完成 =="

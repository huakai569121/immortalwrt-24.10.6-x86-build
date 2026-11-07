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
# 5. 首次启动 UCI 预置（对齐现网调参）
#    重要：故意不设 noresolv / server=127.0.0.1#7874。
#    新固件首次开机时 OpenClash 还没有订阅与规则，预置接管 DNS 会直接
#    把全网解析打死。DNS 主链路留到刷完后按现网备份恢复。
# ------------------------------------------------------------------
echo "== [5/5] 生成首次启动 uci-defaults =="
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom-dns <<'UCI'
#!/bin/sh
# 仅在首次启动执行一次；成功后 OpenWrt 会自动删除本文件

# --- dnsmasq：Fake-IP 198.18.x.x 需要关 rebind；LAN 无 IPv6 需过滤 AAAA ---
uci -q set dhcp.@dnsmasq[0].rebind_protection='0'
uci -q set dhcp.@dnsmasq[0].filter_aaaa='1'
uci -q commit dhcp

# --- SmartDNS：对齐现网调优，只监听 6053，不占 53、不接管主链路 ---
[ -n "$(uci -q get smartdns.@smartdns[0])" ] || uci add smartdns smartdns >/dev/null
uci -q set smartdns.@smartdns[0].enabled='1'
uci -q set smartdns.@smartdns[0].port='6053'
uci -q set smartdns.@smartdns[0].tcp_server='1'
uci -q set smartdns.@smartdns[0].speed_check_mode='tcp:443'
uci -q set smartdns.@smartdns[0].cache_size='65535'
uci -q set smartdns.@smartdns[0].prefetch_domain='1'
uci -q set smartdns.@smartdns[0].dualstack_ip_selection='0'
# 清掉默认上游后按现网重建（限速 20 次，避免极端情况下死循环）
i=0
while [ "$i" -lt 20 ] && uci -q delete smartdns.@server[0]; do i=$((i+1)); done
for s in "AliDNS 223.5.5.5 udp" "DNSPod 119.29.29.29 udp" "AliDoH doh.pub/dns-query https" "AliDoH2 dns.alidns.com/dns-query https"; do
  set -- $s
  uci add smartdns server >/dev/null
  uci -q set smartdns.@server[-1].name="$1"
  uci -q set smartdns.@server[-1].ip="$2"
  uci -q set smartdns.@server[-1].type="$3"
done
uci -q commit smartdns

# --- firewall：开启 Fullcone NAT（kmod-nft-fullcone 已内置，底包含 fw4 补丁）---
# 不预置 flow_offloading：留给用户按实测决定是否开启
uci -q set firewall.@defaults[0].fullcone='1'
uci -q commit firewall

exit 0
UCI
chmod 755 files/etc/uci-defaults/99-custom-dns
echo "  已生成: files/etc/uci-defaults/99-custom-dns"
echo "  说明: 未预置 noresolv / server=7874，避免首次开机 DNS 瘫痪"

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

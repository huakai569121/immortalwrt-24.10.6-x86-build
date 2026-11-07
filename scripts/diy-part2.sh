#!/usr/bin/env bash
# DIY part2：生成 .config、make defconfig、执行编译前冲突预检
# 只要有一项 FAIL 就 exit 1，workflow 不会进入 make download / make 编译
set -uo pipefail

SRC="${1:-.}"
SEED="${2:-config/seed.config}"
cd "$SRC"

ENABLE_QUICKSTART="${ENABLE_QUICKSTART:-true}"
TURBOACC_MODE="${TURBOACC_MODE:-none}"
ROOTFS_PARTSIZE_MIB="${ROOTFS_PARTSIZE_MIB:-6144}"
LAN_IP="${LAN_IP:-192.168.2.1}"
SOURCE_REF="${SOURCE_REF:-v24.10.6}"

REPORT="PREFLIGHT_REPORT.txt"
FAIL=0
: > "$REPORT"

log() { echo "$*" | tee -a "$REPORT"; }
ok()  { log "  [PASS] $*"; }
bad() { log "  [FAIL] $*"; FAIL=1; }
warn(){ log "  [WARN] $*"; }

log "=========================================================="
log " ImmortalWrt 24.10.6 x86_64 编译前冲突预检报告"
log " 生成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "=========================================================="
log ""
log "一、本次输入"
log "  底包 tag          : $SOURCE_REF"
log "  目标平台          : x86 / 64 (Generic, i3-6100T + PVE)"
log "  默认 LAN IP       : $LAN_IP"
log "  rootfs 分区       : ${ROOTFS_PARTSIZE_MIB} MiB"
log "  boot 分区         : 64 MiB"
log "  镜像              : squashfs + ext4 / BIOS + EFI / QCOW2"
log "  quickstart        : $ENABLE_QUICKSTART"
log "  Turbo ACC 方案    : $TURBOACC_MODE"
log ""

# ------------------------------------------------------------------
# 1. 生成 .config
# ------------------------------------------------------------------
log "二、生成 .config"
[ -f "$SEED" ] || { bad "seed 文件不存在: $SEED"; }
cp "$SEED" .config

sed -i "s/^CONFIG_TARGET_ROOTFS_PARTSIZE=.*/CONFIG_TARGET_ROOTFS_PARTSIZE=${ROOTFS_PARTSIZE_MIB}/" .config
if [ "$ENABLE_QUICKSTART" != "true" ]; then
  sed -i '/^CONFIG_PACKAGE_luci-app-quickstart=y$/d' .config
  log "  按开关移除 luci-app-quickstart"
fi
if [ "$TURBOACC_MODE" = "none" ]; then
  sed -i '/^CONFIG_PACKAGE_luci-app-turboacc=y$/d' .config
  log "  按开关移除 luci-app-turboacc"
fi

make defconfig > /tmp/defconfig.log 2>&1 || { bad "make defconfig 执行失败"; tail -n 50 /tmp/defconfig.log | tee -a "$REPORT"; }
log "  make defconfig 完成"
log ""

# ------------------------------------------------------------------
# 2. 目标与镜像开关
# ------------------------------------------------------------------
log "三、目标平台 / 镜像开关（defconfig 后的实际值）"
check_y() {
  local key="$1" desc="$2"
  if grep -q "^${key}=y" .config; then ok "$desc ($key=y)"; else bad "$desc 未启用 ($key)"; fi
}
check_y "CONFIG_TARGET_x86"            "Target x86"
check_y "CONFIG_TARGET_x86_64"         "Subtarget x86/64"
check_y "CONFIG_TARGET_ROOTFS_SQUASHFS" "squashfs 镜像"
check_y "CONFIG_TARGET_ROOTFS_EXT4FS"  "ext4 镜像"
check_y "CONFIG_GRUB_IMAGES"           "BIOS/GRUB combined 镜像"
check_y "CONFIG_GRUB_EFI_IMAGES"       "EFI combined 镜像"
check_y "CONFIG_QCOW2_IMAGES"          "QCOW2 镜像（PVE 直接导入）"
check_y "CONFIG_TARGET_IMAGES_GZIP"    "镜像 gzip 输出（控制 runner 磁盘峰值）"

PARTSIZE=$(sed -n 's/^CONFIG_TARGET_ROOTFS_PARTSIZE=//p' .config)
KERNELSIZE=$(sed -n 's/^CONFIG_TARGET_KERNEL_PARTSIZE=//p' .config)
log "  实际分区: boot=${KERNELSIZE} MiB, rootfs=${PARTSIZE} MiB"
if [ "$PARTSIZE" = "$ROOTFS_PARTSIZE_MIB" ]; then
  ok "rootfs 分区与输入一致"
  # squashfs 固件本体约占 300~600 MiB，估算 overlay 净可用
  OVERLAY_MIN=$((PARTSIZE - 600))
  if [ "$OVERLAY_MIN" -ge 5120 ]; then
    ok "squashfs overlay 净可用保守估计 >= ${OVERLAY_MIN} MiB (>= 5 GiB 要求)"
  else
    bad "rootfs 分区 ${PARTSIZE} MiB 扣除固件本体后 overlay 可能不足 5 GiB，请调大"
  fi
else
  bad "rootfs 分区被 defconfig 改写为 $PARTSIZE"
fi
log ""

# ------------------------------------------------------------------
# 3. 编译前冲突检查
# ------------------------------------------------------------------
log "四、冲突检查"

log "  [C1] dnsmasq / dnsmasq-dhcpv6 / dnsmasq-full 互斥 (三者 PROVIDES:=dnsmasq)"
if grep -q '^CONFIG_PACKAGE_dnsmasq=y' .config; then
  bad "dnsmasq 仍被选中，会与 dnsmasq-full 冲突（OpenClash 依赖 dnsmasq-full）"
else ok "dnsmasq 已禁用"; fi
if grep -q '^CONFIG_PACKAGE_dnsmasq-dhcpv6=y' .config; then
  bad "dnsmasq-dhcpv6 仍被选中，会与 dnsmasq-full 冲突"
else ok "dnsmasq-dhcpv6 已禁用"; fi
if grep -q '^CONFIG_PACKAGE_dnsmasq-full=y' .config; then
  ok "dnsmasq-full 已启用"
else bad "dnsmasq-full 未启用，OpenClash 依赖不满足"; fi

log "  [C2] Turbo ACC 与内核 / 防火墙组件"
case "$TURBOACC_MODE" in
  none)
    warn "本次不内置 Turbo ACC（无内核补丁，无防火墙替换）"
    ;;
  chenmozhijin-no-sfe)
    if [ -d package/turboacc/luci-app-turboacc ]; then
      ok "Turbo ACC 包已注入 package/turboacc/luci-app-turboacc"
    else
      bad "Turbo ACC 包目录不存在，注入脚本可能失败"
    fi
    warn "该方案会替换 firewall4 / nftables / libnftnl 三个核心包"
    warn "已使用 --no-sfe：不打 Shortcut-FE/Fast Classifier 加速引擎（与 fw4/nftables 不兼容）"
    ;;
  mufeng05)
    if [ -d package/turboacc/luci-app-turboacc ]; then
      ok "Turbo ACC 包已注入"
    else bad "Turbo ACC 包目录不存在"; fi
    warn "该分支 rebased 补丁面向 firewall4 2026-10 / nftables 1.1.7 / libnftnl 1.3.2"
    warn "24.10.6 实际为 firewall4 2024-12-18 / nftables 1.1.1 / libnftnl 1.2.8"
    warn "补丁版本不匹配，且脚本不支持 --no-sfe，会强行打 953 SFE / Broadcom fullcone 内核补丁"
    ;;
esac
log "  [C3] 内核版本"
KVER=$(grep -E '^KERNEL_PATCHVER:=' target/linux/x86/Makefile | cut -d= -f2)
log "  x86 KERNEL_PATCHVER = $KVER"
if [ -d "target/linux/generic/hack-$KVER" ]; then ok "generic/hack-$KVER 目录存在"; else bad "generic/hack-$KVER 缺失"; fi

log "  [C4] iStore 商店依赖 libuci-lua / luci-compat"
if [ -f package/system/uci/Makefile ] && grep -q 'define Package/libuci-lua' package/system/uci/Makefile; then
  ok "libuci-lua 由 package/system/uci 提供"
else bad "libuci-lua 包定义未找到，iStore 商店依赖无法满足"; fi

log "  [C5] Flow Offload 与 OpenClash TProxy（运行时冲突，非编译期）"
warn "Turbo ACC 的流量卸载与 OpenClash 的 TProxy 模式可能互相干扰"
warn "固件不预置开启 flow offload，请二者择一使用（见 README）"
log ""

# ------------------------------------------------------------------
# 4. 点名插件解析结果（defconfig 后仍为 =y 才说明 feed + 依赖都 OK）
# ------------------------------------------------------------------
log "五、点名插件在 defconfig 后的解析结果"
PACKAGES="luci luci-app-openclash smartdns luci-app-smartdns luci-app-store dnsmasq-full"
[ "$ENABLE_QUICKSTART" = "true" ] && PACKAGES="$PACKAGES luci-app-quickstart"
[ "$TURBOACC_MODE" != "none" ]    && PACKAGES="$PACKAGES luci-app-turboacc"
for p in $PACKAGES; do
  if grep -q "^CONFIG_PACKAGE_${p}=y" .config; then
    ok "$p 已选中"
  else
    bad "$p 未选中 —— feed 缺失或依赖不满足，请检查上方 defconfig 输出"
  fi
done
log ""
log "六、feed 清单"
while read -r line; do log "  $line"; done < <(grep '^src-' feeds.conf.default)
log ""

# ------------------------------------------------------------------
# 5. 结论
# ------------------------------------------------------------------
log "=========================================================="
if [ "$FAIL" -eq 0 ]; then
  log " 预检结论: PASS —— 未发现阻断性冲突，可以进入编译"
else
  log " 预检结论: FAIL —— 存在阻断项，workflow 已停止，不会开始编译"
fi
log "=========================================================="

if [ "$FAIL" -ne 0 ]; then exit 1; fi

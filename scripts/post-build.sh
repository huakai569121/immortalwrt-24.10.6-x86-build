#!/usr/bin/env bash
# 编译完成后整理产物、校验镜像齐全、生成校验和与构建信息
set -uo pipefail

SRC="${1:-.}"
OUT="$SRC/bin/targets/x86/64"
cd "$OUT" || { echo "ERROR: 产物目录不存在 $OUT"; exit 1; }

echo "== 产物目录: $OUT =="
ls -lh

echo ""
echo "== 镜像齐全性检查 =="
EXPECT=(
  "*squashfs-combined.img.gz"
  "*squashfs-combined-efi.img.gz"
  "*ext4-combined.img.gz"
  "*ext4-combined-efi.img.gz"
  "*combined-efi.qcow2"
)
for pat in "${EXPECT[@]}"; do
  # shellcheck disable=SC2086
  if ls $pat >/dev/null 2>&1; then
    echo "  [OK]   $pat"
  else
    echo "  [MISS] $pat  (未生成，请查看编译日志)"
  fi
done

echo ""
echo "== 生成 SHA256SUMS =="
sha256sum *.img.gz *.qcow2 2>/dev/null > SHA256SUMS || true
cat SHA256SUMS

echo ""
echo "== 生成 BUILD_INFO.txt =="
{
  echo "ImmortalWrt 24.10.6 x86_64 定制固件"
  echo "构建时间      : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "底包          : ${SOURCE_REF:-v24.10.6} (immortalwrt/immortalwrt)"
  echo "目标          : x86 / 64 Generic (i3-6100T 物理机 + PVE)"
  echo "分区          : boot 64 MiB + rootfs ${ROOTFS_PARTSIZE_MIB:-6144} MiB"
  echo "              squashfs 固件本体占用分区前部，其余为 overlay 可写空间(>=5 GiB)"
  echo "默认 LAN IP   : ${LAN_IP:-192.168.2.1}"
  echo ""
  echo "内置插件："
  echo "  luci-app-quickstart (向导)  : ${ENABLE_QUICKSTART:-true}"
  echo "  luci-app-store (iStore 商店): 是"
  echo "  smartdns + luci-app-smartdns: 是"
  echo "  luci-app-openclash          : 是 (预置 Clash Meta 内核)"
  echo "  luci-app-turboacc           : ${TURBOACC_MODE:-none} (本次确认不内置)"
  echo "  中文语言包 / luci-compat    : 是"
  echo ""
  echo "冲突处理："
  echo "  dnsmasq / dnsmasq-dhcpv6 已禁用，使用 dnsmasq-full (PROVIDES 互斥)"
  echo "  Turbo ACC 不启用 SFE/Fast Classifier (与 fw4/nftables 不兼容)"
  echo "  未预置开启 flow offload；与 OpenClash TProxy 请择一使用"
  echo ""
  echo "镜像说明："
  echo "  *combined.img.gz          BIOS/Legacy + squashfs 或 ext4"
  echo "  *combined-efi.img.gz      UEFI/GPT   + squashfs 或 ext4 (PVE OVMF / 6100T UEFI 推荐)"
  echo "  *combined-efi.qcow2       PVE qm importdisk 直接导入"
  echo ""
  echo "产物清单："
  ls -lh *.img.gz *.qcow2 2>/dev/null | sed 's/^/  /'
} > BUILD_INFO.txt
cat BUILD_INFO.txt

echo ""
echo "== 磁盘占用 =="
df -h / || true

# ImmortalWrt 24.10.6 x86_64 定制固件编译工程

面向 **i3-6100T 物理机** 与 **PVE 虚拟机**。本仓库只存放 GitHub Actions 编译配置，不含 ImmortalWrt 源码。

> 当前状态：**工程已就绪，未推送、未触发任何编译**。
> 已确认（2026-11-07）：**本次不内置 Turbo ACC**（`turboacc_mode=none`），规避内核补丁冲突。
> 还需你提供 GitHub PAT 后才会创建仓库 / 推送 / 先跑预检。

## 一、方案概览

| 项目 | 取值 |
|---|---|
| 底包 | `immortalwrt/immortalwrt` tag `v24.10.6`（feeds 锁定 commit，可复现） |
| 内核 | Linux 6.6（`target/linux/x86/Makefile` 的 `KERNEL_PATCHVER`） |
| 目标 | x86 / 64 Generic |
| 默认 LAN | `192.168.2.1`（匹配现有 192.168.2.x 内网） |
| 分区 | boot 64 MiB + rootfs 6144 MiB。squashfs 固件本体占分区前部约 300~600 MiB，其余为 overlay 可写空间，**净可用 > 5 GiB** |
| 镜像 | 一次编译产出 4 份 combined（squashfs / ext4 × BIOS / EFI，均为 `.img.gz`）+ EFI QCOW2 |
| 内置插件 | quickstart 向导、iStore 商店、SmartDNS + LuCI、OpenClash；**Turbo ACC 本次不内置**（按确认跳过） |
| 附加 | 中文语言包、luci-compat、dnsmasq-full、预置 Clash Meta 内核 |

插件来源（已逐个核验）：

| 插件 | 来源 |
|---|---|
| `luci-app-openclash` 0.47.156 | 官方 `immortalwrt/luci` openwrt-24.10 feed（无需第三方源） |
| `smartdns` / `luci-app-smartdns` | 官方 `immortalwrt/packages` + `immortalwrt/luci` feed |
| `luci-app-store` / `taskd` / `luci-lib-taskd` | `linkease/istore;main` |
| `quickstart` 核心 | `linkease/nas-packages;master` → `network/services/quickstart` |
| `luci/luci-app-quickstart` | `linkease/nas-packages-luci;main`；依赖 `+quickstart +luci-app-store` |
| `luci-app-turboacc` | 第三方注入（官方 24.10 feed 无此包），见冲突 C2~C5 |
| Clash Meta 内核 | `MetaCubeX/mihomo` 最新 release 的 `mihomo-linux-amd64-v*.gz` |

## 二、编译前冲突清单

> **已确认结论：本次 `turboacc_mode=none`，C2~C5 全部规避** —— 不打任何内核补丁、不替换 firewall4 / nftables / libnftnl。
> 下表保留完整核查记录，供以后单独加入 Turbo ACC 时参考；C1、C6~C10 仍然适用。

| 编号 | 冲突 / 风险 | 核查证据 | 处理方式 |
|---|---|---|---|
| **C1** | `dnsmasq`、`dnsmasq-dhcpv6`、`dnsmasq-full` 三者均声明 `PROVIDES:=dnsmasq`，互斥；OpenClash 硬依赖 `dnsmasq-full` | `package/network/services/dnsmasq/Makefile` 第 61、72 行 | seed 中显式 `# CONFIG_PACKAGE_dnsmasq is not set` + `# CONFIG_PACKAGE_dnsmasq-dhcpv6 is not set`，只选 dnsmasq-full；预检会复查 |
| **C2** | Turbo ACC 不在 ImmortalWrt 24.10 官方 luci / packages feed | 两个 feed 的 24.10 tree 均无此包 | 必须第三方注入，因此带来 C3~C5 |
| **C3 ⚠ 需决策** | 新版 `mufeng05/turboacc` 的 rebased 补丁面向 firewall4 2026-10 / nftables 1.1.7 / libnftnl 1.3.2；而 **24.10.6 实际是 firewall4 `PKG_SOURCE_DATE:=2024-12-18` / nftables 1.1.1 / libnftnl 1.2.8**。脚本的 `find_best_pkg_patch_dir` 只选「≤ 实际版本」的补丁目录，全部不匹配 → 退回 lede 旧补丁，大概率打补丁失败；且该脚本不支持 `--no-sfe`，会强行注入 953 SFE / Broadcom fullcone 内核补丁 | 两侧 Makefile 与 turboacc 仓库 tree 对比 | **默认不用这个分支**。workflow 保留 `mufeng05` 仅作对照实验 |
| **C4 ⚠ 需决策** | Shortcut-FE / Fast Classifier 依赖 iptables 时代的 conntrack chain events，**与 firewall4 / nftables 不兼容** | turboacc 项目 README 明确说明 | 采用 `chenmozhijin/turboacc` 的 `luci` 分支 + `--no-sfe`（面向 24.10 / 内核 6.6 / fw4），只保留 Flow Offloading 与兼容模式 Fullcone NAT |
| **C5 ⚠ 需决策** | `chenmozhijin` 方案会 `rm -rf` 并整体替换官方 `firewall4` / `nftables` / `libnftnl` 三个核心包；脚本按 `PKG_SOURCE_VERSION` 匹配自带存档，而 24.10.6 的 firewall4 Makefile **没有**该字段，会 fallback 到自带 latest 版本 → 存在与 ImmortalWrt 定制补丁不匹配的可能 | 脚本第 106/110/124 行 + 24.10.6 Makefile | 预检会检查注入结果；若编译失败，把 `turboacc_mode` 设为 `none` 重跑即可保住其余插件。**也可以本次先不内置 Turbo ACC** |
| **C6** | Turbo ACC 的软件流量卸载（flow offload）与 OpenClash 的 TProxy 透明代理在运行时会互相干扰 | 既有排障经验 + 社区共识 | 固件**不预置开启** flow offload；使用时二者择一（见第四节） |
| **C7** | quickstart 在 24.10 上有「编译成功但开机异常」的社区案例；其依赖链会拉起 `parted / mdadm / smartmontools / smartd / e2fsprogs / shadow-utils` 等 15+ 包，明显增加编译体积与时间 | quickstart Makefile `DEPENDS`；恩山 2025-08 案例 | 提供 `enable_quickstart` 开关，出问题可关闭重跑（iStore 商店不受影响） |
| **C8** | SmartDNS 与 dnsmasq-full 都默认监听 53 端口 | 运行时配置冲突，非编译期 | 首次启动把 SmartDNS 设为上游（如 6053/5335），dnsmasq 转发过去；或反过来让 SmartDNS 作为主 DNS。见第四节 |
| **C9** | 「overlay 5G」≠「rootfs 分区 5G」：squashfs 固件本体也占同一分区 | `scripts/gen_image_generic.sh` 的 PADDING 逻辑 | 分区设为 6144 MiB，扣除本体后净可用仍 > 5 GiB |
| **C10** | GitHub 免费 runner 为 2 核 / 7 GB / 单 job 上限 6 小时；6 GiB 分区镜像生成时需临时落盘 | runner 规格 | `free-disk-space` 释放空间、镜像由编译系统直接输出 `.img.gz`（不保留裸 img）、`timeout-minutes: 350`、提供 `preflight_only` 先跑预检 |

## 三、如何触发（**必须先确认冲突再执行**）

1. 在 Actions → `ImmortalWrt 24.10.6 x86_64 定制固件` → Run workflow。
2. **第一次务必勾上 `preflight_only=true`**：只做 clone、feeds、defconfig 与冲突预检，产出 `PREFLIGHT_REPORT.txt`，不下载源码包、不编译（约 10~20 分钟）。
3. 看报告结论为 `PASS` 且冲突处理方式你认可后，再取消勾选跑正式编译。

| 输入 | 默认 | 说明 |
|---|---|---|
| `preflight_only` | false | 只跑预检，不编译 |
| `turboacc_mode` | **`none`** | 本次确认不内置；`chenmozhijin-no-sfe` / `mufeng05` 仅备用（C3~C5） |
| `enable_quickstart` | true | 关掉可规避 C7 |
| `prebuilt_clash_core` | true | 预置 mihomo 内核，避免首次启动联网下载失败 |
| `rootfs_partsize_mib` | 6144 | 调大可扩 overlay，但会增大 runner 磁盘压力 |
| `lan_ip` | 192.168.2.1 | 默认 LAN 地址 |
| `source_ref` | v24.10.6 | 底包 tag |

预检报告会逐项打印 PASS / FAIL：目标平台、四种镜像开关、分区与 overlay 净空间、dnsmasq 互斥、Turbo ACC 注入结果、内核版本、libuci-lua 可用性、以及每个点名插件在 `make defconfig` 之后是否仍被选中（feed 缺失或依赖不满足会被这一步抓出来）。**只要有一项 FAIL，workflow 立即停止，不会进入编译阶段。**

## 四、产物与装机

产物目录 `bin/targets/x86/64/`，最终作为 Actions artifact 上传：

- `*-squashfs-combined.img.gz`：BIOS/Legacy，支持恢复出厂
- `*-squashfs-combined-efi.img.gz`：**推荐**，UEFI/GPT
- `*-ext4-combined.img.gz` / `*-ext4-combined-efi.img.gz`：rootfs 直接可写，便于扩容，无重置
- `*-combined-efi.qcow2`：PVE 直接导入
- `SHA256SUMS`、`BUILD_INFO.txt`

**PVE（UEFI / OVMF 推荐）**

```bash
gunzip -c immortalwrt-*-squashfs-combined-efi.img.gz > /tmp/immortalwrt.img
qm importdisk <VMID> /tmp/immortalwrt.img local-lvm
# 把导入的磁盘设为 boot 盘，BIOS 选 OVMF(UEFI)，磁盘给 15G
```

也可直接用 `*-combined-efi.qcow2`，省去转换。

**i3-6100T 物理机**：`gunzip -c ...img.gz | dd of=/dev/sdX bs=4M conv=sync`，主板开 UEFI 启动。写盘前务必确认设备名。

**首次启动后建议**

1. LAN 已是 `192.168.2.1`，若与现有网关并存请先改 IP 或断开现有网关，避免 DHCP 冲突。
2. 立刻设置 root 密码（固件未预置密码）。
3. SmartDNS 与 dnsmasq-full 二选一占用 53：常用做法是 SmartDNS 监听 6053 作上游，dnsmasq 转发到 `127.0.0.1#6053`；也可把 SmartDNS 设为主 DNS 并关掉 dnsmasq 的 DNS 功能。
4. OpenClash 已预置 Meta 内核，仍需下载 GeoIP/GeoSite 数据库与订阅配置。
5. **不要同时开 Turbo ACC 的 Flow Offload 与 OpenClash TProxy**；要开流量卸载就把 OpenClash 改用 Redirect / 兼容模式并实测。
6. 15G 磁盘里镜像只占约 6G，剩余空间可在系统内用 `cfdisk` 新建分区挂到 `/data`，或后期扩容 overlay。

## 五、已知风险与降级顺序

1. 本次已跳过 Turbo ACC（C3~C5）。以后要加入时先用 `preflight_only` 预检，失败即 `turboacc_mode=none` 重跑。
2. quickstart 导致开机异常（C7）→ `enable_quickstart=false` 重跑。
3. 编译超过 6 小时 → 改用 PVE 上的 self-hosted runner（`runs-on: self-hosted`），本机编译不受 6 小时与磁盘配额限制。
4. 需要额外插件 → 编辑 `config/seed.config`，加 `CONFIG_PACKAGE_xxx=y`，重新跑预检确认依赖可解析。

## 六、GitHub PAT 权限

若由 AI 代为创建仓库并触发编译，需要你提供 Personal Access Token：

- **推荐 classic PAT**，勾选 `repo` + `workflow`（修改 `.github/workflows` 必须有 `workflow` scope，创建私有/公开仓库需要 `repo`）。
- 或者你先手工新建一个**空公开仓库**并告知仓库名，则 fine-grained PAT 给 `Contents: read/write` + `Actions: read/write` + `Metadata: read` 即可。
- token 仅在本次会话内用于 GitHub API 调用，**不会写入本仓库任何文件**；编译结束后建议立即撤销。

# XG-040G-MF OpenWrt 编译仓库

用于把 **Nokia XG-040G-MF**（Airoha AN7583DT）编译成一台带 PON 光口功能的 OpenWrt 路由器。

所有内容基于公开的 [`pbs05/ponwrt`](https://github.com/pbs05/ponwrt)，不依赖任何私有源码。

---

## 目录结构

```
.
├── .github/workflows/build-mf.yml   # GitHub Actions 编译流程
├── configs/
│   ├── an7583.config                # ponwrt 官方 an7583 基线（含 mf 与 mf-ubi 两个 profile）
│   └── mf-extras.config             # 本仓库的增量配置（PON 包、工具、可选项）
├── files/                           # rootfs 覆盖层：从原厂 MD 固件导出的 ONU 管理界面
├── tools/
│   └── preflash-dump.sh             # 刷前体检脚本（纯只读，生成状态快照）
└── README.md
```

---

## 状态与待办

### 1. 一个 GitHub 仓库（唯一阻塞项）

编译在 GitHub Actions 上跑（本机没有 Linux 环境，且 OpenWrt 全量编译要 40GB 以上）。

两种方式任选：

- **你把本目录推到你的空仓库**（`git init && git add -A && git commit -m init && git push`），然后在仓库页面点 Actions → Build OpenWrt for Nokia XG-040G-MF → Run workflow。
- **把仓库地址和 PAT 给我**，我直接推。

### 2. 软件源（保持 ponwrt 默认）

`ponwrt` 的 feeds 指向 **ImmortalWrt** 的 `packages` 与 `luci`（不是 OpenWrt 官方源）：

```
src-git packages https://github.com/immortalwrt/packages.git
src-git luci     https://github.com/immortalwrt/luci.git
src-git pon_drivers    https://github.com/pbs05/openwrt-pon-drivers.git
src-git pon_userspace  https://github.com/pbs05/openwrt-pon-userspace.git
```

如果你更希望用 OpenWrt 官方源，告诉我，我改 `feeds.conf.default`。

### 3. 可选包（已确认）

用途：**光猫 + 路由**，外加一个全局去广告包。对应 `configs/mf-extras.config`：

- 第四节已启用 `adblock-fast` + `luci-app-adblock-fast` + 中文语言包
- 第五节其余可选项（openclash / samba / ksmbd / vlmcsd / rtp2httpd / usb-printer）全部关闭

> adblock-fast 走 **nftset 模式**（基线配置里 `dnsmasq-full` 已开 `dnsmasq_full_nftset=y`），
> 命中规则由 nftables 直接拦，不靠改 hosts，性能损耗可以忽略。

### 4. 原厂备份（已具备）

`bosa` 与 `ri` 已有备份。补一条核对建议：若方便，把原厂 `cat /proc/mtd` 贴一下，
用于确认你这批次的 NAND 颗粒与 `bl2` 大小是否和 DTS 的 `reg = <0x20000 0xffe0000>` 一致。
**不同批次的 MF 换过颗粒**，这一步能在刷之前发现问题。

---

## 怎么跑

### GitHub Actions（推荐）

1. Actions → **Build OpenWrt for Nokia XG-040G-MF** → Run workflow
2. 参数保持默认（`ponwrt_ref=master`，`release_tag` 留空）
3. 约 2–4 小时后，在 artifact `xg040g-mf-images` 里下载

首次编译大概率会因某个包的源码下载 404 失败，重点看 `make download` 那一步的日志，重跑一次通常就好（镜像缓存已建立）。

### 本地 Linux

```bash
sudo apt install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison \
  build-essential bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar \
  flex gawk gettext gcc-multilib g++-multilib git gnutls-dev gperf haveged help2man \
  intltool lib32gcc-s1 libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev libltdl-dev \
  libmpc-dev libmpfr-dev libncurses-dev libpython3-dev libreadline-dev libssl-dev \
  libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano ninja-build p7zip-full \
  patch pkgconf python3 python3-pip python3-ply python3-docutils python3-pyelftools \
  qemu-utils re2c rsync scons squashfs-tools subversion swig texinfo uglifyjs upx-ucl \
  unzip vim wget xmlto xxd zlib1g-dev zstd

git clone --depth 1 https://github.com/pbs05/ponwrt.git openwrt
cd openwrt
./scripts/feeds update -a && ./scripts/feeds install -a
cp ../configs/an7583.config .config
cat ../configs/mf-extras.config >> .config
make defconfig
mkdir -p files && cp -a ../files/. files/
make download -j8
make -j$(nproc)
```

---

## 产物说明

生成于 `bin/targets/airoha/an7583/`：

| 文件 | 用途 |
|---|---|
| `*-nokia_xg-040g-mf-ubi-squashfs-sysupgrade.itb` | **日常刷写/升级用这个** |
| `*-nokia_xg-040g-mf-ubi-preloader.bin` | 首次刷 U-Boot，TTL + XMODEM 灌入 |
| `*-nokia_xg-040g-mf-ubi-bl31-uboot.fip` | 首次刷 U-Boot，TTL + XMODEM 灌入 |
| `*-nokia_xg-040g-mf-ubi-initramfs-recovery.itb` | 救砖用内存系统 |
| `*-nokia_xg-040g-mf-squashfs-factory-kernel.bin` / `factory-rootfs.bin` | 非 UBI 布局变体（一般不用） |

---

## 刷机顺序（已刷第三方 Web-U-Boot 的情况）

> 前提：MF 已刷 [Loong1996/ImmortalWrt-Airoha](https://github.com/Loong1996/ImmortalWrt-Airoha) 的
> 魔改 OpenWrt U-Boot（`ubi` 变体，带网页救砖），即分区已是 `bl2`(128 KiB) + `ubi`(255.875 MiB)。

**本固件与那套 U-Boot 兼容**，原因有三：

1. 分区布局完全一致 —— ponwrt 与该项目都用 `bl2 @0x0` + `ubi @0x20000`；
2. 卷名一致 —— `fit` / `fip` / `ubootenv` / `ubootenv2` / `bosa` / `ri`；
3. 镜像格式一致 —— 都是标准 FIT（kernel + fdt + rootfs），load 地址 `0x80200000`。

### 当前设备状态（已确认）

刷 U-Boot 时**已经勾过一次「重建 UBI」**，所以现在设备里的 `bosa` 与 `ri` 卷是空的：

| 项 | 现状 | 后果 |
|---|---|---|
| `ri` 卷 | 空 | 网口 MAC 变成随机值（`02:xx:xx:xx:xx:xx`），部分运营商拒绝发 IP |
| `bosa` 卷 | 空 | 光模块无校准数据，PON 无法上线或功率异常 |

原始数据都在本地备份里（`mtd6_bosa.bin`、`mtd7_ri.bin`、`mtd16_all_flash.bin`），刷完固件按下面第 6 步写回即可。**这不是不可逆的损坏。**

### 第 0 步：刷前体检（必做，5 分钟）

刷之前先把当前系统的状态存一份。**这一步不能跳过**，原因很实在：

| 要解决的问题 | 没有基线会怎样 |
|---|---|
| 刷完如果起不来，怎么判断卡在哪 | 不知道刷之前 `bootcmd` 指向什么，只能瞎猜 |
| 刷完如果 MAC 不对 / 光口不通 | 没有「刷之前是什么样」的对照，分不清是固件问题还是校准问题 |
| `bosa`/`ri` 卷现在到底是不是空的 | 只能靠推测。实测一次就有确定答案 |
| NAND 坏块在哪 | 如果坏块正好压在 `fit` 卷上，第一次启动可能失败一次 |

脚本在本仓库 `tools/preflash-dump.sh`，**纯只读**，只会在设备 `/tmp` 下生成一个文本报告，不碰任何分区、不写任何卷、不改 U-Boot 环境变量。

**跑法（Windows 上推荐这两步，最稳）：**

```powershell
scp tools\preflash-dump.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1 sh /tmp/preflash-dump.sh
```

跑完屏幕上会直接打印「关键结论摘要」这一节，然后：

```powershell
scp root@192.168.1.1:/tmp/preflash-dump.txt .
```

> ⚠️ 别用 PowerShell 的 `<` 重定向写法（`ssh ... "sh -s" < script.sh`）——PowerShell 5.1 不支持输入重定向，会直接报语法错。上面这两条 `scp` + `ssh` 没有这个问题。

**报告里最该看的三行：**

```
bootcmd           : ubi read ... fit; bootm ...     ← 指向 fit 卷，刷完能自动启动
当前 br-lan MAC   : e0:3d:a6:9e:b6:bf               ← 说明 ri 卷里还有数据
  bosa : 存在   ubi0_4   data_bytes=0               ← data_bytes=0 才是空卷
```

- `bootcmd` 如果指向 `http`/`web`，说明默认进网页模式，刷完要手动点一次启动（不致命）
- MAC 是 `02:` 开头 → `ri` 确实是空的，写回一步不能省
- `bosa` 的 `data_bytes` 大于 0 → 卷里居然还有数据，那刷完可能不用写（但保险起见还是写一遍）

把 `preflash-dump.txt` 取回来之后发我，我逐项核对，给你一份**针对这台机器**的精确刷机顺序，而不是通用模板。

### 第 1 步：刷写固件

刷写步骤：

1. 网线接 LAN 口，浏览器打开 Web-U-Boot 页面
2. 左栏「**日常刷机**」里选 `...-nokia_xg-040g-mf-ubi-squashfs-sysupgrade.itb`
3. 点「上传并刷写」
4. **不要勾「重建 UBI」** —— 已经重建过了，再建一次只会又擦一遍，没有任何好处
5. 页面会核对文件名里的机型与 `/info` 的 model 是否一致，一致才显示绿框

> ⚠️ 网页 U-Boot 只接受 **`-ubi-squashfs-sysupgrade.itb`**，不要传 `-initramfs-recovery.itb`（那是内存救援系统，不能当系统刷）。

### 第 2 步：写回 bosa 与 ri（必做）

固件里已内置 `restore-pon-identity.sh`（`/usr/sbin/`），会自动补建缺失的卷、把容量对齐到 LEB 整数倍、写完回读比对 md5。

```sh
# 1. 传两个备份上去
scp mtd6_bosa.bin mtd7_ri.bin root@192.168.1.1:/tmp/

# 2. 登录后先看状态
ssh root@192.168.1.1
restore-pon-identity.sh --check
#    bosa : 卷存在(/dev/ubi0_4, 372480 字节)，内容为空
#    ri   : 卷存在(/dev/ubi0_5, 372480 字节)，内容为空

# 3. 写入（脚本会逐个校验）
restore-pon-identity.sh /tmp/mtd6_bosa.bin /tmp/mtd7_ri.bin

# 4. 必须重启，驱动在启动时才读 bosa
reboot
```

如果系统起不来、只能在网页 U-Boot 里操作，用救砖页的「**按卷写入**」分别写 `bosa` 和 `ri`，效果相同。

### 第 3 步：刷机后的三项验证

```sh
ip link show br-lan        # MAC 必须是 E0:3D:A6:9E:B6:BF
ponctl status              # 或 LuCI「ONU 状态」，看收发光功率是否在正常范围
dmesg | grep -i "en7572\|pon"   # 光前端是否成功 probe
```

**光功率那一条不能跳过。** 能上网不代表校准读对了 —— 校准缺失的典型表现是「能注册但速率上不去」或「高峰期反复掉线」，而不是直接断网。


---

## 已知缺口

| 项目 | 状态 |
|---|---|
| `luci-app-onu`（原厂那套上网/IPTV/语音/诊断界面） | 已从你的 MD 固件完整导出，放在 `files/`，随固件一起打包 |
| 全局去广告 | `adblock-fast` 已编入，LuCI → 服务 → AdBlock Fast，首次使用需在页面里「启用」并下载订阅列表 |
| 语音页面 | MF 没有 FXS 接口（无 `/dev/en75xx-fxs0`），该页会显示无设备，属正常 |
| USB | AN7583 在 OpenWrt 下暂不支持，驱动已编入，等上游修 |
| 内核版本 | ponwrt master 为 `KERNEL_PATCHVER:=6.18`，与你原固件的 6.18.55 同系列 |
| 与 Loong1996 那套固件的关系 | 引导层兼容（同布局同卷名同 FIT 格式）；但该项目的 master 分支**不带 PON 栈**（仅 `xpon-test` 实验分支有），所以本仓库仍以 ponwrt 为源码基础 |

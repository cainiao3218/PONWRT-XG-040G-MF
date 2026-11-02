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
└── README.md
```

---

## 需要你配合的 4 件事

### 1. 提供一个 GitHub 仓库

编译在 GitHub Actions 上跑（本机没有 Linux 环境，且 OpenWrt 全量编译要 40GB 以上）。

两种方式任选：

- **你把本目录推到你的空仓库**（`git init && git add -A && git commit -m init && git push`），然后在仓库页面点 Actions → Build OpenWrt for Nokia XG-040G-MF → Run workflow。
- **把仓库地址和 PAT 给我**，我直接推。

### 2. 确认软件源

`ponwrt` 的 feeds 指向 **ImmortalWrt** 的 `packages` 与 `luci`（不是 OpenWrt 官方源）：

```
src-git packages https://github.com/immortalwrt/packages.git
src-git luci     https://github.com/immortalwrt/luci.git
src-git pon_drivers    https://github.com/pbs05/openwrt-pon-drivers.git
src-git pon_userspace  https://github.com/pbs05/openwrt-pon-userspace.git
```

如果你更希望用 OpenWrt 官方源，告诉我，我改 `feeds.conf.default`。

### 3. 选定可选包

MF 是 **2×A53 @1.2 GHz + 512 MiB**，跑不动一整套全家桶。`configs/mf-extras.config` 第四节列了可选项，默认全关。建议：

| 用途 | 建议 |
|---|---|
| 只当光猫 + 路由 | 全关（默认就是） |
| 需要科学上网 | 只开 `luci-app-openclash`，别开 samba |
| 需要局域网共享 | 只开 `luci-app-ksmbd`，别开 clash |
| 需要 IPTV 组播 | 开 `rtp2httpd`（很轻，推荐） |

### 4. 提供原厂备份信息（防砖，不是编译必需）

- `bosa` 与 `ri` 的 dump 文件（你已有，刷完机要写回去）
- 原厂 `cat /proc/mtd` 输出
- 原厂 U-Boot 环境变量（`fw_printenv` 或串口里 `printenv`）

用途：核对 MF 的 `bl2` 大小与 `ubi` 起始偏移是否和 DTS 里的 `reg = <0x20000 0xffe0000>` 一致。**不同批次的 MF 有换过 NAND 的情况**，这一步能提前发现雷。

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

## 刷机顺序

> ⚠️ 下列步骤**只适用于 MF**。MD 的教程（tcboot 那一套）不适用，套错直接变砖。

1. **备份**：TTL 进 U-Boot，确认 `bosa`、`ri` 两个卷已备份到你手上
2. **刷引导**（若已是第三方 U-Boot 可跳过）：
   - 断电按住 Reset 上电，出现 `Press X` 时按 `X`
   - XMODEM 传 `*-preloader.bin`
   - 再按 `X`，XMODEM 传 `*-bl31-uboot.fip`
3. **重建 UBI**：网线接 LAN，浏览器开 `http://192.168.0.1/`，点"重建 UBI 分区"
4. **恢复校准**：先写 `bosa`，再写 `ri`（顺序不要反）
5. **刷固件**：上传 `*-sysupgrade.itb`，或之后在 LuCI 里直接升级

---

## 已知缺口

| 项目 | 状态 |
|---|---|
| `luci-app-onu`（原厂那套上网/IPTV/语音/诊断界面） | 已从你的 MD 固件完整导出，放在 `files/`，随固件一起打包 |
| 语音页面 | MF 没有 FXS 接口（无 `/dev/en75xx-fxs0`），该页会显示无设备，属正常 |
| USB | AN7583 在 OpenWrt 下暂不支持，驱动已编入，等上游修 |
| 内核版本 | ponwrt master 为 `KERNEL_PATCHVER:=6.18`，与你原固件的 6.18.55 同系列 |

#!/bin/sh
# =============================================================================
# XG-040G-MF 刷前体检 / 状态快照
#
# 性质：纯只读。不改任何分区、不写任何卷、不动 U-Boot 环境变量。
#       唯一的写操作是在 /tmp 下生成一个文本报告。
#
# 用法一（推荐，本地一行搞定，不用 scp 往返）：
#     ssh root@192.168.1.1 'sh -s' < tools/preflash-dump.sh
#
# 用法二（先传到设备再跑）：
#     scp tools/preflash-dump.sh root@192.168.1.1:/tmp/
#     ssh root@192.168.1.1 sh /tmp/preflash-dump.sh
#
# 产出：设备上 /tmp/preflash-dump.txt
#      scp root@192.168.1.1:/tmp/preflash-dump.txt .
# =============================================================================

OUT=/tmp/preflash-dump.txt
: > "$OUT"

sec() {
    echo "" >> "$OUT"
    echo "===== $* =====" >> "$OUT"
}

have() { command -v "$1" >/dev/null 2>&1; }

run() {
    _title="$1"; _cmd="$2"
    sec "$_title"
    sh -c "$_cmd" < /dev/null >> "$OUT" 2>&1 || echo "(执行失败: $_cmd)" >> "$OUT"
}

# -----------------------------------------------------------------------------
# 1. 系统身份
# -----------------------------------------------------------------------------
sec "1. 系统身份"
{
    echo "采集时间   : $(date 2>/dev/null || echo unknown)"
    echo "内核       : $(uname -a 2>/dev/null)"
} >> "$OUT"
run "/etc/openwrt_release"            "cat /etc/openwrt_release 2>/dev/null"
run "/etc/os-release（前 6 行）"       "head -6 /etc/os-release 2>/dev/null"
run "运行时长 / 负载"                  "uptime 2>/dev/null"

# -----------------------------------------------------------------------------
# 2. 物理分区表（重建 UBI 后应只剩 bl2 + ubi）
# -----------------------------------------------------------------------------
run "2. /proc/mtd（物理分区）"         "cat /proc/mtd 2>/dev/null"
run "/proc/partitions"                "cat /proc/partitions 2>/dev/null"

# -----------------------------------------------------------------------------
# 3. UBI 设备概况（PEB 总数、可用、坏块）
# -----------------------------------------------------------------------------
sec "3. UBI 设备概况"
if [ -r /sys/class/ubi/ubi0/total_pebs ]; then
    {
        echo "total_pebs      : $(cat /sys/class/ubi/ubi0/total_pebs 2>/dev/null)"
        echo "avail_pebs      : $(cat /sys/class/ubi/ubi0/avail_pebs 2>/dev/null)"
        echo "reserved_pebs   : $(cat /sys/class/ubi/ubi0/reserved_pebs 2>/dev/null)"
        echo "bad_peb_count   : $(cat /sys/class/ubi/ubi0/bad_peb_count 2>/dev/null)"
        echo "eraseblock_size : $(cat /sys/class/ubi/ubi0/eraseblock_size 2>/dev/null)"
        echo "max_vol_count   : $(cat /sys/class/ubi/ubi0/max_vol_count 2>/dev/null)"
    } >> "$OUT"
else
    echo "(没有 /sys/class/ubi/ubi0，UBI 未挂载或未启用)" >> "$OUT"
fi

# -----------------------------------------------------------------------------
# 4. ubinfo -a 完整输出（含每个卷的卷号、大小、Data bytes）
# -----------------------------------------------------------------------------
sec "4. ubinfo -a"
if have ubinfo; then
    ubinfo -a >> "$OUT" 2>&1 || echo "(ubinfo 执行失败)" >> "$OUT"
else
    echo "(设备上没有 ubinfo，改用 /sys 遍历)" >> "$OUT"
    for d in /sys/class/ubi/ubi0_*; do
        [ -e "$d" ] || continue
        echo "--- $(basename "$d") name=$(cat "$d/name" 2>/dev/null)" >> "$OUT"
        echo "    data_bytes=$(cat "$d/data_bytes" 2>/dev/null)" >> "$OUT"
        echo "    reserved_ebs=$(cat "$d/reserved_ebs" 2>/dev/null)" >> "$OUT"
        echo "    usable_eb_size=$(cat "$d/usable_eb_size" 2>/dev/null)" >> "$OUT"
    done
fi

# -----------------------------------------------------------------------------
# 5. 卷名 ↔ 设备号映射（写回 bosa/ri 时要用这个）
# -----------------------------------------------------------------------------
sec "5. 卷名映射（卷号 → 名字 → 是否为空）"
for d in /sys/class/ubi/ubi0_*; do
    [ -e "$d" ] || continue
    _dev=$(basename "$d")
    _name=$(cat "$d/name" 2>/dev/null)
    _bytes=$(cat "$d/data_bytes" 2>/dev/null)
    if [ "$_bytes" = "0" ]; then
        _state="空"
    else
        _state="有数据 ${_bytes} 字节"
    fi
    printf '  %-12s %-14s %s\n' "$_dev" "$_name" "$_state" >> "$OUT"
done

# -----------------------------------------------------------------------------
# 6. U-Boot 环境变量（最关键：bootcmd 决定刷完会不会自动启动）
# -----------------------------------------------------------------------------
sec "6. U-Boot 环境变量"
if have fw_printenv; then
    fw_printenv < /dev/null >> "$OUT" 2>&1 || echo "(fw_printenv 执行失败，可能没有 /etc/fw_env.config)" >> "$OUT"
else
    echo "(设备上没有 fw_printenv，无法从系统内读取 U-Boot 环境)" >> "$OUT"
    echo " fallback: 尝试从 /dev/mtd 直接找 ubootenv 卷" >> "$OUT"
    for f in /etc/fw_env.config /etc/uboot-envtools.conf; do
        [ -r "$f" ] && { echo "--- $f ---" >> "$OUT"; cat "$f" >> "$OUT"; }
    done
fi

# -----------------------------------------------------------------------------
# 7. 引导参数
# -----------------------------------------------------------------------------
run "7. /proc/cmdline"                "cat /proc/cmdline 2>/dev/null"
run "/proc/device-tree/model"         "cat /proc/device-tree/model 2>/dev/null; echo"
run "/proc/device-tree/compatible"    "tr '\\0' '\\n' < /proc/device-tree/compatible 2>/dev/null"

# -----------------------------------------------------------------------------
# 8. 网络接口与 MAC（判断 ri 卷是否已被写回）
# -----------------------------------------------------------------------------
run "8. ip -br link"                  "ip -br link 2>/dev/null || ifconfig -a 2>/dev/null"
run "br-lan 的 MAC"                   "cat /sys/class/net/br-lan/address 2>/dev/null"
run "所有网口 MAC"                     "for i in /sys/class/net/*/address; do echo \"\$(basename \$(dirname \$i)) \$(cat \$i)\"; done"

# -----------------------------------------------------------------------------
# 9. NAND / UBI / MTD 内核日志（坏块、擦除、ubi 挂载过程）
# -----------------------------------------------------------------------------
run "9. dmesg | nand/ubi/mtd"         "dmesg 2>/dev/null | grep -iE 'nand|ubi|mtd|spi-nand|ecc' | tail -60"
run "dmesg 中的错误"                   "dmesg 2>/dev/null | grep -iE 'error|fail|bad|corrupt|timeout' | tail -30"

# -----------------------------------------------------------------------------
# 10. PON 现状（刷完后的对照基线）
# -----------------------------------------------------------------------------
run "10. PON 相关 dmesg"              "dmesg 2>/dev/null | grep -iE 'en7572|en7570|xpon|pon|econet|airoha' | tail -40"
run "PON 设备节点"                     "ls -l /dev 2>/dev/null | grep -iE 'pon|en75|fxs'"
run "PON 相关模块"                     "lsmod 2>/dev/null | grep -iE 'airoha|en75|pon'"
run "ponctl 是否存在"                  "command -v ponctl; command -v pond; command -v pon"
run "ponctl status（如果存在）"         "command -v ponctl >/dev/null 2>&1 && timeout 10 ponctl status 2>&1"

# -----------------------------------------------------------------------------
# 11. 挂载与空间
# -----------------------------------------------------------------------------
run "11. df -h"                       "df -h 2>/dev/null"
run "mount | ubi/overlay"             "mount 2>/dev/null | grep -iE 'ubi|overlay|rootfs'"

# -----------------------------------------------------------------------------
# 12. 关键结论摘要（自动生成，先看这一段）
# -----------------------------------------------------------------------------
sec "12. 关键结论摘要"

_vols=$(ls -d /sys/class/ubi/ubi0_* 2>/dev/null | wc -l)
echo "卷总数            : $_vols" >> "$OUT"

for _v in bosa ri ubootenv ubootenv2 fit fip; do
    _p=$(ls -d /sys/class/ubi/ubi0_* 2>/dev/null | while read -r d; do
            [ "$(cat "$d/name" 2>/dev/null)" = "$_v" ] && echo "$d"
         done | head -1)
    if [ -n "$_p" ]; then
        echo "  $_v : 存在   $(basename "$_p")   data_bytes=$(cat "$_p/data_bytes" 2>/dev/null)" >> "$OUT"
    else
        echo "  $_v : 【缺失】" >> "$OUT"
    fi
done

_bad=$(cat /sys/class/ubi/ubi0/bad_peb_count 2>/dev/null)
[ -n "$_bad" ] && echo "坏块数            : $_bad" >> "$OUT"

_mac=$(cat /sys/class/net/br-lan/address 2>/dev/null)
[ -n "$_mac" ] && echo "当前 br-lan MAC   : $_mac" >> "$OUT"
case "$_mac" in
    e0:3d:a6:*) echo "  → 与原厂 ri 中的 MAC 同前缀，说明 ri 已有数据" >> "$OUT" ;;
    02:*)       echo "  → 本地管理地址（随机），说明 ri 卷是空的，刷完必须写回" >> "$OUT" ;;
    "")         echo "  → 读不到 br-lan，可能接口名不同" >> "$OUT" ;;
esac

_bootcmd=$(fw_printenv bootcmd 2>/dev/null | sed 's/^bootcmd=//')
if [ -n "$_bootcmd" ]; then
    echo "bootcmd           : $_bootcmd" >> "$OUT"
    case "$_bootcmd" in
        *fit*)     echo "  → 指向 fit 卷，刷完应能自动启动" >> "$OUT" ;;
        *http*|*web*) echo "  → 默认进网页模式，刷完需手动点启动" >> "$OUT" ;;
        *)         echo "  → 未识别，需人工确认" >> "$OUT" ;;
    esac
fi

echo "" >> "$OUT"
echo "===== 报告结束 =====" >> "$OUT"

# -----------------------------------------------------------------------------
# 输出
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo " 体检完成，报告已生成：$OUT"
echo " 行数：$(wc -l < "$OUT")"
echo "=============================================="
echo ""
echo "--- 摘要预览 ---"
sed -n '/12. 关键结论摘要/,$p' "$OUT" | head -25
echo ""
echo "把这份报告取回本地（在你自己的电脑上执行，不是在设备上）："
_ip=$(ip -4 addr show br-lan 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -1)
[ -z "$_ip" ] && _ip=192.168.1.1
echo "  scp root@$_ip:$OUT ."
echo ""

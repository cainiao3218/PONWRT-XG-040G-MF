#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# restore-pon-identity.sh — 向 Nokia XG-040G 写回光模块校准(bosa)与设备身份(ri)
#
# 用于「重建 UBI 之后 bosa/ri 卷为空」的恢复场景。会自动补建缺失的卷、
# 调整卷容量到 LEB 整数倍、写入后回读比对 md5。
#
# 用法:
#   restore-pon-identity.sh /tmp/mtd6_bosa.bin /tmp/mtd7_ri.bin
#   restore-pon-identity.sh bosa.bin ri.bin --force     # 卷内已有数据时强制覆盖
#   restore-pon-identity.sh --check                     # 只检查当前状态，不写入
#
# 写完必须重启才生效：驱动在启动时读取 bosa 校准数据。

set -u

BOSA_SIZE=262144
RI_SIZE=262144
UBI_DEV=/dev/ubi0

log()  { echo "[restore] $*" >&2; }
warn() { echo "[restore] 警告: $*" >&2; }
die()  { echo "[restore] 错误: $*" >&2; exit 1; }

# ---------------------------------------------------------------- 基础检查

[ -n "${1:-}" ] || { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

CHECK_ONLY=0
FORCE=0
ARGS=""
for a in "$@"; do
    case "$a" in
        --check) CHECK_ONLY=1 ;;
        --force|-f) FORCE=1 ;;
        *) ARGS="$ARGS $a" ;;
    esac
done

[ -c "$UBI_DEV" ] || die "$UBI_DEV 不存在，UBI 没有挂载或设备不是 UBI 布局"

# LEB 大小（找不到就按 124K 兜底）
LEB=$(ubinfo "$UBI_DEV" 2>/dev/null | sed -n 's/.*LEB size: *\([0-9]*\).*/\1/p' | head -1)
[ -n "$LEB" ] && [ "$LEB" -gt 0 ] 2>/dev/null || LEB=126976
log "UBI 设备 $UBI_DEV, LEB 大小 $LEB 字节"

# ---------------------------------------------------------------- 卷工具

vol_name_of() {   # $1=/sys/class/ubi/ubi0_N  输出卷名
    [ -r "$1/name" ] || return 1
    cat "$1/name"
}

find_vol() {      # $1=卷名  输出 ubi0_N，找不到返回 1
    for d in /sys/class/ubi/ubi0_*; do
        [ -d "$d" ] || continue
        [ "$(vol_name_of "$d" 2>/dev/null)" = "$1" ] && { basename "$d"; return 0; }
    done
    return 1
}

vol_bytes() {     # $1=ubi0_N  输出卷容量字节数
    ubinfo "/dev/$1" 2>/dev/null \
        | sed -n 's/.*Size: *[0-9]* *LEBs *(\([0-9]*\) bytes.*/\1/p' | head -1
}

# ---------------------------------------------------------------- 状态检查

status_of() {     # $1=卷名  $2=期望字节数
    name=$1; want=$2
    if v=$(find_vol "$name"); then
        sz=$(vol_bytes "$v")
        # 取前 want 字节判断是否全空（全 0xFF 或全 0x00 视为空）
        nz=$(dd if="/dev/$v" bs=4096 count=$(( (want + 4095) / 4096 )) 2>/dev/null \
             | od -An -tx1 -v | tr ' ' '\n' | grep -vc '^\(ff\|00\)$')
        if [ "${nz:-0}" -eq 0 ]; then
            echo "  $name : 卷存在(/dev/$v, ${sz:-?} 字节)，内容为空"
        else
            echo "  $name : 卷存在(/dev/$v, ${sz:-?} 字节)，含有效数据($nz 个非空字节)"
        fi
    else
        echo "  $name : 卷不存在"
    fi
}

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "当前 bosa / ri 状态:"
    status_of bosa "$BOSA_SIZE"
    status_of ri   "$RI_SIZE"
    echo
    echo "光口相关:"
    [ -d /sys/class/net ] && ls /sys/class/net | tr '\n' ' ' && echo
    command -v ponctl >/dev/null 2>&1 && { ponctl status 2>/dev/null | head -20 || true; }
    exit 0
fi

# ---------------------------------------------------------------- 写入

set -- $ARGS
[ $# -ge 2 ] || die "需要两个参数: <bosa.bin> <ri.bin>"

write_vol() {
    name=$1; src=$2; want=$3

    [ -f "$src" ] || die "找不到文件: $src"
    actual=$(wc -c < "$src" | tr -d ' ')
    [ "$actual" -eq "$want" ] || die "$src 大小 $actual 字节，应为 $want 字节"

    srcmd5=$(md5sum "$src" | cut -d' ' -f1)

    if v=$(find_vol "$name"); then
        log "卷 $name 已存在: /dev/$v"
        cur=$(vol_bytes "$v")
        if [ "${cur:-0}" -lt "$want" ] 2>/dev/null; then
            log "  容量 ${cur:-0} < $want，扩展中..."
            ubirsvol "$UBI_DEV" -N "$name" -s "$want" >/dev/null 2>&1 \
                || warn "扩展失败，继续尝试写入"
        elif [ "$FORCE" -ne 1 ]; then
            nz=$(dd if="/dev/$v" bs=4096 count=1 2>/dev/null | od -An -tx1 -v \
                 | tr ' ' '\n' | grep -vc '^\(ff\|00\)$')
            if [ "${nz:-0}" -gt 0 ]; then
                warn "卷 $name 已有非空数据，未加 --force 时默认覆盖（这是你要的场景）"
            fi
        fi
    else
        want_lebs=$(( (want + LEB - 1) / LEB ))
        log "卷 $name 不存在，创建 (${want_lebs} LEB = $((want_lebs * LEB)) 字节)"
        ubimkvol "$UBI_DEV" -N "$name" -s "$want" >/dev/null 2>&1 \
            || die "创建卷 $name 失败（可能空间不足）"
        v=$(find_vol "$name") || die "创建后仍找不到卷 $name"
    fi

    log "写入 $src -> /dev/$v ..."
    ubiupdatevol "/dev/$v" "$src" || die "写入 $name 失败"

    # 回读校验
    backmd5=$(dd if="/dev/$v" bs=4096 count=$(( (want + 4095) / 4096 )) 2>/dev/null \
              | head -c "$want" | md5sum | cut -d' ' -f1)
    if [ "$backmd5" = "$srcmd5" ]; then
        log "校验通过 ($srcmd5)"
    else
        die "校验失败! 源 $srcmd5 / 设备 $backmd5"
    fi
}

log "===== 写回 bosa（光模块校准）====="
write_vol bosa "$1" "$BOSA_SIZE"

log "===== 写回 ri（序列号 + MAC）====="
write_vol ri "$2" "$RI_SIZE"

log "全部完成。检查结果:"
status_of bosa "$BOSA_SIZE"
status_of ri   "$RI_SIZE"

cat >&2 <<'EOF'

[restore] 现在必须重启才能生效：
[restore]   reboot
[restore] 重启后验证：
[restore]   ip link show br-lan      # MAC 应为 E0:3D:A6:9E:B6:BF
[restore]   ponctl status            # 或 LuCI「ONU 状态」看收发光功率
EOF

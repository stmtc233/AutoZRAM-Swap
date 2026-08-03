#!/usr/bin/env bash

# ============================================================
# Linux ZRAM + Swap 一键配置脚本
#
# 功能：
#   1. 自动计算 ZRAM 与磁盘 Swap 大小
#   2. 清理现有 ZRAM Swap 设备
#   3. 禁用常见的旧 ZRAM 服务和配置
#   4. 停用现有磁盘 Swap
#   5. 删除旧 Swap 文件
#   6. 移除 /etc/fstab 中旧的 Swap 配置
#   7. 创建新的 ZRAM 和 /swapfile
#   8. 支持重复运行
#
# 注意：
#   - 会停用系统中已有的 Swap 分区，但不会格式化或擦除分区。
#   - 会删除旧的普通 Swap 文件。
#   - 所有关键配置会备份到 /root/zram-swap-backup-*。
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'

trap 'echo "❌ 执行失败：第 ${LINENO} 行：${BASH_COMMAND}" >&2' ERR

# =========================
# 可调整参数
# =========================

SWAP_FILE="${SWAP_FILE:-/swapfile}"

# ZRAM 占物理内存的百分比
ZRAM_PERCENT="${ZRAM_PERCENT:-50}"

# 是否删除发现的旧 Swap 文件：
# 1 = 删除
# 0 = 仅停用
DELETE_OLD_SWAP_FILES="${DELETE_OLD_SWAP_FILES:-1}"

# ZRAM 和磁盘 Swap 优先级
ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"
DISK_SWAP_PRIORITY="${DISK_SWAP_PRIORITY:-10}"

BACKUP_DIR="/root/zram-swap-backup-$(date +%Y%m%d-%H%M%S)"
REMOVED_SWAP_LOG="$BACKUP_DIR/removed-swap.txt"

# =========================
# 基础检查
# =========================

if [[ "${EUID}" -ne 0 ]]; then
    echo "❌ 请使用 root 用户或 sudo 运行此脚本。"
    exit 1
fi

if [[ ! -d /run/systemd/system ]]; then
    echo "❌ 当前系统似乎没有使用 systemd。"
    exit 1
fi

REQUIRED_COMMANDS=(
    awk
    blkid
    chmod
    dd
    df
    findmnt
    grep
    mkswap
    modprobe
    stat
    swapoff
    swapon
    systemctl
    zramctl
)

for command_name in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "❌ 缺少必要命令：$command_name"
        exit 1
    fi
done

mkdir -p "$BACKUP_DIR"
touch "$REMOVED_SWAP_LOG"
chmod 700 "$BACKUP_DIR"

echo "=========================================="
echo "开始配置 ZRAM 和磁盘 Swap"
echo "配置备份目录：$BACKUP_DIR"
echo "=========================================="

# =========================
# 辅助函数
# =========================

is_active_swap() {
    local target="$1"

    awk 'NR > 1 {print $1}' /proc/swaps |
        grep -Fxq -- "$target"
}

backup_path() {
    local source_path="$1"
    local target_path

    if [[ ! -e "$source_path" && ! -L "$source_path" ]]; then
        return 0
    fi

    target_path="${BACKUP_DIR}${source_path}"

    mkdir -p "$(dirname "$target_path")"
    cp -a -- "$source_path" "$target_path"

    echo "📦 已备份：$source_path"
}

move_to_backup() {
    local source_path="$1"
    local target_path

    if [[ ! -e "$source_path" && ! -L "$source_path" ]]; then
        return 0
    fi

    target_path="${BACKUP_DIR}${source_path}"

    mkdir -p "$(dirname "$target_path")"
    mv -- "$source_path" "$target_path"

    echo "📦 已移走旧配置：$source_path"
}

normalize_device_path() {
    local device="$1"

    if [[ "$device" == /dev/* ]]; then
        printf '%s\n' "$device"
    else
        printf '/dev/%s\n' "$device"
    fi
}

# =========================
# 获取内存并计算容量
# =========================

TOTAL_MEM_KB="$(
    awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo
)"

if [[ -z "$TOTAL_MEM_KB" || "$TOTAL_MEM_KB" -le 0 ]]; then
    echo "❌ 无法获取物理内存大小。"
    exit 1
fi

TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
ZRAM_MB=$((TOTAL_MEM_MB * ZRAM_PERCENT / 100))

# 避免极小内存系统得到 0 MB
if [[ "$ZRAM_MB" -lt 64 ]]; then
    ZRAM_MB=64
fi

if [[ "$TOTAL_MEM_MB" -lt 2048 ]]; then
    SWAP_MB=$((TOTAL_MEM_MB * 2))
elif [[ "$TOTAL_MEM_MB" -lt 8192 ]]; then
    SWAP_MB="$TOTAL_MEM_MB"
else
    SWAP_MB=8192
fi

TARGET_SWAP_BYTES=$((SWAP_MB * 1024 * 1024))

echo "✅ 检测到物理内存：${TOTAL_MEM_MB} MB"
echo "📊 新 ZRAM 大小：${ZRAM_MB} MB"
echo "📊 新 Swap 文件：${SWAP_MB} MB"
echo

# =========================
# 备份现有配置
# =========================

backup_path /etc/fstab
backup_path /etc/sysctl.d/99-zram-swap.conf
backup_path /etc/systemd/system/zram-auto.service
backup_path /usr/local/sbin/zram-auto-start
backup_path /usr/local/sbin/zram-auto-stop
backup_path /usr/local/bin/zram-start.sh
backup_path /usr/local/bin/zram-stop.sh

# =========================
# 停止旧 ZRAM 服务
# =========================

echo "⏳ 正在停止旧 ZRAM 服务..."

# 停止本脚本以前创建的服务
systemctl disable --now zram-auto.service >/dev/null 2>&1 || true

# 停止常见第三方 ZRAM 服务
CONFLICTING_SERVICES=(
    zramswap.service
    zram-swap.service
    zram-config.service
    zram.service
)

for service_name in "${CONFLICTING_SERVICES[@]}"; do
    systemctl disable --now "$service_name" >/dev/null 2>&1 || true
done

# 停止 systemd-zram-generator 创建的实例
while read -r service_name; do
    [[ -n "$service_name" ]] || continue

    systemctl stop "$service_name" >/dev/null 2>&1 || true
done < <(
    systemctl list-units \
        --all \
        --type=service \
        --no-legend \
        'systemd-zram-setup@*.service' 2>/dev/null |
        awk '{print $1}'
)

# =========================
# 移除冲突的 ZRAM 配置
# =========================

echo "⏳ 正在移除旧 ZRAM 配置..."

CONFLICTING_CONFIGS=(
    /etc/systemd/zram-generator.conf
    /etc/systemd/zram-generator.conf.d
    /etc/default/zramswap
    /etc/default/zram-config
    /etc/modules-load.d/zram.conf
    /etc/systemd/system/zramswap.service
    /etc/systemd/system/zram-swap.service
    /etc/systemd/system/zram-config.service
    /etc/systemd/system/zram.service
)

for config_path in "${CONFLICTING_CONFIGS[@]}"; do
    move_to_backup "$config_path"
done

systemctl daemon-reload

# =========================
# 清理现有 ZRAM 设备
# =========================

echo "⏳ 正在清理现有 ZRAM Swap 设备..."

mapfile -t EXISTING_ZRAM_DEVICES < <(
    zramctl --raw --noheadings --output NAME 2>/dev/null || true
)

for device in "${EXISTING_ZRAM_DEVICES[@]}"; do
    [[ -n "$device" ]] || continue

    device="$(normalize_device_path "$device")"

    if is_active_swap "$device"; then
        echo "  停用 ZRAM Swap：$device"
        swapoff "$device"
    fi

    # 不重置被挂载成普通文件系统的 ZRAM，防止数据丢失
    if findmnt -rn -S "$device" >/dev/null 2>&1; then
        echo "⚠️ $device 被挂载为文件系统，已跳过重置。"
        continue
    fi

    if [[ -b "$device" ]]; then
        zramctl --reset "$device" >/dev/null 2>&1 || true
    fi
done

# =========================
# 创建 ZRAM 启停脚本
# =========================

echo "⏳ 正在安装新的 ZRAM 服务..."

cat > /usr/local/sbin/zram-auto-start << 'ZRAM_START_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail

ZRAM_SIZE_MB="${1:?必须提供 ZRAM 大小}"
ZRAM_PRIORITY="${2:-100}"

STATE_DIR="/run/zram-auto"
STATE_FILE="$STATE_DIR/device"

mkdir -p "$STATE_DIR"

is_active_swap() {
    local target="$1"

    awk 'NR > 1 {print $1}' /proc/swaps |
        grep -Fxq -- "$target"
}

# 防止服务被重复启动时重复创建设备
if [[ -f "$STATE_FILE" ]]; then
    OLD_DEVICE="$(cat "$STATE_FILE" 2>/dev/null || true)"

    if [[ -n "$OLD_DEVICE" ]] && is_active_swap "$OLD_DEVICE"; then
        exit 0
    fi

    rm -f "$STATE_FILE"
fi

modprobe zram

ZRAM_DEVICE="$(zramctl --find 2>/dev/null || true)"

# 某些系统需要通过 hot_add 手动增加设备
if [[ -z "$ZRAM_DEVICE" && -r /sys/class/zram-control/hot_add ]]; then
    ZRAM_INDEX="$(cat /sys/class/zram-control/hot_add)"
    ZRAM_DEVICE="/dev/zram${ZRAM_INDEX}"
fi

if [[ -z "$ZRAM_DEVICE" ]]; then
    echo "无法找到空闲的 ZRAM 设备。" >&2
    exit 1
fi

if [[ "$ZRAM_DEVICE" != /dev/* ]]; then
    ZRAM_DEVICE="/dev/$ZRAM_DEVICE"
fi

ZRAM_NAME="${ZRAM_DEVICE##*/}"
ALGORITHM_FILE="/sys/block/${ZRAM_NAME}/comp_algorithm"

# 按优先级选择可用压缩算法
if [[ -r "$ALGORITHM_FILE" ]]; then
    AVAILABLE_ALGORITHMS="$(cat "$ALGORITHM_FILE")"

    for algorithm in zstd lz4 lzo-rle lzo; do
        if grep -qw "$algorithm" <<< "$AVAILABLE_ALGORITHMS"; then
            printf '%s' "$algorithm" > "$ALGORITHM_FILE"
            break
        fi
    done
fi

cleanup_failed_device() {
    swapoff "$ZRAM_DEVICE" >/dev/null 2>&1 || true
    zramctl --reset "$ZRAM_DEVICE" >/dev/null 2>&1 || true
}

trap cleanup_failed_device ERR

zramctl "$ZRAM_DEVICE" --size "${ZRAM_SIZE_MB}M"
mkswap -f "$ZRAM_DEVICE" >/dev/null
swapon --priority "$ZRAM_PRIORITY" "$ZRAM_DEVICE"

printf '%s\n' "$ZRAM_DEVICE" > "$STATE_FILE"

trap - ERR
ZRAM_START_SCRIPT

cat > /usr/local/sbin/zram-auto-stop << 'ZRAM_STOP_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail

STATE_FILE="/run/zram-auto/device"

is_active_swap() {
    local target="$1"

    awk 'NR > 1 {print $1}' /proc/swaps |
        grep -Fxq -- "$target"
}

if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

ZRAM_DEVICE="$(cat "$STATE_FILE" 2>/dev/null || true)"

if [[ -z "$ZRAM_DEVICE" ]]; then
    rm -f "$STATE_FILE"
    exit 0
fi

if is_active_swap "$ZRAM_DEVICE"; then
    swapoff "$ZRAM_DEVICE"
fi

if ! findmnt -rn -S "$ZRAM_DEVICE" >/dev/null 2>&1; then
    zramctl --reset "$ZRAM_DEVICE" >/dev/null 2>&1 || true
fi

rm -f "$STATE_FILE"
ZRAM_STOP_SCRIPT

chmod 755 /usr/local/sbin/zram-auto-start
chmod 755 /usr/local/sbin/zram-auto-stop

cat > /etc/systemd/system/zram-auto.service << EOF
[Unit]
Description=Automatic ZRAM Swap
Documentation=man:zramctl(8)
After=systemd-modules-load.service local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-auto-start ${ZRAM_MB} ${ZRAM_PRIORITY}
ExecStop=/usr/local/sbin/zram-auto-stop
TimeoutStartSec=120
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now zram-auto.service

if ! systemctl is-active --quiet zram-auto.service; then
    echo "❌ ZRAM 服务启动失败。"
    systemctl status zram-auto.service --no-pager || true
    exit 1
fi

echo "✅ 新 ZRAM 已启用。"

# =========================
# 保存 fstab 中的旧 Swap 列表
# =========================

mapfile -t FSTAB_SWAP_SPECS < <(
    awk '
        /^[[:space:]]*#/ {
            next
        }

        NF >= 3 && $3 == "swap" {
            print $1
        }
    ' /etc/fstab
)

# =========================
# 停用现有非 ZRAM Swap
# =========================

echo "⏳ 正在停用旧磁盘 Swap..."

mapfile -t ACTIVE_SWAPS < <(
    awk 'NR > 1 {print $1}' /proc/swaps
)

for swap_target in "${ACTIVE_SWAPS[@]}"; do
    [[ -n "$swap_target" ]] || continue

    # 保留刚刚创建的新 ZRAM
    if [[ "$swap_target" == /dev/zram* ]]; then
        continue
    fi

    echo "  停用：$swap_target"

    if ! swapoff "$swap_target"; then
        echo "❌ 无法停用 $swap_target。"
        echo "当前内存可能不足，请先停止高内存占用程序后重新运行。"
        exit 1
    fi

    printf '%s\n' "$swap_target" >> "$REMOVED_SWAP_LOG"

    # 目标 Swap 文件稍后单独判断是否需要重建
    if [[ "$swap_target" == "$SWAP_FILE" ]]; then
        continue
    fi

    if [[ -f "$swap_target" ]]; then
        if [[ "$DELETE_OLD_SWAP_FILES" -eq 1 ]]; then
            echo "  删除旧 Swap 文件：$swap_target"
            rm -f -- "$swap_target"
        fi
    elif [[ -b "$swap_target" ]]; then
        echo "  已停用 Swap 分区：$swap_target"
        echo "  分区数据未擦除。"
    fi
done

# =========================
# 删除 fstab 引用的旧 Swap 文件
# =========================

if [[ "$DELETE_OLD_SWAP_FILES" -eq 1 ]]; then
    for swap_spec in "${FSTAB_SWAP_SPECS[@]}"; do
        [[ -n "$swap_spec" ]] || continue

        # UUID=、LABEL= 和块设备都不执行 rm
        if [[ "$swap_spec" != /* ]]; then
            continue
        fi

        if [[ "$swap_spec" == "$SWAP_FILE" ]]; then
            continue
        fi

        if [[ -f "$swap_spec" ]]; then
            echo "  删除 fstab 引用的旧 Swap 文件：$swap_spec"
            printf '%s\n' "$swap_spec" >> "$REMOVED_SWAP_LOG"
            rm -f -- "$swap_spec"
        fi
    done
fi

# =========================
# 清理 fstab 中所有旧 Swap 行
# =========================

echo "⏳ 正在清理 /etc/fstab 中的旧 Swap 配置..."

FSTAB_TEMP="$(mktemp)"

awk '
    /^[[:space:]]*#/ {
        print
        next
    }

    NF == 0 {
        print
        next
    }

    NF >= 3 && $3 == "swap" {
        next
    }

    {
        print
    }
' /etc/fstab > "$FSTAB_TEMP"

install -m 644 "$FSTAB_TEMP" /etc/fstab
rm -f "$FSTAB_TEMP"

# =========================
# 检查现有目标 Swap 文件
# =========================

RECREATE_SWAP_FILE=1

if [[ -f "$SWAP_FILE" ]]; then
    CURRENT_SWAP_SIZE="$(stat -c '%s' "$SWAP_FILE")"
    CURRENT_SWAP_TYPE="$(
        blkid -p -s TYPE -o value "$SWAP_FILE" 2>/dev/null || true
    )"

    if [[ "$CURRENT_SWAP_SIZE" -eq "$TARGET_SWAP_BYTES" &&
          "$CURRENT_SWAP_TYPE" == "swap" ]]; then
        echo "✅ $SWAP_FILE 大小和格式正确，将直接复用。"
        RECREATE_SWAP_FILE=0
    else
        echo "⚠️ $SWAP_FILE 大小或格式不符合要求，将重新创建。"
        rm -f -- "$SWAP_FILE"
    fi
fi

# =========================
# 创建新的磁盘 Swap 文件
# =========================

if [[ "$RECREATE_SWAP_FILE" -eq 1 ]]; then
    SWAP_DIRECTORY="$(dirname "$SWAP_FILE")"
    AVAILABLE_DISK_MB="$(
        df -Pm "$SWAP_DIRECTORY" |
            awk 'NR == 2 {print $4}'
    )"

    # 预留至少 128 MB 空闲空间
    REQUIRED_DISK_MB=$((SWAP_MB + 128))

    if [[ "$AVAILABLE_DISK_MB" -lt "$REQUIRED_DISK_MB" ]]; then
        echo "❌ 磁盘空间不足。"
        echo "需要约 ${REQUIRED_DISK_MB} MB，当前可用 ${AVAILABLE_DISK_MB} MB。"
        echo "ZRAM 已成功启用，但磁盘 Swap 文件尚未创建。"
        exit 1
    fi

    echo "⏳ 正在创建 ${SWAP_FILE}，大小 ${SWAP_MB} MB..."

    touch "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"

    FILESYSTEM_TYPE="$(
        findmnt -n -o FSTYPE --target "$SWAP_FILE" 2>/dev/null || true
    )"

    # Btrfs Swap 文件必须关闭 CoW 和压缩
    if [[ "$FILESYSTEM_TYPE" == "btrfs" ]]; then
        if command -v chattr >/dev/null 2>&1; then
            chattr +C "$SWAP_FILE" 2>/dev/null || true
        fi

        if command -v btrfs >/dev/null 2>&1; then
            btrfs property set "$SWAP_FILE" compression none \
                >/dev/null 2>&1 || true
        fi
    fi

    dd \
        if=/dev/zero \
        of="$SWAP_FILE" \
        bs=1M \
        count="$SWAP_MB" \
        status=progress \
        conv=fsync

    chmod 600 "$SWAP_FILE"
    mkswap -f "$SWAP_FILE" >/dev/null
fi

swapon --priority "$DISK_SWAP_PRIORITY" "$SWAP_FILE"

printf '%s none swap sw,pri=%s 0 0\n' \
    "$SWAP_FILE" \
    "$DISK_SWAP_PRIORITY" >> /etc/fstab

systemctl daemon-reload

echo "✅ 新磁盘 Swap 配置完成。"

# =========================
# 配置 sysctl
# =========================

echo "⏳ 正在设置内核交换参数..."

SYSCTL_CONF="/etc/sysctl.d/99-zram-swap.conf"

cat > "$SYSCTL_CONF" << 'EOF'
# 优先利用高优先级 ZRAM，降低直接触发 OOM 的概率
vm.swappiness = 100

# ZRAM 以页面为单位工作，关闭 Swap 预读聚簇
vm.page-cluster = 0

# 适度保留目录项和 inode 缓存
vm.vfs_cache_pressure = 50
EOF

chmod 644 "$SYSCTL_CONF"
sysctl -p "$SYSCTL_CONF"

# =========================
# 验证结果
# =========================

echo
echo "=========================================="
echo "🎉 ZRAM 和 Swap 配置完成"
echo "=========================================="
echo
echo "当前 Swap 状态："
swapon --show --output NAME,TYPE,SIZE,USED,PRIO
echo
free -h
echo
echo "ZRAM 设备状态："
zramctl || true
echo
echo "备份目录：$BACKUP_DIR"

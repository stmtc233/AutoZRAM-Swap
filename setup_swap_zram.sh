#!/bin/bash

# ==========================================
# Linux 一键配置 ZRAM 与 Swap 脚本
# 自动识别内存大小并进行最优配置
# ==========================================

# 1. 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 用户或 sudo 运行此脚本。"
  exit 1
fi

echo "开始配置 ZRAM 和 Swap..."

# 2. 获取总物理内存大小 (单位: MB)
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
echo "✅ 检测到物理内存: ${TOTAL_MEM_MB} MB"

if [ -z "$TOTAL_MEM_MB" ] || [ "$TOTAL_MEM_MB" -le 0 ]; then
  echo "❌ 错误: 无法获取物理内存大小。"
  exit 1
fi

# 3. 计算 ZRAM 和 Swap 大小
# ZRAM 设为物理内存的 50%
ZRAM_MB=$((TOTAL_MEM_MB / 2))

# 磁盘 Swap 策略计算
if [ "$TOTAL_MEM_MB" -lt 2048 ]; then
    SWAP_MB=$((TOTAL_MEM_MB * 2))
elif [ "$TOTAL_MEM_MB" -lt 8192 ]; then
    SWAP_MB=$TOTAL_MEM_MB
else
    SWAP_MB=8192
fi

echo "📊 计划配置 ZRAM 大小: ${ZRAM_MB} MB (高优先级)"
echo "📊 计划配置 Swap 文件: ${SWAP_MB} MB (低优先级)"

# ==========================================
# 4. 配置磁盘 Swap 文件
# ==========================================
SWAP_FILE="/swapfile"

if grep -q "$SWAP_FILE" /proc/swaps; then
    echo "⚠️ 检测到已存在 $SWAP_FILE，正在卸载并重新创建..."
    swapoff $SWAP_FILE
fi

echo "⏳ 正在创建磁盘 Swap 文件 ($SWAP_FILE)..."
# 使用 dd 命令创建文件 (兼容性最好，比 fallocate 更安全地支持所有文件系统)
dd if=/dev/zero of=$SWAP_FILE bs=1M count=$SWAP_MB status=progress
chmod 600 $SWAP_FILE
mkswap $SWAP_FILE
# 设置低优先级 10
swapon $SWAP_FILE -p 10

# 写入 fstab 实现开机自动挂载 (如果不存在则添加)
if ! grep -q "$SWAP_FILE.*swap" /etc/fstab; then
    echo "$SWAP_FILE none swap sw,pri=10 0 0" >> /etc/fstab
else
    # 更新 fstab 中的优先级
    sed -i "s|^$SWAP_FILE.*|$SWAP_FILE none swap sw,pri=10 0 0|" /etc/fstab
fi
echo "✅ 磁盘 Swap 配置完成。"

# ==========================================
# 5. 配置 ZRAM
# ==========================================
echo "⏳ 正在配置 ZRAM..."

# 确保内核模块已加载
modprobe zram
if ! lsmod | grep -q zram; then
    echo "❌ 错误: 无法加载 zram 内核模块。您的内核可能不支持。"
    exit 1
fi

# 创建 ZRAM 开机自启服务 (Systemd)
cat > /usr/local/bin/zram-start.sh << 'EOF'
#!/bin/bash
ZRAM_MB=$1
modprobe zram
# 查找空闲的 zram 设备
ZRAM_DEV=$(zramctl --find --size ${ZRAM_MB}M --algorithm zstd)
if [ -z "$ZRAM_DEV" ]; then
    ZRAM_DEV=$(zramctl --find --size ${ZRAM_MB}M --algorithm lzo-rle)
fi
mkswap $ZRAM_DEV
swapon $ZRAM_DEV -p 100
echo $ZRAM_DEV > /var/run/zram_dev_name
EOF

cat > /usr/local/bin/zram-stop.sh << 'EOF'
#!/bin/bash
if [ -f /var/run/zram_dev_name ]; then
    ZRAM_DEV=$(cat /var/run/zram_dev_name)
    swapoff $ZRAM_DEV
    zramctl --reset $ZRAM_DEV
    rm -f /var/run/zram_dev_name
fi
EOF

chmod +x /usr/local/bin/zram-start.sh
chmod +x /usr/local/bin/zram-stop.sh

cat > /etc/systemd/system/zram-auto.service << EOF
[Unit]
Description=Auto Setup ZRAM
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/zram-start.sh $ZRAM_MB
ExecStop=/usr/local/bin/zram-stop.sh

[Install]
WantedBy=multi-user.target
EOF

# 立即启动并设置开机自启
systemctl daemon-reload
systemctl stop zram-auto.service 2>/dev/null
systemctl enable --now zram-auto.service
echo "✅ ZRAM 配置完成。"

# ==========================================
# 6. 系统内核参数 (Sysctl) 优化
# ==========================================
echo "⏳ 正在优化系统内核交换参数..."

SYSCTL_CONF="/etc/sysctl.d/99-zram-swap.conf"

cat > $SYSCTL_CONF << EOF
# 优先使用 Swap (因为有了极快的 ZRAM，调高此值可减少 OOM)
vm.swappiness=100
# 避免一次性读取多个内存页到 Swap，ZRAM 是按页压缩的，设为 0 最高效
vm.page-cluster=0
# 倾向于保留目录和 inode 缓存
vm.vfs_cache_pressure=50
EOF

sysctl -p $SYSCTL_CONF

echo "=========================================="
echo "🎉 配置全部完成！当前系统的 Swap 状态如下："
echo "=========================================="
swapon --show
free -h

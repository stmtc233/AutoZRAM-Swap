# AutoZRAM-Swap

🚀 一个轻量级的 Linux 一键自动配置 ZRAM 与 Swap 的 Bash 脚本。

日常使用 Linux 服务器（尤其是 1GB / 2GB 内存的小鸡）时，经常会遇到内存不足导致进程被杀（OOM）的情况。本项目通过一键脚本，自动为你配置 **ZRAM（高性能内存压缩）** 和 **传统磁盘 Swap（容量兜底）**，并优化系统内核参数，最大化利用服务器内存。

## ✨ 核心特性

- **🤖 智能识别**：自动检测当前服务器物理内存大小，无需手动计算。
- **⚡ 分级存储策略**：
  - **ZRAM (优先级 100)**：分配物理内存的 50%，极速读写，系统优先使用。
  - **Swap 文件 (优先级 10)**：根据物理内存大小智能分配（最高 8GB），作为最后的容量防线。
- **⚙️ 内核调优**：自动配置 `sysctl` 参数（如调高 `swappiness`），让系统完美适配 ZRAM 的特性。
- **🔄 持久化运行**：自动生成 Systemd 服务和修改 `/etc/fstab`，重启后配置依然生效。

## 🛠️ 系统要求

- 操作系统：主流 Linux 发行版（Ubuntu, Debian, CentOS, AlmaLinux 等）
- 权限：需要 `root` 用户或 `sudo` 权限
- 内核：支持 `zram` 模块的较新内核

## 🚀 快速开始

只需在终端中运行以下一键命令即可完成配置（需具有 sudo 权限）：

```bash
curl -sL https://raw.githubusercontent.com/stmtc233/AutoZRAM-Swap/refs/heads/main/setup_swap_zram.sh | sudo bash

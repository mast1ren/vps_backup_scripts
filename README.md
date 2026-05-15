# VPS 备份脚本

基于 systemd 和 inotify 的自动化备份解决方案，支持目录监控和定时备份。

## 功能特性

- **实时监控**：使用 inotifywait 监控指定目录的文件变化
- **定时备份**：每天凌晨 2 点自动执行备份任务
- **增量标记**：只备份有变化的目录，避免不必要的压缩操作
- **版本管理**：自动维护备份文件数量，保留最近 N 个版本
- **配置灵活**：INI 格式配置文件，易于维护
- **Systemd 集成**：服务化管理，开机自启

## 目录结构

```
vps_backup_scripts/
├── monitor.sh              # 监控脚本（后台常驻）
├── backup.sh               # 备份脚本（定时执行）
├── monitor_config.conf     # 配置文件
├── monitor.service         # Monitor systemd 服务文件
├── backup.service          # Backup systemd 服务文件
├── backup.timer            # Backup systemd 定时器文件
└── README.md               # 使用说明
```

## 安装与配置

### 前置要求

```bash
# 安装 inotify-tools（用于目录监控）
sudo apt-get install inotify-tools     # Debian/Ubuntu
sudo yum install inotify-tools         # CentOS/RHEL

# 安装 zip（用于文件压缩）
sudo apt-get install zip               # Debian/Ubuntu
sudo yum install zip                   # CentOS/RHEL
```

### 1. 克隆项目

```bash
git clone https://github.com/mast1ren/vps_backup_scripts.git
cd vps_backup_scripts
```

### 2. 配置文件说明

编辑 `monitor_config.conf` 文件：

```ini
[BACKUP]
MARK_DIR="/path/to/marks"              # 标记文件存储目录
WATCH_DIRS="blog,reader,nginx-conf"     # 监控项目列表（逗号分隔）
TARGET_DIR="/path/to/backup"            # 备份文件存储目录
BACKUP_NUM=3                            # 保留备份版本数量
RETRY_COUNT=2                           # 单个项目失败后的重试次数
MONITOR_RESTART_RETRIES=3               # 监控子进程故障后的重启重试次数

[blog]
TYPE="DIR"                              # 类型：DIR（目录）或 FILE（文件）
PATH="/var/www/blog"                    # 监控路径

[reader]
TYPE="DIR"
PATH="/home/user/reader-server"

[nginx-conf]
TYPE="DIR"
PATH="/etc/nginx/conf.d"
```

**配置说明：**

- `MARK_DIR`：存放变化标记文件的目录，monitor 检测到变化时会创建标记
- `WATCH_DIRS`：要监控的项目名称列表，与下方的配置块对应
- `TARGET_DIR`：备份压缩包的存储目录
- `BACKUP_NUM`：每个项目保留的最大备份版本数
- `RETRY_COUNT`：单个项目备份失败后的重试次数，总尝试次数为 `RETRY_COUNT + 1`
- `MONITOR_RESTART_RETRIES`：监控子进程异常退出后的重启重试次数，总尝试次数为 `MONITOR_RESTART_RETRIES + 1`
- `[项目名]`：每个监控项目的详细配置
  - `TYPE`：资源类型，DIR 或 FILE
  - `PATH`：要监控/备份的实际路径

### 3. 修改 systemd 文件路径

根据脚本实际安装位置，修改以下文件中的路径：

**monitor.service**
```ini
# 修改为脚本实际安装目录
ExecStart=/bin/bash /your/actual/path/monitor.sh
```

**backup.service**
```ini
# 修改为 backup.sh 的实际安装路径
ExecStart=/bin/bash /your/actual/path/backup.sh
```

### 4. 安装 systemd 服务

```bash
# 复制服务文件到 systemd 目录
sudo cp monitor.service /etc/systemd/system/
sudo cp backup.service /etc/systemd/system/
sudo cp backup.timer /etc/systemd/system/

# 重新加载 systemd 配置
sudo systemctl daemon-reload

# 启用并启动监控服务（常驻后台）
sudo systemctl enable monitor.service
sudo systemctl start monitor.service

# 启用定时备份任务（每天凌晨2点执行）
sudo systemctl enable backup.timer
sudo systemctl start backup.timer
```

## 使用说明

### 工作原理

1. **监控阶段（monitor.sh）**
   - 以前台方式运行，由 systemd 接管进程生命周期
   - 使用 inotifywait 监控配置文件中指定的目录
   - 检测到文件变化时，创建标记文件（格式：`项目名.mark`）
   - 标记文件存储在 `MARK_DIR` 目录下
   - 定期检查各监控子进程状态，发现退出时会按 `MONITOR_RESTART_RETRIES` 自动重试拉起
   - 如果重试后仍然失败，会记录失败状态；备份脚本每天运行前会再次输出这些未恢复的监控错误

2. **备份阶段（backup.sh）**
   - 每天凌晨 2 点由 systemd timer 触发执行
   - 检查项目对应的标记文件，有标记则执行备份
   - 压缩目标目录/文件为 zip 格式
   - 移动到 `TARGET_DIR` 并维护版本数量
   - 成功后删除标记文件；如果失败则按 `RETRY_COUNT` 重试，最终失败时保留标记文件，等待下次继续备份

### 服务管理命令

```bash
# 查看监控服务状态
sudo systemctl status monitor.service

# 停止/重启监控服务
sudo systemctl stop monitor.service
sudo systemctl restart monitor.service

# 查看备份定时器状态
sudo systemctl status backup.timer

# 查看备份定时器列表
sudo systemctl list-timers

# 手动执行一次备份
sudo systemctl start backup.service

# 查看服务日志
sudo journalctl -u monitor.service -f
sudo journalctl -u backup.service -f
```

### 日志文件

脚本会在脚本目录下生成日志文件：

- `monitor.log`：监控脚本日志，记录目录变化和监控状态
- `backup.log`：备份脚本日志，记录备份过程和结果

```bash
# 查看监控日志
tail -f /path/to/vps_backup_scripts/monitor.log

# 查看备份日志
tail -f /path/to/vps_backup_scripts/backup.log
```

## 进阶配置

### 修改备份时间

编辑 `backup.timer` 文件，修改 `OnCalendar` 行：

```ini
# 每天凌晨 2 点
OnCalendar=*-*-* 02:00:00

# 每天凌晨 3 点 30 分
OnCalendar=*-*-* 03:30:00

# 每周日凌晨 1 点
OnCalendar=Sun *-*-* 01:00:00
```

修改后需要重新加载：
```bash
sudo systemctl daemon-reload
sudo systemctl restart backup.timer
```

### 添加新的监控项目

1. 编辑 `monitor_config.conf`
2. 在 `WATCH_DIRS` 中添加项目名称
3. 添加对应的配置块

```ini
[BACKUP]
WATCH_DIRS="blog,reader,new-project"
RETRY_COUNT=2

[new-project]
TYPE="DIR"
PATH="/path/to/new-project"
```

4. 重启监控服务
```bash
sudo systemctl restart monitor.service
```

### 调整备份保留数量

修改 `monitor_config.conf` 中的 `BACKUP_NUM`：

```ini
[BACKUP]
BACKUP_NUM=5    # 保留最近5个版本
```

## 故障排查

### 监控服务无法启动

```bash
# 检查 inotify-tools 是否安装
which inotifywait

# 检查锁文件
ls -la /var/run/backup_monitor.pid
sudo rm /var/run/backup_monitor.pid  # 清除过期锁文件

# 查看详细错误
sudo journalctl -u monitor.service -n 50
```

### 备份未执行

```bash
# 检查 timer 是否启用
sudo systemctl is-enabled backup.timer

# 查看下次执行时间
sudo systemctl list-timers | grep backup

# 检查标记文件是否存在
ls -la /path/to/marks/

# 手动测试备份脚本
sudo bash /path/to/backup.sh
```

### 目录监控不生效

- 确认目录路径正确且有权限访问
- 检查 inotify 监控限制：`cat /proc/sys/fs/inotify/max_user_watches`
- 必要时增加限制：`echo 524288 | sudo tee /proc/sys/fs/inotify/max_user_watches`

## 注意事项

1. **权限要求**：脚本需要有权限访问监控目录和备份目录
2. **磁盘空间**：确保备份目标目录有足够空间
3. **标记文件清理**：成功备份后会自动删除标记文件
4. **时区设置**：备份时间基于系统时区
5. **并发保护**：monitor 脚本有锁机制，防止多实例运行

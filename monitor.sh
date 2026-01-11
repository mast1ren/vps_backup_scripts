#!/bin/bash

# 颜色配置
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 将脚本转入后台运行
if [ "$1" != "background" ]; then
    echo -e "${YELLOW}正在后台启动监控脚本...${NC}"
    # 检查锁文件，防止启动多个进程
    if [ -f "${LOCK_FILE}" ]; then
        pid=$(cat "${LOCK_FILE}")
        if ps -p "${pid}" > /dev/null 2>&1; then
            echo -e "${RED}错误: 监控脚本已经在运行，PID: ${pid}。退出...${NC}"
            exit 1
        fi
    fi
    $0 background > /dev/null 2>&1 &
    echo -e "${GREEN}监控脚本成功启动! (PID: $!)${NC}"
    echo "你可以查看日志: ${SCRIPT_DIR}/monitor.log"
    exit 0
fi

# 配置部分
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/monitor_config.conf"
LOG_FILE="${SCRIPT_DIR}/monitor.log"
LOCK_FILE="/var/run/backup_monitor.pid"

# 加载公共函数库
source "${SCRIPT_DIR}/common.sh"

# 读取配置函数（INI解析）
declare -A WATCH_DIRS
declare -A WATCH_TYPES
MARK_DIR=""
SLEEP_INTERVAL=86400

parse_config() {
    # 第一步：读取 BACKUP section 的配置
    MARK_DIR=$(read_section_value "BACKUP" "MARK_DIR" "$CONFIG_FILE")
    SLEEP_INTERVAL=$(read_section_value "BACKUP" "SLEEP_INTERVAL" "$CONFIG_FILE")
    WATCH_LIST=$(read_section_value "BACKUP" "WATCH_DIRS" "$CONFIG_FILE")
    
    # 第二步：根据 WATCH_LIST 读取各项目的配置
    IFS=',' read -ra PROJECTS <<< "$WATCH_LIST"
    for project in "${PROJECTS[@]}"; do
        project="$(echo "$project" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        path=$(read_section_value "$project" "PATH" "$CONFIG_FILE")
        type=$(read_section_value "$project" "TYPE" "$CONFIG_FILE")
        if [[ -n "$path" ]]; then
            WATCH_DIRS[$project]="$path"
            WATCH_TYPES[$project]="${type:-DIR}"
        fi
    done
}

# 日志函数
log() {
    local level=$1
    shift
    local message="$*"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [${level}] ${message}" >> "${LOG_FILE}"
}

# 检查是否已运行
check_running() {
    if [ -f "${LOCK_FILE}" ]; then
        pid=$(cat "${LOCK_FILE}")
        if ps -p "${pid}" > /dev/null 2>&1; then
            log "错误" "监控脚本已经在运行，PID: ${pid}"
            echo -e "${RED}错误: 监控脚本已经在运行，PID: ${pid}。退出...${NC}"
            exit 1
        else
            log "警告" "发现过期的锁文件，正在移除"
            rm -f "${LOCK_FILE}"
        fi
    fi
    echo $$ > "${LOCK_FILE}"
}

# 清理函数
cleanup() {
    log "信息" "清理并退出"
    rm -f "${LOCK_FILE}"
    pkill -P $$  # 终止所有子进程
    exit 0
}

# 监控单个目录
monitor_target() {
    local project_name=$1
    local target_path=$2
    local target_type=$3
    
    # 检查目标是否存在
    if [[ "$target_type" == "DIR" ]]; then
        if [ ! -d "${target_path}" ]; then
            log "错误" "项目 ${project_name} 的目录 ${target_path} 不存在"
            return 1
        fi
        log "信息" "开始监控项目 ${project_name}，目录: ${target_path}"
        # 监控目录（递归）
        inotifywait -m -r -e modify,create,delete,move "${target_path}" 2>> "${LOG_FILE}" | while read -r directory events filename; do
            local TODAY=$(date +"%Y-%m-%d")
            local MARK_FILE="${MARK_DIR}/${project_name}_${TODAY}.mark"
            
            if [ ! -f "${MARK_FILE}" ]; then
                touch "${MARK_FILE}"
                log "信息" "检测到 ${project_name} 的变化，创建标记文件: ${MARK_FILE}"
            fi
        done &
    elif [[ "$target_type" == "FILE" ]]; then
        if [ ! -f "${target_path}" ]; then
            log "错误" "项目 ${project_name} 的文件 ${target_path} 不存在"
            return 1
        fi
        log "信息" "开始监控项目 ${project_name}，文件: ${target_path}"
        # 监控单个文件（不递归）
        inotifywait -m -e modify,create,delete,move "${target_path}" 2>> "${LOG_FILE}" | while read -r directory events filename; do
            local TODAY=$(date +"%Y-%m-%d")
            local MARK_FILE="${MARK_DIR}/${project_name}_${TODAY}.mark"
            
            if [ ! -f "${MARK_FILE}" ]; then
                touch "${MARK_FILE}"
                log "信息" "检测到 ${project_name} 的变化，创建标记文件: ${MARK_FILE}"
            fi
        done &
    else
        log "错误" "项目 ${project_name} 的类型 ${target_type} 不支持"
        return 1
    fi
}

# 主函数
main() {
    # 设置退出时的清理
    trap cleanup SIGTERM SIGINT

    # 检查必要的工具
    if ! command -v inotifywait &> /dev/null; then
        log "错误" "inotify-tools 未安装，请先安装它。"
        echo -e "${RED}错误: inotify-tools 未安装，请先安装它。${NC}"
        exit 1
    fi

    # 加载配置
    parse_config
    mkdir -p "${MARK_DIR}"

    # 检查是否已运行
    check_running

    log "信息" "监控脚本已启动"

    # 启动所有目录的监控
    IFS=',' read -ra PROJECTS <<< "$WATCH_LIST"
    for project in "${PROJECTS[@]}"; do
        project="$(echo "$project" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        path="${WATCH_DIRS[$project]}"
        type="${WATCH_TYPES[$project]}"
        if [ -n "$path" ]; then
            monitor_target "$project" "$path" "$type"
            log "信息" "已启动监控进程，项目: $project, 类型: $type, 路径: $path"
        else
            log "警告" "未找到项目 $project 的监控路径"
        fi
    done

    # 保持主进程运行
    wait
}

# 运行主函数
main
#!/bin/bash

# 颜色配置
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 配置部分
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/monitor_config.conf}"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/monitor.log}"
LOCK_FILE="${LOCK_FILE:-/var/run/backup_monitor.pid}"

# 显式请求时转入后台运行
if [ "$1" = "background" ]; then
    echo -e "${YELLOW}正在后台启动监控脚本...${NC}"
    # 检查锁文件，防止启动多个进程
    if [ -f "${LOCK_FILE}" ]; then
        pid=$(cat "${LOCK_FILE}")
        if ps -p "${pid}" > /dev/null 2>&1; then
            echo -e "${RED}错误: 监控脚本已经在运行，PID: ${pid}。退出...${NC}"
            exit 1
        fi
    fi
    "$0" foreground > /dev/null 2>&1 &
    echo -e "${GREEN}监控脚本成功启动! (PID: $!)${NC}"
    echo "你可以查看日志: ${LOG_FILE}"
    exit 0
fi

if [ "$1" = "foreground" ]; then
    shift
fi

# 加载公共函数库
source "${SCRIPT_DIR}/common.sh"

# 读取配置函数（INI解析）
declare -A WATCH_DIRS
declare -A WATCH_TYPES
declare -A WATCH_PIDS
MARK_DIR=""
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-30}"
MONITOR_RESTART_RETRIES=3
FAILED_MONITOR_DIR=""

parse_config() {
    # 第一步：读取 BACKUP section 的配置
    MARK_DIR=$(read_section_value "BACKUP" "MARK_DIR" "$CONFIG_FILE")
    WATCH_LIST=$(read_section_value "BACKUP" "WATCH_DIRS" "$CONFIG_FILE")
    MONITOR_RESTART_RETRIES=$(read_section_value "BACKUP" "MONITOR_RESTART_RETRIES" "$CONFIG_FILE")
    
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
}

write_monitor_failure_state() {
    local project_name=$1
    local target_path=$2
    local target_type=$3
    local reason=$4
    local state_file="${FAILED_MONITOR_DIR}/${project_name}.state"

    cat > "${state_file}" <<EOF
PROJECT=${project_name}
PATH=${target_path}
TYPE=${target_type}
LAST_ERROR_AT=$(date +'%Y-%m-%d %H:%M:%S')
REASON=${reason}
EOF
}

clear_monitor_failure_state() {
    local project_name=$1

    rm -f "${FAILED_MONITOR_DIR}/${project_name}.state"
}

start_monitor_process() {
    local project_name=$1
    local target_path=$2
    local target_type=$3
    local monitor_pid

    if [[ "$target_type" == "DIR" ]]; then
        inotifywait -m -r -e modify,create,delete,move "${target_path}" 2>> "${LOG_FILE}" | while read -r directory events filename; do
            local MARK_FILE="${MARK_DIR}/${project_name}.mark"

            if [ ! -f "${MARK_FILE}" ]; then
                touch "${MARK_FILE}"
                log "信息" "检测到 ${project_name} 的变化，创建标记文件: ${MARK_FILE}"
            fi
        done &
    else
        inotifywait -m -e modify,create,delete,move "${target_path}" 2>> "${LOG_FILE}" | while read -r directory events filename; do
            local MARK_FILE="${MARK_DIR}/${project_name}.mark"

            if [ ! -f "${MARK_FILE}" ]; then
                touch "${MARK_FILE}"
                log "信息" "检测到 ${project_name} 的变化，创建标记文件: ${MARK_FILE}"
            fi
        done &
    fi

    monitor_pid=$!
    sleep 1
    if ! kill -0 "${monitor_pid}" 2>/dev/null; then
        wait "${monitor_pid}" 2>/dev/null || true
        return 1
    fi

    WATCH_PIDS["${project_name}"]="${monitor_pid}"
    clear_monitor_failure_state "${project_name}"
    log "信息" "已启动监控子进程，项目: ${project_name}, PID: ${monitor_pid}"
    return 0
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
        if ! start_monitor_process "${project_name}" "${target_path}" "${target_type}"; then
            log "错误" "项目 ${project_name} 的监控子进程启动失败"
            return 1
        fi
    elif [[ "$target_type" == "FILE" ]]; then
        if [ ! -f "${target_path}" ]; then
            log "错误" "项目 ${project_name} 的文件 ${target_path} 不存在"
            return 1
        fi
        log "信息" "开始监控项目 ${project_name}，文件: ${target_path}"
        if ! start_monitor_process "${project_name}" "${target_path}" "${target_type}"; then
            log "错误" "项目 ${project_name} 的监控子进程启动失败"
            return 1
        fi
    else
        log "错误" "项目 ${project_name} 的类型 ${target_type} 不支持"
        return 1
    fi
}

restart_monitor_with_retries() {
    local project_name=$1
    local target_path=$2
    local target_type=$3
    local max_attempts
    local attempt

    if ! [[ "${MONITOR_RESTART_RETRIES}" =~ ^[0-9]+$ ]]; then
        MONITOR_RESTART_RETRIES=3
    fi
    max_attempts=$((MONITOR_RESTART_RETRIES + 1))

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        log "警告" "正在重启项目 ${project_name} 的监控子进程，第 ${attempt}/${max_attempts} 次尝试"
        if monitor_target "${project_name}" "${target_path}" "${target_type}"; then
            log "信息" "项目 ${project_name} 的监控子进程已恢复"
            return 0
        fi
    done

    WATCH_PIDS["${project_name}"]=""
    write_monitor_failure_state "${project_name}" "${target_path}" "${target_type}" \
        "Monitor process restart failed after ${max_attempts} attempts"
    log "错误" "项目 ${project_name} 的监控子进程重启失败，已达到最大重试次数 ${max_attempts}"
    return 1
}

restart_monitor_if_needed() {
    local project_name=$1
    local target_path=$2
    local target_type=$3
    local monitor_pid="${WATCH_PIDS[$project_name]}"

    if [ -n "${monitor_pid}" ] && kill -0 "${monitor_pid}" 2>/dev/null; then
        return 0
    fi

    log "警告" "检测到项目 ${project_name} 的监控子进程已退出，正在尝试重启"
    restart_monitor_with_retries "${project_name}" "${target_path}" "${target_type}"
}

health_check_loop() {
    while true; do
        sleep "${HEALTH_CHECK_INTERVAL}"

        IFS=',' read -ra PROJECTS <<< "$WATCH_LIST"
        for project in "${PROJECTS[@]}"; do
            project="$(echo "$project" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            path="${WATCH_DIRS[$project]}"
            type="${WATCH_TYPES[$project]}"
            if [ -n "$path" ]; then
                restart_monitor_if_needed "$project" "$path" "$type"
            fi
        done
    done
}

# 主函数
main() {
    # 设置退出时的清理
    trap cleanup EXIT
    trap 'exit 0' SIGTERM SIGINT

    # 检查必要的工具
    if ! command -v inotifywait &> /dev/null; then
        log "错误" "inotify-tools 未安装，请先安装它。"
        echo -e "${RED}错误: inotify-tools 未安装，请先安装它。${NC}"
        exit 1
    fi

    # 加载配置
    parse_config
    mkdir -p "${MARK_DIR}"
    FAILED_MONITOR_DIR="${MARK_DIR}/.monitor_failures"
    mkdir -p "${FAILED_MONITOR_DIR}"

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
            if monitor_target "$project" "$path" "$type"; then
                log "信息" "已启动监控进程，项目: $project, 类型: $type, 路径: $path"
            else
                WATCH_PIDS["${project}"]=""
                write_monitor_failure_state "$project" "$path" "$type" \
                    "Initial monitor start failed"
                log "错误" "项目 $project 的监控进程启动失败，已记录错误状态"
            fi
        else
            log "警告" "未找到项目 $project 的监控路径"
        fi
    done

    health_check_loop &

    # 保持主进程运行
    wait
}

# 运行主函数
main "$@"

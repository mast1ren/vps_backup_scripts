#!/bin/bash

# 配置文件和日志文件路径自动获取
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/monitor_config.conf}"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/backup.log}"
exec >>"${LOG_FILE}" 2>&1
echo "==================== $(date +"%Y-%m-%d %H:%M:%S") ===================="

# 加载公共函数库
source "${SCRIPT_DIR}/common.sh"

# 解析配置
declare -A DIR_PATHS
declare -A DIR_TYPES
MARK_DIR=""
TARGET_DIR=""
BACKUP_NUM=3
RETRY_COUNT=2
WATCH_LIST=""
FAILED_MONITOR_DIR=""

parse_config() {
    # 第一步：读取 BACKUP section 的配置
    MARK_DIR=$(read_section_value "BACKUP" "MARK_DIR" "$CONFIG_FILE")
    TARGET_DIR=$(read_section_value "BACKUP" "TARGET_DIR" "$CONFIG_FILE")
    BACKUP_NUM=$(read_section_value "BACKUP" "BACKUP_NUM" "$CONFIG_FILE")
    RETRY_COUNT=$(read_section_value "BACKUP" "RETRY_COUNT" "$CONFIG_FILE")
    WATCH_LIST=$(read_section_value "BACKUP" "WATCH_DIRS" "$CONFIG_FILE")
    
    # 第二步：根据 WATCH_LIST 读取各项目的配置
    IFS=',' read -ra PROJECTS <<< "$WATCH_LIST"
    for project in "${PROJECTS[@]}"; do
        project="$(echo "$project" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        path=$(read_section_value "$project" "PATH" "$CONFIG_FILE")
        type=$(read_section_value "$project" "TYPE" "$CONFIG_FILE")
        if [[ -n "$path" ]]; then
            DIR_PATHS[$project]="$path"
            DIR_TYPES[$project]="${type:-DIR}"
        fi
    done
}

report_monitor_failures() {
    local state_file

    if [ ! -d "${FAILED_MONITOR_DIR}" ]; then
        return 0
    fi

    shopt -s nullglob
    for state_file in "${FAILED_MONITOR_DIR}"/*.state; do
        echo "Monitor warning: unresolved monitor failure detected."
        sed 's/^/  /' "${state_file}"
    done
    shopt -u nullglob
}

prune_old_backups() {
    local project_name=$1
    local excess_count
    local find_output
    local -a project_backups=()

    cd "${TARGET_DIR}" || return 1
    while IFS= read -r backup_file; do
        project_backups+=("${backup_file}")
    done < <(find . -maxdepth 1 -type f -name "*_${project_name}.zip" -printf '%T@ %P\n' | sort -rn | cut -d' ' -f2-)

    if [ "${#project_backups[@]}" -le "${BACKUP_NUM}" ]; then
        return 0
    fi

    echo "Deleting old backup files for ${project_name}..."
    excess_count=$(("${#project_backups[@]}" - BACKUP_NUM))
    for backup_file in "${project_backups[@]: -${excess_count}}"; do
        rm -f -- "${backup_file}"
    done
}

attempt_backup_once() {
    local project_name=$1
    local source_path=$2
    local zip_file=$3

    rm -f "${zip_file}"
    echo "Compressing ${source_path} to ${zip_file}..."
    zip -r "${zip_file}" "${source_path}" > /dev/null 2>> "${LOG_FILE}" || return 1
    echo "Compression completed: ${zip_file}"

    mkdir -p "${TARGET_DIR}"
    mv "${zip_file}" "${TARGET_DIR}/" || return 1
    echo "File moved successfully."

    prune_old_backups "${project_name}" || return 1
}

# 备份函数
backup_target() {
    local PROJECT_NAME=$1
    local SOURCE_PATH=$2
    local SOURCE_TYPE=$3
    local DATE
    local ZIP_FILE
    local MARK_FILE="${MARK_DIR}/${PROJECT_NAME}.mark"
    local max_attempts
    local attempt

    DATE=$(date +"%Y-%m-%d")
    ZIP_FILE="/tmp/${DATE}_${PROJECT_NAME}.zip"
    if ! [[ "${RETRY_COUNT}" =~ ^[0-9]+$ ]]; then
        RETRY_COUNT=2
    fi
    max_attempts=$((RETRY_COUNT + 1))

    if [ ! -f "${MARK_FILE}" ]; then
        echo "No changes detected for ${PROJECT_NAME}, skipping backup."
        return 0
    fi

    echo "Starting backup for ${PROJECT_NAME}..."

    # 检查源路径是否存在
    if [[ "$SOURCE_TYPE" == "DIR" ]]; then
        if [ ! -d "${SOURCE_PATH}" ]; then
            echo "Error: Source directory ${SOURCE_PATH} does not exist. Skipping."
            return 1
        fi
    elif [[ "$SOURCE_TYPE" == "FILE" ]]; then
        if [ ! -f "${SOURCE_PATH}" ]; then
            echo "Error: Source file ${SOURCE_PATH} does not exist. Skipping."
            return 1
        fi
    else
        echo "Error: Unknown source type ${SOURCE_TYPE}. Skipping."
        return 1
    fi

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        echo "Backup attempt ${attempt}/${max_attempts} for ${PROJECT_NAME}..."
        if attempt_backup_once "${PROJECT_NAME}" "${SOURCE_PATH}" "${ZIP_FILE}"; then
            rm -f "${MARK_FILE}"
            echo "Removed mark file for ${PROJECT_NAME}"
            echo "Backup completed for ${PROJECT_NAME}"
            echo "----------------------------------------"
            return 0
        fi

        echo "Error: Backup attempt ${attempt}/${max_attempts} failed for ${PROJECT_NAME}."
    done

    rm -f "${ZIP_FILE}"
    echo "Error: Backup failed for ${PROJECT_NAME} after ${max_attempts} attempts. Keeping mark file for retry."
    echo "----------------------------------------"
    return 1
}

main() {
    local overall_status=0

    if ! command -v zip &> /dev/null; then
        echo "Error: zip is not installed. Please install it first."
        return 1
    fi

    parse_config
    FAILED_MONITOR_DIR="${MARK_DIR}/.monitor_failures"
    report_monitor_failures
    IFS=',' read -ra PROJECTS <<< "$WATCH_LIST"
    for project in "${PROJECTS[@]}"; do
        project="$(echo "$project" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        path="${DIR_PATHS[$project]}"
        type="${DIR_TYPES[$project]}"
        if [ -n "$path" ]; then
            if ! backup_target "$project" "$path" "$type"; then
                overall_status=1
            fi
        fi
    done
    echo "All backups completed at $(date +"%Y-%m-%d %H:%M:%S")."
    return "${overall_status}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

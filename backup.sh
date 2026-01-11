#!/bin/bash

# 配置文件和日志文件路径自动获取
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/monitor_config.conf"
LOG_FILE="${SCRIPT_DIR}/backup.log"
exec >>"${LOG_FILE}" 2>&1
echo "==================== $(date +"%Y-%m-%d %H:%M:%S") ===================="

# 解析配置
declare -A DIR_PATHS
MARK_DIR=""
TARGET_DIR=""
BACKUP_NUM=3
WATCH_LIST=""

parse_config() {
    local section=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line%%;*}"
        # 去除前后空白
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}" 
        [[ -z "$line" ]] && continue
        if [[ $line =~ ^\[(.*)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
        elif [[ $section == "BACKUP" ]]; then
            if [[ $line =~ ^MARK_DIR="(.*)"$ ]]; then
                MARK_DIR="${BASH_REMATCH[1]}"
            elif [[ $line =~ ^TARGET_DIR="(.*)"$ ]]; then
                TARGET_DIR="${BASH_REMATCH[1]}"
            elif [[ $line =~ ^BACKUP_NUM=([0-9]+) ]]; then
                BACKUP_NUM="${BASH_REMATCH[1]}"
            elif [[ $line =~ ^WATCH_DIRS="(.*)"$ ]]; then
                WATCH_LIST="${BASH_REMATCH[1]}"
            fi
        elif [[ ",${WATCH_LIST}," == *",${section},"* ]]; then
            if [[ $line =~ ^PATH="(.*)"$ ]]; then
                DIR_PATHS[$section]="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$CONFIG_FILE"
}

# 备份函数
backup_directory() {
    local PROJECT_NAME=$1
    local SOURCE_PATH=$2
    local DATE=$(date -d "-1 day" +"%Y-%m-%d")
    local ZIP_FILE="/tmp/${DATE}_${PROJECT_NAME}.zip"
    local MARK_FILE="${MARK_DIR}/${PROJECT_NAME}_${DATE}.mark"

    if [ ! -f "${MARK_FILE}" ]; then
        echo "No changes detected for ${PROJECT_NAME} today, skipping backup."
        return 0
    fi

    echo "Starting backup for ${PROJECT_NAME}..."

    if [ ! -e "${SOURCE_PATH}" ]; then
        echo "Error: Source path ${SOURCE_PATH} does not exist. Skipping."
        return 1
    fi

    # 压缩并加密（可按需修改加密参数）
    echo "Compressing ${SOURCE_PATH} to ${ZIP_FILE}..."
    zip -r "${ZIP_FILE}" "${SOURCE_PATH}" > /dev/null 2>> "${LOG_FILE}"
    if [ $? -ne 0 ]; then
        echo "Error: Compression failed for ${PROJECT_NAME}. Skipping."
        return 1
    fi
    echo "Compression completed: ${ZIP_FILE}"

    # 检查并维护目标目录备份数量
    mkdir -p "${TARGET_DIR}"
    cd "${TARGET_DIR}" || return 1
    BACKUP_COUNT=$(ls -1 "*_${PROJECT_NAME}.zip" 2>/dev/null | wc -l)
    if [ "${BACKUP_COUNT}" -ge "${BACKUP_NUM}" ]; then
        echo "Deleting old backup files for ${PROJECT_NAME}..."
        ls -1t "*_${PROJECT_NAME}.zip" | tail -n +$((BACKUP_NUM)) | xargs rm -f
    fi

    # 移动压缩包
    mv "${ZIP_FILE}" "${TARGET_DIR}/" && echo "File moved successfully."
    # 删除标记文件
    rm -f "${MARK_FILE}"
    echo "Removed mark file for ${PROJECT_NAME}"
    echo "Backup completed for ${PROJECT_NAME}"
    echo "----------------------------------------"
}

# 主流程
parse_config
IFS=',' read -ra PROJECTS <<< "$WATCH_LIST"
for project in "${PROJECTS[@]}"; do
    path="${DIR_PATHS[$project]}"
    if [ -n "$path" ]; then
        backup_directory "$project" "$path"
    fi
done
echo "All backups completed at $(date +"%Y-%m-%d %H:%M:%S")."
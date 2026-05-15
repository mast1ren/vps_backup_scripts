#!/bin/bash

# 测试配置读取功能
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "=== 测试配置文件读取 ==="
echo ""

echo "测试 1: 读取 BACKUP section 的 MARK_DIR"
MARK_DIR=$(read_section_value "BACKUP" "MARK_DIR" "${SCRIPT_DIR}/monitor_config.conf")
echo "结果: [$MARK_DIR]"
echo ""

echo "测试 2: 读取 BACKUP section 的 RETRY_COUNT"
RETRY_COUNT=$(read_section_value "BACKUP" "RETRY_COUNT" "${SCRIPT_DIR}/monitor_config.conf")
echo "结果: [$RETRY_COUNT]"
echo ""

echo "测试 3: 读取 BACKUP section 的 WATCH_DIRS"
WATCH_DIRS=$(read_section_value "BACKUP" "WATCH_DIRS" "${SCRIPT_DIR}/monitor_config.conf")
echo "结果: [$WATCH_DIRS]"
echo ""

echo "测试 4: 读取 BACKUP section 的 TARGET_DIR"
TARGET_DIR=$(read_section_value "BACKUP" "TARGET_DIR" "${SCRIPT_DIR}/monitor_config.conf")
echo "结果: [$TARGET_DIR]"
echo ""

echo "测试 5: 读取 BACKUP section 的 BACKUP_NUM"
BACKUP_NUM=$(read_section_value "BACKUP" "BACKUP_NUM" "${SCRIPT_DIR}/monitor_config.conf")
echo "结果: [$BACKUP_NUM]"
echo ""

echo "测试 6: 读取 blog section 的 PATH"
BLOG_PATH=$(read_section_value "blog" "PATH" "${SCRIPT_DIR}/monitor_config.conf")
echo "结果: [$BLOG_PATH]"
echo ""

echo "测试 7: 读取 nginx-conf section 的 PATH"
NGINX_PATH=$(read_section_value "nginx-conf" "PATH" "${SCRIPT_DIR}/monitor_config.conf")
echo "结果: [$NGINX_PATH]"
echo ""

echo "测试 8: 读取 database section 的 PATH"
DB_PATH=$(read_section_value "database" "PATH" "${SCRIPT_DIR}/monitor_config.conf")
echo "结果: [$DB_PATH]"
echo ""

echo "=== 测试完成 ==="

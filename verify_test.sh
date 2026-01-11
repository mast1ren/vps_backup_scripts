#!/bin/bash
# 简化测试 - 直接模拟函数逻辑

CONFIG_FILE="monitor_config.conf"

echo "=== 手动验证配置读取逻辑 ==="
echo ""

# 测试读取 MARK_DIR
echo "测试: 读取 BACKUP.MARK_DIR"
in_section=0
while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    [[ "$line" =~ ^# ]] && continue
    
    if [[ "$line" =~ ^\[.*\]$ ]]; then
        current_section=$(echo "$line" | sed 's/^\[\(.*\)\]$/\1/')
        if [ "$current_section" = "BACKUP" ]; then
            in_section=1
        else
            in_section=0
        fi
        continue
    fi
    
    if [ $in_section -eq 1 ]; then
        if [[ "$line" =~ ^MARK_DIR= ]]; then
            value=$(echo "$line" | sed "s/^MARK_DIR=//" | sed 's/^["'"'"']\(.*\)["'"'"']$/\1/')
            echo "找到: [$value]"
            break
        fi
    fi
done < "$CONFIG_FILE"

echo ""
echo "测试: 读取 blog.PATH"
in_section=0
while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    [[ "$line" =~ ^# ]] && continue
    
    if [[ "$line" =~ ^\[.*\]$ ]]; then
        current_section=$(echo "$line" | sed 's/^\[\(.*\)\]$/\1/')
        if [ "$current_section" = "blog" ]; then
            in_section=1
        else
            in_section=0
        fi
        continue
    fi
    
    if [ $in_section -eq 1 ]; then
        if [[ "$line" =~ ^PATH= ]]; then
            value=$(echo "$line" | sed "s/^PATH=//" | sed 's/^["'"'"']\(.*\)["'"'"']$/\1/')
            echo "找到: [$value]"
            break
        fi
    fi
done < "$CONFIG_FILE"

echo ""
echo "=== 验证完成 ==="

#!/bin/bash

# 公共函数库

# 读取指定section的配置项
read_section_value() {
    local section_name="$1"
    local key_name="$2"
    local config_file="$3"
    local in_section=0
    local value=""
    
    # Check if config file exists
    if [ ! -f "$config_file" ]; then
        return 1
    fi
    
    while IFS= read -r line; do
        # Remove leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Skip empty lines and comments
        if [ -z "$line" ] || [[ "$line" =~ ^# ]]; then
            continue
        fi
        
        # Check if we're entering the target section
        if [[ "$line" =~ ^\[.*\]$ ]]; then
            local current_section=$(echo "$line" | sed 's/^\[\(.*\)\]$/\1/')
            if [ "$current_section" = "$section_name" ]; then
                in_section=1
            else
                in_section=0
            fi
            continue
        fi
        
        # If we're in the target section, look for the key
        if [ $in_section -eq 1 ]; then
            if [[ "$line" =~ ^${key_name}= ]]; then
                value=$(echo "$line" | sed "s/^${key_name}=//" | sed 's/^["'"'"']\(.*\)["'"'"']$/\1/')
                echo "$value"
                return 0
            fi
        fi
    done < "$config_file"
    
    return 1
}

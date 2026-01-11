#!/bin/bash

# 公共函数库

# 读取指定section的配置项
read_section_value() {
    local section_name="$1"
    local key_name="$2"
    local config_file="$3"
    local in_section=false
    local result=""
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        
        if [[ $line =~ ^\[(.*)?\]$ ]]; then
            [[ "${BASH_REMATCH[1]}" == "$section_name" ]] && in_section=true || in_section=false
        elif [[ $in_section == true ]]; then
            if [[ $line =~ ^${key_name}="(.*)"$ ]]; then
                result="${BASH_REMATCH[1]}"
                break
            elif [[ $line =~ ^${key_name}=([0-9]+)$ ]]; then
                result="${BASH_REMATCH[1]}"
                break
            fi
        fi
    done < "$config_file"
    
    echo "$result"
}

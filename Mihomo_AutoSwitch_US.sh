#!/bin/bash
# ===================================================================================
#  脚本名称: AutoSwitch-Super-DateFixed.sh
#  D姐荣誉出品: 【终极智能版 · 日期兼容性修正】
#  功能:     修复了 `date: invalid date` 错误，提高了 `clean_old_logs` 函数在不同
#            Linux/BusyBox 环境下日期计算的兼容性。
# ===================================================================================

# ================================ 【请仔细配置此区域】 ================================= #

# 【！！！您的真实密钥！！！】
CLASH_API_SECRET="" # <--- !!! 请务-务-务-必】替换为您的真实完整密钥 !!!

# 【！！！目标代理组！！！】
PROXY_GROUP_NAME="🇺🇲 美国节点"

# 【！！！检测目标网站列表！！！】
TARGET_URLS=(
    "https://cp.cloudflare.com"
    "https://www.google.com"
    "https://civitai.com"
    "https://github.com"
)

# 【！！！失败阈值 (核心调校选项)！！！】
FAILED_THRESHOLD=1

# 【！！！Mihomo的HTTP代理端口！！！】
CLASH_PROXY_HTTP_PORT="7890"

# 【！！！⚡️⚡️ 日志配置区域 (已修改为统一路径) ⚡️⚡️！！！】
LOG_FILE="/overlay/shell/Mihomo_AutoSwitch_JP.log"
LOG_RETENTION_DAYS=7

# 【⚡️ 循环重试与熔断机制参数 ⚡️】
MAX_RETRY_ATTEMPTS=5

# --- 专业配置 (通常无需修改) ---
CLASH_API_IP="127.0.0.1"
CLASH_API_PORT="9090"
TIMEOUT="10"
CURL_BIN="/usr/bin/curl"
JQ_BIN="/usr/bin/jq"

# ================================ 配置区域结束，下方代码无需修改 ================================= #

CLASH_API_BASE_URL="http://${CLASH_API_IP}:${CLASH_API_PORT}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1 - $2"
}

# 【清理旧日志函数】 - 已升级日期计算兼容性
clean_old_logs() {
    local temp_log_file="${LOG_FILE}.tmp"
    local log_dir="$(dirname "$LOG_FILE")"

    # 如果日志目录不存在，尝试创建
    if [ ! -d "$log_dir" ]; then
        log "WARNING" "日志文件目录 ($log_dir) 不存在，尝试创建..."
        if ! mkdir -p "$log_dir"; then
            log "ERROR" "无法创建日志文件目录 ($log_dir)，日志清理和写入可能受影响。"
            return 1
        fi
        log "INFO" "已创建日志文件目录: $log_dir"
    fi

    # 如果日志文件不存在，尝试创建空文件
    if [ ! -f "$LOG_FILE" ]; then
        if touch "$LOG_FILE"; then
            chmod 644 "$LOG_FILE"
            log "INFO" "日志文件 ($LOG_FILE) 不存在，已创建新文件。"
        else
            log "ERROR" "无法创建日志文件 ($LOG_FILE)，请检查目录权限。"
            return 1
        fi
        return 0
    fi

    log "INFO" "开始清理超过 $LOG_RETENTION_DAYS 天的旧日志..."
    
    # ⚡️⚡️ 修正：更兼容的日期计算方法 ⚡️⚡️
    local current_timestamp=$(date +%s)
    local delete_before_timestamp=$((current_timestamp - LOG_RETENTION_DAYS * 86400)) # 86400秒 = 1天
    
    awk -v dt="$delete_before_timestamp" '
    BEGIN { OFS = "" }
    {
        if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
            time_str = substr($0, RSTART, RLENGTH)
            gsub(/[-:]/, " ", time_str)
            current_line_timestamp = mktime(time_str)
            if (current_line_timestamp >= dt) {
                print
            }
        } else {
            print # 非标准日期格式的行，为了安全，默认保留
        }
    }' "$LOG_FILE" > "$temp_log_file"

    if [ "$?" -eq 0 ] && [ -f "$temp_log_file" ]; then
        mv "$temp_log_file" "$LOG_FILE"
        chmod 644 "$LOG_FILE"
        log "INFO" "日志清理完成，当前文件行数：$(wc -l < "$LOG_FILE")"
    else
        log "ERROR" "日志清理失败或awk命令执行异常。保留原文件。"
        rm -f "$temp_log_file" 2>/dev/null
        return 1
    fi
    return 0
}


# 【函数：网站连通性检测】
check_website_access() {
    local check_title="$1"; if [ -z "$check_title" ]; then check_title="开始通过代理 (127.0.0.1:${CLASH_PROXY_HTTP_PORT}) 检测网络连通性..."; fi
    log 'INFO' "$check_title"
    
    local failed_count=0
    local target_urls_count=${#TARGET_URLS[@]}

    if [ "$target_urls_count" -eq 0 ]; then
        log "WARNING" "未配置任何 TARGET_URLS，默认判定网络【良好】。"
        return 0
    fi

    for url in "${TARGET_URLS[@]}"; do
        log "INFO" "  - 检测: '$url' ..." 

        local http_code=$("$CURL_BIN" -o /dev/null -s -w "%{http_code}" --connect-timeout "$TIMEOUT" --proxy "http://127.0.0.1:${CLASH_PROXY_HTTP_PORT}" -L "$url")
        if [ "$?" -eq 0 ] && [[ "$http_code" -ge 200 && "$http_code" -lt 400 ]]; then
            log "INFO" "    - 结果: '$url' 成功 (HTTP: $http_code)"
        else
            log "ERROR" "    - 结果: '$url' 失败 (HTTP: $http_code)"; failed_count=$((failed_count + 1));
        fi
    done

    if [ "$failed_count" -gt "$FAILED_THRESHOLD" ]; then
        log "WARNING" "网络状态评估：【不佳】($failed_count 个网站失败，已超过阈值 $FAILED_THRESHOLD)"
        return 1
    else
        log "INFO" "网络状态评估：【良好】($failed_count 个网站失败，未超过阈值 $FAILED_THRESHOLD)"
        return 0
    fi
}

# 【函数：获取并打印当前节点信息】
get_and_log_current_node() {
    log "INFO" "正在获取当前代理组 '$PROXY_GROUP_NAME' 的活动节点..."
    local headers="-H \"Content-Type: application/json\""; if [ -n "$CLASH_API_SECRET" ]; then headers+=" -H \"Authorization: Bearer $CLASH_API_SECRET\""; fi
    local encoded_group_name=$(echo -n "$PROXY_GROUP_NAME" | "$JQ_BIN" -sRr @uri); local final_url="${CLASH_API_BASE_URL}/proxies/${encoded_group_name}"
    local api_response=$("$CURL_BIN" -s $headers "$final_url")

    if ! echo "$api_response" | "$JQ_BIN" -e '.now' > /dev/null 2>&1; then log "ERROR" "Mihomo API返回异常或无法解析当前节点信息！"; log "ERROR" "API原始回复: $api_response"; return 1; fi
    local current_node=$(echo "$api_response" | "$JQ_BIN" -r '.now')
    log "INFO" "当前活动节点为: 【$current_node】"
    return 0
}

# 【函数二：切换到下一个节点】
switch_to_next() {
    log "INFO" "启动节点切换程序，目标代理组: '$PROXY_GROUP_NAME'"
    local headers="-H \"Content-Type: application/json\""; if [ -n "$CLASH_API_SECRET" ]; then headers+=" -H \"Authorization: Bearer $CLASH_API_SECRET\""; fi
    local encoded_group_name=$(echo -n "$PROXY_GROUP_NAME" | "$JQ_BIN" -sRr @uri); local final_url="${CLASH_API_BASE_URL}/proxies/${encoded_group_name}"
    local api_response=$("$CURL_BIN" -s $headers "$final_url")

    if ! echo "$api_response" | "$JQ_BIN" -e '.all' > /dev/null 2>&1; then log "ERROR" "Mihomo API返回异常或无法解析节点列表！无法切换。"; log "ERROR" "API原始回复: $api_response"; return 1; fi
    mapfile -t all_nodes < <(echo "$api_response" | "$JQ_BIN" -r '.all[]'); local current_node=$(echo "$api_response" | "$JQ_BIN" -r '.now')
    if [ ${#all_nodes[@]} -lt 2 ]; then log "WARNING" "组内节点少于2个，无法切换。"; return 1; fi
    log "INFO" "切换前活动节点: '$current_node'"; local current_index=-1
    for i in "${!all_nodes[@]}"; do if [[ "${all_nodes[$i]}" == "$current_node" ]]; then current_index=$i; break; fi; done
    if [ "$current_index" -eq -1 ]; then log "WARNING" "当前节点不在列表中？将从第一个开始计算。"; current_index=0; fi

    local next_index=$(( (current_index + 1) % ${#all_nodes[@]} )); local next_node="${all_nodes[$next_index]}"
    log "INFO" "计算出的下一个节点是: '$next_node'"

    log "INFO" "正在执行切换..."
    local payload=$("$JQ_BIN" -n --arg name "$next_node" '{"name":$name}'); local switch_response=$("$CURL_BIN" -s -w "\n%{http_code}" -X PUT $headers -d "$payload" "$final_url")
    local http_code=$(echo "$switch_response" | tail -n1)

    if [ "$http_code" = "204" ]; then log "SUCCESS" "✅ 节点切换成功！已切换至: '$next_node'"; return 0;
    else local body=$(echo "$switch_response" | sed '$d'); log "ERROR" "❌ 节点切换失败！HTTP状态码: $http_code"; if [ -n "$body" ]; then log "ERROR" "API返回信息: $body"; fi; return 1; fi
}

# --- 主逻辑 ---
main() {
    log "INFO" "--- 【终极智能版 · 日期兼容性修正】脚本启动 (代理组: $PROXY_GROUP_NAME) ---"
    
    clean_old_logs # 先清理旧日志

    local attempt=0
    local switch_needed=false

    if ! get_and_log_current_node; then
        log "ERROR" "首次启动无法获取当前节点信息，提前退出脚本。"
        log "INFO" "--- 脚本运行结束 ---"
        return 1
    fi
    
    if ! check_website_access "开始【初次】网络连通性检测..."; then
        switch_needed=true
        log "WARNING" "初次检测网络不佳，将启动循环切换机制。"
    else
        log "INFO" "网络连接良好，无需切换。"
    fi
    
    while $switch_needed && [ "$attempt" -lt "$MAX_RETRY_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        log "INFO" "--- 第 $attempt 次尝试切换和检测 (总共 $MAX_RETRY_ATTEMPTS 次) ---"
        
        if switch_to_next; then
            log "INFO" "等待 2 秒，让新节点网络生效..."
            sleep 2
            
            if get_and_log_current_node; then
                if check_website_access "开始【切换后复核】新节点的连通性..."; then
                    log "SUCCESS" "✅✅✅ 节点切换成功并复核合格！已退出循环。✅✅✅"
                    switch_needed=false
                else
                    log "WARNING" "新节点检测仍不合格，将尝试下一个节点..."
                    if [ "$attempt" -eq "$MAX_RETRY_ATTEMPTS" ]; then
                        log "ERROR" "已达最大重试次数 ($MAX_RETRY_ATTEMPTS)，仍未找到合格节点。放弃切换。"
                    fi
                fi
            else
                log "WARNING" "切换成功，但无法获取新节点信息进行复核，将尝试下一个节点..."
                 if [ "$attempt" -eq "$MAX_RETRY_ATTEMPTS" ]; then
                    log "ERROR" "已达最大重试次数 ($MAX_RETRY_ATTEMPTS)，仍未找到合格节点。放弃切换。"
                fi
            fi
        else
            log "ERROR" "节点切换操作失败，无法继续尝试。放弃。"
            switch_needed=false
        fi
    done

    if $switch_needed; then
        log "ERROR" "❌❌❌ 经过 $attempt 次尝试，未能找到合格的节点。请检查代理配置或节点可用性。❌❌❌"
    fi

    log "INFO" "--- 脚本运行结束 (代理组: $PROXY_GROUP_NAME) ---"
}

# 执行主函数
main

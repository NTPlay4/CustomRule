#!/bin/bash
# ===================================================================================
#  脚本名称: AutoSwitch-Super-UnifiedLog.sh
#  D姐荣誉出品: 【终极智能版 · 统一日志路径】
#  功能:     在【终极智能版】的基础上，将所有日志统一输出到指定的文件路径。
# ===================================================================================

# ================================ 【请仔细配置此区域】 ================================= #

# 【！！！您的真实密钥！！！】
CLASH_API_SECRET="您的真实密钥" # <--- !!! 请务-务-务-必】替换为您的真实完整密钥 !!!

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
FAILED_THRESHOLD=0

# 【！！！Mihomo的HTTP代理端口！！！】
CLASH_PROXY_HTTP_PORT="7890"

# 【！！！⚡️⚡️ 日志配置区域 (已修改为统一路径) ⚡️⚡️！！！】
LOG_FILE="/overlay/shell/Mihomo_AutoSwitch.log" # <--- !!! 日志文件路径已统一修改 !!!
LOG_RETENTION_DAYS=7                             # 日志保留天数，超过此天数的日志将被删除

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

# 调整日志函数格式，使其包含完整日期
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1 - $2"
}

# 【清理旧日志函数】 (已利用新 LOG_FILE 路径)
clean_old_logs() {
    local temp_log_file="${LOG_FILE}.tmp"
    if [ ! -f "$LOG_FILE" ]; then
        log "INFO" "日志文件 ($LOG_FILE) 不存在，无需清理。"
        # 如果日志文件不存在，但其父目录存在，尝试创建空日志文件以备后续写入
        if [ -d "$(dirname "$LOG_FILE")" ]; then
            touch "$LOG_FILE"
            chmod 644 "$LOG_FILE"
            log "INFO" "已创建新的日志文件: $LOG_FILE"
        else
            log "ERROR" "日志文件目录 $(dirname "$LOG_FILE") 不存在，无法创建日志文件。"
            return 1 # 目录不存在，清理失败
        fi
        return 0
    fi

    log "INFO" "开始清理超过 $LOG_RETENTION_DAYS 天的旧日志..."
    
    local delete_before_timestamp=$(date -d "$(date '+%Y-%m-%d %H:%M:%S') -${LOG_RETENTION_DAYS} days" +%s)
    
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
            print # 非标准日期格式的行，保留
        }
    }' "$LOG_FILE" > "$temp_log_file"

    if [ "$?" -eq 0 ] && [ -s "$temp_log_file" ] || [ ! -f "$LOG_FILE" ] && [ ! -s "$temp_log_file" ]; then # 确保awk成功或原文件就为空
        # 只有在临时文件非空或者原文件就是空的情况下才替换
        mv "$temp_log_file" "$LOG_FILE"
        chmod 644 "$LOG_FILE"
        log "INFO" "日志清理完成，当前文件行数：$(wc -l < "$LOG_FILE")"
    else
        log "ERROR" "日志清理失败或awk命令执行异常。保留原文件。临时文件内容（如有）：$(cat "$temp_log_file" 2>/dev/null)"
        rm -f "$temp_log_file" # 清理临时文件
    fi
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
        # 日志写入标准输出，由crontab重定向，不再echo到屏幕
        log "INFO" "  - 检测: '$url' ... (结果将由log函数统一输出)" # 这里的echo也要改成log
        # 使用log函数输出检测结果
        local http_code=$("$CURL_BIN" -o /dev/null -s -w "%{http_code}" --connect-timeout "$TIMEOUT" --proxy "http://127.0.0.1:${CLASH_PROXY_HTTP_PORT}" -L "$url")
        if [ "$?" -eq 0 ] && [[ "$http_code" -ge 200 && "$http_code" -lt 400 ]]; then
            log "INFO" "  - 检测: '$url' ... 成功 (HTTP: $http_code)"
        else
            log "ERROR" "  - 检测: '$url' ... 失败 (HTTP: $http_code)"; failed_count=$((failed_count + 1));
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
    log 

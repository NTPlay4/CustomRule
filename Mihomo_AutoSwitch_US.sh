#!/bin/bash
# ===================================================================================
#  脚本名称: AutoSwitch-Silent.sh
#  D姐荣誉出品: 【极致精简版 · 静默运行】
#  功能:     移除所有日志相关功能，脚本将完全静默运行。
#            仅执行节点检测、切换和重试的逻辑。
#  ⚠️ 警告：移除日志功能将使故障排查变得极其困难！请谨慎使用。
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
FAILED_THRESHOLD=1

# 【！！！Mihomo的HTTP代理端口！！！】
CLASH_PROXY_HTTP_PORT="7890"

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

# ================================ 日志相关函数已全部移除 ================================= #
# ======================== 这里的函数将不产生任何可见的输出 ========================= #

# 【函数：网站连通性检测】
check_website_access() {
    local failed_count=0
    local target_urls_count=${#TARGET_URLS[@]}

    if [ "$target_urls_count" -eq 0 ]; then
        return 0 # 良好
    fi

    for url in "${TARGET_URLS[@]}"; do
        local http_code=$("$CURL_BIN" -o /dev/null -s -w "%{http_code}" --connect-timeout "$TIMEOUT" --proxy "http://127.0.0.1:${CLASH_PROXY_HTTP_PORT}" -L "$url" --fail)
        if [ "$?" -eq 0 ] && [[ "$http_code" -ge 200 && "$http_code" -lt 400 ]]; then
            : # 成功，不输出
        else
            failed_count=$((failed_count + 1));
        fi
    done

    if [ "$failed_count" -gt "$FAILED_THRESHOLD" ]; then
        return 1 # 不佳
    else
        return 0 # 良好
    fi
}

# 【函数：获取当前节点信息 (仅用于内部判断，不输出)】
get_current_node_silent() {
    local headers="-H \"Content-Type: application/json\""; if [ -n "$CLASH_API_SECRET" ]; then headers+=" -H \"Authorization: Bearer $CLASH_API_SECRET\""; fi
    local encoded_group_name=$(echo -n "$PROXY_GROUP_NAME" | "$JQ_BIN" -sRr @uri); local final_url="${CLASH_API_BASE_URL}/proxies/${encoded_group_name}"
    local api_response=$("$CURL_BIN" -s $headers "$final_url")

    # 仅提取节点名，不打印
    local current_node=$(echo "$api_response" | "$JQ_BIN" -r '.now' 2>/dev/null)
    if [ -n "$current_node" ]; then
        echo "$current_node" # 仅返回节点名，方便调用者获取
        return 0
    else
        return 1 # 获取失败
    fi
}

# 【函数二：切换到下一个节点 (不输出细节日志)】
switch_to_next_silent() {
    local headers="-H \"Content-Type: application/json\""; if [ -n "$CLASH_API_SECRET" ]; then headers+=" -H \"Authorization: Bearer $CLASH_API_SECRET\""; fi
    local encoded_group_name=$(echo -n "$PROXY_GROUP_NAME" | "$JQ_BIN" -sRr @uri); local final_url="${CLASH_API_BASE_URL}/proxies/${encoded_group_name}"
    local api_response=$("$CURL_BIN" -s $headers "$final_url")

    if ! echo "$api_response" | "$JQ_BIN" -e '.all' > /dev/null 2>&1; then return 1; fi # 无法获取节点列表
    mapfile -t all_nodes < <(echo "$api_response" | "$JQ_BIN" -r '.all[]'); local current_node=$(echo "$api_response" | "$JQ_BIN" -r '.now')
    if [ ${#all_nodes[@]} -lt 2 ]; then return 1; fi # 组内节点少于2个
    
    local current_index=-1
    for i in "${!all_nodes[@]}"; do if [[ "${all_nodes[$i]}" == "$current_node" ]]; then current_index=$i; break; fi; done
    if [ "$current_index" -eq -1 ]; then current_index=0; fi # 当前节点不在列表中？从第一个开始

    local next_index=$(( (current_index + 1) % ${#all_nodes[@]} )); local next_node="${all_nodes[$next_index]}"
    
    local payload=$("$JQ_BIN" -n --arg name "$next_node" '{"name":$name}'); local switch_response=$("$CURL_BIN" -s -w "\n%{http_code}" -X PUT $headers -d "$payload" "$final_url")
    local http_code=$(echo "$switch_response" | tail -n1)

    if [ "$http_code" = "204" ]; then return 0; # 切换成功
    else return 1; fi # 切换失败
}

# --- 主逻辑 ---
main() {
    local attempt=0
    local switch_needed=false

    # 首次检查，判断是否需要切换
    if ! get_current_node_silent >/dev/null; then # 确保不产生输出
        return 1 # 首次启动无法获取当前节点信息，提前退出
    fi
    
    if ! check_website_access; then
        switch_needed=true
    else
        return 0 # 网络良好，无需切换，直接静默退出
    fi

    # 循环切换机制
    while $switch_needed && [ "$attempt" -lt "$MAX_RETRY_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        
        # 尝试切换节点
        if switch_to_next_silent; then
            sleep 2 # 等待 2 秒，让新节点网络生效
            
            # 切换成功后，复核
            if get_current_node_silent >/dev/null; then # 确保不产生输出
                if check_website_access; then
                    switch_needed=false # 新节点合格，跳出循环
                fi
            fi
        else
            return 1 # 节点切换操作本身失败，直接静默放弃
        fi
    done

    if $switch_needed; then
        return 1 # 达到最大重试次数仍未找到合格节点
    else
        return 0 # 成功找到合格节点
    fi
}

# 执行主函数
main

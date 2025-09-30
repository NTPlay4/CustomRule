#!/bin/bash
# ===================================================================================
#  脚本名称: LogClean-Manager-Detailed.sh
#  D姐荣誉出品: 【日志清理经理 · 精细报告】
#  功能:     在清理多个日志文件时，为每个文件提供更详细的日志输出。
#            报告清理了哪个路径，清理前后的行数，以及未清理的原因。
# ===================================================================================

# ================================ 【请仔细配置此区域】 ================================= #

# 【！！！⚡️⚡️要清理的日志文件路径列表⚡️⚡️！！！】
LOG_FILES_TO_CLEAN=(
    "/overlay/shell/Mihomo_AutoSwitch_US.log"
    "/overlay/shell/Mihomo_AutoSwitch_JP.log"
    # 添加您所有需要清理的日志文件路径
)

LOG_RETENTION_DAYS=7                             # 日志保留天数，超过此天数的日志将被删除

# --- 专业配置 (通常无需修改) ---
JQ_BIN="/usr/bin/jq" # JQ可能被用于其他日志处理，这里保留，以防万一

# ================================ 配置区域结束，下方代码无需修改 ================================= #

log_cleaner() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [LOG_CLEANER] $1 - $2"
}

# 【核心功能：清理单个日志文件】 - (日志输出已增强)
clean_single_log_file() {
    local target_log_file="$1"
    local temp_log_file="${target_log_file}.tmp"
    local log_dir="$(dirname "$target_log_file")"
    local initial_lines=0
    local final_lines=0
    local cleanup_performed=false

    log_cleaner "INFO" "--- 开始处理日志文件: $target_log_file ---"

    # 1. 检查并创建目录
    if [ ! -d "$log_dir" ]; then
        log_cleaner "WARNING" "  - 目录 '$log_dir' 不存在，尝试创建。"
        if ! mkdir -p "$log_dir"; then
            log_cleaner "ERROR" "  - 无法创建目录 '$log_dir'，清理失败。"
            return 1
        fi
        log_cleaner "INFO" "  - 目录 '$log_dir' 已创建。"
    fi

    # 2. 检查并创建日志文件
    if [ ! -f "$target_log_file" ]; then
        log_cleaner "INFO" "  - 日志文件 '$target_log_file' 不存在，尝试创建新文件。"
        if touch "$target_log_file"; then
            chmod 644 "$target_log_file"
            log_cleaner "INFO" "  - 已创建新文件 '$target_log_file'，无需清理。"
        else
            log_cleaner "ERROR" "  - 无法创建日志文件 '$target_log_file'，请检查权限。"
            return 1
        fi
        log_cleaner "INFO" "--- 处理文件结束: $target_log_file (未清理) ---"
        return 0 # 文件不存在或刚创建，无需清理，但视为成功处理
    fi

    # 3. 获取清理前行数
    initial_lines=$(wc -l < "$target_log_file" 2>/dev/null || echo 0)
    log_cleaner "INFO" "  - 清理前行数: $initial_lines 行。"

    if [ "$initial_lines" -eq 0 ]; then
        log_cleaner "INFO" "  - 文件为空，无需清理。"
        log_cleaner "INFO" "--- 处理文件结束: $target_log_file (未清理) ---"
        return 0
    fi

    log_cleaner "INFO" "  - 正在计算应删除的 $LOG_RETENTION_DAYS 天前的时间戳..."
    local current_timestamp=$(date +%s)
    local delete_before_timestamp=$((current_timestamp - LOG_RETENTION_DAYS * 86400)) # 86400秒 = 1天
    
    # 4. 执行AWK过滤
    log_cleaner "INFO" "  - 目标：保留时间戳 >= $delete_before_timestamp (即 $LOG_RETENTION_DAYS 天内) 的日志行。"
    awk -v dt="$delete_before_timestamp" -v logfile="$target_log_file" '
    BEGIN { OFS = ""; lines_kept = 0; lines_discarded = 0 }
    {
        if (match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
            time_str = substr($0, RSTART, RLENGTH)
            gsub(/[-:]/, " ", time_str)
            current_line_timestamp = mktime(time_str)
            if (current_line_timestamp >= dt) {
                print
                lines_kept++
            } else {
                lines_discarded++
            }
        } else {
            # 非标准日期格式的行，为了安全，默认保留
            print
            lines_kept++
            # print "WARNING: Non-standard log line retained: " $0 > "/dev/stderr" # 可以考虑输出到stderr方便调试
        }
    }
    END {
        # awk的print语句不会返回到shell变量，但可以通过awk自身输出总结
        # print "AWK_SUMMARY: Kept " lines_kept ", Discarded " lines_discarded > "/dev/stderr"
    }' "$target_log_file" > "$temp_log_file"

    local awk_exit_code=$?
    if [ "$awk_exit_code" -ne 0 ]; then
        log_cleaner "ERROR" "  - 日志清理失败：awk 命令执行异常 (退出码: $awk_exit_code)。保留原文件 '$target_log_file'。"
        rm -f "$temp_log_file" 2>/dev/null
        return 1
    fi

    # 5. 替换原文件 (仅当临时文件存在且awk成功处理时)
    if [ -f "$temp_log_file" ]; then
        mv -f "$temp_log_file" "$target_log_file" # 使用-f强制覆盖
        chmod 644 "$target_log_file"
        cleanup_performed=true
    else
        log_cleaner "ERROR" "  - 临时文件 '$temp_log_file' 不存在，或 awk 未能生成内容。保留原文件 '$target_log_file'。"
        return 1
    fi

    # 6. 获取清理后行数并报告
    final_lines=$(wc -l < "$target_log_file" 2>/dev/null || echo 0)
    if $cleanup_performed; then
        log_cleaner "INFO" "  - 清理完成！清理前: $initial_lines 行，清理后: $final_lines 行 (删除了 $((initial_lines - final_lines)) 行日志)。"
    else
         log_cleaner "INFO" "  - 未进行文件替换操作 (可能因无变化或错误)。清理后: $final_lines 行。"
    fi
    log_cleaner "INFO" "--- 处理文件结束: $target_log_file (清理 $cleanup_performed) ---"
    return 0
}

# --- 主逻辑 ---
main() {
    log_cleaner "INFO" "--- 【日志清理经理】脚本启动 ---"
    
    local overall_status=0 # 0表示所有文件清理成功，1表示至少一个文件清理失败

    for log_file in "${LOG_FILES_TO_CLEAN[@]}"; do
        if ! clean_single_log_file "$log_file"; then
            overall_status=1 # 如果有任何一个文件清理失败，就标记为失败
        fi
    done

    if [ "$overall_status" -eq 0 ]; then
        log_cleaner "SUCCESS" "✅ 所有指定日志文件清理流程完成！所有任务均成功。✅"
    else
        log_cleaner "ERROR" "❌ 部分日志文件清理失败，请检查上面针对具体文件的日志输出。❌"
    fi

    log_cleaner "INFO" "--- 【日志清理经理】脚本运行结束 ---"
}

# 执行主函数
main

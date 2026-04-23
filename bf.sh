#!/bin/bash

# ==========================================
# 哪吒面板 V2 自动备份与管理脚本
# (已优化：包含配置文件打包与迁移后自动重建 Cron)
# ==========================================

# 强制本脚本运行环境为北京时间 (东八区)
export TZ='Asia/Shanghai'

CURRENT_VERSION="1.3.0"
CONFIG_FILE="/root/.nezha_backup_config"
UPDATE_URL="https://raw.githubusercontent.com/ioiy/nezha_backup/main/bf.sh"

# 默认配置初始化
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << EOF
TG_TOKEN=""
TG_CHAT_ID=""
NOTIFY_MODE="ALL" # ALL: 成功失败都通知, FAIL_ONLY: 只通知失败, NONE: 不通知
RETENTION_DAYS="14"
S3_BUCKET=""
CRON_RULE="0 3 * * *"
ENCRYPT_PASS=""
RETAIN_FIRST_DAY="false"
EOF
    fi
    source "$CONFIG_FILE"
    # 兼容旧版本配置文件
    [ -z "$CRON_RULE" ] && CRON_RULE="0 3 * * *"
    [ -z "$RETAIN_FIRST_DAY" ] && RETAIN_FIRST_DAY="false"
}

# 保存配置
save_config() {
    cat > "$CONFIG_FILE" << EOF
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
NOTIFY_MODE="$NOTIFY_MODE"
RETENTION_DAYS="$RETENTION_DAYS"
S3_BUCKET="$S3_BUCKET"
CRON_RULE="$CRON_RULE"
ENCRYPT_PASS="$ENCRYPT_PASS"
RETAIN_FIRST_DAY="$RETAIN_FIRST_DAY"
EOF
    echo -e "\n\033[32m[OK]\033[0m 配置已保存！"
    sleep 1
}

# ----------------- 核心重试机制 -----------------
# 用法: execute_with_retry <最大重试次数> <重试间隔秒数> <具体命令...>
execute_with_retry() {
    local max_attempts=$1
    local interval=$2
    shift 2
    local attempt=1
    local exit_code=0
    
    while [ $attempt -le $max_attempts ]; do
        "$@"
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            return 0
        fi
        
        # 仅在非 cron 模式下打印重试警告到终端，避免 cron 产生多余邮件/日志
        if [ "$run_mode" != "cron" ]; then
            echo -e "\033[33m[警告]\033[0m 命令执行失败 (退出码: $exit_code)，将在 $interval 秒后进行第 $attempt/$max_attempts 次重试..."
        fi
        sleep $interval
        attempt=$((attempt + 1))
    done
    return $exit_code
}

# TG 通知发送函数
send_tg() {
    local status=$1
    local message=$2
    
    if [ "$NOTIFY_MODE" == "NONE" ]; then return; fi
    if [ "$NOTIFY_MODE" == "FAIL_ONLY" ] && [ "$status" == "SUCCESS" ]; then return; fi
    if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then return; fi

    local current_time=$(date "+%Y-%m-%d %H:%M:%S")
    local text="🤖 <b>哪吒面板备份通知</b>%0A⏰ 北京时间: ${current_time}%0A"
    
    if [ "$status" == "SUCCESS" ]; then
        # 获取服务器状态
        local disk_usage=$(df -h / | awk 'NR==2 {print $5}')
        local mem_usage=$(free -m | awk 'NR==2{printf "%.2f%%", $3*100/$2 }')
        
        text="${text}✅ <b>状态: 备份成功</b>%0A📄 ${message}%0A%0A🖥 <b>服务器状态</b>%0A💾 根目录占用: ${disk_usage}%0A🧠 内存占用: ${mem_usage}"
    else
        text="${text}❌ <b>状态: 备份失败</b>%0A⚠️ 原因: ${message}"
    fi

    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="${text}" > /dev/null 2>&1
}

# 核心备份逻辑 (Cron 调用的部分)
run_backup() {
    local run_mode="$1"
    source "$CONFIG_FILE"
    
    if [ -z "$S3_BUCKET" ]; then
        send_tg "FAIL" "未配置 S3 存储桶名称，请进入控制面板配置。"
        exit 1
    fi

    # 如果是 Cron 定时后台运行，启用极致静默低优先级模式
    if [ "$run_mode" == "cron" ]; then
        # 降低当前脚本及子进程的 CPU 调度优先级
        renice -n 19 -p $$ >/dev/null 2>&1
        # 降低磁盘 IO 优先级
        if command -v ionice >/dev/null 2>&1; then
            ionice -c 2 -n 7 -p $$ >/dev/null 2>&1
        fi
    fi

    # --- 预检机制: 磁盘空间 ---
    if [ "$run_mode" != "cron" ]; then echo "正在进行磁盘空间预检..."; fi
    local NEZHA_SIZE_KB=$(du -sk /opt/nezha 2>/dev/null | awk '{print $1}')
    local AVAIL_SPACE_KB=$(df -k / | awk 'NR==2 {print $4}')
    local REQ_SPACE_KB=$((NEZHA_SIZE_KB + 102400)) # 加上 100MB 缓冲
    
    if [ -n "$AVAIL_SPACE_KB" ] && [ -n "$NEZHA_SIZE_KB" ] && [ "$AVAIL_SPACE_KB" -lt "$REQ_SPACE_KB" ]; then
        send_tg "FAIL" "服务器磁盘空间严重不足！打包需要约 $((REQ_SPACE_KB/1024))MB，当前仅剩 $((AVAIL_SPACE_KB/1024))MB。为防止宕机，已终止备份。"
        [ "$run_mode" != "cron" ] && echo -e "\033[31m[错误]\033[0m 磁盘可用空间不足以完成打包！"
        exit 1
    fi

    # --- 预检机制: 数据库完整性 ---
    local DB_PATH="/opt/nezha/dashboard/data/sqlite.db"
    if [ -f "$DB_PATH" ]; then
        if command -v sqlite3 >/dev/null 2>&1; then
            if [ "$run_mode" != "cron" ]; then echo "正在进行数据库完整性校验..."; fi
            local DB_CHECK=$(sqlite3 "$DB_PATH" "PRAGMA integrity_check;" 2>&1)
            if [[ "$DB_CHECK" != *"ok"* ]]; then
                send_tg "FAIL" "数据库完整性预检失败！数据可能已损坏，已终止备份以防覆盖云端正常存档。诊断信息: $DB_CHECK"
                [ "$run_mode" != "cron" ] && echo -e "\033[31m[错误]\033[0m 数据库完整性校验未通过: $DB_CHECK"
                exit 1
            fi
        fi
    fi

    # 修改日期格式以便于过滤每月1号 (北京时间)
    DATE_STR=$(date +%Y-%m-%d_%H%M)
    
    # 1. 打包数据与加密 (此处将备份脚本的配置文件 $CONFIG_FILE 一并打包进去)
    if [ -n "$ENCRYPT_PASS" ]; then
        BACKUP_FILE="/root/nezha_backup_${DATE_STR}.tar.gz.enc"
        [ "$run_mode" != "cron" ] && echo "开始打包并加密 /opt/nezha 目录与脚本配置..."
        tar -czf - /opt/nezha "$CONFIG_FILE" 2>/dev/null | openssl enc -aes-256-cbc -pbkdf2 -salt -k "$ENCRYPT_PASS" > "$BACKUP_FILE"
        if [ $? -ne 0 ]; then
            send_tg "FAIL" "打包并加密失败，请检查磁盘空间或 openssl 依赖。"
            exit 1
        fi
    else
        BACKUP_FILE="/root/nezha_backup_${DATE_STR}.tar.gz"
        [ "$run_mode" != "cron" ] && echo "开始打包 /opt/nezha 目录与脚本配置..."
        tar -czf "$BACKUP_FILE" /opt/nezha "$CONFIG_FILE" > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            send_tg "FAIL" "打包目录失败，请检查磁盘空间或权限。"
            exit 1
        fi
    fi
    
    FILE_SIZE=$(du -sh "$BACKUP_FILE" | awk '{print $1}')

    # 2. 上传到 S3 (引入重试机制)
    [ "$run_mode" != "cron" ] && echo "开始上传至 S3 (启用重试机制)..."
    local RCLONE_OPTS="--transfers 1 --buffer-size 0 --use-mmap --s3-no-check-bucket"
    if [ "$run_mode" != "cron" ] && [ -t 0 ]; then
        RCLONE_OPTS="$RCLONE_OPTS -P" # 只有手动运行才显示上传进度
    fi
    
    # 执行上传：最多重试 3 次，每次间隔 10 秒
    execute_with_retry 3 10 rclone copy "$BACKUP_FILE" "nezha_s3:${S3_BUCKET}/nezha_backups/" $RCLONE_OPTS
    if [ $? -ne 0 ]; then
        send_tg "FAIL" "经过 3 次重试，上传到 S3 依然失败，请检查 Rclone 配置和网络连通性。"
        rm -f "$BACKUP_FILE"
        exit 1
    fi

    # 3. 清理旧备份 (引入重试机制)
    [ "$run_mode" != "cron" ] && echo "清理 ${RETENTION_DAYS} 天前的旧备份..."
    local DELETE_OPTS="--min-age ${RETENTION_DAYS}d --s3-no-check-bucket"
    if [ "$RETAIN_FIRST_DAY" == "true" ]; then
        # 排除包含 -01_ 的文件，实现每月1号长效保留
        DELETE_OPTS="$DELETE_OPTS --exclude *_*-01_*.*"
    fi
    # 清理操作最多重试 3 次
    execute_with_retry 3 10 rclone delete "nezha_s3:${S3_BUCKET}/nezha_backups/" $DELETE_OPTS > /dev/null 2>&1

    # 4. 扫尾与通知
    rm -f "$BACKUP_FILE"
    local notify_msg="数据与脚本配置已成功打包上传！%0A📦 文件大小: ${FILE_SIZE}%0A🧹 已清理 ${RETENTION_DAYS} 天前的旧文件。"
    [ "$RETAIN_FIRST_DAY" == "true" ] && notify_msg="${notify_msg}%0A🛡️ 已过滤每月1号的长效备份。"
    [ -n "$ENCRYPT_PASS" ] && notify_msg="${notify_msg}%0A🔒 数据已进行 AES-256 强加密。"
    
    send_tg "SUCCESS" "$notify_msg"
    
    # 手动运行结束提示
    if [ "$run_mode" != "cron" ] && [ -t 0 ]; then
        echo -e "\n\033[32m[OK]\033[0m 备份流程执行完毕！"
        read -n 1 -s -r -p "按任意键返回主菜单..."
    fi
}

# ----------------- UI 交互部分 -----------------

setup_s3() {
    clear
    echo "=========================================="
    echo "          配置 S3 存储桶 (Rclone)         "
    echo "=========================================="
    
    if ! command -v rclone &> /dev/null; then
        echo "检测到未安装 Rclone，正在自动安装..."
        curl -s https://rclone.org/install.sh | sudo bash
    fi

    echo ""
    read -p "请输入 Endpoint (例如: https://ny-1s.enzonix.com): " s3_endpoint
    read -p "请输入 地区 (例如 us-east-1，直接回车默认为 us-east-1): " s3_region
    s3_region=${s3_region:-us-east-1} # 默认值设置
    read -p "请输入 访问密钥 Id: " s3_ak
    read -p "请输入 安全访问密钥: " s3_sk
    read -p "请输入 存储桶 (Bucket) 名称: " S3_BUCKET

    # 写入 rclone 配置文件
    mkdir -p /root/.config/rclone
    cat > /root/.config/rclone/rclone.conf << EOF
[nezha_s3]
type = s3
provider = Other
env_auth = false
access_key_id = ${s3_ak}
secret_access_key = ${s3_sk}
endpoint = ${s3_endpoint}
region = ${s3_region}
force_path_style = true
no_check_bucket = true
EOF

    save_config
    echo -e "\n\033[32m[OK]\033[0m Rclone 和 S3 配置已生成！名称为 [nezha_s3]"
    sleep 2
    quick_check_s3
}

# 快速检测 S3 连接状态 (无 UI，用于主菜单显示)
quick_check_s3() {
    if [ -z "$S3_BUCKET" ]; then
        S3_CONN_STATUS="\033[31m[未配置]\033[0m"
    else
        # 检测连接也使用重试，避免偶尔的网络抖动造成误判
        if execute_with_retry 2 3 rclone lsf "nezha_s3:${S3_BUCKET}" --s3-no-check-bucket --contimeout 5s --retries 1 > /dev/null 2>&1; then
            S3_CONN_STATUS="\033[32m[✅ 正常]\033[0m"
        else
            S3_CONN_STATUS="\033[31m[❌ 异常]\033[0m"
        fi
    fi
}

# 交互式管理 S3 中的备份
manage_backups() {
    if [ -z "$S3_BUCKET" ]; then
        clear
        echo "=========================================="
        echo "        可视化 S3 备份管理中心            "
        echo "=========================================="
        echo -e "\033[31m[错误]\033[0m 尚未配置 S3 存储桶名称，请先配置！"
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
        return
    fi

    while true; do
        clear
        echo "=========================================="
        echo "        可视化 S3 备份管理中心            "
        echo "=========================================="
        echo -e "正在获取云端备份数据，请稍候...\n"
        
        # 将文件列表抓取到 Bash 数组中，按时间倒序
        FILES=($(rclone lsf "nezha_s3:${S3_BUCKET}/nezha_backups/" --s3-no-check-bucket | grep -E '\.tar\.gz$|\.enc$' | sort -r))
        
        if [ ${#FILES[@]} -eq 0 ]; then
            echo -e "\033[33m[提示]\033[0m 当前存储桶中还没有任何备份文件。"
            echo ""
            read -n 1 -s -r -p "按任意键返回主菜单..."
            break
        fi
        
        # 打印带序号的列表
        for i in "${!FILES[@]}"; do
            echo -e " [\033[36m$i\033[0m] ${FILES[$i]}"
        done
        
        echo -e "\n------------------------------------------"
        echo "操作说明："
        echo " - 输入数字 (如 0)     可 🗑️ 永久删除对应备份"
        echo " - 输入 r+数字 (如 r0) 可 🚑 定点恢复对应备份"
        echo " - 直接回车 或 输入 q  可退出管理中心返回主菜单"
        echo "------------------------------------------"
        read -p "请输入操作指令: " action
        
        if [ -z "$action" ] || [ "$action" == "q" ] || [ "$action" == "Q" ]; then
            break
        elif [[ "$action" =~ ^r([0-9]+)$ ]]; then
            local idx="${BASH_REMATCH[1]}"
            if [ -n "${FILES[$idx]}" ]; then
                restore_backup "${FILES[$idx]}"
                break
            else
                echo -e "\033[31m[错误]\033[0m 无效的序号！" && sleep 1
            fi
        elif [[ "$action" =~ ^[0-9]+$ ]]; then
            local idx="$action"
            if [ -n "${FILES[$idx]}" ]; then
                read -p "⚠️ 确定要永久删除 ${FILES[$idx]} 吗？[y/N]: " del_confirm
                if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                    echo "正在向 S3 发送删除请求..."
                    execute_with_retry 3 5 rclone deletefile "nezha_s3:${S3_BUCKET}/nezha_backups/${FILES[$idx]}" --s3-no-check-bucket
                    if [ $? -eq 0 ]; then
                        echo -e "\033[32m[成功]\033[0m 备份文件已删除！"
                    else
                        echo -e "\033[31m[错误]\033[0m 删除失败，请重试。"
                    fi
                    sleep 1
                fi
            else
                echo -e "\033[31m[错误]\033[0m 无效的序号！" && sleep 1
            fi
        else
            echo -e "\033[31m[错误]\033[0m 未知指令，请重新输入！" && sleep 1
        fi
    done
    quick_check_s3
}

setup_tg() {
    clear
    echo "=========================================="
    echo "          配置 Telegram Bot 通知          "
    echo "=========================================="
    read -p "请输入 TG Bot Token (留空不修改): " input_token
    read -p "请输入 接收通知的 Chat ID (留空不修改): " input_chat_id
    
    [ -n "$input_token" ] && TG_TOKEN="$input_token"
    [ -n "$input_chat_id" ] && TG_CHAT_ID="$input_chat_id"
    
    echo "选择通知模式:"
    echo "1. 全部通知 (成功和失败都发)"
    echo "2. 仅失败时通知 (适合不希望被打扰)"
    echo "3. 关闭通知"
    read -p "请选择 [1-3]: " mode_choice
    
    case $mode_choice in
        1) NOTIFY_MODE="ALL" ;;
        2) NOTIFY_MODE="FAIL_ONLY" ;;
        3) NOTIFY_MODE="NONE" ;;
        *) echo "输入无效，保持原有配置" ;;
    esac
    save_config
}

setup_retention() {
    clear
    echo "=========================================="
    echo "          配置历史备份保留天数            "
    echo "=========================================="
    echo "当前保留天数: ${RETENTION_DAYS} 天"
    read -p "请输入你想保留的天数 (纯数字，例如 14): " input_days
    
    if [[ "$input_days" =~ ^[0-9]+$ ]]; then
        RETENTION_DAYS="$input_days"
    else
        echo -e "\033[31m[错误]\033[0m 请输入有效的数字！"
        sleep 2
        return
    fi

    echo ""
    echo "【长效白名单策略 (GFS)】"
    echo "开启后，系统将永久保留每月 1 号的备份文件，不受 ${RETENTION_DAYS} 天规则限制。"
    echo -e "当前状态: $( [ "$RETAIN_FIRST_DAY" == "true" ] && echo -e "\033[32m已开启\033[0m" || echo -e "\033[31m未开启\033[0m" )"
    read -p "是否开启长效保留策略？[y/N]: " confirm_gfs
    if [[ "$confirm_gfs" =~ ^[Yy]$ ]]; then
        RETAIN_FIRST_DAY="true"
    else
        RETAIN_FIRST_DAY="false"
    fi
    
    save_config
}

setup_cron() {
    clear
    echo "=========================================="
    echo "             配置自动备份定时任务             "
    echo "=========================================="
    
    echo "正在确保系统时区为北京时间以保障定时执行精准..."
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone Asia/Shanghai 2>/dev/null
    else
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null
    fi
    echo -e "当前服务器系统时间: \033[36m$(date "+%Y-%m-%d %H:%M:%S")\033[0m"
    echo "------------------------------------------"
    echo -e "当前定时规则: \033[33m${CRON_RULE}\033[0m"
    echo "------------------------------------------"
    echo " 1. 每天凌晨 3:00 (0 3 * * *) [基于北京时间]"
    echo " 2. 每 12 小时一次 (0 */12 * * *)"
    echo " 3. 每周日凌晨 3:00 (0 3 * * 0) [基于北京时间]"
    echo " 4. 自定义 Cron 表达式"
    echo " 5. 🛑 关闭/删除定时任务"
    read -p "请选择 [1-5]: " cron_choice
    
    SCRIPT_PATH=$(readlink -f "$0")
    CRON_CMD="$SCRIPT_PATH cron > /dev/null 2>&1"
    
    if [ "$cron_choice" == "5" ]; then
        crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab -
        echo -e "\033[32m[OK]\033[0m 定时任务已关闭！"
        sleep 2
        return
    fi
    
    case $cron_choice in
        1) CRON_RULE="0 3 * * *" ;;
        2) CRON_RULE="0 */12 * * *" ;;
        3) CRON_RULE="0 3 * * 0" ;;
        4) 
            read -p "请输入自定义 Cron 表达式 (例如 30 4 * * *): " input_cron
            CRON_RULE="$input_cron"
            ;;
        *) echo "输入无效，保持原有配置" && sleep 1 && return ;;
    esac
    
    save_config
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_RULE $CRON_CMD") | crontab -
    echo -e "\033[32m[OK]\033[0m 定时任务已更新为: ${CRON_RULE}"
    sleep 2
}

setup_encryption() {
    clear
    echo "=========================================="
    echo "         🔒 配置备份文件加密              "
    echo "=========================================="
    echo -e "启用加密后，您的数据在 S3 中将以密文形式存放，极大地提升安全性。"
    echo -e "当前状态: $( [ -n "$ENCRYPT_PASS" ] && echo -e "\033[32m已开启\033[0m" || echo -e "\033[31m未开启\033[0m" )\n"
    
    read -p "请输入备份加密密码 (留空则关闭加密): " input_pass
    ENCRYPT_PASS="$input_pass"
    save_config
    
    if [ -n "$ENCRYPT_PASS" ]; then
        echo -e "\033[32m[OK]\033[0m 备份加密已开启！请务必牢记您的密码。"
    else
        echo -e "\033[33m[OK]\033[0m 备份加密已关闭。"
    fi
    sleep 2
}

update_script() {
    clear
    echo "=========================================="
    echo "             检查脚本更新版本             "
    echo "=========================================="
    
    SCRIPT_PATH=$(readlink -f "$0")
    TMP_FILE="/tmp/nezha_backup_update.sh"

    echo -e "正在从 GitHub 获取最新版本信息..."
    curl -L -s "${UPDATE_URL}?t=$(date +%s)" -o "$TMP_FILE"

    if [ $? -eq 0 ] && grep -q "^CURRENT_VERSION=" "$TMP_FILE"; then
        NEW_VERSION=$(grep "^CURRENT_VERSION=" "$TMP_FILE" | cut -d'"' -f2 | head -n 1)
        
        echo -e "\n当前版本: \033[33mv${CURRENT_VERSION}\033[0m"
        echo -e "最新版本: \033[32mv${NEW_VERSION}\033[0m"
        
        if [ "$CURRENT_VERSION" == "$NEW_VERSION" ]; then
            echo -e "\n当前已是最新版本，无需更新！"
            rm -f "$TMP_FILE"
            read -n 1 -s -r -p "按任意键返回主菜单..."
            return
        fi

        echo ""
        read -p "发现新版本，是否立即覆盖更新？[Y/n]: " confirm_update
        case "$confirm_update" in
            [yY][eE][sS]|[yY]|"")
                cat "$TMP_FILE" > "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"
                rm -f "$TMP_FILE"
                echo -e "\n\033[32m[OK]\033[0m 脚本更新成功！"
                echo -e "请按任意键重启面板..."
                read -n 1 -s -r
                exec "$SCRIPT_PATH"
                ;;
            *)
                echo -e "\n已取消更新。"
                rm -f "$TMP_FILE"
                sleep 2
                ;;
        esac
    else
        echo -e "\n\033[31m[错误]\033[0m 下载失败或文件不完整，无法获取版本信息。"
        rm -f "$TMP_FILE"
        sleep 3
    fi
}

# 从 S3 恢复指定或最新备份 (并包含配置重载逻辑)
restore_backup() {
    local target_file="$1"
    clear
    echo "=========================================="
    echo "          从 S3 恢复备份数据              "
    echo "=========================================="
    if [ -z "$S3_BUCKET" ]; then
        echo -e "\033[31m[错误]\033[0m 尚未配置 S3 存储桶，请先配置！"
        sleep 2; return
    fi

    if [ -z "$target_file" ]; then
        echo "正在连接 S3 获取最新的备份列表..."
        target_file=$(execute_with_retry 3 5 rclone lsf "nezha_s3:${S3_BUCKET}/nezha_backups/" --s3-no-check-bucket | grep -E '\.tar\.gz$|\.enc$' | sort -r | head -n 1)
        
        if [ -z "$target_file" ]; then
            echo -e "\n\033[31m[失败]\033[0m 未在 S3 存储桶中找到任何备份文件或网络连接失败！"
            read -n 1 -s -r -p "按任意键返回主菜单..."
            return
        fi
    fi

    echo -e "\n准备恢复备份: \033[32m${target_file}\033[0m"
    echo -e "\033[31m⚠️ 警告：恢复操作将停止面板服务，并覆盖当前的 /opt/nezha 及本脚本配置！\033[0m"
    read -p "确定要继续吗？[y/N]: " confirm_restore
    
    if [[ "$confirm_restore" =~ ^[Yy]$ ]]; then
        echo -e "\n1. 正在从 S3 下载备份文件 (最大重试 3 次，显示实时进度)..."
        execute_with_retry 3 10 rclone copy "nezha_s3:${S3_BUCKET}/nezha_backups/${target_file}" /tmp/ -P --transfers 1 --buffer-size 0 --use-mmap --s3-no-check-bucket
        
        if [ $? -eq 0 ]; then
            echo -e "\n2. 下载成功，正在停止哪吒面板服务..."
            systemctl stop nezha-dashboard 2>/dev/null
            
            # 判断是否是加密备份
            if [[ "$target_file" == *.enc ]]; then
                if [ -z "$ENCRYPT_PASS" ]; then
                    read -s -p "🔒 此备份已加密，请输入解密密码: " input_pass
                    echo ""
                else
                    input_pass="$ENCRYPT_PASS"
                    echo "🔒 检测到预设了加密密码，正在自动尝试解密..."
                fi
                echo "3. 正在解密并解压数据与配置文件..."
                if ! openssl enc -d -aes-256-cbc -pbkdf2 -salt -k "$input_pass" -in "/tmp/${target_file}" | tar -xz -C /; then
                    echo -e "\n\033[31m[错误]\033[0m 解密失败！密码错误或文件已损坏。"
                    systemctl restart nezha-dashboard 2>/dev/null
                    rm -f "/tmp/${target_file}"
                    read -n 1 -s -r -p "按任意键返回主菜单..."
                    return
                fi
            else
                echo "3. 正在解压并覆盖数据与配置文件..."
                tar -xzf "/tmp/${target_file}" -C /
            fi
            
            echo "4. 正在还原系统与脚本运行配置..."
            if [ -f "$CONFIG_FILE" ]; then
                # 重新加载刚解压出的配置文件
                source "$CONFIG_FILE"
                
                # 尝试根据原配置为新服务器注册自动备份 Cron 任务
                SCRIPT_PATH=$(readlink -f "$0")
                CRON_CMD="$SCRIPT_PATH cron > /dev/null 2>&1"
                (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_RULE $CRON_CMD") | crontab -
                echo "   ✅ 已成功迁移并挂载定时任务: $CRON_RULE"
            fi
            
            echo "5. 正在重启面板服务..."
            systemctl restart nezha-dashboard 2>/dev/null
            
            echo "6. 正在清理临时文件..."
            rm -f "/tmp/${target_file}"
            
            echo -e "\n\033[32m[成功]\033[0m 数据及配置恢复完毕，哪吒面板已重新启动！"
        else
            echo -e "\n\033[31m[错误]\033[0m 下载备份文件失败，请检查网络或配置。"
            rm -f "/tmp/${target_file}"
        fi
    else
        echo -e "\n已取消恢复操作。"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# 主菜单
show_menu() {
    init_config
    clear
    echo -e "正在初始化并检测 S3 连接状态，请稍候..."
    quick_check_s3

    while true; do
        clear
        echo -e "=========================================="
        echo -e "   \033[36m哪吒面板 V2 数据备份控制台 \033[32m[v${CURRENT_VERSION}]\033[0m"
        echo -e "=========================================="
        echo -e " S3 存储桶  : \033[33m${S3_BUCKET:-未配置}\033[0m ${S3_CONN_STATUS}"
        echo -e " 定时规则   : \033[33m${CRON_RULE}\033[0m $(crontab -l 2>/dev/null | grep "$0" > /dev/null && echo "[\033[32m运行中\033[0m]" || echo "[\033[31m未开启\033[0m]")"
        echo -e " 保留天数   : \033[33m${RETENTION_DAYS} 天\033[0m $( [ "$RETAIN_FIRST_DAY" == "true" ] && echo "[+每月1号长效保留]" )"
        echo -e " 数据加密   : $( [ -n "$ENCRYPT_PASS" ] && echo "\033[32m已开启\033[0m" || echo "\033[31m未开启\033[0m" )"
        echo -e "=========================================="
        echo " 1. 🚀 立即执行一次备份"
        echo " 2. 🪣  配置 S3 存储桶参数 (Rclone)"
        echo " 3. 🗂️  可视化管理 (查看/删除/定点恢复)"
        echo " 4. 🤖 配置 Telegram Bot 通知"
        echo " 5. 📅 设置旧备份保留天数与长效白名单"
        echo " 6. ⏰ 配置自动备份定时任务"
        echo " 7. 🔄 检查并从 GitHub 更新脚本"
        echo " 8. 🚑 从 S3 一键恢复最新备份"
        echo " 9. 🔒 配置备份文件加密"
        echo " 0. 退出面板"
        echo "=========================================="
        read -p "请输入选项 [0-9]: " choice
        
        case $choice in
            1) run_backup "manual" ;;
            2) setup_s3 ;;
            3) manage_backups ;;
            4) setup_tg ;;
            5) setup_retention ;;
            6) setup_cron ;;
            7) update_script ;;
            8) restore_backup ;;
            9) setup_encryption ;;
            0) exit 0 ;;
            *) echo "无效选项，请重新输入" && sleep 1 ;;
        esac
    done
}

# 脚本入口点判断
if [ "$1" == "cron" ]; then
    init_config
    run_backup "cron"
else
    show_menu
fi

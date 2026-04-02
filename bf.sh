#!/bin/bash

# ==========================================
# 哪吒面板 V2 自动备份与管理脚本
# ==========================================

CURRENT_VERSION="1.0.3"
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
EOF
    fi
    source "$CONFIG_FILE"
}

# 保存配置
save_config() {
    cat > "$CONFIG_FILE" << EOF
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
NOTIFY_MODE="$NOTIFY_MODE"
RETENTION_DAYS="$RETENTION_DAYS"
S3_BUCKET="$S3_BUCKET"
EOF
    echo -e "\n\033[32m[OK]\033[0m 配置已保存！"
    sleep 1
}

# TG 通知发送函数
send_tg() {
    local status=$1
    local message=$2
    
    if [ "$NOTIFY_MODE" == "NONE" ]; then return; fi
    if [ "$NOTIFY_MODE" == "FAIL_ONLY" ] && [ "$status" == "SUCCESS" ]; then return; fi
    if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then return; fi

    local current_time=$(date "+%Y-%m-%d %H:%M:%S")
    local text="🤖 <b>哪吒面板备份通知</b>%0A⏰ 时间: ${current_time}%0A"
    
    if [ "$status" == "SUCCESS" ]; then
        text="${text}✅ <b>状态: 备份成功</b>%0A📄 ${message}"
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
    source "$CONFIG_FILE"
    
    if [ -z "$S3_BUCKET" ]; then
        send_tg "FAIL" "未配置 S3 存储桶名称，请进入控制面板配置。"
        exit 1
    fi

    DATE_STR=$(date +%Y%m%d_%H%M)
    BACKUP_FILE="/root/nezha_backup_${DATE_STR}.tar.gz"
    
    # 1. 打包数据
    echo "开始打包 /opt/nezha 目录..."
    tar -czf "$BACKUP_FILE" /opt/nezha > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        send_tg "FAIL" "打包 /opt/nezha 目录失败，请检查磁盘空间或权限。"
        exit 1
    fi
    
    FILE_SIZE=$(du -sh "$BACKUP_FILE" | awk '{print $1}')

    # 2. 上传到 S3 (加入了极低内存参数)
    echo "开始上传至 S3..."
    rclone copy "$BACKUP_FILE" "nezha_s3:${S3_BUCKET}/nezha_backups/" --transfers 1 --buffer-size 0 --use-mmap > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        send_tg "FAIL" "上传到 S3 失败，请检查 Rclone 配置和网络连通性。"
        rm -f "$BACKUP_FILE"
        exit 1
    fi

    # 3. 清理旧备份
    echo "清理 ${RETENTION_DAYS} 天前的旧备份..."
    rclone delete "nezha_s3:${S3_BUCKET}/nezha_backups/" --min-age "${RETENTION_DAYS}d" > /dev/null 2>&1

    # 4. 扫尾与通知
    rm -f "$BACKUP_FILE"
    send_tg "SUCCESS" "数据已成功打包上传！%0A📦 文件大小: ${FILE_SIZE}%0A🧹 已清理 ${RETENTION_DAYS} 天前的旧文件。"
    
    # 如果是手动运行，稍微停留一下
    if [ -t 0 ]; then
        echo -e "\033[32m[OK]\033[0m 备份流程执行完毕！"
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

    # 写入 rclone 配置文件，加入 region 和 force_path_style 修复兼容性问题
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
}

# 检测 S3 连接状态
check_s3() {
    clear
    echo "=========================================="
    echo "          测试 S3 存储桶连接状态          "
    echo "=========================================="
    if [ -z "$S3_BUCKET" ]; then
        echo -e "\033[31m[错误]\033[0m 尚未配置 S3 存储桶名称，请先配置！"
    else
        echo "正在尝试连接并获取 S3 数据 (超时 10 秒)..."
        # 使用 lsf 列出目录代替 mkdir，避免触发 bucket 创建权限问题
        if rclone lsf "nezha_s3:${S3_BUCKET}" --contimeout 10s --retries 1 > /dev/null 2>&1; then
            echo -e "\n\033[32m[成功]\033[0m 连接正常！可以顺利访问 ${S3_BUCKET} 桶。"
        else
            echo -e "\n\033[31m[失败]\033[0m 连接异常！请检查：\n1. 访问密钥或 Endpoint 是否填写错误\n2. 存储桶 ${S3_BUCKET} 是否存在\n3. 机器网络是否通畅"
        fi
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
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
        save_config
    else
        echo -e "\033[31m[错误]\033[0m 请输入有效的数字！"
        sleep 2
    fi
}

setup_cron() {
    clear
    echo "=========================================="
    echo "             配置定时自动备份             "
    echo "=========================================="
    echo "我们将配置脚本在每天凌晨自动执行。"
    
    SCRIPT_PATH=$(readlink -f "$0")
    CRON_CMD="0 3 * * * $SCRIPT_PATH cron > /dev/null 2>&1"
    
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH"; echo "$CRON_CMD") | crontab -
    echo -e "\033[32m[OK]\033[0m 定时任务已添加！每天凌晨 03:00 自动执行备份。"
    sleep 2
}

# 在线更新脚本 (带版本比对和确认)
update_script() {
    clear
    echo "=========================================="
    echo "            检查脚本更新版本              "
    echo "=========================================="
    
    SCRIPT_PATH=$(readlink -f "$0")
    TMP_FILE="/tmp/nezha_backup_update.sh"

    echo -e "正在从 GitHub 获取最新版本信息..."
    # 核心修复点：添加时间戳 ?t=$(date +%s) 来强制绕过 GitHub Raw CDN 缓存
    curl -L -s "${UPDATE_URL}?t=$(date +%s)" -o "$TMP_FILE"

    # 验证下载是否成功且包含版本号变量
    if [ $? -eq 0 ] && grep -q "^CURRENT_VERSION=" "$TMP_FILE"; then
        # 提取临时文件中的新版本号
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
        echo -e "请检查服务器网络是否能正常访问 GitHub Raw。"
        rm -f "$TMP_FILE"
        sleep 3
    fi
}

# 主菜单
show_menu() {
    init_config
    while true; do
        clear
        echo -e "=========================================="
        echo -e "   \033[36m哪吒面板 V2 数据备份控制台 \033[32m[v${CURRENT_VERSION}]\033[0m"
        echo -e "=========================================="
        echo -e " S3 存储桶  : \033[33m${S3_BUCKET:-未配置}\033[0m"
        echo -e " 保留天数   : \033[33m${RETENTION_DAYS} 天\033[0m"
        echo -e " 通知模式   : \033[33m${NOTIFY_MODE}\033[0m"
        echo -e " 定时任务   : \033[33m$(crontab -l 2>/dev/null | grep "$0" > /dev/null && echo "已开启" || echo "未开启")\033[0m"
        echo -e "=========================================="
        echo " 1. 🚀 立即执行一次备份"
        echo " 2. 🪣  配置 S3 存储桶参数 (Rclone)"
        echo " 3. 🔍 测试 S3 存储桶连接状态"
        echo " 4. 🤖 配置 Telegram Bot 通知"
        echo " 5. 📅 设置旧备份保留天数"
        echo " 6. ⏰ 开启/刷新自动备份定时任务"
        echo " 7. 🔄 检查并从 GitHub 更新脚本"
        echo " 0. 退出面板"
        echo "=========================================="
        read -p "请输入选项 [0-7]: " choice
        
        case $choice in
            1) run_backup ;;
            2) setup_s3 ;;
            3) check_s3 ;;
            4) setup_tg ;;
            5) setup_retention ;;
            6) setup_cron ;;
            7) update_script ;;
            0) exit 0 ;;
            *) echo "无效选项，请重新输入" && sleep 1 ;;
        esac
    done
}

# 脚本入口点判断
if [ "$1" == "cron" ]; then
    init_config
    run_backup
else
    show_menu
fi

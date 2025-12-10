#!/bin/bash

# ==================================================
# Snell Server Manager (GitHub Managed Edition)
# Author: Lumos-ron & Gemini
# Repo: https://github.com/Lumos-ron/snell-manager
# ==================================================

# --- 核心配置 ---
# 您的 GitHub Raw 链接 (请确保文件名与您仓库里的文件名一致)
GITHUB_RAW_URL="https://raw.githubusercontent.com/Lumos-ron/snell-manager/main/snell.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PURPLE='\033[0;35m'
PLAIN='\033[0m'

# 路径定义
SNELL_BIN="/usr/local/bin/snell-server"
CONF_DIR="/etc/snell"
SYSTEMD_DIR="/etc/systemd/system"

# 检查 Root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用 root 用户运行此脚本！\n" && exit 1

# 1. 检查依赖
check_dependencies() {
    if ! command -v wget &> /dev/null || ! command -v unzip &> /dev/null || ! command -v iptables &> /dev/null || ! command -v bc &> /dev/null; then
        echo -e "${YELLOW}正在安装必要的依赖...${PLAIN}"
        apt-get update -y
        apt-get install -y wget unzip iptables bc
    fi
}

# 2. 更新脚本自身 (Self-Update)
update_script() {
    echo -e "\n${SKYBLUE}>>> 正在检查 GitHub 更新...${PLAIN}"
    echo -e "源地址: ${GITHUB_RAW_URL}"
    
    # 获取当前脚本的绝对路径
    CURRENT_PATH=$(realpath "$0")
    
    # 下载新版本到临时文件
    wget -O /tmp/snell_update.sh "$GITHUB_RAW_URL"
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败！请检查网络或 GitHub 地址是否正确。${PLAIN}"
        rm -f /tmp/snell_update.sh
        return
    fi

    # 检查下载的文件是否为空
    if [[ ! -s /tmp/snell_update.sh ]]; then
        echo -e "${RED}错误：下载的文件为空。${PLAIN}"
        rm -f /tmp/snell_update.sh
        return
    fi

    # 覆盖当前脚本
    mv /tmp/snell_update.sh "$CURRENT_PATH"
    chmod +x "$CURRENT_PATH"
    
    echo -e "${GREEN}脚本更新成功！正在重启脚本...${PLAIN}"
    sleep 1
    exec "$CURRENT_PATH"
}

# 3. 安装/更新 Snell (版本选择)
install_snell() {
    echo -e "\n${SKYBLUE}>>> 选择安装版本${PLAIN}"
    echo -e "1. ${GREEN}Snell v4${PLAIN} (v4.0.1 - 经典稳定版)"
    echo -e "2. ${GREEN}Snell v5${PLAIN} (v5.0.1 - 支持 QUIC 优化)"
    read -p "请输入选项 [1-2]: " VER_OPT

    ARCH=$(uname -m)
    DOWNLOAD_URL=""

    if [[ "$VER_OPT" == "1" ]]; then
        if [[ $ARCH == "x86_64" ]]; then
            DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v4.0.1-linux-amd64.zip"
        elif [[ $ARCH == "aarch64" ]]; then
            DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v4.0.1-linux-aarch64.zip"
        fi
    elif [[ "$VER_OPT" == "2" ]]; then
        if [[ $ARCH == "x86_64" ]]; then
            DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
        elif [[ $ARCH == "aarch64" ]]; then
            DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-aarch64.zip"
        fi
    else
        echo -e "${RED}无效选项${PLAIN}"
        return
    fi

    if [[ -z "$DOWNLOAD_URL" ]]; then
        echo -e "${RED}您的架构 ($ARCH) 不支持该版本。${PLAIN}"
        return
    fi

    echo -e "${GREEN}正在下载...${PLAIN}"
    wget -N --no-check-certificate -O snell.zip $DOWNLOAD_URL
    
    if [[ ! -f snell.zip ]]; then
        echo -e "${RED}下载失败，请检查网络。${PLAIN}"
        return
    fi

    pkill snell-server 2>/dev/null
    unzip -o snell.zip
    rm -f snell.zip
    mv snell-server $SNELL_BIN
    chmod +x $SNELL_BIN
    mkdir -p $CONF_DIR

    cat > ${SYSTEMD_DIR}/snell@.service <<EOF
[Unit]
Description=Snell Proxy Service on Port %i
After=network.target

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=32768
ExecStart=${SNELL_BIN} -c ${CONF_DIR}/%i.conf
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo -e "${GREEN}Snell Server 安装完成！${PLAIN}"
    CUR_VER=$($SNELL_BIN -v 2>&1)
    echo -e "当前运行版本: ${PURPLE}$CUR_VER${PLAIN}"
}

# 辅助函数：生成 Surge 配置
get_surge_config_str() {
    local port=$1
    local psk=$2
    local host_ip=$3
    local ver_num="4"
    if [[ -f $SNELL_BIN ]]; then
        if $SNELL_BIN -v 2>&1 | grep -q "v5"; then ver_num="5"; fi
    fi
    local extra_params=", tfo=true"
    if [[ "$ver_num" == "5" ]]; then extra_params=", tfo=true, udp-relay=true"; fi
    echo "Snell-Port${port} = snell, ${host_ip}, ${port}, psk=${psk}, version=${ver_num}${extra_params}"
}

# 4. 添加节点
add_node() {
    echo -e "\n${SKYBLUE}>>> 添加新节点${PLAIN}"
    read -p "请输入端口号 (1-65535): " PORT
    [[ -z "$PORT" ]] && echo -e "${RED}端口不能为空${PLAIN}" && return
    if [[ -f "${CONF_DIR}/${PORT}.conf" ]]; then echo -e "${RED}端口已存在。${PLAIN}"; return; fi

    read -p "请输入 PSK 密钥 (留空自动生成): " PSK
    if [[ -z "$PSK" ]]; then PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20); echo -e "${GREEN}PSK: ${PSK}${PLAIN}"; fi

    read -p "是否启用 IPv6? (y/n, 默认 n): " IPV6_OPT
    IPV6="false"; [[ "$IPV6_OPT" == "y" ]] && IPV6="true"

    cat > ${CONF_DIR}/${PORT}.conf <<EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = ${IPV6}
obfs = off
EOF
    systemctl enable snell@${PORT} --now
    
    iptables -I INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -I OUTPUT -p tcp --sport $PORT -j ACCEPT 2>/dev/null
    iptables -I OUTPUT -p udp --sport $PORT -j ACCEPT 2>/dev/null

    HOST_IP=$(curl -s4 ifconfig.me)
    SURGE_CONF=$(get_surge_config_str "$PORT" "$PSK" "$HOST_IP")

    echo -e "\n${GREEN}节点添加成功！${PLAIN}"
    echo -e "------------------------------------------------------"
    echo -e "${YELLOW}>>> Surge 配置:${PLAIN}"
    echo -e "${PURPLE}${SURGE_CONF}${PLAIN}"
    echo -e "------------------------------------------------------"
}

# 5. 查看配置
view_config() {
    echo -e "\n${SKYBLUE}>>> 节点配置查看${PLAIN}"
    count=$(ls ${CONF_DIR}/*.conf 2>/dev/null | wc -l)
    if [[ "$count" -eq 0 ]]; then echo -e "${YELLOW}暂无节点。${PLAIN}"; return; fi
    HOST_IP=$(curl -s4 ifconfig.me)
    for conf in ${CONF_DIR}/*.conf; do
        PORT=$(basename "$conf" .conf)
        PSK=$(grep "psk" $conf | awk -F "=" '{print $2}' | tr -d ' ')
        SURGE_CONF=$(get_surge_config_str "$PORT" "$PSK" "$HOST_IP")
        echo -e "------------------------------------------------------"
        echo -e "端口: ${GREEN}${PORT}${PLAIN} | 密钥: ${GREEN}${PSK}${PLAIN}"
        echo -e "${PURPLE}${SURGE_CONF}${PLAIN}"
    done
    echo -e "------------------------------------------------------"
}

# 6. 删除节点
del_node() {
    echo -e "\n${SKYBLUE}>>> 删除节点${PLAIN}"
    ls ${CONF_DIR}/*.conf 2>/dev/null | xargs -n 1 basename | sed 's/.conf//' | xargs -I {} echo "运行端口: {}"
    read -p "请输入要删除的端口号: " PORT
    [[ -z "$PORT" ]] && return
    if [[ ! -f "${CONF_DIR}/${PORT}.conf" ]]; then echo -e "${RED}配置不存在${PLAIN}"; return; fi
    systemctl stop snell@${PORT}; systemctl disable snell@${PORT}; rm -f "${CONF_DIR}/${PORT}.conf"
    iptables -D INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp --dport $PORT -j ACCEPT 2>/dev/null
    echo -e "${GREEN}节点 ${PORT} 已删除。${PLAIN}"
}

# 7. 流量统计 (修复科学计数法报错版)
show_traffic() {
    echo -e "\n${SKYBLUE}>>> 流量统计 (TCP+UDP)${PLAIN}"
    printf "%-10s %-15s %-15s %-15s\n" "端口" "入站" "出站" "总计"
    echo "--------------------------------------------------------"
    for conf in ${CONF_DIR}/*.conf; do
        [ -e "$conf" ] || continue
        PORT=$(basename "$conf" .conf)
        
        # 核心修复：使用 printf "%.0f" 强制输出完整的纯整数，禁止科学计数法
        RX_BYTES=$(iptables -nvx -L INPUT | grep "dpt:$PORT" | awk '{s+=$2} END {printf "%.0f", s}')
        TX_BYTES=$(iptables -nvx -L OUTPUT | grep "spt:$PORT" | awk '{s+=$2} END {printf "%.0f", s}')
        
        # 防止空值导致报错
        [[ -z "$RX_BYTES" ]] && RX_BYTES=0
        [[ -z "$TX_BYTES" ]] && TX_BYTES=0
        
        # 计算总流量
        TOTAL_BYTES=$(echo "$RX_BYTES + $TX_BYTES" | bc)

        # 格式化显示函数
        format_bytes() {
            local num=$1
            # 再次确保传入的是数字
            if [[ ! "$num" =~ ^[0-9]+$ ]]; then num=0; fi
            
            if [ $(echo "$num < 1024" | bc) -eq 1 ]; then 
                echo "${num} B"
            elif [ $(echo "$num < 1048576" | bc) -eq 1 ]; then 
                echo "$(echo "scale=2; $num/1024" | bc) KB"
            elif [ $(echo "$num < 1073741824" | bc) -eq 1 ]; then 
                echo "$(echo "scale=2; $num/1024/1024" | bc) MB"
            else 
                echo "$(echo "scale=2; $num/1024/1024/1024" | bc) GB"
            fi
        }

        printf "%-10s %-15s %-15s %-15s\n" "$PORT" "$(format_bytes $RX_BYTES)" "$(format_bytes $TX_BYTES)" "$(format_bytes $TOTAL_BYTES)"
    done
}

# 主菜单
show_menu() {
    clear
    echo -e "==========================================="
    echo -e "   Snell 管理脚本 (Pro) - GitHub Managed   "
    echo -e "==========================================="
    echo -e "1. 安装/切换版本 (v4 / v5)"
    echo -e "2. 添加新节点 (+Surge配置)"
    echo -e "3. 查看现有节点 (+Surge配置)"
    echo -e "4. 删除节点"
    echo -e "5. 流量统计"
    echo -e "6. 重启节点"
    echo -e "-------------------------------------------"
    echo -e "7. 更新本脚本 (从 GitHub 拉取最新代码)"
    echo -e "0. 退出"
    echo -e "==========================================="
    read -p "请选择: " OPT
    
    case $OPT in
        1) install_snell ;;
        2) add_node ;;
        3) view_config ;;
        4) del_node ;;
        5) show_traffic ;;
        6) read -p "端口: " P; systemctl restart snell@${P}; echo "已重启 ${P}" ;;
        7) update_script ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

check_dependencies
while true; do show_menu; echo -e "\n按回车继续..."; read; done

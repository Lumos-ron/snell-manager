#!/bin/bash

# ==================================================
# Snell Server Manager (Ultimate Edition)
# System: Debian / Ubuntu
# Features: v4/v5 Selection, Multi-port, Surge Config Output
# ==================================================

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

# 2. 安装/更新 Snell (版本选择)
install_snell() {
    echo -e "\n${SKYBLUE}>>> 选择安装版本${PLAIN}"
    echo -e "1. ${GREEN}Snell v4${PLAIN} (v4.0.1 - 经典稳定版)"
    echo -e "2. ${GREEN}Snell v5${PLAIN} (v5.0.1 - 支持 QUIC 优化)"
    read -p "请输入选项 [1-2]: " VER_OPT

    ARCH=$(uname -m)
    DOWNLOAD_URL=""

    if [[ "$VER_OPT" == "1" ]]; then
        # v4 下载链接
        if [[ $ARCH == "x86_64" ]]; then
            DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v4.0.1-linux-amd64.zip"
        elif [[ $ARCH == "aarch64" ]]; then
            DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v4.0.1-linux-aarch64.zip"
        fi
    elif [[ "$VER_OPT" == "2" ]]; then
        # v5 下载链接
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

    # 停止旧服务
    pkill snell-server 2>/dev/null

    unzip -o snell.zip
    rm -f snell.zip
    mv snell-server $SNELL_BIN
    chmod +x $SNELL_BIN
    
    mkdir -p $CONF_DIR

    # 创建 Systemd 模板
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
    # 显示版本
    CUR_VER=$($SNELL_BIN -v 2>&1)
    echo -e "当前运行版本: ${PURPLE}$CUR_VER${PLAIN}"
}

# 辅助函数：生成 Surge 配置字符串
get_surge_config_str() {
    local port=$1
    local psk=$2
    local host_ip=$3
    
    # 检测当前二进制文件的版本来决定 version=4 还是 5
    local ver_num="4"
    if [[ -f $SNELL_BIN ]]; then
        # 简单判断，如果 -v 输出包含 v5 则设为 5
        if $SNELL_BIN -v 2>&1 | grep -q "v5"; then
            ver_num="5"
        fi
    fi

    # 生成配置字符串
    # 格式: 别名 = snell, IP, 端口, psk=密钥, version=版本, tfo=true, udp-relay=true
    # v5 推荐开启 udp-relay 以支持 QUIC
    local extra_params=", tfo=true"
    if [[ "$ver_num" == "5" ]]; then
        extra_params=", tfo=true, udp-relay=true"
    fi

    echo "Snell-Port${port} = snell, ${host_ip}, ${port}, psk=${psk}, version=${ver_num}${extra_params}"
}

# 3. 添加节点
add_node() {
    echo -e "\n${SKYBLUE}>>> 添加新节点${PLAIN}"
    
    read -p "请输入端口号 (1-65535): " PORT
    [[ -z "$PORT" ]] && echo -e "${RED}端口不能为空${PLAIN}" && return
    
    if [[ -f "${CONF_DIR}/${PORT}.conf" ]]; then
        echo -e "${RED}该端口已存在配置。${PLAIN}"
        return
    fi

    read -p "请输入 PSK 密钥 (留空自动生成): " PSK
    if [[ -z "$PSK" ]]; then
        PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
        echo -e "${GREEN}已自动生成 PSK: ${PSK}${PLAIN}"
    fi

    read -p "是否启用 IPv6? (y/n, 默认 n): " IPV6_OPT
    IPV6="false"
    [[ "$IPV6_OPT" == "y" ]] && IPV6="true"

    # 写入配置
    cat > ${CONF_DIR}/${PORT}.conf <<EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = ${IPV6}
obfs = off
EOF

    # 启动服务
    systemctl enable snell@${PORT} --now
    
    # 添加防火墙规则 (TCP+UDP)
    iptables -I INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -I INPUT -p udp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -I OUTPUT -p tcp --sport $PORT -j ACCEPT 2>/dev/null
    iptables -I OUTPUT -p udp --sport $PORT -j ACCEPT 2>/dev/null

    # 获取 IP 并展示
    HOST_IP=$(curl -s4 ifconfig.me)
    SURGE_CONF=$(get_surge_config_str "$PORT" "$PSK" "$HOST_IP")

    echo -e "\n${GREEN}节点添加成功！${PLAIN}"
    echo -e "------------------------------------------------------"
    echo -e "${YELLOW}>>> Surge 配置文件 (可直接复制到 [Proxy] 下):${PLAIN}"
    echo -e "${PURPLE}${SURGE_CONF}${PLAIN}"
    echo -e "------------------------------------------------------"
}

# 4. 查看已存在节点 (新功能)
view_config() {
    echo -e "\n${SKYBLUE}>>> 节点配置查看${PLAIN}"
    
    # 检查是否有配置文件
    count=$(ls ${CONF_DIR}/*.conf 2>/dev/null | wc -l)
    if [[ "$count" -eq 0 ]]; then
        echo -e "${YELLOW}暂无任何节点配置。${PLAIN}"
        return
    fi

    HOST_IP=$(curl -s4 ifconfig.me)

    for conf in ${CONF_DIR}/*.conf; do
        PORT=$(basename "$conf" .conf)
        # 从配置文件中提取 PSK
        PSK=$(grep "psk" $conf | awk -F "=" '{print $2}' | tr -d ' ')
        
        echo -e "------------------------------------------------------"
        echo -e "端口 (Port): ${GREEN}${PORT}${PLAIN}"
        echo -e "密钥 (PSK) : ${GREEN}${PSK}${PLAIN}"
        
        # 生成 Surge 配置
        SURGE_CONF=$(get_surge_config_str "$PORT" "$PSK" "$HOST_IP")
        echo -e "\n${YELLOW}Surge 配置:${PLAIN}"
        echo -e "${PURPLE}${SURGE_CONF}${PLAIN}"
    done
    echo -e "------------------------------------------------------"
}

# 5. 删除节点
del_node() {
    echo -e "\n${SKYBLUE}>>> 删除节点${PLAIN}"
    ls ${CONF_DIR}/*.conf 2>/dev/null | xargs -n 1 basename | sed 's/.conf//' | xargs -I {} echo "运行端口: {}"
    
    read -p "请输入要删除的端口号: " PORT
    [[ -z "$PORT" ]] && return

    if [[ ! -f "${CONF_DIR}/${PORT}.conf" ]]; then
        echo -e "${RED}配置不存在${PLAIN}"
        return
    fi

    systemctl stop snell@${PORT}
    systemctl disable snell@${PORT}
    rm -f "${CONF_DIR}/${PORT}.conf"
    
    iptables -D INPUT -p tcp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -D INPUT -p udp --dport $PORT -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -p tcp --sport $PORT -j ACCEPT 2>/dev/null
    iptables -D OUTPUT -p udp --sport $PORT -j ACCEPT 2>/dev/null

    echo -e "${GREEN}节点 ${PORT} 已删除。${PLAIN}"
}

# 6. 流量统计
show_traffic() {
    echo -e "\n${SKYBLUE}>>> 流量统计 (TCP+UDP)${PLAIN}"
    printf "%-10s %-15s %-15s %-15s\n" "端口" "入站" "出站" "总计"
    echo "--------------------------------------------------------"

    for conf in ${CONF_DIR}/*.conf; do
        [ -e "$conf" ] || continue
        PORT=$(basename "$conf" .conf)
        
        RX_BYTES=$(iptables -nvx -L INPUT | grep "dpt:$PORT" | awk '{s+=$2} END {print s}')
        TX_BYTES=$(iptables -nvx -L OUTPUT | grep "spt:$PORT" | awk '{s+=$2} END {print s}')
        [[ -z "$RX_BYTES" ]] && RX_BYTES=0
        [[ -z "$TX_BYTES" ]] && TX_BYTES=0
        TOTAL_BYTES=$(echo "$RX_BYTES + $TX_BYTES" | bc)

        # 格式化函数
        format_bytes() {
            num=$1
            if [ $num -lt 1024 ]; then echo "${num} B"; elif [ $num -lt 1048576 ]; then echo "$(echo "scale=2; $num/1024" | bc) KB"; elif [ $num -lt 1073741824 ]; then echo "$(echo "scale=2; $num/1024/1024" | bc) MB"; else echo "$(echo "scale=2; $num/1024/1024/1024" | bc) GB"; fi
        }

        printf "%-10s %-15s %-15s %-15s\n" "$PORT" "$(format_bytes $RX_BYTES)" "$(format_bytes $TX_BYTES)" "$(format_bytes $TOTAL_BYTES)"
    done
}

# 主菜单
show_menu() {
    clear
    echo -e "=================================="
    echo -e "   Snell 管理脚本 (Pro版)   "
    echo -e "=================================="
    echo -e "1. 安装/切换版本 (v4 / v5)"
    echo -e "2. 添加新节点 (+Surge配置)"
    echo -e "3. 查看现有节点配置 (+Surge配置)"
    echo -e "4. 删除节点"
    echo -e "5. 流量统计"
    echo -e "6. 重启节点"
    echo -e "0. 退出"
    echo -e "=================================="
    read -p "请选择: " OPT
    
    case $OPT in
        1) install_snell ;;
        2) add_node ;;
        3) view_config ;;
        4) del_node ;;
        5) show_traffic ;;
        6) 
            read -p "端口: " R_PORT
            systemctl restart snell@${R_PORT}
            echo "已重启 ${R_PORT}" 
            ;;
        0) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

check_dependencies
while true; do
    show_menu
    echo -e "\n按回车继续..."
    read
done

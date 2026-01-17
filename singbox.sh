#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/etc/sing-box/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# 检查 Root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：请使用 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

# 1. 环境检查与安装 Sing-box
install_singbox() {
    echo -e "${YELLOW}正在更新系统并安装依赖...${PLAIN}"
    apt-get update -y && apt-get install -y curl wget tar jq openssl

    echo -e "${YELLOW}正在检测系统架构...${PLAIN}"
    ARCH=$(dpkg --print-architecture)
    if [[ "$ARCH" == "amd64" ]]; then arch="amd64"; elif [[ "$ARCH" == "arm64" ]]; then arch="arm64"; else echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1; fi

    echo -e "${YELLOW}正在获取最新版本...${PLAIN}"
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then VERSION="1.8.0"; echo -e "${RED}获取失败，使用默认版本 $VERSION${PLAIN}"; fi

    echo -e "${GREEN}正在下载 Sing-box v$VERSION...${PLAIN}"
    wget -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${arch}.tar.gz"

    if [[ $? -ne 0 ]]; then echo -e "${RED}下载失败！${PLAIN}"; exit 1; fi

    tar -zxvf sing-box.tar.gz
    mv sing-box-${VERSION}-linux-${arch}/sing-box /usr/local/bin/ 2>/dev/null || mv sing-box/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box.tar.gz sing-box-${VERSION}-linux-${arch}
    mkdir -p /etc/sing-box
    
    echo -e "${GREEN}Sing-box 安装成功！${PLAIN}"
}

# 2. 端口选择逻辑 (支持自定义或随机高位)
get_port() {
    read -p "请输入服务端口 (1-65535，回车随机生成): " input_port
    if [[ -z "$input_port" ]]; then
        PORT=$(shuf -i 10000-65000 -n 1)
        echo -e "${GREEN}已自动选择随机端口: $PORT${PLAIN}"
    else
        if [[ $input_port -ge 1 && $input_port -le 65535 ]]; then
            PORT=$input_port
            echo -e "${GREEN}使用自定义端口: $PORT${PLAIN}"
        else
            echo -e "${RED}端口输入错误，使用随机端口。${PLAIN}"
            PORT=$(shuf -i 10000-65000 -n 1)
        fi
    fi
}

# 3. 配置 Systemd 服务
setup_service() {
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
}

# 4. 协议配置：VLESS Reality
config_reality() {
    get_port
    echo -e "${YELLOW}正在生成 Reality 证书与密钥...${PLAIN}"
    UUID=$(/usr/local/bin/sing-box generate uuid)
    KEYS=$(/usr/local/bin/sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
    PUBLIC_KEY=$(echo "$KEYS" | grep "PublicKey" | awk '{print $2}')
    SHORT_ID=$(openssl rand -hex 8)
    DEST_DOMAIN="updates.cdn-apple.com"

    cat > $CONFIG_FILE <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": { "servers": [{ "tag": "google", "address": "8.8.8.8", "detour": "direct" }], "strategy": "prefer_ipv6" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision", "name": "client" }],
      "tls": {
        "enabled": true,
        "server_name": "$DEST_DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$DEST_DOMAIN", "server_port": 443 },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct", "domain_strategy": "prefer_ipv6" },
    { "type": "block", "tag": "block" }
  ]
}
EOF
    restart_service
    show_reality_info
}

# 5. 协议配置：Hysteria 2 (自签证书)
config_hysteria2() {
    get_port
    echo -e "${YELLOW}正在生成自签证书 (用于 Hysteria2)...${PLAIN}"
    # 生成自签证书
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout /etc/sing-box/hy2.key -out /etc/sing-box/hy2.crt \
    -subj "/CN=bing.com" -addext "subjectAltName=DNS:bing.com" >/dev/null 2>&1

    PASSWORD=$(openssl rand -base64 16)

    cat > $CONFIG_FILE <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": { "servers": [{ "tag": "google", "address": "8.8.8.8", "detour": "direct" }], "strategy": "prefer_ipv6" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [{ "password": "$PASSWORD", "name": "client" }],
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/sing-box/hy2.crt",
        "key_path": "/etc/sing-box/hy2.key"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct", "domain_strategy": "prefer_ipv6" },
    { "type": "block", "tag": "block" }
  ]
}
EOF
    restart_service
    show_hy2_info
}

# 6. 协议配置：Shadowsocks (2022-blake3)
config_shadowsocks() {
    get_port
    PASSWORD=$(openssl rand -base64 32)
    METHOD="2022-blake3-aes-128-gcm" 

    cat > $CONFIG_FILE <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": { "servers": [{ "tag": "google", "address": "8.8.8.8", "detour": "direct" }], "strategy": "prefer_ipv6" },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": $PORT,
      "method": "$METHOD",
      "password": "$PASSWORD"
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct", "domain_strategy": "prefer_ipv6" },
    { "type": "block", "tag": "block" }
  ]
}
EOF
    restart_service
    show_ss_info
}

# 服务管理函数
restart_service() { systemctl restart sing-box; echo -e "${GREEN}服务已重启!${PLAIN}"; }
stop_service() { systemctl stop sing-box; echo -e "${RED}服务已停止!${PLAIN}"; }
show_log() { journalctl -u sing-box -f; }

# 获取 IPv4/IPv6 用于显示
get_ips() {
    IP4=$(curl -s4m 5 ip.sb)
    IP6=$(curl -s6m 5 ip.sb)
    if [[ -n "$IP6" ]]; then LINK_IP="[$IP6]"; else LINK_IP="$IP4"; fi
}

# 显示连接信息
show_reality_info() {
    get_ips
    echo "------------------------------------------------"
    echo -e "协议: VLESS Reality (IPv6 优先出站)"
    echo -e "地址: ${GREEN}$LINK_IP${PLAIN}"
    echo -e "端口: ${GREEN}$PORT${PLAIN}"
    echo -e "UUID: ${GREEN}$UUID${PLAIN}"
    echo -e "Public Key: ${GREEN}$PUBLIC_KEY${PLAIN}"
    echo -e "SNI: ${GREEN}updates.cdn-apple.com${PLAIN}"
    echo -e "分享链接: vless://$UUID@$LINK_IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=updates.cdn-apple.com&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp&headerType=none#SingBox-Reality"
    echo "------------------------------------------------"
}

show_hy2_info() {
    get_ips
    echo "------------------------------------------------"
    echo -e "协议: Hysteria 2 (自签证书 - 客户端需开启 allowInsecure/跳过验证)"
    echo -e "地址: ${GREEN}$LINK_IP${PLAIN}"
    echo -e "端口: ${GREEN}$PORT${PLAIN}"
    echo -e "密码: ${GREEN}$PASSWORD${PLAIN}"
    echo -e "分享链接: hysteria2://$PASSWORD@$LINK_IP:$PORT?insecure=1&sni=bing.com#SingBox-Hy2"
    echo "------------------------------------------------"
}

show_ss_info() {
    get_ips
    echo "------------------------------------------------"
    echo -e "协议: Shadowsocks (2022-blake3-aes-128-gcm)"
    echo -e "地址: ${GREEN}$LINK_IP${PLAIN}"
    echo -e "端口: ${GREEN}$PORT${PLAIN}"
    echo -e "密码: ${GREEN}$PASSWORD${PLAIN}"
    echo -e "分享链接: ss://$(echo -n "2022-blake3-aes-128-gcm:$PASSWORD" | base64 -w 0)@$LINK_IP:$PORT#SingBox-SS"
    echo "------------------------------------------------"
}

# 主菜单
menu() {
    clear
    echo "################################################"
    echo -e "#        ${GREEN}Sing-box 全能一键部署脚本${PLAIN}           #"
    echo -e "#        ${YELLOW}自动配置 IPv6 优先出站${PLAIN}              #"
    echo "################################################"
    echo -e " 1. 安装/重置为 ${GREEN}VLESS Reality${PLAIN} (推荐，最稳)"
    echo -e " 2. 安装/重置为 ${GREEN}Hysteria 2${PLAIN} (速度快，自签证书)"
    echo -e " 3. 安装/重置为 ${GREEN}Shadowsocks${PLAIN} (简单兼容)"
    echo "------------------------------------------------"
    echo -e " 4. 重启服务"
    echo -e " 5. 停止服务"
    echo -e " 6. 查看实时日志 (按 Ctrl+C 退出)"
    echo -e " 7. 更新 Sing-box 核心"
    echo "------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo ""
    read -p "请选择操作 [0-7]: " choice

    case $choice in
        1) check_root; install_singbox; setup_service; config_reality ;;
        2) check_root; install_singbox; setup_service; config_hysteria2 ;;
        3) check_root; install_singbox; setup_service; config_shadowsocks ;;
        4) restart_service ;;
        5) stop_service ;;
        6) show_log ;;
        7) install_singbox; restart_service ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择，请重新输入!${PLAIN}"; sleep 2; menu ;;
    esac
}

menu

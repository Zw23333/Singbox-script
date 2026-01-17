#!/bin/bash

# 全局变量
CONFIG_FILE="/etc/sing-box/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
BIN_PATH="/usr/local/bin/sing-box"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 检查 Root
check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}错误：请使用 root 用户运行！${PLAIN}" && exit 1
}

# 1. 安装依赖
install_deps() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}正在安装必要依赖 (jq, openssl, curl)...${PLAIN}"
        apt-get update -y && apt-get install -y curl wget tar jq openssl
    fi
}

# 2. 配置 Systemd 服务 (修复的核心部分)
setup_service() {
    echo -e "${YELLOW}正在配置 Systemd 服务...${PLAIN}"
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=$BIN_PATH run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box
}

# 3. 安装/更新 Sing-box
install_singbox() {
    install_deps
    
    # 检查是否已安装
    if [ -f "$BIN_PATH" ]; then
        echo -e "${GREEN}检测到 Sing-box 已安装。${PLAIN}"
    else
        echo -e "${YELLOW}未检测到 Sing-box，正在下载...${PLAIN}"
        ARCH=$(dpkg --print-architecture)
        case "$ARCH" in
            amd64) arch="amd64" ;;
            arm64) arch="arm64" ;;
            *) echo -e "${RED}不支持架构: $ARCH${PLAIN}"; exit 1 ;;
        esac

        VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
        [[ -z "$VERSION" || "$VERSION" == "null" ]] && VERSION="1.8.0"
        
        echo -e "${GREEN}下载 Sing-box v${VERSION}...${PLAIN}"
        wget -O sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${arch}.tar.gz"
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}下载失败，请检查网络！${PLAIN}"
            rm -f sb.tar.gz
            exit 1
        fi

        tar -zxvf sb.tar.gz
        mv sing-box-${VERSION}-linux-${arch}/sing-box /usr/local/bin/ 2>/dev/null || mv sing-box/sing-box /usr/local/bin/
        chmod +x /usr/local/bin/sing-box
        rm -rf sb.tar.gz sing-box-${VERSION}-linux-${arch}
        
        # 安装完成后配置服务
        setup_service
        echo -e "${GREEN}Sing-box 安装完成！${PLAIN}"
    fi
    
    # 确保服务文件存在（应对更新脚本的情况）
    if [ ! -f "$SERVICE_FILE" ]; then
        setup_service
    fi
}

# 4. 初始化基础配置
init_config() {
    mkdir -p /etc/sing-box
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}初始化全新 config.json...${PLAIN}"
        cat > $CONFIG_FILE <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": { 
    "servers": [{ "tag": "google", "address": "8.8.8.8", "detour": "direct" }], 
    "strategy": "prefer_ipv6" 
  },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct", "domain_strategy": "prefer_ipv6" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [],
    "auto_detect_interface": true
  }
}
EOF
    fi
}

get_port() {
    read -p "请输入本机监听端口 (回车随机 10000-60000): " port
    if [[ -z "$port" ]]; then
        PORT=$(shuf -i 10000-60000 -n 1)
    else
        PORT=$port
    fi
}

safe_base64_decode() {
    local input="$1"
    input=$(echo "$input" | sed 's/-/+/g; s/_/\//g')
    rem=$(( ${#input} % 4 ))
    if [ $rem -eq 2 ]; then input="$input=="; fi
    if [ $rem -eq 3 ]; then input="$input="; fi
    echo "$input" | base64 -d 2>/dev/null
}

parse_link_to_outbound() {
    local LINK="$1"
    local TAG_OUT="$2"
    
    if [[ "$LINK" == ss://* ]]; then
        RAW=$(echo "$LINK" | sed 's/ss:\/\///')
        IFS='@' read -r USER_INFO HOST_INFO <<< "$RAW"
        IFS='#' read -r HOST_PORT NAME <<< "$HOST_INFO"
        DECODED_USER=$(safe_base64_decode "$USER_INFO")
        IFS=':' read -r METHOD PASSWORD <<< "$DECODED_USER"
        IFS=':' read -r SERVER SERVER_PORT <<< "$HOST_PORT"

        echo -e "识别为 Shadowsocks: $SERVER:$SERVER_PORT"
        jq -n --arg type "shadowsocks" --arg tag "$TAG_OUT" --arg server "$SERVER" --arg port "$SERVER_PORT" --arg method "$METHOD" --arg password "$PASSWORD" \
            '{type: $type, tag: $tag, server: $server, server_port: ($port|tonumber), method: $method, password: $password}'

    elif [[ "$LINK" == vless://* ]]; then
        RAW=$(echo "$LINK" | sed 's/vless:\/\///')
        IFS='@' read -r UUID HOST_PART <<< "$RAW"
        IFS='?' read -r ADDRESS QUERY_PART <<< "$HOST_PART"
        IFS=':' read -r SERVER SERVER_PORT <<< "$ADDRESS"
        
        FLOW=$(echo "$QUERY_PART" | grep -oP '(?<=flow=)[^&]*' || echo "")
        SECURITY=$(echo "$QUERY_PART" | grep -oP '(?<=security=)[^&]*' || echo "none")
        SNI=$(echo "$QUERY_PART" | grep -oP '(?<=sni=)[^&]*' || echo "")
        PBK=$(echo "$QUERY_PART" | grep -oP '(?<=pbk=)[^&]*' || echo "")
        SID=$(echo "$QUERY_PART" | grep -oP '(?<=sid=)[^&]*' || echo "")
        FP=$(echo "$QUERY_PART" | grep -oP '(?<=fp=)[^&]*' || echo "chrome")

        echo -e "识别为 VLESS: $SERVER:$SERVER_PORT (Security: $SECURITY)"

        OUT_BASE=$(jq -n --arg type "vless" --arg tag "$TAG_OUT" --arg server "$SERVER" --arg port "$SERVER_PORT" --arg uuid "$UUID" --arg flow "$FLOW" \
            '{type: $type, tag: $tag, server: $server, server_port: ($port|tonumber), uuid: $uuid, flow: $flow}')

        if [[ "$SECURITY" == "reality" ]]; then
             TLS_JSON=$(jq -n --arg sni "$SNI" --arg pbk "$PBK" --arg sid "$SID" --arg fp "$FP" \
                '{enabled: true, server_name: $sni, reality: {enabled: true, public_key: $pbk, short_id: $sid}, utls: {enabled: true, fingerprint: $fp}}')
             echo "$OUT_BASE" | jq --argjson tls "$TLS_JSON" '.tls = $tls'
        elif [[ "$SECURITY" == "tls" ]]; then
             TLS_JSON=$(jq -n --arg sni "$SNI" '{enabled: true, server_name: $sni}')
             echo "$OUT_BASE" | jq --argjson tls "$TLS_JSON" '.tls = $tls'
        else
             echo "$OUT_BASE"
        fi
    else
        echo "ERROR"
    fi
}

# --- 功能函数 ---
gen_reality_inbound() {
    local port=$1
    local tag=$2
    # 强制使用绝对路径调用 sing-box
    UUID=$($BIN_PATH generate uuid)
    KEYS=$($BIN_PATH generate reality-keypair)
    PRI=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
    PUB=$(echo "$KEYS" | grep "PublicKey" | awk '{print $2}')
    SID=$(openssl rand -hex 8)
    
    # 记录 PUBKEY 到临时文件以便显示
    echo "$PUB" > /tmp/sb_last_pubkey
    
    jq -n --arg port "$port" --arg tag "$tag" --arg uuid "$UUID" --arg pri "$PRI" --arg sid "$SID" \
        '{type: "vless", tag: $tag, listen: "::", listen_port: ($port|tonumber), users: [{uuid: $uuid, flow: "xtls-rprx-vision", name: "client"}], tls: {enabled: true, server_name: "updates.cdn-apple.com", reality: {enabled: true, handshake: {server: "updates.cdn-apple.com", server_port: 443}, private_key: $pri, short_id: [$sid]}}}'
}

gen_ss_inbound() {
    local port=$1
    local tag=$2
    PASS=$(openssl rand -base64 16)
    METHOD="2022-blake3-aes-128-gcm"
    jq -n --arg port "$port" --arg tag "$tag" --arg method "$METHOD" --arg pass "$PASS" \
        '{type: "shadowsocks", tag: $tag, listen: "::", listen_port: ($port|tonumber), method: $method, password: $pass}'
}

update_config_append_inbound() {
    local json=$1
    tmp=$(mktemp)
    jq --argjson new "$json" '.inbounds += [$new]' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

show_share_link() {
    local type=$1
    local port=$2
    local json=$3
    IP=$(curl -s4 ip.sb)
    
    echo -e "------------------------------------------------"
    if [[ "$type" == "1" ]]; then # Reality
        UUID=$(echo "$json" | jq -r '.users[0].uuid')
        SID=$(echo "$json" | jq -r '.tls.reality.short_id[0]')
        # 尝试读取刚才保存的公钥
        if [ -f /tmp/sb_last_pubkey ]; then
            PUB=$(cat /tmp/sb_last_pubkey)
        else
            PUB="无法获取(请查看日志)"
        fi
        
        LINK="vless://$UUID@$IP:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=updates.cdn-apple.com&fp=chrome&pbk=$PUB&sid=$SID&type=tcp&headerType=none#SingBox-Reality"
        echo -e "分享链接: ${GREEN}$LINK${PLAIN}"
        echo -e "Public Key: ${GREEN}$PUB${PLAIN}"
    elif [[ "$type" == "2" ]]; then # SS
        PASS=$(echo "$json" | jq -r '.password')
        METHOD=$(echo "$json" | jq -r '.method')
        LINK="ss://$(echo -n "$METHOD:$PASS" | base64 -w 0)@$IP:$port#SingBox-SS"
        echo -e "分享链接: ${GREEN}$LINK${PLAIN}"
    fi
    echo -e "------------------------------------------------"
}

restart_service() { 
    systemctl daemon-reload
    if systemctl restart sing-box; then
        echo -e "${GREEN}服务重启成功！${PLAIN}"
    else
        echo -e "${RED}服务重启失败！请运行 journalctl -u sing-box -n 20 查看错误。${PLAIN}"
    fi
}

add_direct_server() {
    echo -e "${YELLOW}>>> 添加直连服务${PLAIN}"
    echo "1. VLESS Reality"
    echo "2. Shadowsocks"
    read -p "选择: " p_choice
    get_port
    TAG_IN="in-$PORT-direct"
    
    if [[ "$p_choice" == "1" ]]; then
        IN_JSON=$(gen_reality_inbound "$PORT" "$TAG_IN")
    elif [[ "$p_choice" == "2" ]]; then
        IN_JSON=$(gen_ss_inbound "$PORT" "$TAG_IN")
    else
        echo "无效选择"; return
    fi
    
    update_config_append_inbound "$IN_JSON"
    restart_service
    show_share_link "$p_choice" "$PORT" "$IN_JSON"
}

add_forward_server() {
    echo -e "${YELLOW}>>> 添加链式中转${PLAIN}"
    read -p "请输入外部节点链接: " LINK_URL
    if [[ -z "$LINK_URL" ]]; then echo "不能为空"; return; fi
    
    get_port
    LOCAL_PORT=$PORT
    TAG_OUT="out-relay-$LOCAL_PORT"
    TAG_IN="in-relay-$LOCAL_PORT"

    OUT_JSON=$(parse_link_to_outbound "$LINK_URL" "$TAG_OUT")
    if [[ "$OUT_JSON" == "ERROR" ]]; then echo -e "${RED}解析失败${PLAIN}"; return; fi

    echo -e "${YELLOW}客户端连接本机的方式:${PLAIN}"
    echo "1. VLESS Reality"
    echo "2. Shadowsocks"
    read -p "选择: " in_choice

    if [[ "$in_choice" == "1" ]]; then
        IN_JSON=$(gen_reality_inbound "$LOCAL_PORT" "$TAG_IN")
    elif [[ "$in_choice" == "2" ]]; then
        IN_JSON=$(gen_ss_inbound "$LOCAL_PORT" "$TAG_IN")
    else
        echo "无效选择"; return
    fi

    RULE_JSON=$(jq -n --arg in "$TAG_IN" --arg out "$TAG_OUT" '{inbound: [$in], outbound: $out}')

    tmp=$(mktemp)
    jq --argjson new_in "$IN_JSON" --argjson new_out "$OUT_JSON" --argjson new_rule "$RULE_JSON" \
       '.inbounds += [$new_in] | .outbounds += [$new_out] | .route.rules += [$new_rule]' \
       "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"

    restart_service
    show_share_link "$in_choice" "$LOCAL_PORT" "$IN_JSON"
}

# --- 主菜单 ---
menu() {
    check_root
    # 在菜单启动时，必须检查并安装环境
    install_singbox 
    init_config
    
    clear
    echo "################################################"
    echo -e "#         Sing-box 全能脚本                 #"
    echo "################################################"
    echo -e " 1. 添加 ${GREEN}直连入站${PLAIN}"
    echo -e " 2. 添加 ${YELLOW}链式中转${PLAIN}"
    echo "------------------------------------------------"
    echo -e " 3. 查看当前配置"
    echo -e " 4. 重置所有配置"
    echo -e " 5. 强制重装/更新 Sing-box"
    echo -e " 6. 重启服务"
    echo -e " 0. 退出"
    echo ""
    read -p "请选择: " n
    case $n in
        1) add_direct_server ;;
        2) add_forward_server ;;
        3) jq -r '.inbounds[]|.tag + " (" + .type + "): " + (.listen_port|tostring)' $CONFIG_FILE; read -p "按回车继续..." ;;
        4) rm -f $CONFIG_FILE; init_config; restart_service; echo "已重置" ;;
        5) rm -f $BIN_PATH; install_singbox ;;
        6) restart_service ;;
        0) exit 0 ;;
        *) menu ;;
    esac
}

menu
menu

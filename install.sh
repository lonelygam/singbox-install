#!/bin/bash
# ================================================================
# Sing-box 一键安装脚本 (Oracle Cloud VPS)
# 支持: ARM64 / AMD64
# 带主节点 + 两个随机端口备用节点
# 自动生成 Clash 配置
# ================================================================

set -e

# -------- 用户输入 --------
read -p "请输入已解析到服务器的域名: " DOMAIN
SINGBOX_DIR="/usr/local/etc/sing-box"
CLASH_FILE="$SINGBOX_DIR/clash.yaml"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# -------- 随机端口 --------
PORT_MAIN=443
PORT_1=$((RANDOM % 50000 + 10000))
PORT_2=$((RANDOM % 50000 + 10000))

# -------- 检测架构 --------
ARCH=$(uname -m)
if [[ $ARCH == "aarch64" ]]; then
    SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-arm64.zip"
    echo "[INFO] 检测到架构: ARM64"
elif [[ $ARCH == "x86_64" ]]; then
    SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.zip"
    echo "[INFO] 检测到架构: AMD64"
else
    echo "[ERROR] 未知架构: $ARCH"
    exit 1
fi

# -------- 系统准备 --------
echo "[1/9] 更新系统..."
apt update -y && apt upgrade -y
apt install -y curl wget git unzip socat cron

# -------- 安装 Sing-box --------
echo "[2/9] 安装 Sing-box..."
cd /tmp
wget -O sing-box.zip $SINGBOX_URL
unzip -o sing-box.zip
chmod +x sing-box
mv sing-box /usr/local/bin/
rm -f sing-box.zip
mkdir -p $SINGBOX_DIR

# -------- 生成 UUID --------
UUID_MAIN=$(cat /proc/sys/kernel/random/uuid)
UUID_1=$(cat /proc/sys/kernel/random/uuid)
UUID_2=$(cat /proc/sys/kernel/random/uuid)
echo "[INFO] 生成 UUID:"
echo "主节点: $UUID_MAIN"
echo "备用1: $UUID_1"
echo "备用2: $UUID_2"

# -------- 安装 acme.sh 并申请 TLS --------
echo "[3/9] 安装 acme.sh 并申请证书..."
curl https://get.acme.sh | sh
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --keylength ec-256
~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
  --ecc \
  --key-file $SINGBOX_DIR/server.key \
  --fullchain-file $SINGBOX_DIR/server.crt \
  --reloadcmd "systemctl restart sing-box"

# -------- 生成 Sing-box 配置 --------
echo "[4/9] 生成 Sing-box 配置..."
cat > $SINGBOX_DIR/config.json <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $PORT_MAIN,
      "users": [ { "id": "$UUID_MAIN" } ],
      "tls": { "enabled": true, "certificate_path": "$SINGBOX_DIR/server.crt", "key_path": "$SINGBOX_DIR/server.key" },
      "transport": { "type": "ws", "path": "/ray", "headers": { "Host": "$DOMAIN" } }
    },
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $PORT_1,
      "users": [ { "id": "$UUID_1" } ],
      "transport": { "type": "ws", "path": "/chat", "headers": { "Host": "$DOMAIN" } }
    },
    {
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": $PORT_2,
      "users": [ { "id": "$UUID_2" } ],
      "transport": { "type": "ws", "path": "/login", "headers": { "Host": "$DOMAIN" } }
    }
  ],
  "outbounds": [ { "type": "direct" } ]
}
EOF

# -------- 生成 Clash 配置 --------
echo "[5/9] 生成 Clash 配置..."
cat > $CLASH_FILE <<EOF
port: 7890
socks-port: 7891
allow-lan: true
mode: Rule
log-level: info

proxies:
  - name: "Singbox-主节点"
    type: vless
    server: $DOMAIN
    port: $PORT_MAIN
    uuid: $UUID_MAIN
    udp: true
    tls: true
    servername: $DOMAIN
    network: ws
    ws-opts:
      path: "/ray"
      headers:
        Host: "$DOMAIN"

  - name: "Singbox-备用1"
    type: vless
    server: $DOMAIN
    port: $PORT_1
    uuid: $UUID_1
    udp: true
    tls: false
    network: ws
    ws-opts:
      path: "/chat"
      headers:
        Host: "$DOMAIN"

  - name: "Singbox-备用2"
    type: vless
    server: $DOMAIN
    port: $PORT_2
    uuid: $UUID_2
    udp: true
    tls: false
    network: ws
    ws-opts:
      path: "/login"
      headers:
        Host: "$DOMAIN"

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - Singbox-主节点
      - Singbox-备用1
      - Singbox-备用2
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF

# -------- 创建 systemd 服务 --------
echo "[6/9] 创建 systemd 服务..."
cat > $SERVICE_FILE <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $SINGBOX_DIR/config.json
Restart=on-failure
StandardOutput=file:/var/log/sing-box.log
StandardError=file:/var/log/sing-box.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl start sing-box

# -------- 自动更新 Sing-box --------
echo "[7/9] 设置自动更新任务..."
cat > /usr/local/bin/update-singbox.sh <<EOF
#!/bin/bash
cd /tmp
wget -O sing-box.zip $SINGBOX_URL
unzip -o sing-box.zip
chmod +x sing-box
mv sing-box /usr/local/bin/
rm -f sing-box.zip
systemctl restart sing-box
EOF
chmod +x /usr/local/bin/update-singbox.sh
echo "0 3 * * * root /usr/local/bin/update-singbox.sh" > /etc/cron.d/singbox-update

# -------- 安装完成提示 --------
echo "[8/9] 安装完成，节点信息如下："
echo "-----------------------------------"
echo "节点 1 (主节点):"
echo "  地址: $DOMAIN"
echo "  端口: $PORT_MAIN"
echo "  UUID: $UUID_MAIN"
echo "  路径: /ray"
echo "  TLS: 开启"
echo ""
echo "节点 2 (备用):"
echo "  地址: $DOMAIN"
echo "  端口: $PORT_1"
echo "  UUID: $UUID_1"
echo "  路径: /chat"
echo "  TLS: 关闭"
echo ""
echo "节点 3 (备用):"
echo "  地址: $DOMAIN"
echo "  端口: $PORT_2"
echo "  UUID: $UUID_2"
echo "  路径: /login"
echo "  TLS: 关闭"
echo "-----------------------------------"
echo "Clash 配置文件: $CLASH_FILE"
echo "日志文件: /var/log/sing-box.log"
echo "安装完成 ✅"

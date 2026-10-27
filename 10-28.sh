#!/usr/bin/env bash
# ================================================================
# Trojan 一体化部署脚本（融合版）
# 服务端: sing-box (Trojan) + Nginx (伪装回落)
# 平台: Debian/Ubuntu | Docker Compose v2
# 特性: 密钥环境变量 | 镜像锁版本 | 证书 SAN | 多源取 IP
#       TLS 自检 | 容器健康检查 | Telegram 降级推送
# ================================================================

set -euo pipefail

# ── 1. 配置区（可用环境变量覆盖，未设置时用下面的默认值）────────
TG_TOKEN="${TG_TOKEN:-8526087156:AAHR5forb44MA061r0zgcPMiGtkkxHD5K6o}"
TG_CHAT_ID="${TG_CHAT_ID:-6303873752}"
TROJAN_PASSWORD="${TROJAN_PASSWORD:-BinldLDAkkfda55588AAA}"

TROJAN_PORT="${TROJAN_PORT:-51566}"
SNI_DOMAIN="${SNI_DOMAIN:-tool.browser.qq.com}"
DOH_URL="${DOH_URL:-https://223.5.5.5/dns-query}"

# 锁版本，不用 latest
SINGBOX_IMAGE="ghcr.io/sagernet/sing-box:v1.10.7"
NGINX_IMAGE="nginx:1.27.3-alpine"

WORK_DIR="/opt/trojan-deploy"
FALLBACK_PORT=8080          # Nginx 在容器网络内监听的端口
TROJAN_CONTAINER="trojan-singbox"
NGINX_CONTAINER="trojan-nginx"

# ── 颜色 ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 2. root 检查 ────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "请使用 root 运行: sudo bash $0"

# ── 3. 安装 Docker（官方源）─────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    success "Docker + Compose v2 已就绪"
  else
    info "安装 Docker..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    success "Docker 安装完成"
  fi

  # 确保 python3 存在（脚本用 python3 做 URL 编码和 JSON 转义）
  if ! command -v python3 &>/dev/null; then
    info "安装 python3..."
    apt-get install -y python3
  fi
}

# ── 4. 证书（带 SAN，幂等且校验域名）────────────────────────────
gen_cert() {
  local cert_dir="${WORK_DIR}/cert"
  local cert_file="${cert_dir}/server.crt"
  local key_file="${cert_dir}/server.key"
  mkdir -p "$cert_dir"

  # 已有证书时，校验其 SAN/CN 是否包含当前 SNI_DOMAIN，不匹配则重建
  if [[ -f "$cert_file" && -f "$key_file" ]]; then
    local current_san
    current_san=$(openssl x509 -in "$cert_file" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | grep -o "DNS:[^,]*" | head -1 || true)
    local current_cn
    current_cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p' || true)
    if [[ "$current_san" == "DNS:${SNI_DOMAIN}" || "$current_cn" == "${SNI_DOMAIN}" ]]; then
      success "证书已存在且域名匹配（${SNI_DOMAIN}），跳过生成"
      return
    fi
    warn "已存在证书域名与当前 SNI_DOMAIN 不匹配，重新生成..."
    rm -f "$cert_file" "$key_file"
  fi

  info "生成自签证书（CN + SAN = ${SNI_DOMAIN}）..."
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$key_file" \
    -out    "$cert_file" \
    -subj "/CN=${SNI_DOMAIN}" \
    -addext "subjectAltName=DNS:${SNI_DOMAIN}" 2>/dev/null
  chmod 600 "$key_file"
  success "证书生成完成"
}

# ── 5. sing-box 配置（含 fallback 指向 Nginx）────────────────────
write_singbox_config() {
  info "写入 sing-box 配置..."
  cat > "${WORK_DIR}/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [{ "tag": "dns-remote", "address": "${DOH_URL}", "detour": "direct" }],
    "strategy": "ipv4_only"
  },
  "inbounds": [{
    "type": "trojan",
    "tag": "trojan-in",
    "listen": "::",
    "listen_port": ${TROJAN_PORT},
    "users": [{ "name": "user1", "password": "${TROJAN_PASSWORD}" }],
    "tls": {
      "enabled": true,
      "server_name": "${SNI_DOMAIN}",
      "certificate_path": "/etc/sing-box/cert/server.crt",
      "key_path": "/etc/sing-box/cert/server.key"
    },
    "fallback": {
      "server": "${NGINX_CONTAINER}",
      "server_port": ${FALLBACK_PORT}
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
  success "sing-box 配置完成（fallback → ${NGINX_CONTAINER}:${FALLBACK_PORT}）"
}

# ── 6. Nginx 伪装配置 ──────────────────────────────────────────
write_nginx_config() {
  info "写入 Nginx 伪装配置..."
  mkdir -p "${WORK_DIR}/nginx"
  cat > "${WORK_DIR}/nginx/default.conf" <<EOF
server {
    listen ${FALLBACK_PORT} default_server;
    server_name _;

    add_header Server "nginx";
    add_header X-Powered-By "";

    location / {
        return 301 https://${SNI_DOMAIN}\$request_uri;
    }

    location /health {
        access_log off;
        return 200 'ok';
        add_header Content-Type text/plain;
    }
}
EOF
  success "Nginx 伪装配置完成"
}

# ── 7. docker-compose.yml ──────────────────────────────────────
write_compose() {
  info "写入 docker-compose.yml..."
  cat > "${WORK_DIR}/docker-compose.yml" <<EOF
services:
  nginx:
    image: ${NGINX_IMAGE}
    container_name: ${NGINX_CONTAINER}
    restart: always
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:${FALLBACK_PORT}/health"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    networks:
      - trojan_net

  singbox:
    image: ${SINGBOX_IMAGE}
    container_name: ${TROJAN_CONTAINER}
    restart: always
    ports:
      - "${TROJAN_PORT}:${TROJAN_PORT}/tcp"
      - "${TROJAN_PORT}:${TROJAN_PORT}/udp"
    volumes:
      - ./config.json:/etc/sing-box/config.json:ro
      - ./cert:/etc/sing-box/cert:ro
    command: run -D /var/lib/sing-box -c /etc/sing-box/config.json
    depends_on:
      nginx:
        condition: service_healthy
    networks:
      - trojan_net

networks:
  trojan_net:
    driver: bridge
EOF
  success "docker-compose.yml 写入完成"
}

# ── 8. 防火墙 ──────────────────────────────────────────────────
open_firewall() {
  info "放行端口 ${TROJAN_PORT}..."
  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${TROJAN_PORT}/tcp" >/dev/null 2>&1 || true
    ufw allow "${TROJAN_PORT}/udp" >/dev/null 2>&1 || true
  fi
  iptables -I INPUT -p tcp --dport "${TROJAN_PORT}" -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p udp --dport "${TROJAN_PORT}" -j ACCEPT 2>/dev/null || true
  success "防火墙规则已处理（云安全组需手动放行 ${TROJAN_PORT}）"
}

# ── 9. 启动 + 健康检查 ─────────────────────────────────────────
start_services() {
  info "清理旧容器..."
  docker rm -f "${TROJAN_CONTAINER}" "${NGINX_CONTAINER}" 2>/dev/null || true

  info "拉取镜像并启动..."
  cd "${WORK_DIR}"
  docker compose pull
  docker compose up -d

  info "等待容器就绪..."
  local retries=10
  while (( retries-- > 0 )); do
    local nginx_status singbox_status
    nginx_status=$(docker inspect --format='{{.State.Health.Status}}' "${NGINX_CONTAINER}" 2>/dev/null || echo "unknown")
    singbox_status=$(docker inspect --format='{{.State.Status}}' "${TROJAN_CONTAINER}" 2>/dev/null || echo "unknown")
    if [[ "$nginx_status" == "healthy" && "$singbox_status" == "running" ]]; then
      success "Nginx healthy, sing-box running"
      return 0
    fi
    sleep 2
  done
  warn "容器状态未达预期，请检查: docker compose logs"
  return 0
}

# ── 10. TLS 自检 ───────────────────────────────────────────────
verify_tls() {
  info "验证 TLS 握手（端口 ${TROJAN_PORT}）..."
  sleep 1
  local result
  result=$(echo | timeout 5 openssl s_client -connect "127.0.0.1:${TROJAN_PORT}" -servername "${SNI_DOMAIN}" 2>&1 | grep -E "CONNECTED|subject=" || true)
  if echo "$result" | grep -q "CONNECTED"; then
    success "TLS 握手成功（自签证书，Verify 非 0 属预期）"
  else
    warn "TLS 握手失败，请检查: docker logs ${TROJAN_CONTAINER}"
  fi
}

# ── 11. 多源取公网 IPv4 ────────────────────────────────────────
get_public_ip() {
  local ip=""
  ip=$(curl -4 -s --max-time 5 https://api4.ipify.org 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
  ip=$(curl -4 -s --max-time 5 https://ipv4.icanhazip.com 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
  ip=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
  echo "YOUR_SERVER_IP"
}

# ── 12. Telegram 推送（MarkdownV2 失败降级纯文本）─────────────
send_telegram() {
  local server_ip="$1" link="$2"

  local msg_md
  msg_md=$(cat <<EOF
🚀 *Trojan 节点部署成功*

\`\`\`
地址: ${server_ip}
端口: ${TROJAN_PORT}
密码: ${TROJAN_PASSWORD}
SNI : ${SNI_DOMAIN}
\`\`\`

🔗 \`${link}\`

⚠️ 云安全组请放行 TCP ${TROJAN_PORT}
EOF
)

  # 尝试 MarkdownV2
  local http_code
  http_code=$(curl -s -o /tmp/tg_resp.json -w "%{http_code}" \
    -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"chat_id": sys.argv[1], "text": sys.stdin.read(), "parse_mode": "MarkdownV2", "disable_web_page_preview": True}))' "${TG_CHAT_ID}" <<< "$msg_md")" 2>/dev/null || echo "000")

  if [[ "$http_code" == "200" ]] && grep -q '"ok":true' /tmp/tg_resp.json 2>/dev/null; then
    success "Telegram 推送成功（Markdown）"
    return
  fi

  # 降级纯文本
  warn "Markdown 推送失败，降级纯文本..."
  local plain_msg="Trojan 节点部署完成
地址: ${server_ip}
端口: ${TROJAN_PORT}
密码: ${TROJAN_PASSWORD}
SNI : ${SNI_DOMAIN}

链接:
${link}

请在云安全组放行 TCP ${TROJAN_PORT}"

  curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${plain_msg}" \
    --data-urlencode "disable_web_page_preview=true" >/dev/null
  success "纯文本降级推送完成"
}

# ── 13. 输出与推送 ─────────────────────────────────────────────
print_and_notify() {
  info "获取公网 IP..."
  local server_ip
  server_ip=$(get_public_ip)
  success "公网 IP: ${server_ip}"

  local encoded_pass
  encoded_pass=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${TROJAN_PASSWORD}', safe=''))")
  local node_name="Trojan-${server_ip}"
  local encoded_name
  encoded_name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${node_name}', safe=''))")
  local link="trojan://${encoded_pass}@${server_ip}:${TROJAN_PORT}?sni=${SNI_DOMAIN}&allowInsecure=1#${encoded_name}"

  echo ""
  echo -e "${GREEN}=================================================${NC}"
  echo -e "${GREEN}         🎉 部署完成                          ${NC}"
  echo -e "${GREEN}=================================================${NC}"
  echo -e "  地址    : ${server_ip}"
  echo -e "  端口    : ${TROJAN_PORT}"
  echo -e "  密码    : ${TROJAN_PASSWORD}"
  echo -e "  SNI     : ${SNI_DOMAIN}"
  echo -e "  链接    : ${YELLOW}${link}${NC}"
  echo -e "${GREEN}=================================================${NC}"
  echo -e "  ⚠️  云安全组放行 TCP ${TROJAN_PORT}"
  echo -e "  🐳 日志: docker logs ${TROJAN_CONTAINER}"
  echo -e "${GREEN}=================================================${NC}"

  send_telegram "${server_ip}" "${link}"
}

# ================================================================
# 主流程
# ================================================================
info "开始部署..."
install_docker
gen_cert
write_singbox_config
write_nginx_config
write_compose
open_firewall
start_services
verify_tls
print_and_notify
success "全部完成"
#!/bin/sh
# TokenForge Gateway 一键安装脚本 (Mac + Linux)
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/tokenforgegateway/tokenforge-install/main/install.sh | sh
#
# 环境变量覆盖:
#   TF_VERSION   镜像版本,默认 latest  (TF_VERSION=1.2.1 curl ... | sh)
#   TF_DIR       安装目录,默认 ~/tokenforge-gateway
#   TF_PORT      监听端口,默认 3080
#   TF_BIND      监听地址,默认 0.0.0.0(所有网卡,局域网可访问)
#                  设 127.0.0.1 则仅本机;设具体网卡 IP 则只绑该网卡
#   TF_MIRROR    设为 cn 时用阿里云 ACR 镜像源(国内免翻墙)
set -e

GHCR_OWNER="tokenforgegateway"
VERSION="${TF_VERSION:-1.3.0}"

# ── 镜像源:默认 GHCR(海外);国内 TF_MIRROR=cn 切阿里云 ACR ──────────────────
if [ "$TF_MIRROR" = "cn" ]; then
  REGISTRY="${TF_REGISTRY:-crpi-7ojsi5ho45o7q3y9.cn-hangzhou.personal.cr.aliyuncs.com/tokenforge}"
  PG_IMAGE="${TF_PG_IMAGE:-crpi-7ojsi5ho45o7q3y9.cn-hangzhou.personal.cr.aliyuncs.com/tokenforge/postgres:16-alpine}"
  REDIS_IMAGE="${TF_REDIS_IMAGE:-crpi-7ojsi5ho45o7q3y9.cn-hangzhou.personal.cr.aliyuncs.com/tokenforge/redis:7-alpine}"
else
  REGISTRY="${TF_REGISTRY:-ghcr.io/${GHCR_OWNER}}"
  PG_IMAGE="${TF_PG_IMAGE:-postgres:16-alpine}"
  REDIS_IMAGE="${TF_REDIS_IMAGE:-redis:7-alpine}"
fi
IMAGE="${REGISTRY}/tokenforge-gateway"
OTA_IMAGE="${IMAGE}-ota"
INSTALL_DIR="${TF_DIR:-$HOME/tokenforge-gateway}"
PORT="${TF_PORT:-3080}"
BIND="${TF_BIND:-0.0.0.0}"

# ── 终端颜色(非 tty 时自动清空) ─────────────────────────────────────────────
if [ -t 1 ]; then
  C_CYAN='\033[0;36m'; C_GREEN='\033[0;32m'
  C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_RESET='\033[0m'
else
  C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi

step()  { printf "${C_CYAN}→${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}✓${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}!${C_RESET} %s\n" "$*"; }
die()   { printf "${C_RED}✗${C_RESET} %s\n" "$*" >&2; exit 1; }

# ── 前置检查 ─────────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 \
  || die "未找到 docker — 请先安装 Docker Desktop: https://docs.docker.com/get-docker/"

docker compose version >/dev/null 2>&1 \
  || die "未找到 'docker compose'(v2) — 请升级 Docker Desktop 或安装 docker-compose-plugin"

# ── 检测架构 ─────────────────────────────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  PLATFORM="linux/amd64" ;;
  aarch64|arm64) PLATFORM="linux/arm64" ;;
  *) die "不支持的 CPU 架构: $ARCH" ;;
esac

# ── 准备安装目录 ──────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo ""
step "安装目录: $INSTALL_DIR"
step "镜像: ${IMAGE}:${VERSION} (${PLATFORM})"
step "OTA sidecar: ${OTA_IMAGE}:${VERSION} (${PLATFORM})"
echo ""

# ── 拉取镜像 ─────────────────────────────────────────────────────────────────
step "拉取镜像..."
if ! docker pull --platform "$PLATFORM" "${IMAGE}:${VERSION}"; then
  echo ""
  die "镜像拉取失败。请确认镜像已设为 Public，或联系 TokenForge 获取访问权限。"
fi
if ! docker pull --platform "$PLATFORM" "${OTA_IMAGE}:${VERSION}"; then
  echo ""
  die "OTA sidecar 镜像拉取失败。请确认镜像已设为 Public，或联系 TokenForge 获取访问权限。"
fi
ok "镜像已就绪"

# ── 写入 docker-compose.yml ──────────────────────────────────────────────────
step "写入 docker-compose.yml..."
cat > docker-compose.yml << 'COMPOSE_EOF'
# 由 install.sh 生成，升级时会覆盖此文件；请勿手动编辑镜像标签。
# 如需自定义端口等参数，修改 .env 文件。
name: tokenforge-gateway
services:
  db:
    image: PG_IMAGE_PLACEHOLDER
    environment:
      POSTGRES_USER: tokenforge
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: tokenforge
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U tokenforge']
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  redis:
    image: REDIS_IMAGE_PLACEHOLDER
    healthcheck:
      test: ['CMD', 'redis-cli', 'ping']
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  tokenforge:
    image: ${GATEWAY_IMAGE_REPO}:${GATEWAY_VERSION}
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      # 监听地址由 .env 的 TF_BIND 控制(默认 0.0.0.0,局域网可访问)
      - '${TF_BIND:-0.0.0.0}:${TF_PORT:-3080}:3080'
    environment:
      - NODE_ENV=production
      - TF_DB_DIALECT=pg
      - DATABASE_URL=${DATABASE_URL}
      - REDIS_URL=redis://redis:6379
      - TF_LICENSE_KEY=${TF_LICENSE_KEY}
      - TF_SESSION_SECRET=${TF_SESSION_SECRET}
      # 网关主密钥:加密落库的 sync token / 网关私钥。production 下缺失会导致序列码激活失败。
      - GATEWAY_KEY_MASTER=${GATEWAY_KEY_MASTER}
      - TF_LOG_LEVEL=${TF_LOG_LEVEL:-info}
      # 序列码激活:经 tokenforge-server 注册握手(置 0 则本地激活、无需序列码)
      - TOKENFORGE_SERVER_ENABLED=${TOKENFORGE_SERVER_ENABLED:-1}
      - TOKENFORGE_SERVER_URL=${TOKENFORGE_SERVER_URL:-https://tokenforge.tokgoai.com}
      # 网关访问地址展示(ADR 0047):页面按位面给候选地址。
      - TF_PUBLIC_BASE_URL=${TF_PUBLIC_BASE_URL:-}
      - TF_ADVERTISE_IPS=${TF_ADVERTISE_IPS:-}
      - TF_ADVERTISE_PORT=${TF_ADVERTISE_PORT:-${TF_PORT:-3080}}
      - TF_OTA_DIR=/otastate
    volumes:
      - otastate:/otastate
    healthcheck:
      test: ['CMD', 'wget', '-qO-', 'http://127.0.0.1:3080/healthz']
      interval: 30s
      timeout: 10s
      start_period: 30s
      retries: 3
    restart: unless-stopped

  ota-updater:
    image: ${GATEWAY_OTA_IMAGE_REPO}:${GATEWAY_VERSION}
    depends_on:
      tokenforge:
        condition: service_started
    environment:
      - TF_OTA_DIR=/otastate
      - TF_OTA_INTERVAL=${TF_OTA_INTERVAL:-30}
      - TF_OTA_HEALTH_URL=http://tokenforge:3080/healthz
      - TF_OTA_HEALTH_TIMEOUT=${TF_OTA_HEALTH_TIMEOUT:-60}
      - COMPOSE_PROJECT_DIR=/compose
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - otastate:/otastate
      - ./:/compose
    restart: unless-stopped

volumes:
  pgdata:
  otastate:
COMPOSE_EOF

# 把占位符替换为实际镜像(sed -i 在 macOS 和 Linux 写法不同,用临时文件规避)
sed -e "s|PG_IMAGE_PLACEHOLDER|${PG_IMAGE}|" \
    -e "s|REDIS_IMAGE_PLACEHOLDER|${REDIS_IMAGE}|" \
    docker-compose.yml > docker-compose.yml.tmp
mv docker-compose.yml.tmp docker-compose.yml
ok "docker-compose.yml 已就绪"

# ── 生成 .env(幂等:已存在则复用,不改密) ─────────────────────────────────────
gen32() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 43; }

set_env_line() {
  key="$1"; value="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed "s#^${key}=.*#${key}=${value}#" .env > .env.new && cat .env.new > .env && rm -f .env.new
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

if [ ! -f .env ]; then
  step "生成随机密钥..."
  umask 077
  PG_PW=$(gen32)
  cat > .env << ENV_EOF
POSTGRES_PASSWORD=$PG_PW
DATABASE_URL=postgres://tokenforge:$PG_PW@db:5432/tokenforge
TF_LICENSE_KEY=$(gen32)
TF_SESSION_SECRET=$(gen32)
GATEWAY_KEY_MASTER=$(gen32)
TF_PORT=$PORT
TF_BIND=$BIND
GATEWAY_IMAGE_REPO=$IMAGE
GATEWAY_OTA_IMAGE_REPO=$OTA_IMAGE
GATEWAY_VERSION=$VERSION
TF_OTA_INTERVAL=${TF_OTA_INTERVAL:-30}
TF_OTA_HEALTH_TIMEOUT=${TF_OTA_HEALTH_TIMEOUT:-60}
TOKENFORGE_SERVER_ENABLED=${TOKENFORGE_SERVER_ENABLED:-1}
TOKENFORGE_SERVER_URL=${TOKENFORGE_SERVER_URL:-https://tokenforge.tokgoai.com}
ENV_EOF
  ok "密钥已生成(.env)"
  warn "请备份 .env 文件!丢失后数据库加密数据将永久无法恢复。"
else
  ok "复用已有 .env(密钥不变)"
  # 存量自愈:1.2.4 及更早版本的 .env 缺 GATEWAY_KEY_MASTER,补上以免序列码激活失败。
  if ! grep -q '^GATEWAY_KEY_MASTER=' .env; then
    printf 'GATEWAY_KEY_MASTER=%s\n' "$(gen32)" >> .env
    ok "已补全缺失的 GATEWAY_KEY_MASTER"
  fi
  # 存量自愈:旧版 .env 无 TF_BIND(老 compose 把端口写死在 127.0.0.1)。
  # 补成 0.0.0.0,使升级后局域网即可访问(与全新安装行为一致)。
  if ! grep -q '^TF_BIND=' .env; then
    printf 'TF_BIND=%s\n' "$BIND" >> .env
    ok "已补全 TF_BIND=$BIND(升级后局域网可访问)"
  fi
fi

set_env_line GATEWAY_IMAGE_REPO "$IMAGE"
set_env_line GATEWAY_OTA_IMAGE_REPO "$OTA_IMAGE"
set_env_line GATEWAY_VERSION "$VERSION"
set_env_line TF_OTA_INTERVAL "${TF_OTA_INTERVAL:-30}"
set_env_line TF_OTA_HEALTH_TIMEOUT "${TF_OTA_HEALTH_TIMEOUT:-60}"

# ── 枚举宿主网卡 IP,注入 TF_ADVERTISE_IPS(ADR 0047)──────────────────────────
# 过滤 docker 网桥/回环;容器内看不到宿主网卡,必须在宿主枚举后注入。IP 可能变,每次刷新。
if command -v ip >/dev/null 2>&1; then
  ADVERTISE_IPS=$(ip -o -4 addr show scope global 2>/dev/null \
    | awk '$2 !~ /^(docker|br-|veth|lo)/ { print $4 }' \
    | cut -d/ -f1 | paste -sd, -)
else
  ADVERTISE_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' \
    | grep -vE '^(127\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.)' \
    | grep -E '^[0-9]+\.' | paste -sd, -)
fi
if grep -q '^TF_ADVERTISE_IPS=' .env; then
  sed "s#^TF_ADVERTISE_IPS=.*#TF_ADVERTISE_IPS=${ADVERTISE_IPS}#" .env > .env.new \
    && cat .env.new > .env && rm -f .env.new
else
  printf 'TF_ADVERTISE_IPS=%s\n' "$ADVERTISE_IPS" >> .env
fi

# ── 启动服务 ─────────────────────────────────────────────────────────────────
step "启动服务..."
docker compose up -d
ok "容器已启动"

# ── 等待健康检查 ──────────────────────────────────────────────────────────────
ACTUAL_PORT=$(grep -E '^TF_PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
ACTUAL_PORT=${ACTUAL_PORT:-$PORT}
ACTUAL_BIND=$(grep -E '^TF_BIND=' .env 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
ACTUAL_BIND=${ACTUAL_BIND:-$BIND}

# 尽力探测一个局域网 IP(Linux: hostname -I;macOS: ipconfig),失败则留占位符
lan_ip() {
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -z "$ip" ] && ip=$(ipconfig getifaddr en0 2>/dev/null)
  [ -z "$ip" ] && ip=$(ipconfig getifaddr en1 2>/dev/null)
  [ -z "$ip" ] && ip="<本机IP>"
  echo "$ip"
}

step "等待服务就绪 (http://127.0.0.1:${ACTUAL_PORT}/healthz)..."
http_ok() { wget -qO- "http://127.0.0.1:${ACTUAL_PORT}/healthz" >/dev/null 2>&1 \
         || curl -fsS -o /dev/null -m 2 "http://127.0.0.1:${ACTUAL_PORT}/healthz" 2>/dev/null; }

n=0
while [ $n -lt 30 ] && ! http_ok; do
  n=$((n+1))
  sleep 2
done

echo ""
if http_ok; then
  printf "${C_GREEN}✓ TokenForge Gateway 安装成功！${C_RESET}\n"
  echo ""
  echo "  本机访问 → http://localhost:${ACTUAL_PORT}"
  if [ "$ACTUAL_BIND" = "0.0.0.0" ]; then
    echo "  局域网访问 → http://$(lan_ip):${ACTUAL_PORT}  (同网段的其他设备)"
    echo ""
    warn "已监听所有网卡。若装在有公网 IP 的服务器上,3080/${ACTUAL_PORT} 端口会对公网暴露:"
    echo "      · 仅内网使用 → 在 .env 设 TF_BIND=127.0.0.1 后 docker compose up -d"
    echo "      · 需公网访问 → 前置反向代理(Caddy/Nginx)加 HTTPS+认证,勿裸暴露"
    echo "      · 若开了防火墙/云安全组,记得放行 ${ACTUAL_PORT}/tcp"
  fi
  echo "  首次使用 → 浏览器打开后完成开箱引导，输入序列码激活"
  echo ""
  echo "  安装目录: $INSTALL_DIR"
  echo "  常用命令(在安装目录下运行):"
  echo "    docker compose logs -f    # 实时日志"
  echo "    docker compose down       # 停止"
  echo "    docker compose up -d      # 启动"
  echo "    docker compose down -v    # 重置(慎用，删除所有数据)"
  echo ""
  echo "  升级: 再次运行安装命令，指定新版本号"
  echo "    TF_VERSION=1.3.0 curl -fsSL .../install.sh | sh"
else
  warn "服务 60s 内未就绪，运行以下命令查看日志:"
  echo "  cd $INSTALL_DIR && docker compose logs"
  exit 1
fi

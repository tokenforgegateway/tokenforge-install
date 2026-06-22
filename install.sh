#!/bin/sh
# TokenForge Gateway 一键安装脚本 (Mac + Linux)
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/tokenforgegateway/install/main/install.sh | sh
#
# 环境变量覆盖:
#   TF_VERSION   镜像版本,默认 latest  (TF_VERSION=1.2.1 curl ... | sh)
#   TF_DIR       安装目录,默认 ~/tokenforge-gateway
#   TF_PORT      监听端口,默认 3080
#   TF_MIRROR    设为 cn 时用阿里云 ACR 镜像源(国内免翻墙)
set -e

GHCR_OWNER="tokenforgegateway"
VERSION="${TF_VERSION:-latest}"

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
INSTALL_DIR="${TF_DIR:-$HOME/tokenforge-gateway}"
PORT="${TF_PORT:-3080}"

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
echo ""

# ── 拉取镜像 ─────────────────────────────────────────────────────────────────
step "拉取镜像..."
if ! docker pull --platform "$PLATFORM" "${IMAGE}:${VERSION}"; then
  echo ""
  die "镜像拉取失败。请确认镜像已设为 Public，或联系 TokenForge 获取访问权限。"
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
    image: GATEWAY_IMAGE_PLACEHOLDER
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      - '127.0.0.1:${TF_PORT:-3080}:3080'
    environment:
      - NODE_ENV=production
      - TF_DB_DIALECT=pg
      - DATABASE_URL=${DATABASE_URL}
      - REDIS_URL=redis://redis:6379
      - TF_LICENSE_KEY=${TF_LICENSE_KEY}
      - TF_SESSION_SECRET=${TF_SESSION_SECRET}
      - TF_LOG_LEVEL=${TF_LOG_LEVEL:-info}
      # 序列码激活:经 tokenforge-server 注册握手(置 0 则本地激活、无需序列码)
      - TOKENFORGE_SERVER_ENABLED=${TOKENFORGE_SERVER_ENABLED:-1}
      - TOKENFORGE_SERVER_URL=${TOKENFORGE_SERVER_URL:-https://tokenforge.tokgoai.com}
    healthcheck:
      test: ['CMD', 'wget', '-qO-', 'http://127.0.0.1:3080/healthz']
      interval: 30s
      timeout: 10s
      start_period: 30s
      retries: 3
    restart: unless-stopped

volumes:
  pgdata:
COMPOSE_EOF

# 把占位符替换为实际镜像(sed -i 在 macOS 和 Linux 写法不同,用临时文件规避)
sed -e "s|GATEWAY_IMAGE_PLACEHOLDER|${IMAGE}:${VERSION}|" \
    -e "s|PG_IMAGE_PLACEHOLDER|${PG_IMAGE}|" \
    -e "s|REDIS_IMAGE_PLACEHOLDER|${REDIS_IMAGE}|" \
    docker-compose.yml > docker-compose.yml.tmp
mv docker-compose.yml.tmp docker-compose.yml
ok "docker-compose.yml 已就绪"

# ── 生成 .env(幂等:已存在则复用,不改密) ─────────────────────────────────────
gen32() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 43; }

if [ ! -f .env ]; then
  step "生成随机密钥..."
  umask 077
  PG_PW=$(gen32)
  cat > .env << ENV_EOF
POSTGRES_PASSWORD=$PG_PW
DATABASE_URL=postgres://tokenforge:$PG_PW@db:5432/tokenforge
TF_LICENSE_KEY=$(gen32)
TF_SESSION_SECRET=$(gen32)
TF_PORT=$PORT
TOKENFORGE_SERVER_ENABLED=${TOKENFORGE_SERVER_ENABLED:-1}
TOKENFORGE_SERVER_URL=${TOKENFORGE_SERVER_URL:-https://tokenforge.tokgoai.com}
ENV_EOF
  ok "密钥已生成(.env)"
  warn "请备份 .env 文件!丢失后数据库加密数据将永久无法恢复。"
else
  ok "复用已有 .env(密钥不变)"
fi

# ── 启动服务 ─────────────────────────────────────────────────────────────────
step "启动服务..."
docker compose up -d
ok "容器已启动"

# ── 等待健康检查 ──────────────────────────────────────────────────────────────
ACTUAL_PORT=$(grep -E '^TF_PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
ACTUAL_PORT=${ACTUAL_PORT:-$PORT}

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
  echo "  访问地址 → http://localhost:${ACTUAL_PORT}"
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

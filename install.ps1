# TokenForge Gateway 一键安装脚本 (Windows PowerShell)
#
# 用法:
#   irm https://raw.githubusercontent.com/tokenforgegateway/install/main/install.ps1 | iex
#
# 环境变量覆盖:
#   $env:TF_VERSION   镜像版本，默认 latest
#   $env:TF_DIR       安装目录，默认 $HOME\tokenforge-gateway
#   $env:TF_PORT      监听端口，默认 3080
#   $env:TF_MIRROR    设为 cn 时用阿里云 ACR 镜像源(国内免翻墙)
#
# 依赖: Docker Desktop for Windows (https://docs.docker.com/desktop/install/windows-install/)
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$GhcrOwner = 'tokenforgegateway'
$Version   = if ($env:TF_VERSION) { $env:TF_VERSION } else { 'latest' }

# 镜像源:默认 GHCR(海外);国内 $env:TF_MIRROR=cn 切阿里云 ACR
if ($env:TF_MIRROR -eq 'cn') {
  $Registry  = if ($env:TF_REGISTRY)  { $env:TF_REGISTRY }  else { 'crpi-7ojsi5ho45o7q3y9.cn-hangzhou.personal.cr.aliyuncs.com/tokenforge' }
  $PgImage   = if ($env:TF_PG_IMAGE)  { $env:TF_PG_IMAGE }  else { 'crpi-7ojsi5ho45o7q3y9.cn-hangzhou.personal.cr.aliyuncs.com/tokenforge/postgres:16-alpine' }
  $RedisImage= if ($env:TF_REDIS_IMAGE){ $env:TF_REDIS_IMAGE }else { 'crpi-7ojsi5ho45o7q3y9.cn-hangzhou.personal.cr.aliyuncs.com/tokenforge/redis:7-alpine' }
} else {
  $Registry  = if ($env:TF_REGISTRY)  { $env:TF_REGISTRY }  else { "ghcr.io/$GhcrOwner" }
  $PgImage   = if ($env:TF_PG_IMAGE)  { $env:TF_PG_IMAGE }  else { 'postgres:16-alpine' }
  $RedisImage= if ($env:TF_REDIS_IMAGE){ $env:TF_REDIS_IMAGE }else { 'redis:7-alpine' }
}
$Image     = "$Registry/tokenforge-gateway:$Version"
$InstallDir = if ($env:TF_DIR) { $env:TF_DIR } else { Join-Path $HOME 'tokenforge-gateway' }
$Port      = if ($env:TF_PORT)    { $env:TF_PORT }    else { '3080' }

function Write-Step  { Write-Host "-> $args" -ForegroundColor Cyan }
function Write-Ok    { Write-Host "v  $args" -ForegroundColor Green }
function Write-Warn  { Write-Host "!  $args" -ForegroundColor Yellow }
function Write-Fail  { Write-Host "x  $args" -ForegroundColor Red; exit 1 }

# ── 前置检查 ──────────────────────────────────────────────────────────────────
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Fail "未找到 docker — 请先安装 Docker Desktop: https://docs.docker.com/desktop/install/windows-install/"
}
try { docker compose version 2>&1 | Out-Null }
catch { Write-Fail "未找到 'docker compose'(v2) — 请升级 Docker Desktop" }

# ── 检测架构 ──────────────────────────────────────────────────────────────────
$arch = (Get-WmiObject Win32_Processor).Architecture
$Platform = switch ($arch) {
  9  { 'linux/amd64' }   # x64
  12 { 'linux/arm64' }   # ARM64
  default { Write-Fail "不支持的 CPU 架构 ($arch)" }
}

# ── 准备安装目录 ──────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Set-Location $InstallDir

Write-Host ""
Write-Step "安装目录: $InstallDir"
Write-Step "镜像: $Image ($Platform)"
Write-Host ""

# ── 拉取镜像 ──────────────────────────────────────────────────────────────────
Write-Step "拉取镜像..."
$pullResult = docker pull --platform $Platform $Image 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host $pullResult
  Write-Fail "镜像拉取失败。请确认镜像已设为 Public，或联系 TokenForge 获取访问权限。"
}
Write-Ok "镜像已就绪"

# ── 写入 docker-compose.yml ───────────────────────────────────────────────────
Write-Step "写入 docker-compose.yml..."
$composeContent = @"
# 由 install.ps1 生成，升级时会覆盖此文件；请勿手动编辑镜像标签。
# 如需自定义端口等参数，修改 .env 文件。
name: tokenforge-gateway
services:
  db:
    image: $PgImage
    environment:
      POSTGRES_USER: tokenforge
      POSTGRES_PASSWORD: `${POSTGRES_PASSWORD}
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
    image: $RedisImage
    healthcheck:
      test: ['CMD', 'redis-cli', 'ping']
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  tokenforge:
    image: $Image
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      - '127.0.0.1:`${TF_PORT:-3080}:3080'
    environment:
      - NODE_ENV=production
      - TF_DB_DIALECT=pg
      - DATABASE_URL=`${DATABASE_URL}
      - REDIS_URL=redis://redis:6379
      - TF_LICENSE_KEY=`${TF_LICENSE_KEY}
      - TF_SESSION_SECRET=`${TF_SESSION_SECRET}
      - TF_LOG_LEVEL=`${TF_LOG_LEVEL:-info}
    healthcheck:
      test: ['CMD', 'wget', '-qO-', 'http://127.0.0.1:3080/healthz']
      interval: 30s
      timeout: 10s
      start_period: 30s
      retries: 3
    restart: unless-stopped

volumes:
  pgdata:
"@
# 用 UTF-8(无 BOM)写入，避免 docker compose 解析失败
[System.IO.File]::WriteAllText(
  (Join-Path $InstallDir 'docker-compose.yml'),
  $composeContent,
  [System.Text.UTF8Encoding]::new($false)
)
Write-Ok "docker-compose.yml 已就绪"

# ── 生成 .env(幂等:已存在则复用，不改密) ─────────────────────────────────────
function New-Secret {
  $bytes = [byte[]]::new(48)
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  # base64 后只保留字母数字，取前 43 位
  return [Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]','' | ForEach-Object { $_.Substring(0, [Math]::Min(43, $_.Length)) }
}

$envFile = Join-Path $InstallDir '.env'
if (-not (Test-Path $envFile)) {
  Write-Step "生成随机密钥..."
  $pgPw = New-Secret
  $envContent = @"
POSTGRES_PASSWORD=$pgPw
DATABASE_URL=postgres://tokenforge:$pgPw@db:5432/tokenforge
TF_LICENSE_KEY=$(New-Secret)
TF_SESSION_SECRET=$(New-Secret)
TF_PORT=$Port
"@
  [System.IO.File]::WriteAllText($envFile, $envContent, [System.Text.UTF8Encoding]::new($false))
  Write-Ok "密钥已生成(.env)"
  Write-Warn "请备份 .env 文件！丢失后数据库加密数据将永久无法恢复。"
} else {
  Write-Ok "复用已有 .env(密钥不变)"
}

# ── 启动服务 ──────────────────────────────────────────────────────────────────
Write-Step "启动服务..."
docker compose up -d
if ($LASTEXITCODE -ne 0) { Write-Fail "docker compose up 失败，请查看上方错误信息" }
Write-Ok "容器已启动"

# ── 等待健康检查 ──────────────────────────────────────────────────────────────
$actualPort = (Get-Content $envFile -ErrorAction SilentlyContinue |
  Where-Object { $_ -match '^TF_PORT=' } |
  ForEach-Object { ($_ -split '=', 2)[1].Trim() } |
  Select-Object -First 1)
if (-not $actualPort) { $actualPort = $Port }

$healthUrl = "http://127.0.0.1:$actualPort/healthz"
Write-Step "等待服务就绪 ($healthUrl)..."

$ready = $false
for ($i = 0; $i -lt 30; $i++) {
  try {
    $r = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
    if ($r.StatusCode -eq 200) { $ready = $true; break }
  } catch {}
  Start-Sleep -Seconds 2
}

Write-Host ""
if ($ready) {
  Write-Host "v  TokenForge Gateway 安装成功！" -ForegroundColor Green
  Write-Host ""
  Write-Host "  访问地址 -> http://localhost:$actualPort"
  Write-Host "  首次使用 -> 浏览器打开后完成开箱引导，输入序列码激活"
  Write-Host ""
  Write-Host "  安装目录: $InstallDir"
  Write-Host "  常用命令(在安装目录下运行 PowerShell):"
  Write-Host "    docker compose logs -f    # 实时日志"
  Write-Host "    docker compose down       # 停止"
  Write-Host "    docker compose up -d      # 启动"
  Write-Host "    docker compose down -v    # 重置(慎用，删除所有数据)"
  Write-Host ""
  Write-Host "  升级: 再次运行安装命令，指定新版本号"
  Write-Host '    $env:TF_VERSION="1.3.0"; irm .../install.ps1 | iex'
} else {
  Write-Warn "服务 60s 内未就绪，运行以下命令查看日志:"
  Write-Host "  cd `"$InstallDir`"; docker compose logs"
  exit 1
}

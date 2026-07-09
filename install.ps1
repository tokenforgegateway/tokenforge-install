# TokenForge Gateway 一键安装脚本 (Windows PowerShell)
#
# 用法:
#   irm https://raw.githubusercontent.com/tokenforgegateway/tokenforge-install/main/install.ps1 | iex
#
# 环境变量覆盖:
#   $env:TF_VERSION   镜像版本，默认 latest
#   $env:TF_DIR       安装目录，默认 $HOME\tokenforge-gateway
#   $env:TF_PORT      监听端口，默认 3080
#   $env:TF_BIND      监听地址，默认 0.0.0.0(所有网卡，局域网可访问);设 127.0.0.1 则仅本机
#   $env:TF_MIRROR    设为 cn 时用阿里云 ACR 镜像源(国内免翻墙)
#
# 依赖: Docker Desktop for Windows (https://docs.docker.com/desktop/install/windows-install/)
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$GhcrOwner = 'tokenforgegateway'
$Version   = if ($env:TF_VERSION) { $env:TF_VERSION } else { '1.3.0' }

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
$ImageRepo = "$Registry/tokenforge-gateway"
$OtaImageRepo = "$Registry/tokenforge-gateway-ota"
$Image = "${ImageRepo}:$Version"
$OtaImage = "${OtaImageRepo}:$Version"
$InstallDir = if ($env:TF_DIR) { $env:TF_DIR } else { Join-Path $HOME 'tokenforge-gateway' }
$Port      = if ($env:TF_PORT)    { $env:TF_PORT }    else { '3080' }
$Bind      = if ($env:TF_BIND)    { $env:TF_BIND }    else { '0.0.0.0' }

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
Write-Step "OTA sidecar: $OtaImage ($Platform)"
Write-Host ""

# ── 拉取镜像 ──────────────────────────────────────────────────────────────────
Write-Step "拉取镜像..."
$pullResult = docker pull --platform $Platform $Image 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host $pullResult
  Write-Fail "镜像拉取失败。请确认镜像已设为 Public，或联系 TokenForge 获取访问权限。"
}
$pullOtaResult = docker pull --platform $Platform $OtaImage 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host $pullOtaResult
  Write-Fail "OTA sidecar 镜像拉取失败。请确认镜像已设为 Public，或联系 TokenForge 获取访问权限。"
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
    image: `${GATEWAY_IMAGE_REPO}:`${GATEWAY_VERSION}
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    ports:
      # 监听地址由 .env 的 TF_BIND 控制(默认 0.0.0.0,局域网可访问;设 127.0.0.1 则仅本机)
      - '`${TF_BIND:-0.0.0.0}:`${TF_PORT:-3080}:3080'
    environment:
      - NODE_ENV=production
      - TF_DB_DIALECT=pg
      - DATABASE_URL=`${DATABASE_URL}
      - REDIS_URL=redis://redis:6379
      - TF_LICENSE_KEY=`${TF_LICENSE_KEY}
      - TF_SESSION_SECRET=`${TF_SESSION_SECRET}
      # 网关主密钥:加密落库的 sync token / 网关私钥。production 下缺失会导致序列码激活失败。
      - GATEWAY_KEY_MASTER=`${GATEWAY_KEY_MASTER}
      - TF_LOG_LEVEL=`${TF_LOG_LEVEL:-info}
      # 序列码激活:经 tokenforge-server 注册握手(置 0 则本地激活、无需序列码)
      - TOKENFORGE_SERVER_ENABLED=`${TOKENFORGE_SERVER_ENABLED:-1}
      - TOKENFORGE_SERVER_URL=`${TOKENFORGE_SERVER_URL:-https://tokenforge.tokgoai.com}
      # 网关访问地址展示(ADR 0047):页面按位面给候选地址。
      - TF_PUBLIC_BASE_URL=`${TF_PUBLIC_BASE_URL:-}
      - TF_ADVERTISE_IPS=`${TF_ADVERTISE_IPS:-}
      - TF_ADVERTISE_PORT=`${TF_ADVERTISE_PORT:-`${TF_PORT:-3080}}
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
    image: `${GATEWAY_OTA_IMAGE_REPO}:`${GATEWAY_VERSION}
    depends_on:
      tokenforge:
        condition: service_started
    environment:
      - TF_OTA_DIR=/otastate
      - TF_OTA_INTERVAL=`${TF_OTA_INTERVAL:-30}
      - TF_OTA_HEALTH_URL=http://tokenforge:3080/healthz
      - TF_OTA_HEALTH_TIMEOUT=`${TF_OTA_HEALTH_TIMEOUT:-60}
      - COMPOSE_PROJECT_DIR=/compose
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - otastate:/otastate
      - ./:/compose
    restart: unless-stopped

volumes:
  pgdata:
  otastate:
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
  # Windows PowerShell 5.1(.NET Framework)没有静态 Fill 方法，用实例 GetBytes 兼容
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $bytes = [byte[]]::new(48)
  $rng.GetBytes($bytes)
  # base64 后只保留字母数字，取前 43 位
  $s = [Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]',''
  return $s.Substring(0, [Math]::Min(43, $s.Length))
}

$envFile = Join-Path $InstallDir '.env'
function Set-EnvLine {
  param([string]$Key, [string]$Value)
  $lines = @()
  if (Test-Path $envFile) {
    $lines = @(Get-Content $envFile | Where-Object { $_ -notmatch "^$([regex]::Escape($Key))=" })
  }
  $lines += "$Key=$Value"
  Set-Content -Path $envFile -Value $lines
}

if (-not (Test-Path $envFile)) {
  Write-Step "生成随机密钥..."
  $pgPw = New-Secret
  $envContent = @"
POSTGRES_PASSWORD=$pgPw
DATABASE_URL=postgres://tokenforge:$pgPw@db:5432/tokenforge
TF_LICENSE_KEY=$(New-Secret)
TF_SESSION_SECRET=$(New-Secret)
GATEWAY_KEY_MASTER=$(New-Secret)
TF_PORT=$Port
TF_BIND=$Bind
GATEWAY_IMAGE_REPO=$ImageRepo
GATEWAY_OTA_IMAGE_REPO=$OtaImageRepo
GATEWAY_VERSION=$Version
TF_OTA_INTERVAL=30
TF_OTA_HEALTH_TIMEOUT=60
TOKENFORGE_SERVER_ENABLED=1
TOKENFORGE_SERVER_URL=https://tokenforge.tokgoai.com
"@
  [System.IO.File]::WriteAllText($envFile, $envContent, [System.Text.UTF8Encoding]::new($false))
  Write-Ok "密钥已生成(.env)"
  Write-Warn "请备份 .env 文件！丢失后数据库加密数据将永久无法恢复。"
} else {
  Write-Ok "复用已有 .env(密钥不变)"
  # 存量自愈:1.2.4 及更早版本的 .env 缺 GATEWAY_KEY_MASTER,补上以免序列码激活失败。
  if (-not (Select-String -Path $envFile -Pattern '^GATEWAY_KEY_MASTER=' -Quiet)) {
    Add-Content -Path $envFile -Value "GATEWAY_KEY_MASTER=$(New-Secret)"
    Write-Ok "已补全缺失的 GATEWAY_KEY_MASTER"
  }
  # 存量自愈:旧版 .env 无 TF_BIND(老 compose 把端口写死在 127.0.0.1)。补成 0.0.0.0,升级后局域网可访问。
  if (-not (Select-String -Path $envFile -Pattern '^TF_BIND=' -Quiet)) {
    Add-Content -Path $envFile -Value "TF_BIND=$Bind"
    Write-Ok "已补全 TF_BIND=$Bind(升级后局域网可访问)"
  }
}

Set-EnvLine 'GATEWAY_IMAGE_REPO' $ImageRepo
Set-EnvLine 'GATEWAY_OTA_IMAGE_REPO' $OtaImageRepo
Set-EnvLine 'GATEWAY_VERSION' $Version
Set-EnvLine 'TF_OTA_INTERVAL' '30'
Set-EnvLine 'TF_OTA_HEALTH_TIMEOUT' '60'

# ── 枚举宿主网卡 IP,注入 TF_ADVERTISE_IPS(ADR 0047)──────────────────────────
# 过滤 docker/WSL 虚拟网卡与回环;容器内看不到宿主网卡,必须在宿主枚举后注入。
$advertiseIps = ((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object {
    $_.IPAddress -notmatch '^(127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)' -and
    $_.InterfaceAlias -notmatch '(?i)(vEthernet|WSL|Docker|Loopback)'
  } |
  Select-Object -ExpandProperty IPAddress) -join ',')
$envLines = @(Get-Content $envFile -ErrorAction SilentlyContinue |
  Where-Object { $_ -notmatch '^TF_ADVERTISE_IPS=' })
$envLines += "TF_ADVERTISE_IPS=$advertiseIps"
Set-Content -Path $envFile -Value $envLines
Write-Ok "已注入对外候选 IP:TF_ADVERTISE_IPS=$advertiseIps"

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

$actualBind = (Get-Content $envFile -ErrorAction SilentlyContinue |
  Where-Object { $_ -match '^TF_BIND=' } |
  ForEach-Object { ($_ -split '=', 2)[1].Trim() } |
  Select-Object -First 1)
if (-not $actualBind) { $actualBind = $Bind }

# 尽力探测一个局域网 IPv4
$lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' } |
  Select-Object -First 1 -ExpandProperty IPAddress)
if (-not $lanIp) { $lanIp = '<本机IP>' }

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
  Write-Host "  本机访问 -> http://localhost:$actualPort"
  if ($actualBind -eq '0.0.0.0') {
    Write-Host "  局域网访问 -> http://${lanIp}:$actualPort  (同网段的其他设备)"
    Write-Host ""
    Write-Warn "已监听所有网卡。若装在有公网 IP 的服务器上，$actualPort 端口会对公网暴露:"
    Write-Host "      . 仅内网使用 -> 在 .env 设 TF_BIND=127.0.0.1 后 docker compose up -d"
    Write-Host "      . 需公网访问 -> 前置反向代理(Caddy/Nginx)加 HTTPS+认证，勿裸暴露"
    Write-Host "      . 若开了防火墙/云安全组，记得放行 $actualPort/tcp"
  }
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

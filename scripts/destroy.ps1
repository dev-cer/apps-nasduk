# Destroy 1-klik: hapus aplikasi, load balancer, volume, dan cluster Civo.
# Pemakaian: klik dua kali scripts\destroy.cmd, atau: powershell -ExecutionPolicy Bypass -File scripts\destroy.ps1 [-Yes]
# PERHATIAN: semua data pesanan ikut terhapus. Unduh Excel dari /admin.html dulu kalau masih perlu.
param([switch]$Yes)
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$RootDir = Split-Path $ScriptDir -Parent
$EnvFile = Join-Path $ScriptDir '.deploy.env'

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Test-Native { # true kalau perintah berhasil; output dibuang (aman di Windows PowerShell 5.1)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $args[0] @($args | Select-Object -Skip 1) *> $null } catch {}
    $ok = ($LASTEXITCODE -eq 0); $ErrorActionPreference = $old
    return $ok
}

$Settings = @{}
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | Where-Object { $_ -match '^([A-Z_][A-Z0-9_]*)=(.*)$' } | ForEach-Object { $Settings[$Matches[1]] = $Matches[2] }
}
function Get-Setting($name, $default = '') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($null -ne $value) { return $value }
    if ($Settings.ContainsKey($name)) { return $Settings[$name] }
    return $default
}

$ClusterName = Get-Setting 'CLUSTER_NAME' 'nasduk'
$Region = Get-Setting 'REGION'
$env:KUBECONFIG = Join-Path $ScriptDir ".kubeconfig-$ClusterName"

if (-not (Get-Command civo -ErrorAction SilentlyContinue)) { Fail "'civo' belum terpasang" }
if (-not $Region) { Fail 'REGION belum diketahui. Isi REGION=<kode> di scripts\.deploy.env' }
if (-not (Test-Native civo kubernetes show $ClusterName --region $Region)) { Fail "Cluster '$ClusterName' tidak ditemukan di region $Region" }

if (-not $Yes) {
    Write-Host "Cluster '$ClusterName' ($Region) beserta SEMUA data pesanan akan dihapus permanen."
    $answer = Read-Host 'Ketik nama cluster untuk melanjutkan'
    if ($answer -ne $ClusterName) { Fail 'Dibatalkan' }
}

# 1. Hapus aplikasi dulu supaya load balancer dan volume ikut terhapus (tidak ditagih terus)
if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    civo kubernetes config $ClusterName --region $Region | Set-Content -Path $env:KUBECONFIG -Encoding ascii
    Info 'Menghapus aplikasi, load balancer, dan volume...'
    Test-Native kubectl delete -f (Join-Path $RootDir 'k8s') --ignore-not-found --wait=true --timeout=300s | Out-Null
}

# 2. Hapus cluster
Info "Menghapus cluster '$ClusterName'..."
civo kubernetes remove $ClusterName --region $Region -y
if ($LASTEXITCODE -ne 0) { Fail 'Gagal menghapus cluster' }

# 3. Bersihkan file lokal
Remove-Item -Force -ErrorAction SilentlyContinue $env:KUBECONFIG, (Join-Path $ScriptDir ".kubeconfig-$ClusterName.b64")

Info 'SELESAI. Cek sisa resource yang mungkin masih ditagih:'
civo volume ls --region $Region
civo loadbalancer ls --region $Region
civo firewall ls --region $Region

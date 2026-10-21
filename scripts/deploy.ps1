# Deploy 1-klik: buat cluster Civo (region Jakarta, 1 node medium) lalu jalankan aplikasi Nasi Uduk.
# Pemakaian: klik dua kali scripts\deploy.cmd, atau jalankan: powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1
# Konfigurasi bisa lewat environment variable atau file scripts\.deploy.env (dibuat otomatis saat pertama kali).
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$RootDir = Split-Path $ScriptDir -Parent
$EnvFile = Join-Path $ScriptDir '.deploy.env'

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Invoke-Native { # jalankan perintah eksternal dan berhenti kalau gagal
    & $args[0] @($args | Select-Object -Skip 1)
    if ($LASTEXITCODE -ne 0) { Fail "Perintah gagal: $($args -join ' ')" }
}
function Test-Native { # true kalau perintah berhasil; output dibuang (aman di Windows PowerShell 5.1)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $args[0] @($args | Select-Object -Skip 1) *> $null } catch {}
    $ok = ($LASTEXITCODE -eq 0); $ErrorActionPreference = $old
    return $ok
}
function Get-Setting($name, $default = '') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($null -ne $value) { return $value }
    if ($Settings.ContainsKey($name)) { return $Settings[$name] }
    return $default
}
function Save-Setting($name, $value) { # simpan nilai supaya run berikutnya tidak perlu input lagi
    $Settings[$name] = $value
    $Settings.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Set-Content -Path $EnvFile -Encoding ascii
}
function Read-Secret($prompt) {
    $secure = Read-Host $prompt -AsSecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
function Apply-Yaml($yaml) {
    $yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { Fail 'kubectl apply gagal' }
}

$Settings = [ordered]@{}
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | Where-Object { $_ -match '^([A-Z_][A-Z0-9_]*)=(.*)$' } | ForEach-Object { $Settings[$Matches[1]] = $Matches[2] }
}

$ClusterName = Get-Setting 'CLUSTER_NAME' 'nasduk'
$NodeSize = Get-Setting 'NODE_SIZE' 'g4s.kube.medium'
$NodeCount = Get-Setting 'NODE_COUNT' '1'
$Region = Get-Setting 'REGION'
$GithubRepo = Get-Setting 'GITHUB_REPO' 'dev-cer/apps-nasduk'
$env:KUBECONFIG = Join-Path $ScriptDir ".kubeconfig-$ClusterName"

# 1. Cek tool yang dibutuhkan
foreach ($tool in 'civo', 'kubectl') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "'$tool' belum terpasang. Lihat README bagian 'Deploy 1-klik'." }
}

# 2. API key Civo
$ApiKey = Get-Setting 'CIVO_API_KEY'
if (-not $ApiKey) {
    if (-not (Test-Native civo kubernetes ls)) {
        $ApiKey = Read-Secret 'Civo API key (Dashboard > Settings > Profile > Security)'
        if (-not $ApiKey) { Fail 'API key Civo wajib diisi' }
    }
}
if ($ApiKey) {
    Test-Native civo apikey save $ClusterName $ApiKey | Out-Null
    Invoke-Native civo apikey use $ClusterName
}

# 3. Region Jakarta (kode region dicari otomatis dari daftar region Civo)
if (-not $Region) {
    $regions = civo region ls -o json | ConvertFrom-Json
    $match = $regions | Where-Object { ($_.PSObject.Properties.Value -join ' ') -match '(?i)jakarta|indonesia|jkt' } | Select-Object -First 1
    if (-not $match) {
        civo region ls
        Fail 'Region Jakarta tidak ditemukan. Isi REGION=<kode> di scripts\.deploy.env lalu jalankan ulang.'
    }
    $Region = $match.PSObject.Properties.Value | Where-Object { "$_" -cmatch '^[A-Z]{2,}[0-9]+$' } | Select-Object -First 1
    if (-not $Region) { Fail 'Kode region Jakarta tidak terbaca. Isi REGION=<kode> di scripts\.deploy.env lalu jalankan ulang.' }
    Save-Setting 'REGION' $Region
}
Info "Region: $Region | Cluster: $ClusterName | Node: $NodeCount x $NodeSize"

# 4. Buat cluster (dilewati kalau sudah ada)
if (Test-Native civo kubernetes show $ClusterName --region $Region) {
    Info "Cluster '$ClusterName' sudah ada, dipakai ulang"
} else {
    Info 'Membuat cluster (biasanya 2-5 menit)...'
    Invoke-Native civo kubernetes create $ClusterName --region $Region --size $NodeSize --nodes $NodeCount --wait
}
civo kubernetes config $ClusterName --region $Region | Set-Content -Path $env:KUBECONFIG -Encoding ascii
if ($LASTEXITCODE -ne 0) { Fail 'Gagal mengambil kubeconfig' }
Invoke-Native kubectl wait --for=condition=Ready nodes --all --timeout=300s

# 5. Secret: akses image GHCR dan token admin
$GhcrUser = Get-Setting 'GHCR_USERNAME' $null
if ($null -eq $GhcrUser) {
    $GhcrUser = Read-Host 'Username GitHub untuk GHCR (kosongkan kalau image public)'
    Save-Setting 'GHCR_USERNAME' $GhcrUser
}
if ($GhcrUser) {
    $GhcrToken = Get-Setting 'GHCR_TOKEN'
    if (-not $GhcrToken) {
        $GhcrToken = Read-Secret 'GitHub token dengan scope read:packages'
        Save-Setting 'GHCR_TOKEN' $GhcrToken
    }
    Apply-Yaml (kubectl create secret docker-registry ghcr-secret --docker-server=ghcr.io `
        --docker-username=$GhcrUser --docker-password=$GhcrToken --dry-run=client -o yaml)
}
$AdminToken = Get-Setting 'ADMIN_TOKEN'
if (-not $AdminToken) {
    $AdminToken = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ })
    Save-Setting 'ADMIN_TOKEN' $AdminToken
}
Apply-Yaml (kubectl create secret generic order-admin --from-literal=ADMIN_TOKEN=$AdminToken --dry-run=client -o yaml)

# 6. Jalankan aplikasi
Info 'Deploy aplikasi...'
Invoke-Native kubectl apply -f (Join-Path $RootDir 'k8s')
Invoke-Native kubectl rollout restart deployment menu-service order-service frontend-service
foreach ($d in 'menu-service', 'order-service', 'frontend-service') {
    Invoke-Native kubectl rollout status "deployment/$d" --timeout=600s
}

# 7. Tunggu IP publik frontend
Info 'Menunggu IP publik...'
$Ip = ''
for ($i = 0; $i -lt 60 -and -not $Ip; $i++) {
    $Ip = kubectl get svc frontend-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
    if (-not $Ip) { Start-Sleep -Seconds 5 }
}
if (-not $Ip) { Fail "IP publik belum muncul. Cek dengan: kubectl --kubeconfig $env:KUBECONFIG get svc frontend-service" }

# 8. Perbarui kubeconfig untuk GitHub Actions (supaya push ke main deploy ke cluster baru)
$KubeB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($env:KUBECONFIG))
$ghReady = $false
if (Get-Command gh -ErrorAction SilentlyContinue) { $ghReady = Test-Native gh auth status }
if ($ghReady) {
    $KubeB64 | gh secret set CIVO_KUBECONFIG -R $GithubRepo
    if ($LASTEXITCODE -eq 0) { Info 'Secret CIVO_KUBECONFIG di GitHub sudah diperbarui' }
} else {
    $B64File = Join-Path $ScriptDir ".kubeconfig-$ClusterName.b64"
    Set-Content -Path $B64File -Value $KubeB64 -Encoding ascii -NoNewline
    Info "GitHub CLI (gh) tidak tersedia/login: salin isi $B64File ke secret CIVO_KUBECONFIG di GitHub"
}

Write-Host ''
Info 'SELESAI!'
Write-Host "   Aplikasi     : http://$Ip"
Write-Host "   Halaman admin: http://$Ip/admin.html"
Write-Host "   Token admin  : $AdminToken"
Write-Host "   Kubeconfig   : $env:KUBECONFIG"

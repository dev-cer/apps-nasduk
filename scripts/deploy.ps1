# Deploy 1-klik: buat cluster Civo (region Jakarta, 1 node medium) lalu jalankan aplikasi Nasi Uduk.
# Pemakaian: klik dua kali scripts\deploy.cmd, atau jalankan: powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1
# Konfigurasi bisa lewat environment variable atau file scripts\.deploy.env (dibuat otomatis saat pertama kali).
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 belum tentu memakai TLS 1.2 (dibutuhkan ghcr.io)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

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
function Get-NativeOutput { # stdout perintah eksternal, stderr dibuang; $null kalau gagal
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $args[0] @($args | Select-Object -Skip 1) 2> $null } catch { $out = $null }
    $ok = ($LASTEXITCODE -eq 0); $ErrorActionPreference = $old
    if ($ok) { return $out } else { return $null }
}
function Get-Setting($name, $default = '') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($null -ne $value) { return $value }
    if ($Settings.Contains($name)) { return $Settings[$name] }
    return $default
}
function Save-Setting($name, $value) { # simpan nilai supaya run berikutnya tidak perlu input lagi
    $Settings[$name] = $value
    $Settings.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Set-Content -Path $EnvFile -Encoding ascii
}
function Remove-Setting { # hapus nilai yang tersimpan, mis. kredensial yang ditolak
    foreach ($name in $args) { $Settings.Remove($name) }
    $Settings.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } | Set-Content -Path $EnvFile -Encoding ascii
}
function Test-GhcrAccess($user, $token) { # true kalau manifest semua image bisa dibaca (user kosong = anonim)
    $headers = @{}
    if ($user) { $headers.Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${user}:${token}")) }
    $accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json'
    foreach ($img in $Images) {
        try {
            $res = Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "https://ghcr.io/token?scope=repository:$ImageOwner/${img}:pull&service=ghcr.io"
            $bearer = ($res.Content | ConvertFrom-Json).token
            $res = Invoke-WebRequest -UseBasicParsing -Method Head -Headers @{ Authorization = "Bearer $bearer"; Accept = $accept } -Uri "https://ghcr.io/v2/$ImageOwner/$img/manifests/latest"
            if ($res.StatusCode -ne 200) { return $false }
        } catch { return $false }
    }
    return $true
}
function Read-Secret($prompt) {
    $secure = Read-Host $prompt -AsSecureString
    return (New-Object System.Net.NetworkCredential('', $secure)).Password
}
function Apply-Yaml($yaml) {
    $yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { Fail 'kubectl apply gagal' }
}

$Settings = [ordered]@{}
if (Test-Path $EnvFile) {
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match '^([A-Z_][A-Z0-9_]*)=(.*)$') { $Settings[$Matches[1]] = $Matches[2] }
    }
}

$ClusterName = Get-Setting 'CLUSTER_NAME' 'nasduk'
$NodeSize = Get-Setting 'NODE_SIZE' 'g4s.kube.medium'
$NodeCount = Get-Setting 'NODE_COUNT' '1'
$Region = Get-Setting 'REGION' 'JKT1'  # Civo region Jakarta, Indonesia
$GithubRepo = Get-Setting 'GITHUB_REPO' 'dev-cer/apps-nasduk'
$ImageOwner = $GithubRepo.Split('/')[0]
$Images = 'apps-nasduk', 'apps-nasduk-order', 'apps-nasduk-frontend'
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

# 3. Akses image GHCR (dicek sebelum membuat cluster supaya tidak buang waktu & biaya)
$GhcrUser = Get-Setting 'GHCR_USERNAME'
$GhcrToken = Get-Setting 'GHCR_TOKEN'
Info "Mengecek akses image di ghcr.io/$ImageOwner ..."
if (Test-GhcrAccess '' '') {
    # Image public: tidak perlu kredensial. Kredensial yang salah justru membuat GHCR menolak pull (403).
    if ($GhcrUser) {
        Info 'Image GHCR public, kredensial GHCR tidak dipakai'
        Remove-Setting 'GHCR_USERNAME' 'GHCR_TOKEN'
    }
    $GhcrUser = ''; $GhcrToken = ''
} else {
    $GhcrSource = ''
    if ($GhcrUser) {
        $GhcrSource = 'config'
    } elseif ((Get-Command gh -ErrorAction SilentlyContinue) -and (Test-Native gh auth status)) {
        $GhcrUser = Get-NativeOutput gh api user -q .login
        $GhcrToken = Get-NativeOutput gh auth token
        $GhcrSource = 'gh'
    } else {
        Write-Host "Image di ghcr.io/$ImageOwner private, butuh token untuk menariknya."
        $GhcrUser = Read-Host 'Username GitHub'
        $GhcrToken = Read-Secret 'GitHub token CLASSIC dengan scope read:packages'
        $GhcrSource = 'prompt'
    }
    if (-not $GhcrUser -or -not (Test-GhcrAccess $GhcrUser $GhcrToken)) {
        Write-Host "ERROR: GHCR menolak akses untuk user '$GhcrUser' (sumber: $GhcrSource)." -ForegroundColor Red
        Write-Host '   Pilih salah satu:'
        Write-Host "   a) Jadikan 3 package GHCR public: GitHub > $ImageOwner > Packages > (package) > Package settings > Change visibility"
        Write-Host '   b) Pakai token CLASSIC (ghp_...) dengan scope read:packages. Token fine-grained (github_pat_...) tidak didukung GHCR.'
        Write-Host '   c) Beri izin packages ke GitHub CLI: gh auth refresh -h github.com -s read:packages'
        if ($GhcrSource -eq 'config') {
            Remove-Setting 'GHCR_USERNAME' 'GHCR_TOKEN'
            Write-Host '   Kredensial GHCR yang tersimpan sudah dihapus; jalankan ulang script untuk memasukkan yang baru.'
        }
        exit 1
    }
    if ($GhcrSource -eq 'prompt') {
        Save-Setting 'GHCR_USERNAME' $GhcrUser
        Save-Setting 'GHCR_TOKEN' $GhcrToken
    }
}
Info "Akses GHCR OK ($(if ($GhcrUser) { $GhcrUser } else { 'public, tanpa kredensial' }))"

# 4. Region
Info "Region: $Region | Cluster: $ClusterName | Node: $NodeCount x $NodeSize"

# 5. Buat cluster (dilewati kalau sudah ada)
if (Test-Native civo kubernetes show $ClusterName --region $Region) {
    Info "Cluster '$ClusterName' sudah ada, dipakai ulang"
} else {
    Info 'Membuat cluster (biasanya 2-5 menit)...'
    Invoke-Native civo kubernetes create $ClusterName --region $Region --size $NodeSize --nodes $NodeCount --wait
}
civo kubernetes config $ClusterName --region $Region | Set-Content -Path $env:KUBECONFIG -Encoding ascii
if ($LASTEXITCODE -ne 0) { Fail 'Gagal mengambil kubeconfig' }
Invoke-Native kubectl wait --for=condition=Ready nodes --all --timeout=300s

# 6. Secret: akses image GHCR dan token admin
if ($GhcrUser) {
    Apply-Yaml (kubectl create secret docker-registry ghcr-secret --docker-server=ghcr.io `
        --docker-username=$GhcrUser --docker-password=$GhcrToken --dry-run=client -o yaml)
} else {
    Test-Native kubectl delete secret ghcr-secret --ignore-not-found | Out-Null
}
$AdminToken = Get-Setting 'ADMIN_TOKEN'
if (-not $AdminToken) {
    $AdminToken = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ })
    Save-Setting 'ADMIN_TOKEN' $AdminToken
}
Apply-Yaml (kubectl create secret generic order-admin --from-literal=ADMIN_TOKEN=$AdminToken --dry-run=client -o yaml)

# 7. Jalankan aplikasi
Info 'Deploy aplikasi...'
$Existing = kubectl get deployment -o name
Invoke-Native kubectl apply -f (Join-Path $RootDir 'k8s')
# Restart hanya kalau aplikasi sudah pernah jalan (untuk menarik image :latest terbaru)
if ($Existing) { Invoke-Native kubectl rollout restart deployment menu-service order-service frontend-service }
foreach ($d in 'menu-service', 'order-service', 'frontend-service') {
    kubectl rollout status "deployment/$d" --timeout=600s
    if ($LASTEXITCODE -ne 0) {
        kubectl get pods -o wide
        kubectl get events --sort-by=.lastTimestamp | Select-Object -Last 15
        Fail "Deployment $d belum siap. Lihat status pod dan event di atas."
    }
}

# 8. Tunggu IP publik frontend
Info 'Menunggu IP publik...'
$Ip = ''
for ($i = 0; $i -lt 60 -and -not $Ip; $i++) {
    $Ip = kubectl get svc frontend-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
    if (-not $Ip) { Start-Sleep -Seconds 5 }
}
if (-not $Ip) { Fail "IP publik belum muncul. Cek dengan: kubectl --kubeconfig $env:KUBECONFIG get svc frontend-service" }

# 9. Perbarui kubeconfig untuk GitHub Actions (supaya push ke main deploy ke cluster baru)
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

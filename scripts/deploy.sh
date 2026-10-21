#!/usr/bin/env bash
# Deploy 1-klik: buat cluster Civo (region Jakarta, 1 node medium) lalu jalankan aplikasi Nasi Uduk.
# Pemakaian: ./scripts/deploy.sh
# Konfigurasi bisa lewat environment variable atau file scripts/.deploy.env (dibuat otomatis saat pertama kali).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$SCRIPT_DIR/.deploy.env"
load_env() { # baca scripts/.deploy.env (KEY=VALUE); environment variable tetap diutamakan
    [ -f "$ENV_FILE" ] || return 0
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [ -n "${!key+x}" ] || declare -g "$key=$value"
    done < "$ENV_FILE"
}
load_env

CLUSTER_NAME="${CLUSTER_NAME:-nasduk}"
NODE_SIZE="${NODE_SIZE:-g4s.kube.medium}"
NODE_COUNT="${NODE_COUNT:-1}"
REGION="${REGION:-JKT1}"  # Civo region Jakarta, Indonesia
GITHUB_REPO="${GITHUB_REPO:-dev-cer/apps-nasduk}"
IMAGE_OWNER="${GITHUB_REPO%%/*}"
IMAGES="apps-nasduk apps-nasduk-order apps-nasduk-frontend"
DNS_ZONE="${DNS_ZONE-arupa.id}"   # domain yang dikelola di DNS Civo; kosongkan untuk HTTP saja (tanpa domain)
SUBDOMAIN="${SUBDOMAIN:-nasduk}"
DOMAIN=""
[ -n "$DNS_ZONE" ] && DOMAIN="$SUBDOMAIN.$DNS_ZONE"
DEPLOYMENTS="menu-service order-service frontend-service caddy"
export KUBECONFIG="$SCRIPT_DIR/.kubeconfig-$CLUSTER_NAME"

info() { printf '\033[1;33m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
save_env() { # simpan nilai supaya run berikutnya tidak perlu input lagi
    touch "$ENV_FILE"
    grep -v "^$1=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
    printf "%s=%s\n" "$1" "$2" >> "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}
remove_env() { # hapus nilai yang tersimpan, mis. kredensial yang ditolak
    [ -f "$ENV_FILE" ] || return 0
    grep -vE "^($(IFS='|'; echo "$*"))=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
    mv "$ENV_FILE.tmp" "$ENV_FILE" && chmod 600 "$ENV_FILE"
}

# 1. Cek tool yang dibutuhkan
for tool in civo kubectl curl; do
    command -v "$tool" >/dev/null || fail "'$tool' belum terpasang. Lihat README bagian 'Deploy 1-klik'."
done

# 2. API key Civo
if [ -n "${CIVO_API_KEY:-}" ]; then
    civo apikey save "$CLUSTER_NAME" "$CIVO_API_KEY" >/dev/null 2>&1 || true
    civo apikey use "$CLUSTER_NAME" >/dev/null
elif ! civo kubernetes ls >/dev/null 2>&1; then
    read -rsp "Civo API key (Dashboard > Settings > Profile > Security): " CIVO_API_KEY; echo
    [ -n "$CIVO_API_KEY" ] || fail "API key Civo wajib diisi"
    civo apikey save "$CLUSTER_NAME" "$CIVO_API_KEY" >/dev/null
    civo apikey use "$CLUSTER_NAME" >/dev/null
fi

# 3. Akses image GHCR (dicek sebelum membuat cluster supaya tidak buang waktu & biaya)
ghcr_ok() { # $1=username $2=token (kosong = anonim); true kalau manifest semua image bisa dibaca
    local img token auth=()
    [ -n "$1" ] && auth=(-u "$1:$2")
    for img in $IMAGES; do
        token="$(curl -sf ${auth[@]+"${auth[@]}"} "https://ghcr.io/token?scope=repository:$IMAGE_OWNER/$img:pull&service=ghcr.io" \
            | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')" || return 1
        [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
            "https://ghcr.io/v2/$IMAGE_OWNER/$img/manifests/latest")" = "200" ] || return 1
    done
}
info "Mengecek akses image di ghcr.io/$IMAGE_OWNER ..."
if ghcr_ok "" ""; then
    # Image public: tidak perlu kredensial. Kredensial yang salah justru membuat GHCR menolak pull (403).
    if [ -n "${GHCR_USERNAME:-}" ]; then
        info "Image GHCR public, kredensial GHCR tidak dipakai"
        remove_env GHCR_USERNAME GHCR_TOKEN
    fi
    GHCR_USERNAME="" GHCR_TOKEN=""
else
    GHCR_SOURCE=""
    if [ -n "${GHCR_USERNAME:-}" ]; then
        GHCR_SOURCE="config"
    elif command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
        GHCR_USERNAME="$(gh api user -q .login 2>/dev/null || true)"
        GHCR_TOKEN="$(gh auth token 2>/dev/null || true)"
        GHCR_SOURCE="gh"
    else
        echo "Image di ghcr.io/$IMAGE_OWNER private, butuh token untuk menariknya."
        read -rp "Username GitHub: " GHCR_USERNAME
        read -rsp "GitHub token CLASSIC dengan scope read:packages: " GHCR_TOKEN; echo
        GHCR_SOURCE="prompt"
    fi
    if [ -z "$GHCR_USERNAME" ] || ! ghcr_ok "$GHCR_USERNAME" "${GHCR_TOKEN:-}"; then
        printf '\033[1;31mERROR: GHCR menolak akses untuk user "%s" (sumber: %s).\033[0m\n' "$GHCR_USERNAME" "$GHCR_SOURCE" >&2
        echo "   Pilih salah satu:"
        echo "   a) Jadikan 3 package GHCR public: GitHub > $IMAGE_OWNER > Packages > (package) > Package settings > Change visibility"
        echo "   b) Pakai token CLASSIC (ghp_...) dengan scope read:packages. Token fine-grained (github_pat_...) tidak didukung GHCR."
        echo "   c) Beri izin packages ke GitHub CLI: gh auth refresh -h github.com -s read:packages"
        if [ "$GHCR_SOURCE" = "config" ]; then
            remove_env GHCR_USERNAME GHCR_TOKEN
            echo "   Kredensial GHCR yang tersimpan sudah dihapus; jalankan ulang script untuk memasukkan yang baru."
        fi
        exit 1
    fi
    if [ "$GHCR_SOURCE" = "prompt" ]; then
        save_env GHCR_USERNAME "$GHCR_USERNAME"
        save_env GHCR_TOKEN "$GHCR_TOKEN"
    fi
fi
info "Akses GHCR OK (${GHCR_USERNAME:-public, tanpa kredensial})"

# 4. Region
info "Region: $REGION | Cluster: $CLUSTER_NAME | Node: $NODE_COUNT x $NODE_SIZE"

# 5. Buat cluster (dilewati kalau sudah ada)
if civo kubernetes show "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
    info "Cluster '$CLUSTER_NAME' sudah ada, dipakai ulang"
else
    info "Membuat cluster (biasanya 2-5 menit)..."
    civo kubernetes create "$CLUSTER_NAME" --region "$REGION" --size "$NODE_SIZE" --nodes "$NODE_COUNT" --wait
fi
civo kubernetes config "$CLUSTER_NAME" --region "$REGION" > "$KUBECONFIG"
chmod 600 "$KUBECONFIG"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# 6. Secret: akses image GHCR dan token admin
if [ -n "$GHCR_USERNAME" ]; then
    kubectl create secret docker-registry ghcr-secret --docker-server=ghcr.io \
        --docker-username="$GHCR_USERNAME" --docker-password="$GHCR_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    kubectl delete secret ghcr-secret --ignore-not-found
fi
if [ -z "${ADMIN_TOKEN:-}" ]; then
    ADMIN_TOKEN="$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')"
    save_env ADMIN_TOKEN "$ADMIN_TOKEN"
fi
kubectl create secret generic order-admin --from-literal=ADMIN_TOKEN="$ADMIN_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
# Domain untuk HTTPS (dibaca Caddy)
kubectl create configmap caddy-env --from-literal=DOMAIN="$DOMAIN" --dry-run=client -o yaml | kubectl apply -f -

# 7. Jalankan aplikasi
info "Deploy aplikasi..."
EXISTING="$(kubectl get deployment -o name 2>/dev/null || true)"
# Versi lama membuka frontend/menu langsung lewat LoadBalancer; sekarang publik hanya lewat caddy
for svc in frontend-service menu-service; do
    if [ "$(kubectl get svc "$svc" -o jsonpath='{.spec.type}' 2>/dev/null || true)" = "LoadBalancer" ]; then
        kubectl delete svc "$svc"
    fi
done
kubectl apply -f "$ROOT_DIR/k8s/"
# Restart hanya kalau aplikasi sudah pernah jalan (untuk menarik image :latest terbaru dan domain baru)
[ -n "$EXISTING" ] && kubectl rollout restart deployment $DEPLOYMENTS
for d in $DEPLOYMENTS; do
    if ! kubectl rollout status "deployment/$d" --timeout=600s; then
        kubectl get pods -o wide || true
        kubectl get events --sort-by=.lastTimestamp | tail -n 15 || true
        fail "Deployment $d belum siap. Lihat status pod dan event di atas."
    fi
done

# 8. Tunggu IP publik
info "Menunggu IP publik..."
IP=""
for _ in $(seq 1 60); do
    IP="$(kubectl get svc caddy -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -n "$IP" ] && break
    sleep 5
done
[ -n "$IP" ] || fail "IP publik belum muncul. Cek dengan: KUBECONFIG=$KUBECONFIG kubectl get svc caddy"

# 9. DNS + HTTPS: arahkan $DOMAIN ke IP load balancer (record A di DNS Civo)
URL="http://$IP"
if [ -n "$DOMAIN" ]; then
    info "Mengarahkan $DOMAIN ke $IP ..."
    # Daftar kosong: civo tidak mencetak apa pun dan tetap exit 0. Tipe record bisa huruf kecil ("a").
    if ! records="$(civo domain record ls "$DNS_ZONE" -o custom -f 'id|name|type|value' 2>"$ENV_FILE.err")"; then
        cat "$ENV_FILE.err" >&2; rm -f "$ENV_FILE.err"
        fail "Gagal membaca record DNS $DNS_ZONE dari Civo (lihat pesan di atas)"
    fi
    rm -f "$ENV_FILE.err"
    if ! printf '%s\n' "$records" | awk -F'|' -v n="$SUBDOMAIN" -v ip="$IP" '$2==n && toupper($3)=="A" && $4==ip {f=1} END {exit !f}'; then
        printf '%s\n' "$records" | awk -F'|' -v n="$SUBDOMAIN" '$2==n && (toupper($3)=="A" || toupper($3)=="CNAME") {print $1}' \
            | while read -r id; do civo domain record remove "$DNS_ZONE" "$id" -y >/dev/null; done
        civo domain record create "$DNS_ZONE" --name "$SUBDOMAIN" --type A --value "$IP" --ttl 600 >/dev/null
    fi
    info "Menunggu DNS dan sertifikat HTTPS (biasanya 1-5 menit)..."
    for _ in $(seq 1 60); do
        if curl -sf -o /dev/null -m 10 "https://$DOMAIN/"; then URL="https://$DOMAIN"; break; fi
        sleep 10
    done
    if [ "$URL" != "https://$DOMAIN" ]; then
        info "HTTPS untuk $DOMAIN belum aktif. Caddy akan terus mencoba otomatis; cek lagi beberapa menit lagi."
        echo "   Kalau tetap tidak bisa: pastikan nameserver $DNS_ZONE di registrar adalah ns0.civo.com dan ns1.civo.com,"
        echo "   lalu lihat log: kubectl --kubeconfig $KUBECONFIG logs deploy/caddy"
        URL="https://$DOMAIN"
    fi
fi

# 10. Perbarui kubeconfig untuk GitHub Actions (supaya push ke main deploy ke cluster baru)
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    base64 < "$KUBECONFIG" | tr -d '\n' | gh secret set CIVO_KUBECONFIG -R "$GITHUB_REPO" \
        && info "Secret CIVO_KUBECONFIG di GitHub sudah diperbarui"
else
    info "GitHub CLI (gh) tidak tersedia/login: perbarui secret CIVO_KUBECONFIG secara manual dengan isi:"
    echo "   base64 < $KUBECONFIG | tr -d '\\n'"
fi

echo
info "SELESAI!"
echo "   Aplikasi     : $URL"
echo "   Halaman admin: $URL/admin.html"
echo "   IP publik    : $IP"
echo "   Token admin  : $ADMIN_TOKEN"
echo "   Kubeconfig   : $KUBECONFIG"

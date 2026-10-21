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

# 7. Jalankan aplikasi
info "Deploy aplikasi..."
EXISTING="$(kubectl get deployment -o name 2>/dev/null || true)"
kubectl apply -f "$ROOT_DIR/k8s/"
# Restart hanya kalau aplikasi sudah pernah jalan (untuk menarik image :latest terbaru)
[ -n "$EXISTING" ] && kubectl rollout restart deployment menu-service order-service frontend-service
for d in menu-service order-service frontend-service; do
    if ! kubectl rollout status "deployment/$d" --timeout=600s; then
        kubectl get pods -o wide || true
        kubectl get events --sort-by=.lastTimestamp | tail -n 15 || true
        fail "Deployment $d belum siap. Lihat status pod dan event di atas."
    fi
done

# 8. Tunggu IP publik frontend
info "Menunggu IP publik..."
IP=""
for _ in $(seq 1 60); do
    IP="$(kubectl get svc frontend-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -n "$IP" ] && break
    sleep 5
done
[ -n "$IP" ] || fail "IP publik belum muncul. Cek dengan: KUBECONFIG=$KUBECONFIG kubectl get svc frontend-service"

# 9. Perbarui kubeconfig untuk GitHub Actions (supaya push ke main deploy ke cluster baru)
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    base64 < "$KUBECONFIG" | tr -d '\n' | gh secret set CIVO_KUBECONFIG -R "$GITHUB_REPO" \
        && info "Secret CIVO_KUBECONFIG di GitHub sudah diperbarui"
else
    info "GitHub CLI (gh) tidak tersedia/login: perbarui secret CIVO_KUBECONFIG secara manual dengan isi:"
    echo "   base64 < $KUBECONFIG | tr -d '\\n'"
fi

echo
info "SELESAI!"
echo "   Aplikasi     : http://$IP"
echo "   Halaman admin: http://$IP/admin.html"
echo "   Token admin  : $ADMIN_TOKEN"
echo "   Kubeconfig   : $KUBECONFIG"

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
REGION="${REGION:-}"
GITHUB_REPO="${GITHUB_REPO:-dev-cer/apps-nasduk}"
export KUBECONFIG="$SCRIPT_DIR/.kubeconfig-$CLUSTER_NAME"

info() { printf '\033[1;33m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
save_env() { # simpan nilai supaya run berikutnya tidak perlu input lagi
    touch "$ENV_FILE"
    grep -v "^$1=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
    printf "%s=%s\n" "$1" "$2" >> "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

# 1. Cek tool yang dibutuhkan
for tool in civo kubectl; do
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

# 3. Region Jakarta (kode region dicari otomatis dari daftar region Civo)
if [ -z "$REGION" ]; then
    REGION="$(civo region ls 2>/dev/null | grep -iE 'jakarta|indonesia|jkt' | grep -oE '\b[A-Z]{2,}[0-9]+\b' | head -n1 || true)"
    if [ -z "$REGION" ]; then
        civo region ls || true
        fail "Region Jakarta tidak ditemukan. Jalankan ulang dengan REGION=<kode> ./scripts/deploy.sh"
    fi
    save_env REGION "$REGION"
fi
info "Region: $REGION | Cluster: $CLUSTER_NAME | Node: $NODE_COUNT x $NODE_SIZE"

# 4. Buat cluster (dilewati kalau sudah ada)
if civo kubernetes show "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
    info "Cluster '$CLUSTER_NAME' sudah ada, dipakai ulang"
else
    info "Membuat cluster (biasanya 2-5 menit)..."
    civo kubernetes create "$CLUSTER_NAME" --region "$REGION" --size "$NODE_SIZE" --nodes "$NODE_COUNT" --wait
fi
civo kubernetes config "$CLUSTER_NAME" --region "$REGION" > "$KUBECONFIG"
chmod 600 "$KUBECONFIG"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# 5. Secret: akses image GHCR dan token admin
if [ -z "${GHCR_USERNAME+x}" ]; then
    read -rp "Username GitHub untuk GHCR (kosongkan kalau image public): " GHCR_USERNAME
    save_env GHCR_USERNAME "$GHCR_USERNAME"
fi
if [ -n "$GHCR_USERNAME" ]; then
    if [ -z "${GHCR_TOKEN:-}" ]; then
        read -rsp "GitHub token dengan scope read:packages: " GHCR_TOKEN; echo
        save_env GHCR_TOKEN "$GHCR_TOKEN"
    fi
    kubectl create secret docker-registry ghcr-secret --docker-server=ghcr.io \
        --docker-username="$GHCR_USERNAME" --docker-password="$GHCR_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
fi
if [ -z "${ADMIN_TOKEN:-}" ]; then
    ADMIN_TOKEN="$(od -An -N10 -tx1 /dev/urandom | tr -d ' \n')"
    save_env ADMIN_TOKEN "$ADMIN_TOKEN"
fi
kubectl create secret generic order-admin --from-literal=ADMIN_TOKEN="$ADMIN_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

# 6. Jalankan aplikasi
info "Deploy aplikasi..."
kubectl apply -f "$ROOT_DIR/k8s/"
kubectl rollout restart deployment menu-service order-service frontend-service
for d in menu-service order-service frontend-service; do
    kubectl rollout status "deployment/$d" --timeout=600s
done

# 7. Tunggu IP publik frontend
info "Menunggu IP publik..."
IP=""
for _ in $(seq 1 60); do
    IP="$(kubectl get svc frontend-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -n "$IP" ] && break
    sleep 5
done
[ -n "$IP" ] || fail "IP publik belum muncul. Cek dengan: KUBECONFIG=$KUBECONFIG kubectl get svc frontend-service"

# 8. Perbarui kubeconfig untuk GitHub Actions (supaya push ke main deploy ke cluster baru)
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

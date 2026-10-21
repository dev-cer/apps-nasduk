#!/usr/bin/env bash
# Destroy 1-klik: hapus aplikasi, load balancer, volume, dan cluster Civo.
# Pemakaian: ./scripts/destroy.sh        (minta konfirmasi)
#            ./scripts/destroy.sh -y     (tanpa konfirmasi)
# PERHATIAN: semua data pesanan ikut terhapus. Unduh Excel dari /admin.html dulu kalau masih perlu.
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
REGION="${REGION:-JKT1}"  # Civo region Jakarta, Indonesia
DNS_ZONE="${DNS_ZONE-arupa.id}"
SUBDOMAIN="${SUBDOMAIN:-nasduk}"
export KUBECONFIG="$SCRIPT_DIR/.kubeconfig-$CLUSTER_NAME"

info() { printf '\033[1;33m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v civo >/dev/null || fail "'civo' belum terpasang"
civo kubernetes show "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1 \
    || fail "Cluster '$CLUSTER_NAME' tidak ditemukan di region $REGION"

if [ "${1:-}" != "-y" ]; then
    echo "Cluster '$CLUSTER_NAME' ($REGION) beserta SEMUA data pesanan akan dihapus permanen."
    read -rp "Ketik nama cluster untuk melanjutkan: " answer
    [ "$answer" = "$CLUSTER_NAME" ] || fail "Dibatalkan"
fi

# 1. Hapus aplikasi dulu supaya load balancer dan volume ikut terhapus (tidak ditagih terus)
if command -v kubectl >/dev/null; then
    civo kubernetes config "$CLUSTER_NAME" --region "$REGION" > "$KUBECONFIG" 2>/dev/null || true
    info "Menghapus aplikasi, load balancer, dan volume..."
    kubectl delete -f "$ROOT_DIR/k8s/" --ignore-not-found --wait=true --timeout=300s || true
fi

# 2. Hapus record DNS supaya subdomain tidak menunjuk ke IP yang nanti dipakai orang lain
if [ -n "$DNS_ZONE" ]; then
    civo domain record ls "$DNS_ZONE" -o custom -f 'id|name|type|value' 2>/dev/null \
        | awk -F'|' -v n="$SUBDOMAIN" '$2==n && ($3=="A" || $3=="CNAME") {print $1}' \
        | while read -r id; do
            civo domain record remove "$DNS_ZONE" "$id" -y >/dev/null && info "Record DNS $SUBDOMAIN.$DNS_ZONE dihapus"
        done || true
fi

# 3. Hapus cluster
info "Menghapus cluster '$CLUSTER_NAME'..."
civo kubernetes remove "$CLUSTER_NAME" --region "$REGION" -y

# 4. Bersihkan file lokal
rm -f "$KUBECONFIG"

info "SELESAI. Cek sisa resource yang mungkin masih ditagih:"
civo volume ls --region "$REGION" || true
civo loadbalancer ls --region "$REGION" || true
civo firewall ls --region "$REGION" || true

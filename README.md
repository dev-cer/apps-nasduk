# Nasi Uduk Mpo Rohaya

Aplikasi pemesanan nasi uduk: **frontend** (nginx), **menu-service** dan **order-service** (FastAPI), berjalan di Kubernetes Civo.

## Deploy 1-klik

Script di folder `scripts/` membuat cluster Civo (**region Jakarta, 1 node `g4s.kube.medium`**), lalu menjalankan seluruh aplikasi. Script destroy menghapus semuanya lagi.

| | Linux | Windows |
|---|---|---|
| Deploy | `./scripts/deploy.sh` | klik dua kali `scripts\deploy.cmd` |
| Destroy | `./scripts/destroy.sh` | klik dua kali `scripts\destroy.cmd` |

### Persiapan (sekali saja)

1. **Pasang tool:**
   - Linux: `curl -sL https://civo.com/get | sh` (Civo CLI) dan [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/). Butuh bash 4.2+.
   - Windows: Civo CLI dari [github.com/civo/cli/releases](https://github.com/civo/cli/releases) (atau `choco install civo-cli`), dan kubectl lewat `winget install -e --id Kubernetes.kubectl`.
   - Opsional: [GitHub CLI](https://cli.github.com/) (`gh auth login`), supaya secret `CIVO_KUBECONFIG` di GitHub otomatis diperbarui ke cluster baru.
2. **Siapkan:**
   - **Civo API key**: Dashboard Civo > Settings > Profile > Security.
   - **GitHub token** dengan scope `read:packages`, untuk menarik image dari GHCR. Kosongkan username kalau package GHCR dibuat public.

### Yang terjadi saat deploy

1. Run pertama menanyakan API key Civo, username GitHub, dan token GHCR. Jawabannya disimpan di `scripts/.deploy.env` (tidak ikut ke git), jadi run berikutnya langsung jalan tanpa pertanyaan.
2. Kode region Jakarta dicari otomatis dari `civo region ls`. Kalau tidak ketemu, isi `REGION=<kode>` di `scripts/.deploy.env`.
3. Cluster `nasduk` dibuat (2–5 menit). Kalau sudah ada, cluster dipakai ulang.
4. Secret `ghcr-secret` dan `order-admin` dibuat. Token admin dibuat acak sekali, lalu disimpan.
5. `k8s/` di-apply, lalu script menunggu sampai semua pod jalan dan IP publik muncul.
6. Script menampilkan URL aplikasi, URL halaman admin, dan token admin.

Pengaturan bisa diubah lewat environment variable atau `scripts/.deploy.env`: `CLUSTER_NAME` (default `nasduk`), `REGION`, `NODE_SIZE` (default `g4s.kube.medium`), `NODE_COUNT` (default `1`), `CIVO_API_KEY`, `GHCR_USERNAME`, `GHCR_TOKEN`, `ADMIN_TOKEN`, `GITHUB_REPO`.

### Destroy

Destroy menghapus aplikasi (termasuk load balancer dan volume, supaya tidak terus ditagih), lalu menghapus cluster. Untuk mencegah salah klik, script meminta Anda mengetik nama cluster. Tambahkan `-y` (Linux) atau `-Yes` (PowerShell) untuk melewati konfirmasi.

> **Semua data pesanan ikut terhapus.** Unduh Excel dari `/admin.html` dulu kalau masih perlu.

Setelah selesai, script menampilkan daftar volume, load balancer, dan firewall yang tersisa, supaya bisa dicek tidak ada yang masih ditagih.

## CI/CD

Setiap push ke `main` membangun image ke GHCR dan men-deploy ke cluster yang ada di secret `CIVO_KUBECONFIG` (`.github/workflows/deploy.yml`). Setelah cluster dibuat ulang, secret itu harus diperbarui. `deploy.sh`/`deploy.ps1` melakukannya otomatis kalau `gh` terpasang dan sudah login.

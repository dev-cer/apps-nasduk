# Nasi Uduk Mpo Rohaya

Aplikasi pemesanan nasi uduk: **frontend** (nginx), **menu-service** dan **order-service** (FastAPI), berjalan di Kubernetes Civo. Akses publik hanya lewat **Caddy** (HTTPS otomatis dengan Let's Encrypt) di **https://nasduk.apps.arupa.id**.

## Deploy 1-klik

Script di folder `scripts/` membuat cluster Civo (**region Jakarta `JKT1`, 1 node `g4s.kube.medium`**), lalu menjalankan seluruh aplikasi. Script destroy menghapus semuanya lagi.

| | Linux | Windows |
|---|---|---|
| Deploy | `./scripts/deploy.sh` | klik dua kali `scripts\deploy.cmd` |
| Destroy | `./scripts/destroy.sh` | klik dua kali `scripts\destroy.cmd` |

### Persiapan (sekali saja)

1. **Pasang tool:**
   - Linux: `curl -sL https://civo.com/get | sh` (Civo CLI) dan [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/). Butuh bash 4.2+.
   - Windows: Civo CLI dari [github.com/civo/cli/releases](https://github.com/civo/cli/releases) (atau `choco install civo-cli`), dan kubectl lewat `winget install -e --id Kubernetes.kubectl`.
   - Disarankan: [GitHub CLI](https://cli.github.com/) lalu `gh auth login`. Dengan ini secret `CIVO_KUBECONFIG` untuk GitHub Actions otomatis diisi setiap kali cluster dibuat ulang.
2. **Siapkan Civo API key**: Dashboard Civo > Settings > Profile > Security.

Image di GHCR (`apps-nasduk`, `apps-nasduk-order`, `apps-nasduk-frontend`) public, jadi tidak perlu token GitHub. Kalau suatu saat dijadikan private, script otomatis memakai login `gh` (perlu `gh auth refresh -h github.com -s read:packages`), atau menanyakan token **classic** dengan scope `read:packages`. Token fine-grained tidak didukung GHCR.

### Yang terjadi saat deploy

1. Run pertama menanyakan API key Civo, lalu menyimpannya. Pengaturan lain disimpan di `scripts/.deploy.env` (tidak ikut ke git), jadi run berikutnya langsung jalan tanpa pertanyaan.
2. Akses image GHCR dicek **sebelum** cluster dibuat. Kalau ditolak, script berhenti dengan penjelasan, dan kredensial yang salah dihapus dari `.deploy.env`.
3. Cluster `nasduk` dibuat (2–5 menit). Kalau sudah ada, cluster dipakai ulang.
4. Secret `order-admin` dibuat (dan `ghcr-secret` kalau image private). Token admin dibuat acak sekali, lalu disimpan.
5. `k8s/` di-apply, lalu script menunggu sampai semua pod jalan dan IP publik muncul. Kalau ada pod yang gagal, status pod dan event langsung ditampilkan.
6. Zona `apps.arupa.id` dibuat di DNS Civo kalau belum ada, lalu record `nasduk` diarahkan ke IP load balancer (dibuat atau diperbarui otomatis). Caddy lalu mengambil sertifikat Let's Encrypt, dan HTTP dialihkan ke HTTPS.
7. Script menampilkan URL aplikasi (`https://nasduk.apps.arupa.id`), URL halaman admin, dan token admin.

Pengaturan bisa diubah lewat environment variable atau `scripts/.deploy.env`: `CLUSTER_NAME` (default `nasduk`), `REGION` (default `JKT1`), `DNS_ZONE` (default `apps.arupa.id`; kosongkan untuk HTTP lewat IP saja), `SUBDOMAIN` (default `nasduk`), `NODE_SIZE` (default `g4s.kube.medium`), `NODE_COUNT` (default `1`), `CIVO_API_KEY`, `GHCR_USERNAME`, `GHCR_TOKEN`, `ADMIN_TOKEN`, `GITHUB_REPO`.

### HTTPS dan domain

- `arupa.id` tetap dikelola di nameserver-nya sendiri (`ns1/ns2.arupa.id`). Hanya subdomain `apps.arupa.id` yang **didelegasikan** ke DNS Civo, jadi record `arupa.id` lainnya (website, email) tidak tersentuh.
- **Sekali saja**, di panel DNS yang mengelola `arupa.id`, tambahkan 2 record NS:

  | Name | Type | Value |
  |---|---|---|
  | `apps` | NS | `ns0.civo.com` |
  | `apps` | NS | `ns1.civo.com` |

  Setelah itu, semua record di bawah `apps.arupa.id` diatur otomatis oleh script. Kalau delegasi belum aktif, script menampilkan peringatan. Kalau HTTPS tetap tidak aktif, lihat `kubectl logs deploy/caddy`.
- Sertifikat disimpan di volume `caddy-data` (1 GB), jadi tidak diminta ulang setiap restart. Perpanjangan berjalan otomatis.
- Hanya ada **1 load balancer** (Caddy). `frontend-service` dan `menu-service` sekarang `ClusterIP`, hanya bisa diakses dari dalam cluster.

### Destroy

Destroy menghapus aplikasi (termasuk load balancer dan volume, supaya tidak terus ditagih), record DNS `nasduk.apps.arupa.id`, lalu cluster. Untuk mencegah salah klik, script meminta Anda mengetik nama cluster. Tambahkan `-y` (Linux) atau `-Yes` (PowerShell) untuk melewati konfirmasi.

> **Semua data pesanan ikut terhapus.** Unduh Excel dari `/admin.html` dulu kalau masih perlu.

Setelah selesai, script menampilkan daftar volume, load balancer, dan firewall yang tersisa, supaya bisa dicek tidak ada yang masih ditagih.

## CI/CD

Setiap push ke `main` membangun image ke GHCR dan men-deploy ke cluster yang ada di secret `CIVO_KUBECONFIG` (`.github/workflows/deploy.yml`). Kalau secret itu kosong (misalnya cluster sudah di-destroy), langkah deploy dilewati dengan peringatan, dan image tetap di-build.

Setelah cluster dibuat ulang, secret itu harus diisi lagi. `deploy.sh`/`deploy.ps1` melakukannya otomatis kalau `gh` terpasang dan sudah login. Tanpa `gh`, isi manual di GitHub > Settings > Secrets and variables > Actions > `CIVO_KUBECONFIG`, dengan isi file `scripts/.kubeconfig-nasduk.b64` (Windows) atau hasil `base64 < scripts/.kubeconfig-nasduk | tr -d '\n'` (Linux).

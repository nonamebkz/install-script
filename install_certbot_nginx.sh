#!/usr/bin/env bash
set -e

echo "=== Install Certbot untuk Nginx (Ubuntu 24.x) ==="

if [ "$EUID" -ne 0 ]; then
  echo "Silakan jalankan: sudo $0"
  exit 1
fi

echo ">>> Step 1: Update package index"
apt update -y

echo ">>> Step 2: Install Certbot + plugin Nginx dari repo Ubuntu"
apt install -y certbot python3-certbot-nginx

echo ">>> Step 3: Cek versi Certbot"
certbot --version || {
  echo "Certbot tidak ditemukan di PATH, cek instalasi."
  exit 1
}

echo
echo "=== DONE: Certbot untuk Nginx terpasang ==="
echo "Contoh untuk generate & pasang SSL otomatis di Nginx:"
echo "  sudo certbot --nginx -d example.com -d www.example.com"
echo
echo "Setelah itu, Certbot akan:"
echo "- Minta email dan persetujuan TOS,"
echo "- Validasi domain,"
echo "- Edit config Nginx dan aktifkan HTTPS otomatis."
echo
echo "Auto-renew biasanya sudah di-setup lewat systemd timer."
echo "Anda bisa test renewal dengan:"
echo "  sudo certbot renew --dry-run"

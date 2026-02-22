#!/usr/bin/env bash
set -e

echo "=== Install Nginx on Ubuntu 24.04 ==="

if [ "$EUID" -ne 0 ]; then
  echo "Silakan jalankan: sudo $0"
  exit 1
fi

echo ">>> Step 1: Update package index"
apt update -y

echo ">>> Step 2: Install Nginx"
apt install -y nginx

echo ">>> Step 3: Enable & start Nginx service"
systemctl enable nginx
systemctl start nginx

echo ">>> Step 4: (Opsional) Konfigurasi firewall UFW jika terpasang"
if command -v ufw >/dev/null 2>&1; then
  echo "UFW terdeteksi, menambahkan rule 'Nginx Full' (HTTP + HTTPS)..."
  ufw allow 'Nginx Full' || true
  ufw status || true
else
  echo "UFW tidak terdeteksi, lewati pengaturan firewall."
fi

echo ">>> Step 5: Cek status Nginx"
systemctl status nginx --no-pager

echo
echo "=== DONE ==="
echo "Jika tidak ada error, coba akses:"
echo "  http://<IP-server-kamu>"
echo "atau di server lokal: curl http://localhost"

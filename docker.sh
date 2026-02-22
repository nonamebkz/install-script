#!/usr/bin/env bash
set -e

echo "=== Step 0: Pastikan dijalankan sebagai root atau pakai sudo ==="
if [ "$EUID" -ne 0 ]; then
  echo "Silakan jalankan: sudo $0"
  exit 1
fi

echo "=== Step 1: Hapus repo Docker yang salah (kalau ada) ==="
rm -f /etc/apt/sources.list.d/docker.sources
rm -f /etc/apt/sources.list.d/docker.list

echo "=== Step 2: Hapus instalasi Docker lama (opsional, aman untuk fresh install) ==="
apt-get remove -y docker docker-engine docker.io containerd runc docker-compose docker-compose-v2 podman-docker docker-doc || true

echo "=== Step 3: Update apt & install dependency ==="
apt-get update -y
apt-get install -y ca-certificates curl gnupg apt-transport-https software-properties-common

echo "=== Step 4: Setup Docker GPG key ==="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "=== Step 5: Tambah Docker repo (.list klasik) ==="
UBUNTU_CODENAME=$( . /etc/os-release && echo "$VERSION_CODENAME" )

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

echo "=== Step 6: apt update ==="
apt-get update -y

echo "=== Step 7: Install Docker Engine + plugin ==="
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "=== Step 8: Enable & start Docker service ==="
systemctl enable docker
systemctl start docker

echo "=== Step 9: Tambah user saat ini ke group docker (supaya bisa tanpa sudo) ==="
CURRENT_USER=${SUDO_USER:-$USER}
if id "$CURRENT_USER" &>/dev/null; then
  groupadd docker 2>/dev/null || true
  usermod -aG docker "$CURRENT_USER"
  echo "User '$CURRENT_USER' sudah ditambahkan ke group docker."
  echo "Silakan logout/login atau jalankan: newgrp docker"
else
  echo "User aktif tidak terdeteksi, lewati penambahan group docker."
fi

echo
echo "=== DONE ==="
echo "Cek dengan:"
echo "  docker run hello-world"

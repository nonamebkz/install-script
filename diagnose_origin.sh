#!/usr/bin/env bash
# Diagnosa error 522 Cloudflare + Certbot — jalankan di VPS sebagai root
set -euo pipefail

DOMAIN="${1:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "$DOMAIN" ]] || die "Usage: sudo $0 <domain>\nContoh: sudo $0 pencatatan.rubyjane.my.id"

echo "============================================"
echo "  Diagnosa Origin — ${DOMAIN}"
echo "============================================"
echo

# 1. IP publik server ini
echo ">>> [1] IP publik server ini"
PUBLIC_IP=""
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [[ -n "$PUBLIC_IP" ]]; then
  echo "    IP publik VPS: ${PUBLIC_IP}"
else
  echo "    Tidak bisa deteksi IP publik (cek koneksi internet)"
fi
echo

# 2. DNS
echo ">>> [2] DNS lookup"
if command -v dig >/dev/null 2>&1; then
  echo "    A record:"
  dig +short "$DOMAIN" A | sed 's/^/      /'
  echo "    AAAA record:"
  dig +short "$DOMAIN" AAAA | sed 's/^/      /' || true
  DNS_A="$(dig +short "$DOMAIN" A 2>/dev/null | head -n1)"
  if [[ -n "$DNS_A" && -n "$PUBLIC_IP" ]]; then
    if [[ "$DNS_A" == "$PUBLIC_IP" ]]; then
      echo "    [OK] DNS A = IP server (DNS only / grey cloud)"
    else
      echo "    [INFO] DNS A (${DNS_A}) ≠ IP VPS (${PUBLIC_IP})"
      echo "           Normal jika orange cloud (proxied Cloudflare)."
      echo "           Pastikan di Cloudflare, record A 'pencatatan' → ${PUBLIC_IP}"
    fi
  fi
else
  echo "    dig tidak terpasang — sudo apt install -y dnsutils"
fi
echo

# 3. Nginx
echo ">>> [3] Nginx service"
if systemctl is-active --quiet nginx; then
  echo "    [OK] Nginx aktif"
else
  echo "    [GAGAL] Nginx tidak aktif — sudo systemctl start nginx"
fi
echo

# 4. Port 80
echo ">>> [4] Port 80 listening"
if ss -tlnp 2>/dev/null | grep -q ':80 '; then
  ss -tlnp | grep ':80 ' | sed 's/^/    /'
  echo "    [OK] Port 80 listen"
else
  echo "    [GAGAL] Tidak ada proses di port 80"
fi
echo

# 5. Firewall
echo ">>> [5] Firewall (UFW)"
if command -v ufw >/dev/null 2>&1; then
  ufw status 2>/dev/null | sed 's/^/    /' || true
  if ufw status 2>/dev/null | grep -q "80.*ALLOW"; then
    echo "    [OK] Port 80 diizinkan"
  elif ufw status 2>/dev/null | grep -qi "inactive"; then
    echo "    [INFO] UFW inactive"
  else
    echo "    [PERINGATAN] Port 80 mungkin diblokir — sudo ufw allow 80/tcp"
  fi
else
  echo "    UFW tidak terpasang"
fi
echo

# 6. Nginx config untuk domain
echo ">>> [6] Nginx config untuk ${DOMAIN}"
FOUND=0
for f in /etc/nginx/sites-enabled/*; do
  [[ -f "$f" ]] || continue
  if grep -q "$DOMAIN" "$f" 2>/dev/null; then
    echo "    Ditemukan: $f"
    grep -E "server_name|proxy_pass|root " "$f" | sed 's/^/      /'
    FOUND=1
  fi
done
if [[ "$FOUND" -eq 0 ]]; then
  echo "    [GAGAL] Tidak ada config Nginx untuk ${DOMAIN}"
  echo "           Jalankan: sudo ./setup_nginx_domain.sh"
fi
echo

# 7. Test localhost
echo ">>> [7] Test Nginx di localhost"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H "Host: ${DOMAIN}" "http://127.0.0.1/" 2>/dev/null || echo "000")"
if [[ "$HTTP_CODE" =~ ^[23] ]]; then
  echo "    [OK] HTTP ${HTTP_CODE} — Nginx merespons Host: ${DOMAIN}"
else
  echo "    [GAGAL] HTTP ${HTTP_CODE} — Nginx tidak merespons dengan benar"
fi
echo

# 8. Test dari luar (via Cloudflare)
echo ">>> [8] Test dari internet (via Cloudflare)"
EXT_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${DOMAIN}/" 2>/dev/null || echo "000")"
if [[ "$EXT_CODE" == "522" ]]; then
  echo "    [GAGAL] HTTP 522 — Cloudflare tidak bisa hubungi origin"
  echo "           Ini penyebab Certbot gagal!"
elif [[ "$EXT_CODE" =~ ^[23] ]]; then
  echo "    [OK] HTTP ${EXT_CODE} — origin bisa diakses Cloudflare"
else
  echo "    [INFO] HTTP ${EXT_CODE}"
fi
echo

# 9. IPv6
echo ">>> [9] IPv6 di server"
if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
  echo "    [OK] Server punya IPv6 global"
else
  echo "    [INFO] Server TIDAK punya IPv6"
  echo "           Matikan di Cloudflare: Network → IPv6 Compatibility → Off"
  echo "           (Cloudflare bisa coba koneksi IPv6 ke origin → 522)"
fi
echo

echo "============================================"
echo "  Rekomendasi"
echo "============================================"
echo
echo "Jika test [8] = 522, perbaiki SEBELUM Certbot:"
echo
echo "  A) Cloudflare Dashboard:"
echo "     • DNS: record pencatatan → A → ${PUBLIC_IP:-IP_VPS_ANDA}"
echo "     • SSL/TLS → Flexible (origin cukup HTTP)"
echo "     • Network → IPv6 Compatibility → OFF"
echo
echo "  B) Di VPS:"
echo "     • sudo systemctl start nginx"
echo "     • sudo ufw allow 80/tcp"
echo "     • Pastikan setup_nginx_domain.sh sudah dijalankan"
echo
echo "  C) Pilih salah satu untuk SSL:"
echo "     • MUDAH: Lewati Certbot, pakai SSL Cloudflare (Flexible)"
echo "     • ATAU: Grey cloud sementara → certbot → orange cloud lagi"
echo "     • ATAU: certbot dns-cloudflare (tanpa HTTP challenge)"
echo

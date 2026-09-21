#!/usr/bin/env bash
set -euo pipefail

SITES_AVAILABLE="/etc/nginx/sites-available"
SITES_ENABLED="/etc/nginx/sites-enabled"
WEB_ROOT="/var/www"

# --- helpers ---

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Silakan jalankan: sudo $0"
  fi
}

require_nginx() {
  command -v nginx >/dev/null 2>&1 || die "Nginx belum terpasang. Jalankan dulu: sudo ./install_nginx_ubuntu24.sh"
}

prompt() {
  local var_name="$1"
  local question="$2"
  local default="${3:-}"
  local answer

  if [[ -n "$default" ]]; then
    read -r -p "$question [$default]: " answer
    answer="${answer:-$default}"
  else
    read -r -p "$question: " answer
    while [[ -z "$answer" ]]; do
      read -r -p "$question (wajib diisi): " answer
    done
  fi

  printf -v "$var_name" '%s' "$answer"
}

prompt_yes_no() {
  local question="$1"
  local default="${2:-n}"
  local answer hint

  if [[ "$default" == "y" ]]; then
    hint="Y/n"
  else
    hint="y/N"
  fi

  read -r -p "$question [$hint]: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_email() {
  local email="$1"
  [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

site_config_path() {
  echo "${SITES_AVAILABLE}/$1"
}

site_enabled_path() {
  echo "${SITES_ENABLED}/$1"
}

site_exists() {
  [[ -f "$(site_config_path "$1")" ]]
}

list_domains() {
  echo
  echo "=== Domain terdaftar di Nginx ==="
  local found=0
  for file in "${SITES_AVAILABLE}"/*; do
    [[ -f "$file" ]] || continue
    [[ "$(basename "$file")" == "default" ]] && continue
    found=1
    local name enabled="tidak"
    name="$(basename "$file")"
    [[ -L "$(site_enabled_path "$name")" || -f "$(site_enabled_path "$name")" ]] && enabled="ya"
    echo "  - $name (aktif: $enabled)"
  done
  if [[ "$found" -eq 0 ]]; then
    echo "  (belum ada domain custom)"
  fi
  echo
}

choose_setup_type() {
  echo
  echo "Pilih tipe konfigurasi:"
  echo "  1) Reverse proxy ke aplikasi lokal (Docker / service di localhost)"
  echo "  2) Static website (HTML di /var/www/<domain>)"
  echo "  3) Redirect ke domain/URL lain"
  echo
  local choice
  prompt choice "Pilihan" "1"
  case "$choice" in
    1) SETUP_TYPE="proxy" ;;
    2) SETUP_TYPE="static" ;;
    3) SETUP_TYPE="redirect" ;;
    *) die "Pilihan tidak valid: $choice" ;;
  esac
}

collect_common_input() {
  echo
  echo "=== Setup Domain Baru ==="

  prompt DOMAIN "Nama domain (contoh: app.example.com)"
  validate_domain "$DOMAIN" || die "Format domain tidak valid: $DOMAIN"
  site_exists "$DOMAIN" && die "Config untuk '$DOMAIN' sudah ada di ${SITES_AVAILABLE}/$DOMAIN"

  if prompt_yes_no "Sertakan subdomain www (www.${DOMAIN})?" "n"; then
    INCLUDE_WWW=true
    SERVER_NAMES="$DOMAIN www.$DOMAIN"
  else
    INCLUDE_WWW=false
    SERVER_NAMES="$DOMAIN"
  fi
}

collect_proxy_input() {
  prompt UPSTREAM_HOST "Host upstream" "127.0.0.1"
  prompt UPSTREAM_PORT "Port upstream" "8080"
  validate_port "$UPSTREAM_PORT" || die "Port tidak valid: $UPSTREAM_PORT"

  ENABLE_WEBSOCKET=false
  prompt_yes_no "Aktifkan dukungan WebSocket?" "n" && ENABLE_WEBSOCKET=true

  CLIENT_MAX_BODY="10m"
  prompt CLIENT_MAX_BODY "Ukuran upload maksimum (client_max_body_size)" "$CLIENT_MAX_BODY"
}

collect_static_input() {
  DOCUMENT_ROOT="${WEB_ROOT}/${DOMAIN}"
  prompt DOCUMENT_ROOT "Document root" "$DOCUMENT_ROOT"
  mkdir -p "$DOCUMENT_ROOT"

  if [[ ! -f "${DOCUMENT_ROOT}/index.html" ]]; then
    cat > "${DOCUMENT_ROOT}/index.html" <<EOF
<!DOCTYPE html>
<html lang="id">
<head>
  <meta charset="UTF-8">
  <title>${DOMAIN}</title>
</head>
<body>
  <h1>Selamat datang di ${DOMAIN}</h1>
  <p>Website siap. Ganti file ini di ${DOCUMENT_ROOT}/index.html</p>
</body>
</html>
EOF
    echo ">>> Dibuat placeholder: ${DOCUMENT_ROOT}/index.html"
  fi
}

collect_redirect_input() {
  prompt REDIRECT_TARGET "Redirect ke URL (contoh: https://example.com)" "https://${DOMAIN}"
  [[ "$REDIRECT_TARGET" =~ ^https?:// ]] || die "URL redirect harus diawali http:// atau https://"
}

collect_ssl_input() {
  ENABLE_SSL=false
  CERTBOT_EMAIL=""

  if prompt_yes_no "Pasang SSL otomatis dengan Certbot?" "y"; then
    if ! command -v certbot >/dev/null 2>&1; then
      echo
      echo "Certbot belum terpasang."
      if prompt_yes_no "Lanjut tanpa SSL (bisa pasang Certbot nanti)?" "y"; then
        return
      fi
      die "Pasang Certbot dulu: sudo ./install_certbot_nginx.sh"
    fi

    prompt CERTBOT_EMAIL "Email untuk Let's Encrypt"
    validate_email "$CERTBOT_EMAIL" || die "Format email tidak valid: $CERTBOT_EMAIL"
    ENABLE_SSL=true
  fi
}

write_proxy_config() {
  local websocket_block=""
  if [[ "$ENABLE_WEBSOCKET" == true ]]; then
    websocket_block=$'        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection "upgrade";'
  fi

  cat > "$(site_config_path "$DOMAIN")" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};

    client_max_body_size ${CLIENT_MAX_BODY};

    location / {
        proxy_pass http://${UPSTREAM_HOST}:${UPSTREAM_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
${websocket_block}
        proxy_read_timeout 86400;
    }
}
EOF
}

write_static_config() {
  cat > "$(site_config_path "$DOMAIN")" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};

    root ${DOCUMENT_ROOT};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
}

write_redirect_config() {
  cat > "$(site_config_path "$DOMAIN")" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};

    return 301 ${REDIRECT_TARGET}\$request_uri;
}
EOF
}

preview_config() {
  echo
  echo "=== Preview konfigurasi ==="
  cat "$(site_config_path "$DOMAIN")"
  echo "==========================="
  echo
}

enable_site() {
  ln -sf "$(site_config_path "$DOMAIN")" "$(site_enabled_path "$DOMAIN")"
}

run_certbot() {
  local -a certbot_args=(
    --nginx
    -d "$DOMAIN"
    --non-interactive
    --agree-tos
    -m "$CERTBOT_EMAIL"
    --redirect
  )

  if [[ "$INCLUDE_WWW" == true ]]; then
    certbot_args+=(-d "www.$DOMAIN")
  fi

  echo ">>> Menjalankan Certbot..."
  certbot "${certbot_args[@]}"
}

add_domain() {
  collect_common_input
  choose_setup_type

  case "$SETUP_TYPE" in
    proxy) collect_proxy_input ;;
    static) collect_static_input ;;
    redirect) collect_redirect_input ;;
  esac

  collect_ssl_input

  case "$SETUP_TYPE" in
    proxy) write_proxy_config ;;
    static) write_static_config ;;
    redirect) write_redirect_config ;;
  esac

  preview_config
  prompt_yes_no "Terapkan konfigurasi ini?" "y" || {
    rm -f "$(site_config_path "$DOMAIN")"
    echo "Dibatalkan."
    return
  }

  enable_site

  echo ">>> Validasi konfigurasi Nginx..."
  nginx -t

  echo ">>> Reload Nginx..."
  systemctl reload nginx

  if [[ "$ENABLE_SSL" == true ]]; then
    run_certbot
    nginx -t
    systemctl reload nginx
  fi

  echo
  echo "=== DONE ==="
  echo "Domain : $DOMAIN"
  echo "Config : $(site_config_path "$DOMAIN")"
  case "$SETUP_TYPE" in
    proxy)
      echo "Proxy  : http://${UPSTREAM_HOST}:${UPSTREAM_PORT}"
      ;;
    static)
      echo "Root   : ${DOCUMENT_ROOT}"
      ;;
    redirect)
      echo "Redirect ke: ${REDIRECT_TARGET}"
      ;;
  esac
  if [[ "$ENABLE_SSL" == true ]]; then
    echo "SSL    : aktif (Let's Encrypt)"
    echo "Akses  : https://${DOMAIN}"
  else
    echo "Akses  : http://${DOMAIN}"
    echo "SSL    : belum — jalankan: sudo certbot --nginx -d ${DOMAIN}"
  fi
}

remove_domain() {
  list_domains
  prompt DOMAIN "Nama domain yang akan dihapus"
  site_exists "$DOMAIN" || die "Domain '$DOMAIN' tidak ditemukan"

  echo
  echo "Akan dihapus:"
  echo "  - $(site_config_path "$DOMAIN")"
  echo "  - $(site_enabled_path "$DOMAIN")"
  prompt_yes_no "Yakin hapus domain ini?" "n" || return

  rm -f "$(site_enabled_path "$DOMAIN")"
  rm -f "$(site_config_path "$DOMAIN")"

  nginx -t
  systemctl reload nginx
  echo "Domain '$DOMAIN' berhasil dihapus."
}

show_main_menu() {
  echo
  echo "========================================"
  echo "  Setup Domain Nginx (Interaktif)"
  echo "========================================"
  echo "  1) Tambah domain baru"
  echo "  2) Lihat daftar domain"
  echo "  3) Hapus domain"
  echo "  4) Keluar"
  echo
}

main() {
  require_root
  require_nginx

  while true; do
    show_main_menu
    local choice
    prompt choice "Pilihan" "1"

    case "$choice" in
      1) add_domain ;;
      2) list_domains ;;
      3) remove_domain ;;
      4) echo "Selesai."; exit 0 ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done
}

main "$@"

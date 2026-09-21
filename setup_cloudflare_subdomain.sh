#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/cloudflare/.env"
CF_API_BASE="https://api.cloudflare.com/client/v4"

CF_API_TOKEN=""
CF_ZONE_NAME=""
CF_ZONE_ID=""
CF_DEFAULT_IP=""
CF_DEFAULT_PROXIED="true"
CF_DEFAULT_TTL="1"

# --- helpers ---

die() {
  echo "ERROR: $*" >&2
  exit 1
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

require_deps() {
  command -v curl >/dev/null 2>&1 || die "curl belum terpasang."
  command -v jq >/dev/null 2>&1 || die "jq belum terpasang. Install: sudo apt install -y jq"
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "$ENV_FILE"
    set +a
  fi

  CF_API_TOKEN="${CF_API_TOKEN:-}"
  CF_ZONE_NAME="${CF_ZONE_NAME:-}"
  CF_ZONE_ID="${CF_ZONE_ID:-}"
  CF_DEFAULT_IP="${CF_DEFAULT_IP:-}"
  CF_DEFAULT_PROXIED="${CF_DEFAULT_PROXIED:-true}"
  CF_DEFAULT_TTL="${CF_DEFAULT_TTL:-1}"
}

ensure_credentials() {
  if [[ -z "$CF_API_TOKEN" || "$CF_API_TOKEN" == "your_cloudflare_api_token_here" ]]; then
    echo
    echo "API Token Cloudflare belum dikonfigurasi."
    echo "Buat token di: https://dash.cloudflare.com/profile/api-tokens"
    echo "Permission: Zone > DNS > Edit"
    echo
    prompt CF_API_TOKEN "Masukkan CF_API_TOKEN"
  fi

  if [[ -z "$CF_ZONE_NAME" || "$CF_ZONE_NAME" == "example.com" ]]; then
    prompt CF_ZONE_NAME "Root domain / zone (contoh: example.com)"
  fi
}

validate_subdomain_label() {
  local label="$1"
  [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

validate_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

detect_public_ip() {
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
    || echo ""
}

fqdn_for_subdomain() {
  local label="$1"
  if [[ "$label" == "@" || "$label" == "$CF_ZONE_NAME" ]]; then
    echo "$CF_ZONE_NAME"
  else
    echo "${label}.${CF_ZONE_NAME}"
  fi
}

cf_request() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local url="${CF_API_BASE}${endpoint}"
  local -a curl_args=(
    -fsS
    -X "$method"
    -H "Authorization: Bearer ${CF_API_TOKEN}"
    -H "Content-Type: application/json"
  )

  if [[ -n "$data" ]]; then
    curl_args+=(-d "$data")
  fi

  local response
  response="$(curl "${curl_args[@]}" "$url")"

  local success
  success="$(echo "$response" | jq -r '.success')"
  if [[ "$success" != "true" ]]; then
    echo "Cloudflare API error:" >&2
    echo "$response" | jq -r '.errors[]? | "  [\(.code)] \(.message)"' >&2
    return 1
  fi

  echo "$response"
}

resolve_zone_id() {
  if [[ -n "$CF_ZONE_ID" ]]; then
    return 0
  fi

  echo ">>> Mencari Zone ID untuk ${CF_ZONE_NAME}..."
  local response
  response="$(cf_request GET "/zones?name=${CF_ZONE_NAME}&status=active")"
  CF_ZONE_ID="$(echo "$response" | jq -r '.result[0].id // empty')"

  [[ -n "$CF_ZONE_ID" ]] || die "Zone '${CF_ZONE_NAME}' tidak ditemukan di akun Cloudflare Anda."
  echo "    Zone ID: ${CF_ZONE_ID}"
}

verify_api_token() {
  echo ">>> Memverifikasi API token..."
  local response
  response="$(cf_request GET "/user/tokens/verify")"
  local status
  status="$(echo "$response" | jq -r '.result.status // "unknown"')"
  echo "    Token status: ${status}"
  resolve_zone_id
  echo "    Zone       : ${CF_ZONE_NAME}"
  echo "=== Verifikasi berhasil ==="
}

list_dns_records() {
  resolve_zone_id
  echo
  echo "=== DNS Records — ${CF_ZONE_NAME} ==="

  local response
  response="$(cf_request GET "/zones/${CF_ZONE_ID}/dns_records?per_page=100")"

  echo "$response" | jq -r '
    .result[]
    | "\(.type)\t\(.name)\t\(.content)\tproxied=\(.proxied)\tid=\(.id)"
  ' | while IFS=$'\t' read -r type name content proxied id; do
    printf "  %-6s %-35s %-20s %s\n" "$type" "$name" "$content" "$proxied"
  done

  local total
  total="$(echo "$response" | jq -r '.result | length')"
  if [[ "$total" -eq 0 ]]; then
    echo "  (belum ada record)"
  fi
  echo
}

find_dns_record() {
  local fqdn="$1"
  local record_type="${2:-}"

  resolve_zone_id

  local endpoint="/zones/${CF_ZONE_ID}/dns_records?name=${fqdn}&per_page=10"
  if [[ -n "$record_type" ]]; then
    endpoint+="&type=${record_type}"
  fi

  cf_request GET "$endpoint"
}

create_or_update_record() {
  local record_type="$1"
  local fqdn="$2"
  local content="$3"
  local proxied="$4"
  local ttl="$5"
  local skip_confirm="${6:-false}"

  local existing
  existing="$(find_dns_record "$fqdn" "$record_type")"
  local record_id
  record_id="$(echo "$existing" | jq -r --arg name "$fqdn" '.result[] | select(.name == $name) | .id' | head -n1)"

  local payload
  payload="$(jq -n \
    --arg type "$record_type" \
    --arg name "$fqdn" \
    --arg content "$content" \
    --argjson proxied "$proxied" \
    --argjson ttl "$ttl" \
    '{type: $type, name: $name, content: $content, proxied: $proxied, ttl: $ttl}')"

  echo
  echo "=== Preview DNS Record ==="
  echo "  Type    : $record_type"
  echo "  Name    : $fqdn"
  echo "  Content : $content"
  echo "  Proxied : $proxied"
  echo "  TTL     : $ttl"
  echo "=========================="
  echo

  if [[ -n "$record_id" ]]; then
    echo "Record sudah ada (id: ${record_id})."
    if [[ "$skip_confirm" != "true" ]]; then
      prompt_yes_no "Update record yang sudah ada?" "y" || {
        echo "Dibatalkan."
        return
      }
    fi
    cf_request PUT "/zones/${CF_ZONE_ID}/dns_records/${record_id}" "$payload" >/dev/null
    echo ">>> Record '${fqdn}' berhasil diupdate."
  else
    if [[ "$skip_confirm" != "true" ]]; then
      prompt_yes_no "Buat record DNS ini?" "y" || {
        echo "Dibatalkan."
        return
      }
    fi
    cf_request POST "/zones/${CF_ZONE_ID}/dns_records" "$payload" >/dev/null
    echo ">>> Record '${fqdn}' berhasil dibuat."
  fi

  if [[ "$skip_confirm" != "true" ]]; then
    echo
    echo "=== DONE ==="
    echo "Subdomain : ${fqdn}"
    echo "Target    : ${content}"
    if [[ "$proxied" == "true" ]]; then
      echo "Mode      : Proxied (orange cloud) — SSL Cloudflare aktif"
    else
      echo "Mode      : DNS only (grey cloud)"
    fi
    echo
    echo "Langkah berikutnya:"
    echo "  1) Tunggu propagasi DNS (biasanya 1–5 menit)"
    echo "  2) Setup Nginx: sudo ./setup_nginx_domain.sh"
    echo "     Domain: ${fqdn}"
  fi
}

add_subdomain() {
  ensure_credentials
  resolve_zone_id

  echo
  echo "=== Tambah Subdomain ==="
  echo "Zone: ${CF_ZONE_NAME}"
  echo

  local subdomain_label record_type target proxied ttl default_ip fqdn

  prompt subdomain_label "Nama subdomain (contoh: app, api, db) — '@' untuk root zone" "app"
  if [[ "$subdomain_label" != "@" ]]; then
    subdomain_label="${subdomain_label,,}"
    validate_subdomain_label "$subdomain_label" || die "Format subdomain tidak valid: ${subdomain_label}"
  fi

  fqdn="$(fqdn_for_subdomain "$subdomain_label")"

  echo
  echo "Pilih tipe record:"
  echo "  1) A     — arahkan ke IP server"
  echo "  2) CNAME — arahkan ke hostname lain"
  echo
  prompt record_type "Pilihan" "1"
  case "$record_type" in
    1) record_type="A" ;;
    2) record_type="CNAME" ;;
    *) die "Pilihan tidak valid: $record_type" ;;
  esac

  if [[ "$record_type" == "A" ]]; then
    default_ip="$CF_DEFAULT_IP"
    if [[ -z "$default_ip" ]]; then
      echo ">>> Mendeteksi IP publik..."
      default_ip="$(detect_public_ip)"
      [[ -n "$default_ip" ]] || default_ip="0.0.0.0"
    fi
    prompt target "IP address server" "$default_ip"
    validate_ipv4 "$target" || die "Format IP tidak valid: $target"
  else
    prompt target "Target CNAME (contoh: example.com atau other.example.com)"
    [[ -n "$target" ]] || die "Target CNAME wajib diisi."
  fi

  proxied="false"
  if [[ "$CF_DEFAULT_PROXIED" == "true" ]]; then
    prompt_yes_no "Aktifkan Cloudflare Proxy (orange cloud)?" "y" && proxied="true"
  else
    prompt_yes_no "Aktifkan Cloudflare Proxy (orange cloud)?" "n" && proxied="true"
  fi

  ttl="$CF_DEFAULT_TTL"
  if [[ "$proxied" == "true" ]]; then
    ttl=1
  else
    prompt ttl "TTL (detik, 1=auto)" "$CF_DEFAULT_TTL"
  fi

  create_or_update_record "$record_type" "$fqdn" "$target" "$proxied" "$ttl"
}

add_bulk_subdomains() {
  ensure_credentials
  resolve_zone_id

  echo
  echo "=== Tambah Banyak Subdomain (IP sama) ==="
  echo "Zone: ${CF_ZONE_NAME}"
  echo "Pisahkan nama subdomain dengan koma, contoh: app,api,db,grafana"
  echo

  local subdomain_list default_ip target proxied ttl

  prompt subdomain_list "Daftar subdomain"
  default_ip="$CF_DEFAULT_IP"
  if [[ -z "$default_ip" ]]; then
    default_ip="$(detect_public_ip)"
  fi
  prompt target "IP address server" "${default_ip:-0.0.0.0}"
  validate_ipv4 "$target" || die "Format IP tidak valid: $target"

  proxied="false"
  if [[ "$CF_DEFAULT_PROXIED" == "true" ]]; then
    prompt_yes_no "Aktifkan Cloudflare Proxy untuk semua?" "y" && proxied="true"
  else
    prompt_yes_no "Aktifkan Cloudflare Proxy untuk semua?" "n" && proxied="true"
  fi

  ttl=1
  if [[ "$proxied" != "true" ]]; then
    ttl="$CF_DEFAULT_TTL"
  fi

  IFS=',' read -ra labels <<< "$subdomain_list"

  echo
  echo "Akan dibuat ${#labels[@]} record A → ${target} (proxied=${proxied})"
  prompt_yes_no "Lanjutkan?" "y" || return
  for raw_label in "${labels[@]}"; do
    local label fqdn
    label="$(echo "$raw_label" | xargs | tr '[:upper:]' '[:lower:]')"
    [[ -n "$label" ]] || continue
    validate_subdomain_label "$label" || {
      echo "Lewati '${label}' — format tidak valid."
      continue
    }
    fqdn="$(fqdn_for_subdomain "$label")"
    echo ">>> Memproses ${fqdn}..."
    create_or_update_record "A" "$fqdn" "$target" "$proxied" "$ttl" "true"
  done

  echo
  echo "=== DONE (bulk) ==="
  echo "Setup Nginx per subdomain: sudo ./setup_nginx_domain.sh"
}

delete_subdomain() {
  ensure_credentials
  resolve_zone_id
  list_dns_records

  local subdomain_label fqdn record_type response record_id

  prompt subdomain_label "Subdomain yang akan dihapus (contoh: app)"
  subdomain_label="${subdomain_label,,}"
  fqdn="$(fqdn_for_subdomain "$subdomain_label")"

  prompt record_type "Tipe record (A/CNAME)" "A"

  response="$(find_dns_record "$fqdn" "$record_type")"
  record_id="$(echo "$response" | jq -r --arg name "$fqdn" '.result[] | select(.name == $name) | .id' | head -n1)"

  [[ -n "$record_id" ]] || die "Record '${fqdn}' (${record_type}) tidak ditemukan."

  echo
  echo "Akan dihapus: ${fqdn} (${record_type}), id=${record_id}"
  prompt_yes_no "Yakin hapus record ini?" "n" || return

  cf_request DELETE "/zones/${CF_ZONE_ID}/dns_records/${record_id}" >/dev/null
  echo ">>> Record '${fqdn}' berhasil dihapus."
}

setup_env_file() {
  echo
  echo "=== Setup file cloudflare/.env ==="
  mkdir -p "$(dirname "$ENV_FILE")"

  prompt CF_API_TOKEN "CF_API_TOKEN"
  prompt CF_ZONE_NAME "CF_ZONE_NAME (root domain)" "example.com"
  prompt CF_ZONE_ID "CF_ZONE_ID (kosongkan untuk auto-detect)" ""
  prompt CF_DEFAULT_IP "CF_DEFAULT_IP (kosongkan untuk auto-detect)" ""
  prompt CF_DEFAULT_PROXIED "CF_DEFAULT_PROXIED (true/false)" "true"
  prompt CF_DEFAULT_TTL "CF_DEFAULT_TTL" "1"

  cat > "$ENV_FILE" <<EOF
# Cloudflare API — generated by setup_cloudflare_subdomain.sh
CF_API_TOKEN=${CF_API_TOKEN}
CF_ZONE_NAME=${CF_ZONE_NAME}
CF_ZONE_ID=${CF_ZONE_ID}
CF_DEFAULT_IP=${CF_DEFAULT_IP}
CF_DEFAULT_PROXIED=${CF_DEFAULT_PROXIED}
CF_DEFAULT_TTL=${CF_DEFAULT_TTL}
EOF

  echo
  echo ">>> Disimpan ke: ${ENV_FILE}"
  load_env
}

show_main_menu() {
  echo
  echo "============================================"
  echo "  Setup Cloudflare Subdomain (Interaktif)"
  echo "============================================"
  echo "  1) Tambah subdomain"
  echo "  2) Tambah banyak subdomain (IP sama)"
  echo "  3) Lihat DNS records"
  echo "  4) Hapus subdomain"
  echo "  5) Verifikasi API token"
  echo "  6) Setup / edit cloudflare/.env"
  echo "  7) Keluar"
  echo
}

main() {
  require_deps
  load_env

  while true; do
    show_main_menu
    local choice
    prompt choice "Pilihan" "1"

    case "$choice" in
      1) add_subdomain ;;
      2) add_bulk_subdomains ;;
      3) list_dns_records ;;
      4) delete_subdomain ;;
      5) ensure_credentials; verify_api_token ;;
      6) setup_env_file ;;
      7) echo "Selesai."; exit 0 ;;
      *) echo "Pilihan tidak valid." ;;
    esac
  done
}

main "$@"

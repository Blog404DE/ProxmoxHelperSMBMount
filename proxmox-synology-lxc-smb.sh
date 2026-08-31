#!/usr/bin/env bash
set -euo pipefail

# Helper to mount a Synology SMB/CIFS share on a Proxmox host and expose it
# read-only to an LXC container via a bind mount.

CREDENTIALS_FILE_DEFAULT="/root/.synology-smb-credentials"

usage() {
  cat <<'USAGE'
Usage:
  sudo ./proxmox-synology-lxc-smb.sh --ctid <ID> --server <HOST/IP> --share <NAME> [options]

Required:
  --ctid <ID>              LXC container ID on the Proxmox host
  --server <HOST/IP>       Synology NAS hostname or IP address
  --share <NAME>           SMB share name, for example "media"

Options:
  --username <USER>        SMB user name (prompted if omitted)
  --password <PASSWORD>    SMB password (prompted if omitted)
  --domain <DOMAIN>        SMB domain/workgroup (default: WORKGROUP)
  --host-mount <PATH>      Mount point on Proxmox host (default: /mnt/synology-<share>)
  --container-mount <PATH> Mount path inside the LXC (default: /mnt/synology-<share>)
  --credentials <PATH>     Credentials file path (default: /root/.synology-smb-credentials)
  --smb-version <VERSION>  SMB protocol version (default: 3.0)
  --access-mode <MODE>     Access mode: read-only or read-write (default: read-only)
  --read-only              Shortcut for --access-mode read-only
  --read-write             Shortcut for --access-mode read-write
  --no-start               Do not start the container after configuration
  --help                   Show this help

Examples:
  sudo ./proxmox-synology-lxc-smb.sh --ctid 101 --server 192.168.1.20 --share daten --username backup --access-mode read-only
  sudo ./proxmox-synology-lxc-smb.sh --ctid 101 --server 192.168.1.20 --share daten --username backup --access-mode read-write
USAGE
}

log() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID} -eq 0 ]] || fail "Bitte als root auf dem Proxmox-Host ausführen."
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Benötigter Befehl fehlt: $1"
}

install_cifs_utils_if_needed() {
  if command -v mount.cifs >/dev/null 2>&1; then
    return
  fi

  log "Installiere cifs-utils, weil mount.cifs fehlt."
  need_cmd apt-get
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y cifs-utils
}

escape_systemd_mount_name() {
  systemd-escape --path --suffix=mount "$1"
}

write_credentials() {
  local credentials_file=$1 username=$2 password=$3 domain=$4
  install -d -m 0700 "$(dirname "$credentials_file")"
  cat >"$credentials_file" <<EOF_CREDS
username=${username}
password=${password}
domain=${domain}
EOF_CREDS
  chmod 0600 "$credentials_file"
}

ensure_mount_unit() {
  local server=$1 share=$2 host_mount=$3 credentials_file=$4 smb_version=$5 readonly=$6
  local unit_name unit_path share_path access_option file_mode dir_mode

  need_cmd systemd-escape
  unit_name=$(escape_systemd_mount_name "$host_mount")
  unit_path="/etc/systemd/system/${unit_name}"
  share_path="//${server}/${share}"
  access_option="rw"
  file_mode="0644"
  dir_mode="0755"
  if [[ "$readonly" == "true" ]]; then
    access_option="ro"
    file_mode="0444"
    dir_mode="0555"
  fi

  install -d -m 0755 "$host_mount"
  cat >"$unit_path" <<EOF_UNIT
[Unit]
Description=Synology SMB share ${share_path}
After=network-online.target
Wants=network-online.target

[Mount]
What=${share_path}
Where=${host_mount}
Type=cifs
Options=credentials=${credentials_file},vers=${smb_version},iocharset=utf8,uid=100000,gid=100000,file_mode=${file_mode},dir_mode=${dir_mode},noperm,noserverino,${access_option}
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOF_UNIT

  systemctl daemon-reload
  systemctl enable --now "$unit_name"
}

configure_lxc_bind_mount() {
  local ctid=$1 host_mount=$2 container_mount=$3 readonly=$4
  local current mp_index mp_option

  need_cmd pct
  pct status "$ctid" >/dev/null

  current=$(pct config "$ctid")
  if grep -Fq "${host_mount},mp=${container_mount}" <<<"$current"; then
    log "Bind-Mount ist bereits in Container ${ctid} konfiguriert."
    return
  fi

  mp_index=0
  while grep -Eq "^[[:space:]]*mp${mp_index}:" <<<"$current"; do
    mp_index=$((mp_index + 1))
  done

  mp_option="${host_mount},mp=${container_mount}"
  if [[ "$readonly" == "true" ]]; then
    mp_option="${mp_option},ro=1"
  fi

  pct set "$ctid" -mp"$mp_index" "$mp_option"
}

main() {
  local ctid="" server="" share="" username="" password="" domain="WORKGROUP"
  local host_mount="" container_mount="" credentials_file="$CREDENTIALS_FILE_DEFAULT"
  local smb_version="3.0" access_mode="read-only" readonly="true" start_container="true"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ctid) ctid=${2:-}; shift 2 ;;
      --server) server=${2:-}; shift 2 ;;
      --share) share=${2:-}; shift 2 ;;
      --username) username=${2:-}; shift 2 ;;
      --password) password=${2:-}; shift 2 ;;
      --domain) domain=${2:-}; shift 2 ;;
      --host-mount) host_mount=${2:-}; shift 2 ;;
      --container-mount) container_mount=${2:-}; shift 2 ;;
      --credentials) credentials_file=${2:-}; shift 2 ;;
      --smb-version) smb_version=${2:-}; shift 2 ;;
      --access-mode) access_mode=${2:-}; shift 2 ;;
      --read-only) access_mode="read-only"; shift ;;
      --read-write) access_mode="read-write"; shift ;;
      --no-start) start_container="false"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) fail "Unbekannte Option: $1" ;;
    esac
  done

  [[ -n "$ctid" ]] || fail "--ctid fehlt."
  [[ -n "$server" ]] || fail "--server fehlt."
  [[ -n "$share" ]] || fail "--share fehlt."

  case "$access_mode" in
    read-only|ro) readonly="true" ;;
    read-write|rw) readonly="false" ;;
    *) fail "Ungültiger --access-mode: ${access_mode}. Erlaubt sind read-only oder read-write." ;;
  esac

  host_mount=${host_mount:-/mnt/synology-${share}}
  container_mount=${container_mount:-/mnt/synology-${share}}

  require_root
  need_cmd systemctl
  install_cifs_utils_if_needed

  if [[ -z "$username" ]]; then
    read -r -p "Synology SMB Benutzername: " username
  fi
  if [[ -z "$password" ]]; then
    read -r -s -p "Synology SMB Passwort: " password
    printf '\n'
  fi

  [[ -n "$username" ]] || fail "Benutzername darf nicht leer sein."
  [[ -n "$password" ]] || fail "Passwort darf nicht leer sein."

  write_credentials "$credentials_file" "$username" "$password" "$domain"
  ensure_mount_unit "$server" "$share" "$host_mount" "$credentials_file" "$smb_version" "$readonly"
  configure_lxc_bind_mount "$ctid" "$host_mount" "$container_mount" "$readonly"

  if [[ "$start_container" == "true" ]]; then
    pct start "$ctid" || log "Container ${ctid} läuft vermutlich bereits."
  fi

  log "Fertig. Share ist auf dem Host unter ${host_mount} und im Container unter ${container_mount} eingebunden."
  if [[ "$readonly" == "true" ]]; then
    log "Der Container erhält mindestens Leserechte: CIFS ro,file_mode=0444,dir_mode=0555 und LXC ro=1."
  fi
}

main "$@"

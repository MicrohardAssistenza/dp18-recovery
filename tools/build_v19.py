#!/usr/bin/env python3
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

s = s.replace('# SCRIPT_VERSION=1.8.0', '# SCRIPT_VERSION=1.9.0', 1)
s = s.replace('SCRIPT_VERSION="1.8.0-github"', 'SCRIPT_VERSION="1.9.0-github"', 1)

# Old PHP on these Raspberry images emits one warning per strtotime() when
# date.timezone is unset. Pin UTC for every recovery-side PHP invocation.
s = s.replace('php -d open_basedir=', 'php -d open_basedir= -d date.timezone=UTC')

def replace_func(text, name, new_body):
    start = text.find(name + '() {')
    if start < 0:
        raise SystemExit(name + ' function not found')
    end = text.find('\n}\n\n', start)
    if end < 0:
        raise SystemExit(name + ' function end not found')
    return text[:start] + new_body.rstrip() + '\n\n' + text[end+4:]

bootstrap = r'''bootstrap() {
  require_root
  for c in bash php base64 gzip od dd awk sed grep sort cp mv sync sha256sum seq tee wc tr date hostname sleep systemctl stat find head cat mkdir rm chmod curl; do
    need "$c"
  done

  mkdir -p "$STATE" "$PAYLOADS"
  chmod 700 "$STATE" "$PAYLOADS"

  local boot_name boot_serial boot_pad saved_pad
  boot_name="$(read_machine_name)"
  boot_serial="$(read_machine_serial || true)"

  # Non agganciare una DP18 gia' matricolata se non appartiene chiaramente
  # a un recovery persistente gia' iniziato da noi.
  if [ "$boot_name" = "DP18" ]; then
    case "$boot_serial" in
      ''|*[!0-9]*) ;;
      0) ;;
      *)
        boot_pad="$(printf '%05d' "$boot_serial")"
        saved_pad=""
        [ -r "$TARGET_FILE" ] && saved_pad="$(tr -d '\r\n ' < "$TARGET_FILE")"

        if [ -z "$saved_pad" ]; then
          say "Macchina gia' DP18 con matricola non-zero: $boot_pad"
          say "Nessuno stato recovery persistente: per sicurezza non modifico la macchina"
          cleanup_service
          rm -f "$SECRET_FILE" "$GITHUB_TOKEN_FILE" 2>/dev/null || true
          return 0
        fi

        [ "$saved_pad" = "$boot_pad" ] \
          || fatal "DP18 gia' matricolata $boot_pad ma stato persistente indica $saved_pad: non procedo"

        if [ -f "/root/DP18_RECOVERY_OK_${boot_pad}.txt" ] || [ -e "$DONE_FILE" ]; then
          say "Recovery $boot_pad gia' completata: non eseguo nuovamente flash o configurazione"
          cleanup_service
          rm -f "$SECRET_FILE" "$GITHUB_TOKEN_FILE" 2>/dev/null || true
          return 0
        fi

        say "DP18-$boot_pad coerente con lo stato recovery: riprendo gli step mancanti"
        ;;
    esac
  fi

  case "$boot_name" in
    DD40|DP18) ;;
    *) fatal "machine.name non supportato: '${boot_name:-vuoto}'" ;;
  esac

  rm -f "$FAILED_FILE" "$SERIAL_ATTEMPTS"

  if [ -n "${DP18_SFTP_PASSWORD:-}" ]; then
    umask 077
    printf "%s" "$DP18_SFTP_PASSWORD" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
  fi
  [ -s "$SECRET_FILE" ] || fatal "DP18_SFTP_PASSWORD non fornita al bootstrap"

  if [ -n "${DP18_GITHUB_TOKEN:-}" ]; then
    umask 077
    printf "%s" "$DP18_GITHUB_TOKEN" > "$GITHUB_TOKEN_FILE"
    chmod 600 "$GITHUB_TOKEN_FILE"
  fi
  [ -s "$GITHUB_TOKEN_FILE" ] || fatal "DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub"

  capture_original_info

  # CRITICO: installiamo il service PRIMA di analisi Pardata, estrazione payload
  # e qualunque operazione lunga. Da questo punto la sessione SSH puo' cadere.
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=DP18 Full Automatic Recovery
After=local-fs.target paypoint.service

[Service]
Type=simple
ExecStart=/bin/bash $SELF --resume
Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null

  say "Bootstrap persistente installato PRIMA dell'analisi Pardata"
  echo "Tipo attuale     : $boot_name"
  echo "Servizio         : $SERVICE"
  echo "Log persistente  : $LOG"
  echo
  echo "Da questo momento puoi perdere la sessione SSH/VPN: analisi e recovery proseguono in systemd."
  echo "Anche un reboot del Raspberry e' gestito automaticamente."

  systemctl restart "$SERVICE"
}'''

s = replace_func(s, 'bootstrap', bootstrap)

for needle in [
    'SCRIPT_VERSION="1.9.0-github"',
    "Bootstrap persistente installato PRIMA dell'analisi Pardata",
    'systemctl restart "$SERVICE"',
    'php -d open_basedir= -d date.timezone=UTC',
    'DP18_GITHUB_TOKEN non fornito',
]:
    if needle not in s:
        raise SystemExit('missing expected v1.9 marker: ' + needle)

# Bootstrap must no longer execute the long discovery/payload phase itself.
start = s.find('bootstrap() {')
end = s.find('\n}\n\n', start)
boot = s[start:end]
for forbidden in ['discover_history', 'extract_payloads']:
    if forbidden in boot:
        raise SystemExit('v1.9 bootstrap still contains ' + forbidden)

p.write_text(s)

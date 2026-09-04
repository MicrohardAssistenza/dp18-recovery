#!/usr/bin/env python3
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

def replace_func(text, name, new_body):
    start = text.find(name + '() {')
    if start < 0:
        raise SystemExit(f'{name} function not found')
    end = text.find('\n}\n\n', start)
    if end < 0:
        raise SystemExit(f'{name} function end not found')
    return text[:start] + new_body.rstrip() + '\n\n' + text[end+4:]

s = s.replace('# SCRIPT_VERSION=1.2.0', '# SCRIPT_VERSION=1.5.0', 1)
s = s.replace('SCRIPT_VERSION="1.2.0-github"', 'SCRIPT_VERSION="1.5.0-github"', 1)

anchor = 'CONFIG_DONE="$STATE/config.done"\nSECRET_FILE="$STATE/sftp_password"'
repl = 'CONFIG_DONE="$STATE/config.done"\nCOMBINED_SENT="$STATE/conversion_serial_312.sent"\nSERIAL_PERSIST_OK="$STATE/serial_persistence.ok"\nSECRET_FILE="$STATE/sftp_password"'
if anchor not in s:
    raise SystemExit('state marker anchor not found')
s = s.replace(anchor, repl, 1)

old = '''  if [ -s "$TARGET_FILE" ] && [ -f "$PRODUCTS_FILE" ] && [ -f "$ANALYSIS_JSON" ]; then
    return 0
  fi'''
new = '''  if [ -s "$TARGET_FILE" ] && [ -f "$PRODUCTS_FILE" ]; then
    local saved_pad
    saved_pad="$(tr -d '\\r\\n ' < "$TARGET_FILE")"
    case "$saved_pad" in
      [0-9][0-9][0-9][0-9][0-9]) ;;
      *) fatal "stato persistente target_serial non valido: $saved_pad" ;;
    esac
    [ "$saved_pad" != "00000" ] || fatal "stato persistente target_serial e' 00000"
    say "Riutilizzo storico persistente gia' recuperato: matricola $saved_pad"
    return 0
  fi'''
if old not in s:
    raise SystemExit('discover_history anchor not found')
s = s.replace(old, new, 1)

ensure = r'''ensure_dp18_software() {
  local name pad num current serial_mha attempt
  pad="$(tr -d '\r\n ' < "$TARGET_FILE")"
  num=$((10#$pad))
  name="$(read_machine_name)"
  current="$(read_machine_serial || true)"

  case "$current" in
    ""|*[!0-9]*) fatal "impossibile leggere /root/machine.serial durante conversione" ;;
  esac

  case "$name" in
    DP18)
      if [ "$current" = "$num" ]; then
        say "Software Raspberry gia' DP18 e matricola gia' acquisita: $pad"
        return 0
      fi
      [ "$current" = "0" ] || fatal "DP18 con matricola non-zero $current diversa dal target $num"

      if [ -e "$COMBINED_SENT" ]; then
        say "DP18 rilevata dopo il firmware combinato; attendo la matricola $pad senza inviare un secondo firmware"
        wait_paypoint 300 || fatal "paypoint.service non attivo dopo conversione combinata"
        if wait_serial "$num" 300; then
          say "Conversione combinata riuscita: Raspberry ha ricevuto la matricola $pad dalla MH430"
          return 0
        fi
        say "Matricola non comparsa dal primo firmware combinato: passo al programmatore seriale di fallback"
        return 0
      fi

      say "Software Raspberry gia' DP18"
      if [ -e "$CONVERSION_SENT" ]; then
        say "Conversione legacy rilevata: attendo 90 secondi di stabilizzazione prima del fallback seriale"
        sleep 90
        wait_paypoint 300 || fatal "paypoint.service non attivo dopo stabilizzazione DP18"
      fi
      return 0
      ;;
    DD40)
      ;;
    *)
      fatal "tipo macchina non supportato per recovery automatico: '${name:-vuoto}'"
      ;;
  esac

  serial_mha="$(make_serial_mha "$num" "$pad")"

  attempt=1
  if [ -r "$STATE/conversion_attempts" ]; then
    attempt="$(cat "$STATE/conversion_attempts" 2>/dev/null || echo 1)"
  fi

  while [ "$attempt" -le 3 ]; do
    if [ ! -e "$CONVERSION_SENT" ]; then
      echo "$attempt" > "$STATE/conversion_attempts"
      date +%s > "$COMBINED_SENT"
      trigger_update "$serial_mha" "conversione DD40 -> DP18 firmware 3.12 + matricola $pad (tentativo $attempt)"
      date +%s > "$CONVERSION_SENT"
      say "Pacchetto unico DP18 3.12 + matricola $pad consegnato. Eventuali reboot Raspberry sono gestiti automaticamente."
    else
      if [ -e "$COMBINED_SENT" ]; then
        say "Conversione combinata DP18 + matricola gia' richiesta; attendo lo stato della macchina"
      else
        say "Conversione DP18 legacy gia' richiesta; attendo lo stato della macchina"
      fi
    fi

    if wait_machine_dp18 900; then
      say "Raspberry ora identificato come DP18"
      wait_paypoint 300 || fatal "paypoint.service non attivo dopo conversione DP18"

      if [ -e "$COMBINED_SENT" ]; then
        current="$(read_machine_serial || true)"
        if [ "$current" = "$num" ]; then
          say "Matricola $pad acquisita direttamente durante la conversione"
          return 0
        fi
        say "Attendo fino a 300 secondi la matricola $pad dal firmware combinato"
        if wait_serial "$num" 300; then
          say "Matricola $pad acquisita direttamente durante la conversione"
          return 0
        fi
        say "Conversione completata ma matricola ancora 00000: usero' il fallback seriale senza riconvertire il Raspberry"
        return 0
      fi

      say "Conversione legacy completata; attendo 90 secondi di stabilizzazione"
      sleep 90
      wait_paypoint 300 || fatal "paypoint.service non attivo dopo stabilizzazione DP18"
      return 0
    fi

    name="$(read_machine_name)"
    [ "$name" = "DP18" ] && return 0

    attempt=$((attempt+1))
    rm -f "$CONVERSION_SENT" "$COMBINED_SENT"
    echo "$attempt" > "$STATE/conversion_attempts"
    say "DP18 non ancora rilevato: preparo un nuovo tentativo combinato"
  done

  fatal "conversione DD40 -> DP18 non completata dopo 3 tentativi"
}'''
s = replace_func(s, 'ensure_dp18_software', ensure)

confirm = r'''confirm_serial_persistence() {
  local pad="$1" num="$2" current

  current="$(read_machine_serial || true)"
  [ "$current" = "$num" ] || return 1

  if [ -e "$SERIAL_PERSIST_OK" ]; then
    say "Persistenza EEPROM matricola $pad gia' confermata"
    return 0
  fi

  if [ ! -e "$COMBINED_SENT" ] && [ ! -e "$SERIAL_PATCH_SENT" ]; then
    say "Matricola $pad gia' presente prima del programmatore: nessun test EEPROM aggiuntivo necessario"
    return 0
  fi

  say "Matricola $pad visibile; confermo la persistenza EEPROM con un reboot MH430 controllato"
  sleep 10
  trigger_empty_mha
  date +%s > "$SERIAL_EMPTY_SENT"
  say "Reboot MH430 richiesto dopo conferma della matricola in RAM"
  sleep 45

  if wait_serial "$num" 300; then
    date +%s > "$SERIAL_PERSIST_OK"
    say "Matricola $pad presente anche dopo reboot MH430: persistenza EEPROM confermata"
    return 0
  fi

  say "Matricola $pad persa dopo reboot MH430"
  rm -f "$SERIAL_EMPTY_SENT" "$SERIAL_PERSIST_OK"
  return 1
}'''
pos = s.find('recover_serial() {')
if pos < 0:
    raise SystemExit('recover_serial insertion point missing')
s = s[:pos] + confirm + '\n\n' + s[pos:]

recover = r'''recover_serial() {
  local pad num current serial_mha attempts
  pad="$(tr -d '\r\n ' < "$TARGET_FILE")"
  num=$((10#$pad))

  wait_paypoint 300 || fatal "paypoint.service non attivo prima del recupero matricola"

  current="$(read_machine_serial || true)"
  case "$current" in
    ""|*[!0-9]*) fatal "impossibile leggere /root/machine.serial" ;;
  esac

  if [ "$current" = "$num" ]; then
    say "Matricola MH430 gia' corretta: $pad"
    if [ -e "$COMBINED_SENT" ] || [ -e "$SERIAL_PATCH_SENT" ]; then
      confirm_serial_persistence "$pad" "$num" || fatal "matricola $pad non persistente dopo reboot MH430"
    fi
    return 0
  fi

  [ "$current" = "0" ] || fatal "matricola corrente non-zero ($current) diversa dalla storica ($num): non sovrascrivo"

  serial_mha="$(make_serial_mha "$num" "$pad")"

  attempts=0
  [ -r "$SERIAL_ATTEMPTS" ] && attempts="$(cat "$SERIAL_ATTEMPTS" 2>/dev/null || echo 0)"

  while [ "$attempts" -lt 3 ]; do
    current="$(read_machine_serial || true)"
    if [ "$current" = "$num" ]; then
      confirm_serial_persistence "$pad" "$num" && break
    fi

    attempts=$((attempts+1))
    echo "$attempts" > "$SERIAL_ATTEMPTS"
    rm -f "$SERIAL_PATCH_SENT" "$SERIAL_EMPTY_SENT" "$SERIAL_PERSIST_OK"

    trigger_update "$serial_mha" "programmatore matricola $pad su firmware DP18 3.12 (fallback $attempts)"
    date +%s > "$SERIAL_PATCH_SENT"
    say "Programmatore seriale di fallback consegnato; NON riavvio ancora la MH430"
    say "Attendo fino a 300 secondi che la patch dimostri di essere attiva (machine.serial=$num)"

    if ! wait_serial "$num" 300; then
      say "La matricola non e' comparsa: non invio MHA vuoto; riprovo il firmware patchato"
      continue
    fi

    say "Patch seriale ATTIVA: Raspberry ha ricevuto la matricola $pad dalla MH430"
    if confirm_serial_persistence "$pad" "$num"; then
      break
    fi

    say "Persistenza non confermata: riprovo il ciclo seriale"
  done

  current="$(read_machine_serial || true)"
  [ "$current" = "$num" ] || fatal "recupero matricola $pad fallito dopo 3 tentativi di fallback"

  if [ -e "$COMBINED_SENT" ] || [ -e "$SERIAL_PATCH_SENT" ]; then
    [ -e "$SERIAL_PERSIST_OK" ] || fatal "matricola $pad presente ma persistenza EEPROM non confermata"
  fi

  say "Matricola recuperata e confermata dalla MH430: $pad"
}'''
s = replace_func(s, 'recover_serial', recover)

bootstrap = r'''bootstrap() {
  require_root
  for c in bash php base64 gzip od dd awk sed grep sort cp mv sync sha256sum seq tee wc tr date hostname sleep systemctl stat find head cat mkdir rm chmod; do
    need "$c"
  done

  mkdir -p "$STATE" "$PAYLOADS"
  chmod 700 "$STATE" "$PAYLOADS"

  local boot_name boot_serial boot_pad saved_pad
  boot_name="$(read_machine_name)"
  boot_serial="$(read_machine_serial || true)"
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
          rm -f "$SECRET_FILE" 2>/dev/null || true
          return 0
        fi

        [ "$saved_pad" = "$boot_pad" ] \
          || fatal "DP18 gia' matricolata $boot_pad ma stato persistente indica $saved_pad: non procedo"

        if [ -f "/root/DP18_RECOVERY_OK_${boot_pad}.txt" ] || [ -e "$DONE_FILE" ]; then
          say "Recovery $boot_pad gia' completata: non eseguo nuovamente flash o configurazione"
          cleanup_service
          rm -f "$SECRET_FILE" 2>/dev/null || true
          return 0
        fi

        say "DP18-$boot_pad coerente con lo stato recovery: riprendo gli step mancanti"
        ;;
    esac
  fi

  rm -f "$FAILED_FILE"
  rm -f "$SERIAL_ATTEMPTS"

  if [ -n "${DP18_SFTP_PASSWORD:-}" ]; then
    umask 077
    printf "%s" "$DP18_SFTP_PASSWORD" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
  fi
  [ -s "$SECRET_FILE" ] || fatal "DP18_SFTP_PASSWORD non fornita al bootstrap"
  capture_original_info

  discover_history
  extract_payloads

  local pad name
  pad="$(tr -d '\r\n ' < "$TARGET_FILE")"
  name="$(read_machine_name)"

  case "$name" in
    DD40|DP18) ;;
    *) fatal "machine.name non supportato: '${name:-vuoto}'" ;;
  esac

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

  say "Bootstrap installato"
  echo "Target matricola : $pad"
  echo "Tipo attuale     : $name"
  echo "Servizio         : $SERVICE"
  echo "Log persistente  : $LOG"
  echo
  echo "Da questo momento puoi perdere la sessione SSH/VPN: il recovery prosegue da solo."
  echo "Anche un reboot del Raspberry e' gestito automaticamente."

  systemctl restart "$SERVICE"
}'''
s = replace_func(s, 'bootstrap', bootstrap)

s = s.replace('- converte MH430/Raspberry a DP18 3.12\n', '- converte MH430/Raspberry a DP18 3.12 usando gia\' il firmware patchato con la matricola storica\n', 1)

for needle in [
    'SCRIPT_VERSION="1.5.0-github"',
    'conversione DD40 -> DP18 firmware 3.12 + matricola',
    'Conversione combinata riuscita',
    'serial_persistence.ok',
    'riprendo gli step mancanti',
    'programmatore matricola $pad su firmware DP18 3.12 (fallback $attempts)',
]:
    if needle not in s:
        raise SystemExit('missing expected output marker: ' + needle)

p.write_text(s)

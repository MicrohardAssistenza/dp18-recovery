#!/usr/bin/env python3
from pathlib import Path
import sys

p = Path(sys.argv[1] if len(sys.argv) > 1 else 'DP18-FULL-RECOVERY.sh')
s = p.read_text()

s = s.replace('# SCRIPT_VERSION=1.2.0', '# SCRIPT_VERSION=1.3.0', 1)
s = s.replace('SCRIPT_VERSION="1.2.0-github"', 'SCRIPT_VERSION="1.3.0-github"', 1)

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

old = '''  mkdir -p "$STATE" "$PAYLOADS"
  chmod 700 "$STATE" "$PAYLOADS"
  rm -f "$FAILED_FILE"'''
new = '''  mkdir -p "$STATE" "$PAYLOADS"
  chmod 700 "$STATE" "$PAYLOADS"

  # Idempotenza: una DP18 gia' dotata di seriale non-zero non viene mai
  # riportata dentro la procedura di discovery/flash per errore.
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
        [ -r "$TARGET_FILE" ] && saved_pad="$(tr -d '\\r\\n ' < "$TARGET_FILE")"
        if [ -z "$saved_pad" ] || [ "$saved_pad" = "$boot_pad" ]; then
          say "Macchina gia' DP18 con matricola non-zero: $boot_pad"
          if [ -f "/root/DP18_RECOVERY_OK_${boot_pad}.txt" ] || [ -e "$CONFIG_DONE" ]; then
            say "Recovery gia' completata: non eseguo nuovamente analisi Pardata o flash"
          else
            say "Nessuno stato completo disponibile: per sicurezza non sovrascrivo una DP18 gia' matricolata"
          fi
          cleanup_service
          rm -f "$SECRET_FILE" 2>/dev/null || true
          return 0
        fi
        fatal "DP18 gia' matricolata $boot_pad ma stato persistente indica $saved_pad: non procedo"
        ;;
    esac
  fi

  rm -f "$FAILED_FILE"'''
if old not in s:
    raise SystemExit('bootstrap anchor not found')
s = s.replace(old, new, 1)

s = s.replace('via patch EEPROM nativa DP18 3.12', 'via patch EEPROM nativa DP18 3.12 validata sul campo', 1)

if 'NON riavvio ancora la MH430' not in s:
    raise SystemExit('v1.2 serial sequencing not present')
if 'SCRIPT_VERSION="1.3.0-github"' not in s:
    raise SystemExit('version update failed')

p.write_text(s)

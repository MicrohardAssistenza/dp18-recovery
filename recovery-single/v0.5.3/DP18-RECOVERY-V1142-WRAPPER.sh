#!/bin/bash
set -Eeuo pipefail

VERSION="1.14.2-wrapper"
PIN="923c9251896d6d9cdb6543dff86f5b84cb05123a"
OLD_SHA="b0b75d758797b1c4584a3092304a82d952231141e89954a5f0c4201bc269ebb0"
URL="https://raw.githubusercontent.com/MicrohardAssistenza/dp18-recovery/$PIN/DP18-FULL-RECOVERY.sh"
TARGET="/root/DP18-FULL-RECOVERY.sh"
TMP="$TARGET.v1142.new"
STATE="/var/lib/dp18-full-recovery"

say(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
read_name(){ [ -r /root/machine.name ] && cat /root/machine.name 2>/dev/null | tr -d '\r\n ' || true; }
read_serial(){ od -An -tu4 -N4 /root/machine.serial 2>/dev/null | awk '{print $1}'; }

[ "$(id -u)" -eq 0 ] || { echo 'ERRORE: root richiesto' >&2; exit 1; }
[ -n "${DP18_SFTP_PASSWORD:-}" ] || { echo 'ERRORE: DP18_SFTP_PASSWORD non fornita dal dispatcher' >&2; exit 29; }

say "DP18 recovery wrapper $VERSION"
say "Ripristino sequenza field-validated: 3.12 pulito -> serial patch -> reboot EEPROM -> 3.12 pulito finale"

# Ferma una eventuale recovery combinata precedente prima di cambiare strategia.
systemctl stop dp18-full-recovery.service >/dev/null 2>&1 || true

say "Scarico la v1.13 validata dal commit immutabile $PIN"
curl -k -fL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 180 "$URL" -o "$TMP"
echo "$OLD_SHA  $TMP" | sha256sum -c -

grep -Fq 'SCRIPT_VERSION="1.13.0-github"' "$TMP" || { echo 'ERRORE: marker v1.13 assente' >&2; exit 21; }
grep -Fq '[ -s "$GITHUB_TOKEN_FILE" ] || fatal "DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub"' "$TMP" || { echo 'ERRORE: guard token v1.13 inattesa' >&2; exit 22; }

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
s=s.replace('SCRIPT_VERSION="1.13.0-github"','SCRIPT_VERSION="1.14.2-github"',1)
s=s.replace('[ -s "$GITHUB_TOKEN_FILE" ] || fatal "DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub"',
'''if [ ! -s "$GITHUB_TOKEN_FILE" ]; then
    say "REGISTRO GITHUB: token non fornito; recovery continua senza sincronizzazione remota"
  fi''',1)

start=s.index('ensure_dp18_software() {')
end=s.index('\nmake_serial_mha() {', start)
new=r'''ensure_dp18_software() {
  local name attempt
  name="$(read_machine_name)"

  case "$name" in
    DP18)
      say "Software Raspberry gia' DP18"
      return 0
      ;;
    DD40)
      ;;
    *)
      fatal "tipo macchina non supportato per recovery automatico: '${name:-vuoto}'"
      ;;
  esac

  # Sequenza field-validated v1.3: PRIMA convertiamo DD40 -> DP18 con il
  # firmware UFFICIALE 3.12 PULITO. Solo DOPO recover_serial() inviera' il
  # firmware patchato con la matricola, ne confermera' la persistenza EEPROM
  # con reboot MH430 e infine ensure_final_312() rimettera' il 3.12 pulito.
  attempt=1
  if [ -r "$STATE/conversion_attempts" ]; then
    attempt="$(cat "$STATE/conversion_attempts" 2>/dev/null || echo 1)"
  fi

  while [ "$attempt" -le 3 ]; do
    if [ ! -e "$CONVERSION_SENT" ]; then
      echo "$attempt" > "$STATE/conversion_attempts"
      trigger_update "$OFFICIAL312" "conversione PULITA DD40 -> DP18 firmware ufficiale 3.12 (tentativo $attempt)"
      date +%s > "$CONVERSION_SENT"
      say "Pacchetto DP18 3.12 UFFICIALE PULITO consegnato; attendo che machine.name diventi DP18"
    else
      say "Conversione DP18 pulita gia' richiesta; attendo lo stato della macchina"
    fi

    if wait_machine_dp18 900; then
      say "Raspberry ora identificato come DP18 dopo conversione PULITA"
      wait_paypoint 300 || fatal "paypoint.service non attivo dopo conversione DP18"
      return 0
    fi

    name="$(read_machine_name)"
    [ "$name" = "DP18" ] && return 0

    attempt=$((attempt+1))
    rm -f "$CONVERSION_SENT" "$COMBINED_SENT"
    echo "$attempt" > "$STATE/conversion_attempts"
    say "DP18 non ancora rilevato dopo firmware pulito: preparo un nuovo tentativo"
  done

  fatal "conversione PULITA DD40 -> DP18 non completata dopo 3 tentativi"
}
'''
s=s[:start]+new+s[end:]

for needle in [
    'SCRIPT_VERSION="1.14.2-github"',
    'conversione PULITA DD40 -> DP18 firmware ufficiale 3.12',
    'trigger_update "$OFFICIAL312"',
    'make_serial_mha() {',
    'ensure_final_312() {',
    'REGISTRO GITHUB: token non fornito; recovery continua senza sincronizzazione remota']:
    if needle not in s:
        raise SystemExit('marker mancante dopo patch: '+needle)

# La conversione NON deve piu' usare serial_mha/combinato.
a=s.index('ensure_dp18_software() {')
b=s.index('\nmake_serial_mha() {', a)
conv=s[a:b]
for forbidden in ['serial_mha', 'make_serial_mha', 'conversione DD40 -> DP18 firmware 3.12 + matricola']:
    if forbidden in conv:
        raise SystemExit('conversione pulita contiene ancora '+forbidden)

p.write_text(s)
PY

bash -n "$TMP"
selfout="$(bash "$TMP" --selftest 2>&1)" || { printf '%s\n' "$selfout" >&2; exit 27; }
printf '%s\n' "$selfout"
printf '%s\n' "$selfout" | grep -Eq 'SELFTEST[ _]OK' || { echo 'ERRORE: SELFTEST OK assente' >&2; exit 28; }

# Solo se siamo ancora DD40-00000 azzeriamo i marker della vecchia strategia
# combinata. Pardata, payload ufficiali e configurazione non vengono toccati.
name="$(read_name)"
serial="$(read_serial)"
if [ "$name" = "DD40" ] && [ "${serial:-0}" = "0" ]; then
  say "RESET STRATEGIA COMBINATA: riparto da conversione DP18 3.12 pulita"
  rm -f "$STATE/conversion_attempts" \
        "$STATE/conversion_312.sent" \
        "$STATE/conversion_serial_312.sent" \
        "$STATE/serial_patch.sent" \
        "$STATE/serial_empty.sent" \
        "$STATE/serial_persistence.ok" \
        "$STATE/serial_attempts" \
        "$STATE/FAILED"
fi

chmod 700 "$TMP"
mv -f "$TMP" "$TARGET"
sync
say "DP18 v1.14.2 pronta: sequenza field-validated ripristinata"
exec env DP18_SFTP_PASSWORD="$DP18_SFTP_PASSWORD" DP18_GITHUB_TOKEN="${DP18_GITHUB_TOKEN:-}" "$TARGET" --bootstrap

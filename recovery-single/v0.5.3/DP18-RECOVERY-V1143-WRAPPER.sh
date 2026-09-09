#!/bin/bash
set -Eeuo pipefail

VERSION="1.14.3-wrapper"
PIN="923c9251896d6d9cdb6543dff86f5b84cb05123a"
OLD_SHA="b0b75d758797b1c4584a3092304a82d952231141e89954a5f0c4201bc269ebb0"
URL="https://raw.githubusercontent.com/MicrohardAssistenza/dp18-recovery/$PIN/DP18-FULL-RECOVERY.sh"
TARGET="/root/DP18-FULL-RECOVERY.sh"
TMP="$TARGET.v1143.new"
PATCHED="$TMP.patched"
FUNC="/tmp/dp18-clean-conversion.$$.func"
STATE="/var/lib/dp18-full-recovery"

say(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
read_name(){ [ -r /root/machine.name ] && cat /root/machine.name 2>/dev/null | tr -d '\r\n ' || true; }
read_serial(){ od -An -tu4 -N4 /root/machine.serial 2>/dev/null | awk '{print $1}'; }
cleanup(){ rm -f "$FUNC" "$PATCHED" 2>/dev/null || true; }
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || { echo 'ERRORE: root richiesto' >&2; exit 1; }
[ -n "${DP18_SFTP_PASSWORD:-}" ] || { echo 'ERRORE: DP18_SFTP_PASSWORD non fornita dal dispatcher' >&2; exit 29; }
for c in bash awk sed grep curl sha256sum od systemctl; do command -v "$c" >/dev/null 2>&1 || { echo "ERRORE: comando mancante: $c" >&2; exit 20; }; done

say "DP18 recovery wrapper $VERSION"
say "Sequenza field-validated: 3.12 pulito -> serial patch -> reboot EEPROM -> 3.12 pulito finale"

# Ferma esclusivamente una precedente recovery DP18 prima del cambio strategia.
systemctl stop dp18-full-recovery.service >/dev/null 2>&1 || true

say "Scarico la v1.13 validata dal commit immutabile $PIN"
curl -k -fL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 180 "$URL" -o "$TMP"
echo "$OLD_SHA  $TMP" | sha256sum -c -

grep -Fq 'SCRIPT_VERSION="1.13.0-github"' "$TMP" || { echo 'ERRORE: marker v1.13 assente' >&2; exit 21; }
grep -Fq '[ -s "$GITHUB_TOKEN_FILE" ] || fatal "DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub"' "$TMP" || { echo 'ERRORE: guard token v1.13 inattesa' >&2; exit 22; }

# Modifiche minime alla v1.13: versione + registry opzionale.
sed -i \
  -e 's/SCRIPT_VERSION="1.13.0-github"/SCRIPT_VERSION="1.14.3-github"/' \
  -e 's/\[ -s "$GITHUB_TOKEN_FILE" \] || fatal "DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub"/if [ ! -s "$GITHUB_TOKEN_FILE" ]; then say "REGISTRO GITHUB: token non fornito; recovery continua senza sincronizzazione remota"; fi/' \
  "$TMP"

# Funzione di conversione presa dalla logica field-validated v1.3:
# il primo flash DD40->DP18 usa SOLO l'official 3.12 pulito.
cat > "$FUNC" <<'FUNC_EOF'
ensure_dp18_software() {
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
FUNC_EOF

# Sostituisce esclusivamente ensure_dp18_software(); tutto cio' che segue,
# inclusi make_serial_mha(), recover_serial() ed ensure_final_312(), resta v1.13.
awk -v repl="$FUNC" '
  $0 == "ensure_dp18_software() {" {
    while ((getline l < repl) > 0) print l
    close(repl)
    skip=1
    next
  }
  skip && $0 == "make_serial_mha() {" { skip=0; print; next }
  skip { next }
  { print }
' "$TMP" > "$PATCHED"
mv -f "$PATCHED" "$TMP"

# Guard rail: esattamente una funzione conversione e i due stadi successivi presenti.
[ "$(grep -c '^ensure_dp18_software() {$' "$TMP")" = "1" ] || { echo 'ERRORE: ensure_dp18_software non univoca' >&2; exit 23; }
grep -Fq 'SCRIPT_VERSION="1.14.3-github"' "$TMP" || { echo 'ERRORE: patch versione fallita' >&2; exit 24; }
grep -Fq 'trigger_update "$OFFICIAL312" "conversione PULITA DD40 -> DP18 firmware ufficiale 3.12' "$TMP" || { echo 'ERRORE: conversione pulita assente' >&2; exit 25; }
grep -Fq 'make_serial_mha() {' "$TMP" || { echo 'ERRORE: make_serial_mha assente' >&2; exit 26; }
grep -Fq 'recover_serial() {' "$TMP" || { echo 'ERRORE: recover_serial assente' >&2; exit 27; }
grep -Fq 'ensure_final_312() {' "$TMP" || { echo 'ERRORE: ensure_final_312 assente' >&2; exit 28; }
! grep -Fq 'DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub' "$TMP" || { echo 'ERRORE: token resta obbligatorio' >&2; exit 30; }

bash -n "$TMP"
selfout="$(bash "$TMP" --selftest 2>&1)" || { printf '%s\n' "$selfout" >&2; exit 31; }
printf '%s\n' "$selfout"
printf '%s\n' "$selfout" | grep -Eq 'SELFTEST[ _]OK' || { echo 'ERRORE: SELFTEST OK assente' >&2; exit 32; }

# Se siamo ancora DD40-00000, rimuoviamo SOLO lo stato operativo della
# strategia combinata fallita; storico Pardata, payload e config restano intatti.
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
        "$STATE/final_312.sent" \
        "$STATE/config.done" \
        "$STATE/DONE" \
        "$STATE/FAILED"
fi

chmod 700 "$TMP"
mv -f "$TMP" "$TARGET"
sync
trap - EXIT
cleanup
say "DP18 v1.14.3 pronta: sequenza field-validated ripristinata"
exec env DP18_SFTP_PASSWORD="$DP18_SFTP_PASSWORD" DP18_GITHUB_TOKEN="${DP18_GITHUB_TOKEN:-}" "$TARGET" --bootstrap

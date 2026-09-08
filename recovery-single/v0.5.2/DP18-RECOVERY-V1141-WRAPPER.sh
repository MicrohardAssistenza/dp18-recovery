#!/bin/bash
set -Eeuo pipefail

VERSION="1.14.1-wrapper"
PIN="923c9251896d6d9cdb6543dff86f5b84cb05123a"
OLD_SHA="b0b75d758797b1c4584a3092304a82d952231141e89954a5f0c4201bc269ebb0"
URL="https://raw.githubusercontent.com/MicrohardAssistenza/dp18-recovery/$PIN/DP18-FULL-RECOVERY.sh"
TARGET="/root/DP18-FULL-RECOVERY.sh"
TMP="$TARGET.v1141.new"
STATE="/var/lib/dp18-full-recovery"

say(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
read_name(){ [ -r /root/machine.name ] && tr -d '\000\r\n ' < /root/machine.name || true; }
read_serial(){ od -An -tu4 -N4 /root/machine.serial 2>/dev/null | tr -d ' \r\n'; }

[ "$(id -u)" -eq 0 ] || { echo 'ERRORE: root richiesto' >&2; exit 1; }

say "DP18 recovery wrapper $VERSION"
say "Scarico la v1.13 validata dal commit immutabile $PIN"
curl -k -fL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 180 "$URL" -o "$TMP"

echo "$OLD_SHA  $TMP" | sha256sum -c -

grep -Fq 'SCRIPT_VERSION="1.13.0-github"' "$TMP" || { echo 'ERRORE: marker v1.13 assente' >&2; exit 21; }
grep -Fq '[ -s "$GITHUB_TOKEN_FILE" ] || fatal "DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub"' "$TMP" || { echo 'ERRORE: guard token v1.13 inattesa' >&2; exit 22; }

sed -i \
  -e 's/SCRIPT_VERSION="1.13.0-github"/SCRIPT_VERSION="1.14.1-github"/' \
  -e 's/\[ -s "$GITHUB_TOKEN_FILE" \] || fatal "DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub"/if [ ! -s "$GITHUB_TOKEN_FILE" ]; then say "REGISTRO GITHUB: token non fornito; recovery continua senza sincronizzazione remota"; fi/' \
  "$TMP"

grep -Fq 'SCRIPT_VERSION="1.14.1-github"' "$TMP" || { echo 'ERRORE: patch versione fallita' >&2; exit 23; }
! grep -Fq 'DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub' "$TMP" || { echo 'ERRORE: token resta obbligatorio' >&2; exit 24; }
grep -Fq 'REGISTRO GITHUB: token non fornito; recovery continua senza sincronizzazione remota' "$TMP" || { echo 'ERRORE: warning token opzionale assente' >&2; exit 25; }
grep -Fq 'REGISTRO GITHUB: token non disponibile, record conservato solo localmente' "$TMP" || { echo 'ERRORE: fallback registry opzionale assente' >&2; exit 26; }

bash -n "$TMP"
selfout="$(bash "$TMP" --selftest 2>&1)" || { printf '%s\n' "$selfout" >&2; exit 27; }
printf '%s\n' "$selfout"
printf '%s\n' "$selfout" | grep -Eq 'SELFTEST[ _]OK' || { echo 'ERRORE: SELFTEST OK assente' >&2; exit 28; }

name="$(read_name)"
serial="$(read_serial)"
if [ "$name" = "DD40" ] && [ "${serial:-0}" = "0" ] \
   && ! systemctl is-active dp18-full-recovery.service >/dev/null 2>&1 \
   && [ -f "$STATE/FAILED" ] \
   && grep -Fq 'conversione DD40 -> DP18 non completata dopo 3 tentativi' "$STATE/FAILED"; then
  say "RESET RETRY DP18: stato precedente esaurito; abilito un nuovo ciclo di conversione"
  rm -f "$STATE/conversion_attempts" \
        "$STATE/conversion_312.sent" \
        "$STATE/conversion_serial_312.sent"
fi

chmod 700 "$TMP"
mv -f "$TMP" "$TARGET"
sync
say "DP18 v1.14.1 pronta; registry opzionale e retry conversione ripristinabile"
[ -n "${DP18_SFTP_PASSWORD:-}" ] || { echo "ERRORE: DP18_SFTP_PASSWORD non fornita dal dispatcher" >&2; exit 29; }
exec env DP18_SFTP_PASSWORD="$DP18_SFTP_PASSWORD" DP18_GITHUB_TOKEN="${DP18_GITHUB_TOKEN:-}" "$TARGET" --bootstrap

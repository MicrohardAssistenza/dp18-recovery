#!/bin/bash
# MH430 LEGACY RECOVERY - READ ONLY PREFLIGHT
# No firmware/config/package changes are performed by this script.
set -u

say() { printf '%s\n' "$*"; }
section() { printf '\n================================================\n%s\n================================================\n' "$*"; }

read_serial() {
  od -An -tu4 -N4 /root/machine.serial 2>/dev/null | tr -d ' \r\n'
}

current_name="$(cat /root/machine.name 2>/dev/null | tr -d ' \r\n')"
current_serial="$(read_serial)"
current_host="$(hostname 2>/dev/null || true)"
mac="$(cat /sys/class/net/eth0/address 2>/dev/null || true)"

section "MACCHINA COLLEGATA"
printf 'Hostname attuale : %s\n' "${current_host:-n/d}"
printf 'Tipo attuale     : %s\n' "${current_name:-n/d}"
printf 'Seriale attuale  : %s\n' "${current_serial:-n/d}"
printf 'MAC              : %s\n' "${mac:-n/d}"

TMP="/tmp/mh430-legacy-preflight.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
HIST="$TMP/history.tsv"
: > "$HIST"

for d in /root/sent /root/send /root/delayedsend; do
  [ -d "$d" ] || continue
  find "$d" -type f -name '*.xml' -print 2>/dev/null
done | while IFS= read -r f; do
  [ -r "$f" ] || continue
  root="$(head -n 4 "$f" 2>/dev/null | sed -nE 's/.*<(DP18|DP30|DP60|DD40)[[:space:]]+SerialNumber="([0-9]{5})".*/\1\t\2/p' | head -1)"
  [ -n "$root" ] || continue
  model="${root%%$'\t'*}"
  serial="${root#*$'\t'}"
  [ "$serial" != "00000" ] || continue
  ts="$(head -n 4 "$f" 2>/dev/null | sed -nE 's/.*TimeStamp="([0-9]{8}_[0-9]{6})".*/\1/p' | head -1)"
  [ -n "$ts" ] || ts="00000000_000000"
  mhver="$(grep -m1 -E 'MH430:[[:space:]]+Ver\.' "$f" 2>/dev/null | sed -nE 's/.*MH430:[[:space:]]+Ver\.([0-9]+\.[0-9]+).*/\1/p')"
  [ -n "$mhver" ] || mhver="unknown"
  printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$model" "$serial" "$mhver" "$f"
done > "$HIST"

section "IDENTIFICAZIONE DA STORICO"
if [ ! -s "$HIST" ]; then
  say "NESSUN PARDATA storico non-zero trovato."
  say "ESITO PREFLIGHT : BLOCCATO - nessuna modifica consentita"
  exit 20
fi

latest="$(sort -r "$HIST" | head -1)"
IFS=$'\t' read -r hist_ts hist_model hist_serial hist_fw hist_file <<EOF
$latest
EOF

pair_count="$(awk -F '\t' '{print $2"-"$3}' "$HIST" | sort -u | wc -l | tr -d ' ')"
evidence="$(awk -F '\t' -v m="$hist_model" -v s="$hist_serial" '$2==m && $3==s{n++} END{print n+0}' "$HIST")"

printf 'Modello trovato  : %s\n' "$hist_model"
printf 'Matricola trovata: %s\n' "$hist_serial"
printf 'MH430 storico    : %s\n' "$hist_fw"
printf 'Pardata coerenti : %s\n' "$evidence"
printf 'Ultimo Pardata   : %s\n' "$hist_ts"
printf 'File evidenza    : %s\n' "$hist_file"
printf 'Identita distinte: %s\n' "$pair_count"

if [ "$pair_count" -ne 1 ]; then
  say "ESITO PREFLIGHT : BLOCCATO - piu' identita modello/matricola nello storico"
  exit 21
fi

# DDX classification: current DDX generations observed in field are MH430 4.x.
# DP18 is never classified as DDX by this rule.
ddx_history=0
case "$hist_model:$hist_fw" in
  DP18:*) ddx_history=0 ;;
  *:4.*) ddx_history=1 ;;
esac

if [ "$ddx_history" -eq 1 ]; then
  say "Classificazione : DDX STORICO (MH430 4.x)"
  say "Azione prevista : NON MODIFICARE firmware/configurazione"
  say "Registro        : SKIPPED_DDX"
  exit 30
fi

case "$hist_model" in
  DP18)
    target_fw="DP18 3.12"
    contrast="55"
    ;;
  DP30)
    target_fw="DP30 3.12"
    contrast="60"
    ;;
  DP60)
    target_fw="DP60 2.13"
    contrast="48"
    ;;
  DD40)
    target_fw="DD40 2.13"
    contrast="45"
    ;;
  *)
    say "ESITO PREFLIGHT : BLOCCATO - modello storico non supportato"
    exit 22
    ;;
esac

section "RICERCA GEOMETRIA CANALI"
GEOM="$TMP/geometry.tsv"
: > "$GEOM"
for base in /mhdata /root /var/lib; do
  [ -d "$base" ] || continue
  find "$base" -maxdepth 4 -type f \( -iname '*Config*.txt' -o -iname '*config*.cfg' \) -print 2>/dev/null
done | sort -u | while IFS= read -r cfg; do
  [ -r "$cfg" ] || continue
  sizes="$(grep -Ec '^product-size_[0-9]+=[0-9]+$' "$cfg" 2>/dev/null || true)"
  widths="$(grep -Ec '^product-width_[0-9]+=[0-9]+$' "$cfg" 2>/dev/null || true)"
  [ "$sizes" -gt 0 ] || continue
  [ "$widths" -gt 0 ] || continue
  contrast_found="$(grep -m1 '^screen-contrast=' "$cfg" 2>/dev/null | cut -d= -f2-)"
  printf '%s\t%s\t%s\t%s\n' "$sizes" "$widths" "${contrast_found:-?}" "$cfg"
done > "$GEOM"

if [ -s "$GEOM" ]; then
  sort -nr "$GEOM" | while IFS=$'\t' read -r s w c f; do
    printf 'Config candidato : %s  (size=%s width=%s contrast=%s)\n' "$f" "$s" "$w" "$c"
  done
else
  say "Nessun Config con product-size + product-width trovato."
fi

# Prefer exact historical model Config filename when present; otherwise choose
# the candidate with the largest complete geometry set, but mark it as fallback.
geom_source=""
geom_mode=""
for candidate in "/mhdata/${hist_model}Config.txt" "/root/${hist_model}Config.txt"; do
  if [ -r "$candidate" ] \
     && grep -q '^product-size_' "$candidate" \
     && grep -q '^product-width_' "$candidate"; then
    geom_source="$candidate"
    geom_mode="EXACT_MODEL_CONFIG"
    break
  fi
done
if [ -z "$geom_source" ] && [ -s "$GEOM" ]; then
  geom_source="$(sort -nr "$GEOM" | head -1 | cut -f4-)"
  geom_mode="FALLBACK_CONFIG_REVIEW_REQUIRED"
fi

if [ -n "$geom_source" ]; then
  geom_sizes="$(grep -Ec '^product-size_[0-9]+=[0-9]+$' "$geom_source" || true)"
  geom_widths="$(grep -Ec '^product-width_[0-9]+=[0-9]+$' "$geom_source" || true)"
  printf 'Fonte geometria  : %s\n' "$geom_source"
  printf 'Qualita fonte    : %s\n' "$geom_mode"
  printf 'Profondita trovate: %s\n' "$geom_sizes"
  printf 'Larghezze trovate : %s\n' "$geom_widths"
else
  say "Fonte geometria  : NON TROVATA"
fi

section "PACCHETTO DDX"
ddx_q="$(pacman -Qq 2>/dev/null | grep -Ei '(^|[-_])usbupdate.*ddx|ddx.*usbupdate' || true)"
ddx_db="$(find /var/lib/pacman/local -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -Ei 'usbupdate.*ddx|ddx.*usbupdate' || true)"
if [ -n "$ddx_q" ] || [ -n "$ddx_db" ]; then
  [ -n "$ddx_q" ] && printf 'Pacman package   : %s\n' "$ddx_q"
  [ -n "$ddx_db" ] && printf 'Pacman metadata  : %s\n' "$ddx_db"
  say "Azione recovery : RIMOZIONE DDX prima del flash legacy"
else
  say "Pacchetto DDX   : non rilevato"
fi

section "RECOVERY PIANIFICATO"
printf 'Installeremo      : %s-%s\n' "$hist_model" "$hist_serial"
printf 'Firmware MH430   : %s\n' "$target_fw"
printf 'Contrasto        : %s\n' "$contrast"
printf 'Matricola EEPROM : %s\n' "$hist_serial"
printf 'Config trigger   : /tmp/uploads/config-ready\n'

if [ "$hist_model" = "DP18" ]; then
  say "Recovery engine  : DP18 v1.13 gia' validato"
  say "ESITO PREFLIGHT  : OK - usare recovery DP18"
  exit 0
fi

if [ -z "$geom_source" ]; then
  say "Geometria        : MANCANTE"
  say "ESITO PREFLIGHT  : BLOCCATO - NON FLASHARE finche' size/width non sono recuperabili"
  exit 23
fi

if [ "$geom_mode" != "EXACT_MODEL_CONFIG" ]; then
  say "Geometria        : trovata solo da Config fallback"
  say "ESITO PREFLIGHT  : BLOCCATO - fonte geometria da validare prima del flash"
  exit 24
fi

say "Geometria        : OK"
say "ESITO PREFLIGHT  : OK - dati sufficienti per recovery legacy"
exit 0

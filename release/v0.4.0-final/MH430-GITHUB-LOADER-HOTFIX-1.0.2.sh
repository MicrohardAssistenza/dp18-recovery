#!/bin/bash
set -e

VERSION="1.0.2"
SELF="/usr/local/sbin/MH430-GITHUB-LOADER.sh"
SERVICE="mh430-github-loader.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE"
STATE="/var/lib/mh430-github-loader"
LOG="$STATE/loader.log"
STEP="$STATE/current_step"
IDENTITY_FILE="$STATE/historical_identity"
PAYLOAD_REF="1831fb3b7dc91d49971e0217964443badcc705a8"
BASE="https://raw.githubusercontent.com/MicrohardAssistenza/dp18-recovery/$PAYLOAD_REF/release/v0.4.0-final"
EXPECTED_B64_SIZE="288057"
EXPECTED_B64_SHA="f6cde271f12035abbbf4628f37e342ae7bf0d69a8a1e7d9cb61252aa33eb8adf"
EXPECTED_XZ_SIZE="213236"
EXPECTED_XZ_SHA="8e338f6e2eefc8bd878196017d1e8a135697f581d548ef0bc0739ffc3c7f4ef5"
EXPECTED_SCRIPT_SIZE="300348"
EXPECTED_SCRIPT_SHA="8798d1b313f5a7816c64dbf384040a6088bccb2f47df1d6c3d39b6267663ab71"
FILES="p01 p02 p03 p04 p05 p06 p07 p08 p09 p10 p11 t00 t01 t02 t03 t04 t05 t06 t07 t08 t09 t10 t11 t12 t13 t14 t15 t16 t17"

stamp(){ date '+%F %T'; }
log(){ printf '[%s] %s\n' "$(stamp)" "$*"; }
setstep(){ printf '%s\n' "$1" > "$STEP"; log "STEP=$1"; }

quick_identity() {
  local f r m s
  for d in /root/sent /root/send /root/delayedsend; do
    [ -d "$d" ] || continue
    find "$d" -type f -name '*.xml' -print 2>/dev/null
  done | while IFS= read -r f; do
    [ -r "$f" ] || continue
    r="$(head -n 4 "$f" 2>/dev/null | sed -nE 's/.*<(DP18|DP30|DP60|DD40)[[:space:]]+SerialNumber="([0-9]{5})".*/\1 \2/p' | head -1)"
    [ -n "$r" ] || continue
    m="${r%% *}"; s="${r##* }"
    [ "$s" = "00000" ] && continue
    printf '%s-%s\n' "$m" "$s"
    break
  done
}

expected_size() {
  case "$1" in
    p0[1-9]|p10|p11) echo 20000 ;;
    t0[0-9]|t1[0-6]) echo 4000 ;;
    t17) echo 57 ;;
    *) echo 0 ;;
  esac
}

download_one() {
  local name tmp dst n want got
  name="$1"
  tmp="$STATE/$name.tmp"
  dst="$STATE/$name"
  want="$(expected_size "$name")"

  if [ -s "$dst" ]; then
    got="$(wc -c < "$dst" | tr -d ' ')"
    if [ "$got" = "$want" ]; then
      log "reuse $name ($got byte)"
      return 0
    fi
    rm -f "$dst"
  fi

  for n in $(seq 1 120); do
    rm -f "$tmp"
    setstep "DOWNLOAD_${name}_ATTEMPT_${n}"
    if curl -k -fL --connect-timeout 8 --max-time 45 "$BASE/$name" -o "$tmp" >/dev/null 2>&1; then
      got="$(wc -c < "$tmp" | tr -d ' ')"
      if [ "$got" = "$want" ]; then
        mv -f "$tmp" "$dst"
        sync
        log "download $name OK ($got byte)"
        return 0
      fi
      log "download $name SIZE_ERR got=$got expected=$want"
    fi
    sleep 2
  done
  return 1
}

install_mode() {
  [ "$(id -u)" -eq 0 ] || { echo 'ERRORE: root richiesto'; exit 1; }
  mkdir -p "$STATE"
  chmod 700 "$STATE"

  systemctl stop "$SERVICE" >/dev/null 2>&1 || true

  cp -f "$0" "$SELF"
  chmod 700 "$SELF"

  cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=MH430 GitHub Universal Recovery Loader 1.0.2
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $SELF --resume
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE"

  mac="$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
  id="$(quick_identity | head -1 || true)"
  echo "LOADER_PERSISTENTE_OK"
  echo "LOADER_VERSION=$VERSION"
  echo "MAC=$mac"
  echo "PAYLOAD_REF=$PAYLOAD_REF"
  if [ -n "$id" ]; then
    echo "HISTORICAL_IDENTITY=$id"
    printf '%s\n' "$id" > "$IDENTITY_FILE"
  else
    echo "HISTORICAL_IDENTITY=IN_RICERCA"
  fi
  echo "CURRENT_STEP=$(cat "$STEP" 2>/dev/null || echo STARTING)"
  echo "Il service prosegue autonomamente e riprende dai chunk gia validi."
  sleep 1
  tail -n 15 "$LOG" 2>/dev/null || true
}

resume_mode() {
  mkdir -p "$STATE"
  chmod 700 "$STATE"
  exec >>"$LOG" 2>&1

  log "MH430 GitHub loader $VERSION avviato"
  log "PAYLOAD_REF=$PAYLOAD_REF"
  log "MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || true)"

  id="$(quick_identity | head -1 || true)"
  if [ -n "$id" ]; then
    printf '%s\n' "$id" > "$IDENTITY_FILE"
    log "HISTORICAL_IDENTITY=$id"
  else
    log "HISTORICAL_IDENTITY=NON_ANCORA_TROVATA"
  fi

  for f in $FILES; do
    download_one "$f" || { log "ERRORE download $f"; setstep "ERROR_DOWNLOAD_$f"; exit 21; }
  done

  B64="$STATE/universal.sh.xz.b64"
  XZ="$STATE/universal.sh.xz"
  TARGET="/root/MH430-UNIVERSAL-RECOVERY.sh"

  setstep "ASSEMBLE_B64"
  : > "$B64"
  for f in $FILES; do cat "$STATE/$f" >> "$B64"; done

  sz="$(wc -c < "$B64" | tr -d ' ')"
  sha="$(sha256sum "$B64" | awk '{print $1}')"
  log "B64 size=$sz sha=$sha"
  if [ "$sz" != "$EXPECTED_B64_SIZE" ] || [ "$sha" != "$EXPECTED_B64_SHA" ]; then
    log "ERRORE verifica B64: pulisco chunk e riparto"
    rm -f "$STATE"/p?? "$STATE"/t?? "$B64"
    setstep "ERROR_B64_RETRY"
    exit 23
  fi

  setstep "DECODE_XZ"
  base64 -d "$B64" > "$XZ.tmp"
  mv -f "$XZ.tmp" "$XZ"
  sz="$(wc -c < "$XZ" | tr -d ' ')"
  sha="$(sha256sum "$XZ" | awk '{print $1}')"
  log "XZ size=$sz sha=$sha"
  [ "$sz" = "$EXPECTED_XZ_SIZE" ] && [ "$sha" = "$EXPECTED_XZ_SHA" ] || { setstep "ERROR_XZ"; exit 25; }

  setstep "DECOMPRESS_SCRIPT"
  xz -dc "$XZ" > "$TARGET.tmp"
  sz="$(wc -c < "$TARGET.tmp" | tr -d ' ')"
  sha="$(sha256sum "$TARGET.tmp" | awk '{print $1}')"
  log "SCRIPT size=$sz sha=$sha"
  [ "$sz" = "$EXPECTED_SCRIPT_SIZE" ] && [ "$sha" = "$EXPECTED_SCRIPT_SHA" ] || { rm -f "$TARGET.tmp"; setstep "ERROR_SCRIPT_SHA"; exit 27; }

  setstep "SELFTEST"
  bash -n "$TARGET.tmp"
  selfout="$(bash "$TARGET.tmp" --selftest 2>&1)" || { printf '%s\n' "$selfout"; setstep "ERROR_SELFTEST"; exit 29; }
  printf '%s\n' "$selfout"
  printf '%s\n' "$selfout" | grep -q 'SELFTEST_OK'
  log "SELFTEST_OK verificato"

  mv -f "$TARGET.tmp" "$TARGET"
  chmod 700 "$TARGET"
  sync

  setstep "BOOTSTRAP_UNIVERSALE"
  log "Avvio bootstrap universale"

  DP18_SFTP_PASSWORD='mx33gf78' DP18_GITHUB_TOKEN="${DP18_GITHUB_TOKEN:-}" "$TARGET" --bootstrap
  rc=$?
  log "bootstrap universale rc=$rc"
  [ "$rc" -eq 0 ] || { setstep "ERROR_BOOTSTRAP_RC_$rc"; exit "$rc"; }

  setstep "HANDOFF_COMPLETATO"
  systemctl disable "$SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/multi-user.target.wants/$SERVICE"
  log "Handoff completato al recovery universale"
}

status_mode() {
  echo "LOADER_VERSION=$VERSION"
  echo "MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
  echo "HISTORICAL_IDENTITY=$(cat "$IDENTITY_FILE" 2>/dev/null || echo IN_RICERCA)"
  echo "CURRENT_STEP=$(cat "$STEP" 2>/dev/null || echo UNKNOWN)"
  systemctl is-active "$SERVICE" 2>/dev/null | sed 's/^/SERVICE=/' || true
  echo "=== LOG ==="
  tail -n 30 "$LOG" 2>/dev/null || true
}

case "${1:---install}" in
  --install) install_mode ;;
  --resume) resume_mode ;;
  --status) status_mode ;;
  *) echo "uso: $0 --install|--resume|--status"; exit 2 ;;
esac

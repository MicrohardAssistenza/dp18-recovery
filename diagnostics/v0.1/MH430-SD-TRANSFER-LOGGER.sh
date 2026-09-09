#!/bin/bash
set -Eeuo pipefail

VERSION="0.1"
SELF="/root/MH430-SD-TRANSFER-LOGGER.sh"
SERVICE="mh430-sd-transfer-logger.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE"
STATE="/var/lib/mh430-sd-transfer-logger"
LOG="$STATE/paypoint-foreground.log"
SUMMARY="$STATE/SUMMARY.txt"
DONE="$STATE/DONE"
EXPECTED_SHA="cac20f0f7eb0b3ef228b41947a8bfec936554002a7a0079fbf1e3ed14a99bde2"
MODE="${1:---bootstrap}"

say(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

bootstrap(){
  [ "$(id -u)" -eq 0 ] || { echo "ERRORE: root richiesto" >&2; exit 1; }
  mkdir -p "$STATE"; chmod 700 "$STATE"
  cp -f "$0" "$SELF"; chmod 700 "$SELF"

  cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=MH430 SD transfer logger v$VERSION
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SELF --run
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  systemctl restart "$SERVICE" >/dev/null 2>&1 &

  echo "MH430_SDLOGGER_PERSISTENTE_OK"
  echo "VERSION=$VERSION"
  echo "MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
  echo "LOG=$LOG"
  echo "Da questo punto SSH/VPN puo' cadere."
}

run_test(){
  mkdir -p "$STATE"; chmod 700 "$STATE"
  rm -f "$DONE" "$SUMMARY"
  : > "$LOG"

  exec >>"$LOG" 2>&1
  say "MH430 SD TRANSFER LOGGER v$VERSION"
  say "HOST=$(hostname) MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
  say "machine.name=$(cat /root/machine.name 2>/dev/null || true)"
  printf '[%s] machine.serial=' "$(date '+%F %T')"; od -An -tu4 -N4 /root/machine.serial 2>/dev/null || true

  F="/mhdata/UsbUpdate.mha"
  [ -f "$F" ] || { say "ERRORE: $F assente"; echo "RESULT=NO_MHA" > "$SUMMARY"; touch "$DONE"; exit 0; }
  ACTUAL="$(sha256sum "$F" | awk '{print $1}')"
  SIZE="$(stat -c %s "$F" 2>/dev/null || echo 0)"
  say "MHA_SIZE=$SIZE MHA_SHA=$ACTUAL"
  if [ "$ACTUAL" != "$EXPECTED_SHA" ]; then
    say "ERRORE: MHA non e' il DP18 3.12 ufficiale pulito"
    printf 'RESULT=WRONG_MHA\nMHA_SHA=%s\n' "$ACTUAL" > "$SUMMARY"
    touch "$DONE"
    exit 0
  fi

  say "Sospendo recovery DP18 e paypoint gestito da systemd"
  systemctl disable --now dp18-full-recovery.service >/dev/null 2>&1 || true
  systemctl stop paypoint.service >/dev/null 2>&1 || true
  sleep 1

  [ ! -e /proc/$(pidof paypointserver 2>/dev/null | awk '{print $1}') ] 2>/dev/null || true

  if command -v stdbuf >/dev/null 2>&1; then
    PP_CMD=(stdbuf -oL -eL /root/paypointserver)
  else
    PP_CMD=(/root/paypointserver)
  fi

  say "Avvio paypointserver locale in foreground/capture"
  (
    sleep 2
    say ">>> TRIGGER update-ready <<<"
    rm -f /tmp/uploads/update-ready
    touch /tmp/uploads/update-ready
    sync
  ) &

  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "${PP_CMD[@]}"
    PP_RC=$?
  else
    "${PP_CMD[@]}" &
    P=$!
    sleep 120
    kill "$P" >/dev/null 2>&1 || true
    wait "$P" >/dev/null 2>&1
    PP_RC=$?
  fi
  set -e

  say "Capture terminata RC=$PP_RC"
  READ_LINES="$(grep -Eic 'READ' "$LOG" 2>/dev/null || true)"
  READ200="$(grep -Eic 'READ[^0-9]*:?[^0-9]*200([^0-9]|$)' "$LOG" 2>/dev/null || true)"
  say "READ_LINES=$READ_LINES READ200=$READ200"

  {
    echo "RESULT=CAPTURED"
    echo "DATE=$(date -Is 2>/dev/null || date)"
    echo "HOST=$(hostname)"
    echo "MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
    echo "MHA_SHA=$ACTUAL"
    echo "MHA_SIZE=$SIZE"
    echo "PAYPOINT_RC=$PP_RC"
    echo "READ_LINES=$READ_LINES"
    echo "READ200=$READ200"
    echo "--- FIRST_READS ---"
    grep -Ei 'READ' "$LOG" 2>/dev/null | head -30 || true
    echo "--- LAST_READS ---"
    grep -Ei 'READ' "$LOG" 2>/dev/null | tail -30 || true
  } > "$SUMMARY"

  say "Ripristino paypoint.service normale; recovery DP18 resta sospesa"
  systemctl start paypoint.service >/dev/null 2>&1 || true
  touch "$DONE"
  sync
  say "DONE"
}

status(){
  echo "VERSION=$VERSION"
  echo "MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
  if [ -f "$DONE" ]; then echo "STATE=DONE"; else echo "STATE=RUNNING_OR_NOT_STARTED"; fi
  echo "=== SUMMARY ==="
  cat "$SUMMARY" 2>/dev/null || true
  echo "=== LOG TAIL ==="
  tail -80 "$LOG" 2>/dev/null || true
}

case "$MODE" in
  --bootstrap|--install) bootstrap ;;
  --run) run_test ;;
  --status) status ;;
  *) echo "uso: $0 [--bootstrap|--run|--status]"; exit 2 ;;
esac

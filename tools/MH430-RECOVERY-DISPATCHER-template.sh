#!/bin/bash
set -Eeuo pipefail

VERSION="0.5.0"
SELF="/usr/local/sbin/MH430-RECOVERY-DISPATCHER.sh"
SERVICE="mh430-recovery-dispatch.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE"
STATE="/var/lib/mh430-recovery-dispatch"
LOG="$STATE/dispatch.log"
IDENTITY="$STATE/identity"
CLASSFILE="$STATE/classification"
HIST_FW="$STATE/historical_mh430"
SOURCEFILE="$STATE/source"
TOKENFILE="$STATE/github_token"
SFTPFILE="$STATE/sftp_password"

DP18_REF="923c9251896d6d9cdb6543dff86f5b84cb05123a"
DP18_SHA="b0b75d758797b1c4584a3092304a82d952231141e89954a5f0c4201bc269ebb0"
LEGACY_URL="https://raw.githubusercontent.com/MicrohardAssistenza/dp18-recovery/main/recovery-single/v0.5.0/MH430-LEGACY-RECOVERY.sh"
LEGACY_SHA="__LEGACY_SHA__"

say(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
cleanup_dispatch_service(){
  systemctl disable "$SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/multi-user.target.wants/$SERVICE"
}

analyze_identity(){
  mkdir -p "$STATE"
  php -d open_basedir= -d date.timezone=UTC -r '
$dirs=array("/root/sent","/root/send","/root/delayedsend"); $rows=array();
foreach($dirs as $dir){if(!is_dir($dir))continue;foreach(glob($dir."/*.xml")?:array() as $f){$s=@file_get_contents($f);if($s===false)continue;if(!preg_match("/<(DP18|DP30|DP60|DD40)\\s+SerialNumber=[\"\\x27]([0-9]{5})[\"\\x27][^>]*TimeStamp=[\"\\x27]([^\"\\x27]+)[\"\\x27]/",$s,$m))continue;if($m[2]==="00000")continue;$fw="unknown";if(preg_match("/MH430:\\s*Ver\\.([0-9]+\\.[0-9]+)/",$s,$v))$fw=$v[1];$rows[]=array("model"=>$m[1],"serial"=>$m[2],"ts"=>$m[3],"fw"=>$fw,"file"=>$f);}}
if(!$rows){fwrite(STDERR,"Nessun Pardata storico non-zero trovato\n");exit(20);} usort($rows,function($a,$b){return strcmp($b["ts"],$a["ts"]);});
$pairs=array();foreach($rows as $r)$pairs[$r["model"]."-".$r["serial"]]=1;if(count($pairs)!==1){fwrite(STDERR,"Identita storiche multiple: ".implode(",",array_keys($pairs))."\n");exit(21);} $b=$rows[0];
$class=$b["model"]==="DP18"?"DP18":(preg_match("/^4\\./",$b["fw"])?"DDX":"LEGACY");
file_put_contents($argv[1],$b["model"]."-".$b["serial"]."\n");file_put_contents($argv[2],$class."\n");file_put_contents($argv[3],$b["fw"]."\n");file_put_contents($argv[4],$b["file"]."\n");
' "$IDENTITY" "$CLASSFILE" "$HIST_FW" "$SOURCEFILE"
}

install_mode(){
  [ "$(id -u)" -eq 0 ] || { echo 'ERRORE: root richiesto'; exit 1; }
  mkdir -p "$STATE"; chmod 700 "$STATE"
  systemctl disable --now mh430-github-loader.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/multi-user.target.wants/mh430-github-loader.service
  rm -f /etc/systemd/system/mh430-github-loader.service
  systemctl stop mh430-universal-recovery.service >/dev/null 2>&1 || true
  cp -f "$0" "$SELF"; chmod 700 "$SELF"
  umask 077
  printf '%s' "${MH430_SFTP_PASSWORD:-${DP18_SFTP_PASSWORD:-mx33gf78}}" > "$SFTPFILE"
  if [ -n "${MH430_GITHUB_TOKEN:-${DP18_GITHUB_TOKEN:-}}" ]; then printf '%s' "${MH430_GITHUB_TOKEN:-${DP18_GITHUB_TOKEN:-}}" > "$TOKENFILE"; fi
  cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=MH430 Recovery Dispatcher v$VERSION
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $SELF --resume
Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  systemctl restart "$SERVICE"
  echo "DISPATCHER_PERSISTENTE_OK"
  echo "DISPATCHER_VERSION=$VERSION"
  echo "MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
  for i in $(seq 1 12); do
    if [ -s "$IDENTITY" ]; then
      echo "HISTORICAL_IDENTITY=$(cat "$IDENTITY")"
      echo "CLASSIFICATION=$(cat "$CLASSFILE" 2>/dev/null || true)"
      echo "HISTORICAL_MH430=$(cat "$HIST_FW" 2>/dev/null || true)"
      break
    fi
    sleep 1
  done
  echo "Da questo punto il routing continua localmente anche se SSH/VPN cade."
  tail -n 12 "$LOG" 2>/dev/null || true
}

resume_mode(){
  mkdir -p "$STATE"; chmod 700 "$STATE"
  exec >>"$LOG" 2>&1
  say "MH430 recovery dispatcher v$VERSION"
  say "MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
  rm -f "$IDENTITY" "$CLASSFILE" "$HIST_FW" "$SOURCEFILE"
  analyze_identity
  id="$(tr -d '\r\n' < "$IDENTITY")"
  class="$(tr -d '\r\n' < "$CLASSFILE")"
  fw="$(tr -d '\r\n' < "$HIST_FW")"
  say "HISTORICAL_IDENTITY=$id"
  say "CLASSIFICATION=$class HISTORICAL_MH430=$fw"
  sftp="$(cat "$SFTPFILE")"
  token="$(cat "$TOKENFILE" 2>/dev/null || true)"
  case "$class" in
    DDX)
      say "SKIPPED_DDX: MH430 storico 4.x; nessuna modifica"
      cleanup_dispatch_service
      exit 0
      ;;
    DP18)
      tmp="/root/DP18-FULL-RECOVERY.sh.new"
      say "ROUTE $id -> DP18 FULL RECOVERY v1.13"
      curl -k -fL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 180 "https://raw.githubusercontent.com/MicrohardAssistenza/dp18-recovery/$DP18_REF/DP18-FULL-RECOVERY.sh" -o "$tmp"
      [ "$(sha256sum "$tmp" | awk '{print $1}')" = "$DP18_SHA" ] || { say 'ERRORE SHA DP18'; exit 31; }
      bash -n "$tmp"
      mv -f "$tmp" /root/DP18-FULL-RECOVERY.sh; chmod 700 /root/DP18-FULL-RECOVERY.sh
      cleanup_dispatch_service
      say "HANDOFF DP18 v1.13"
      exec env DP18_SFTP_PASSWORD="$sftp" DP18_GITHUB_TOKEN="$token" /root/DP18-FULL-RECOVERY.sh --bootstrap
      ;;
    LEGACY)
      tmp="/root/MH430-LEGACY-RECOVERY.sh.new"
      say "ROUTE $id -> LEGACY LEAN v0.5.0"
      curl -k -fL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 120 "$LEGACY_URL" -o "$tmp"
      [ "$(sha256sum "$tmp" | awk '{print $1}')" = "$LEGACY_SHA" ] || { say 'ERRORE SHA LEGACY LEAN'; exit 32; }
      bash -n "$tmp"
      mv -f "$tmp" /root/MH430-LEGACY-RECOVERY.sh; chmod 700 /root/MH430-LEGACY-RECOVERY.sh
      cleanup_dispatch_service
      say "HANDOFF LEGACY LEAN v0.5.0"
      exec env MH430_SFTP_PASSWORD="$sftp" MH430_GITHUB_TOKEN="$token" /root/MH430-LEGACY-RECOVERY.sh --bootstrap
      ;;
    *) say "ERRORE classificazione $class"; exit 33 ;;
  esac
}

status_mode(){
  echo "DISPATCHER_VERSION=$VERSION"
  echo "MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
  echo "HISTORICAL_IDENTITY=$(cat "$IDENTITY" 2>/dev/null || echo IN_RICERCA)"
  echo "CLASSIFICATION=$(cat "$CLASSFILE" 2>/dev/null || echo IN_RICERCA)"
  echo "HISTORICAL_MH430=$(cat "$HIST_FW" 2>/dev/null || echo IN_RICERCA)"
  echo '=== LOG ==='; tail -n 50 "$LOG" 2>/dev/null || true
}

case "${1:---install}" in
  --install|--bootstrap) install_mode ;;
  --resume) resume_mode ;;
  --status) status_mode ;;
  *) echo "uso: $0 [--bootstrap|--resume|--status]"; exit 2 ;;
esac

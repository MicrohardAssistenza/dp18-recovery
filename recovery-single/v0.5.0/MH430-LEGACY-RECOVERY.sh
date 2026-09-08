#!/bin/bash
set -Eeuo pipefail

# MH430 UNIVERSAL FULL RECOVERY
# Lean legacy engine: downloads ONLY the selected model firmware; DP18 routes to proven v1.13.
# Native DDX (historical MH430 4.x) is detected and never modified.
SCRIPT_VERSION="0.5.0-lean"
FIRMWARE_BASE="https://raw.githubusercontent.com/MicrohardAssistenza/dp18-recovery/main/recovery-single/v0.5.0/firmware"
SELF="/root/MH430-UNIVERSAL-RECOVERY.sh"
SERVICE="mh430-universal-recovery.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE"
STATE="/var/lib/mh430-universal-recovery"
PAYLOADS="$STATE/payloads"
LOG="$STATE/recovery.log"
PLAN="$STATE/plan.txt"
PLAN_READY="$STATE/plan.ready"
ARMED="$STATE/armed"
DONE="$STATE/DONE"
FAILED="$STATE/FAILED"
TARGET_MODEL_FILE="$STATE/target_model"
TARGET_SERIAL_FILE="$STATE/target_serial"
TARGET_FW_HIST_FILE="$STATE/historical_mh430"
TARGET_SOURCE_FILE="$STATE/historical_source"
CLASSIFICATION_FILE="$STATE/classification"
BASE_CONFIG="$STATE/base_config.txt"
EXPECTED_CONFIG="$STATE/expected_config.txt"
VERIFY_CONFIG="$STATE/verify_config.txt"
PRODUCTS_FILE="$STATE/products.tsv"
ORIGINAL_INFO="$STATE/original.info"
PATCH_SENT="$STATE/patched_firmware.sent"
SERIAL_PERSIST_OK="$STATE/serial_persistence.ok"
FINAL_SENT="$STATE/final_firmware.sent"
CONFIG_DONE="$STATE/config.done"
DDX_REMOVED="$STATE/ddx_removed.ok"
SECRET_FILE="$STATE/sftp_password"
GITHUB_TOKEN_FILE="$STATE/github_token"
GITHUB_REGISTRY_LAST="$STATE/github_registry.last"
GITHUB_REGISTRY_REPO="MicrohardAssistenza/dp18-recovery"
GITHUB_REGISTRY_WORKFLOW="registry-dispatch.yml"
MODE="${1:---bootstrap}"
DP18_REF="923c9251896d6d9cdb6543dff86f5b84cb05123a"
DP18_SCRIPT_SHA="b0b75d758797b1c4584a3092304a82d952231141e89954a5f0c4201bc269ebb0"

DP30_SHA="ab4643f0641a825285bf2595ea813018468f3e93b31395818ce9e30544e8687f"
DP60_SHA="459af7c2912179b07265961000152759aafef81c70977def6b7eb9f048f58466"
DD40_SHA="7d0577fd4abd8a50ca2d2801db18c33bfb39a2789d35fdf18bff63f9c58dc2a8"

say() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERRORE: comando richiesto non trovato: $1" >&2; exit 1; }; }
require_root() { [ "$(id -u)" -eq 0 ] || { echo "ERRORE: eseguire come root." >&2; exit 1; }; }
read_machine_name() { [ -r /root/machine.name ] && tr -d '\000\r\n ' </root/machine.name || true; }
read_machine_serial() { od -An -tu4 -N4 /root/machine.serial 2>/dev/null | tr -d ' \r\n'; }
wait_paypoint() { local t="${1:-300}" i; for i in $(seq 1 "$t"); do systemctl is-active paypoint >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
wait_marker_gone() { local marker="$1" t="${2:-180}" i; for i in $(seq 1 "$t"); do [ ! -e "$marker" ] && return 0; sleep 1; done; return 1; }

cleanup_service() {
  systemctl disable "$SERVICE" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/multi-user.target.wants/$SERVICE" "$SERVICE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

fatal() {
  local msg="$*"
  mkdir -p "$STATE" 2>/dev/null || true
  printf '%s ERROR %s\n' "$(date -Is 2>/dev/null || date)" "$msg" >> "$LOG" 2>/dev/null || true
  printf 'RESULT=FAILED\nDATE=%s\nERROR=%s\n' "$(date -Is 2>/dev/null || date)" "$msg" > "$FAILED" 2>/dev/null || true
  echo "ERRORE: $msg" >&2
  if [ "$MODE" = "--resume" ]; then exit 0; fi
  exit 1
}

capture_original_info() {
  [ -f "$ORIGINAL_INFO" ] && return 0
  {
    echo "STARTED_AT=$(date -Is 2>/dev/null || date)"
    echo "ORIGINAL_HOSTNAME=$(hostname 2>/dev/null || true)"
    echo "ORIGINAL_MACHINE_NAME=$(read_machine_name)"
    echo "ORIGINAL_MACHINE_SERIAL=$(read_machine_serial || true)"
    echo "MAC_ETH0=$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
    echo "RPI_SERIAL=$(awk -F': ' '/^Serial/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  } > "$ORIGINAL_INFO"
}

model_constants() {
  local m="$1"
  case "$m" in
    DP30)
      FW_VERSION="3.12"; OFFICIAL_SHA="$DP30_SHA"; OFFICIAL_SIZE=236776
      HOOK_OFF=$((0x0810)); HOOK_ORIG="00b5d9b0"; HOOK_BRANCH_HEX="39f070b8"
      SHELL_OFF=$((0x398f4)); SERIAL_PATCH_OFF=$((0x39924)); CONFIG_RAM_HEX="6c690010"; SAVE_HEX="95ad0000"; RESUME_HEX="c9070000"
      SHELL_B64="ALXZsC3pHxAISwlKnGiUQgjQmmAYRt/4HMDgRwAoAdECS5xgvegfEN/4DPBsaQAQ776t3pWtAADJBwAA"
      FALLBACK_CONTRAST=60
      ;;
    DP60)
      FW_VERSION="2.13"; OFFICIAL_SHA="$DP60_SHA"; OFFICIAL_SIZE=277060
      HOOK_OFF=$((0x2358)); HOOK_ORIG="90b5d9b0"; HOOK_BRANCH_HEX="41f07ab9"
      SHELL_OFF=$((0x43650)); SERIAL_PATCH_OFF=$((0x43680)); CONFIG_RAM_HEX="40710010"; SAVE_HEX="f1030100"; RESUME_HEX="11230000"
      SHELL_B64="kLXZsC3pHxAISwlKnGiUQgjQmmAYRt/4HMDgRwAoAdECS5xgvegfEN/4DPBAcQAQ776t3vEDAQARIwAA"
      FALLBACK_CONTRAST=48
      ;;
    DD40)
      FW_VERSION="2.13"; OFFICIAL_SHA="$DD40_SHA"; OFFICIAL_SIZE=293848
      HOOK_OFF=$((0x258c)); HOOK_ORIG="90b5d9b0"; HOOK_BRANCH_HEX="45f02ab9"
      SHELL_OFF=$((0x477e4)); SERIAL_PATCH_OFF=$((0x47814)); CONFIG_RAM_HEX="a46f0010"; SAVE_HEX="6d180100"; RESUME_HEX="45250000"
      SHELL_B64="kLXZsC3pHxAISwlKnGiUQgjQmmAYRt/4HMDgRwAoAdECS5xgvegfEN/4DPCkbwAQ776t3m0YAQBFJQAA"
      FALLBACK_CONTRAST=45
      ;;
    *) fatal "modello legacy non supportato: $m" ;;
  esac
}

official_path() { echo "$PAYLOADS/UsbUpdate_${1}_DUREX.$FW_VERSION.mha"; }

extract_embedded_bundle() {
  # v0.5.0 lean: no universal embedded bundle.
  return 0
}

extract_official_payload() {
  local model="$1" out src filename url
  model_constants "$model"
  out="$(official_path "$model")"
  mkdir -p "$PAYLOADS"
  if [ -f "$out" ] && [ "$(sha256sum "$out" | awk '{print $1}')" = "$OFFICIAL_SHA" ]; then return 0; fi
  src="${MH430_PAYLOAD_SOURCE_DIR:-}"
  filename="UsbUpdate_${model}_DUREX.$FW_VERSION.mha"
  if [ -n "$src" ] && [ -f "$src/$filename" ]; then
    say "Copio firmware ufficiale $model $FW_VERSION dalla sorgente locale di self-test"
    cp -f "$src/$filename" "$out.new"
  else
    url="$FIRMWARE_BASE/$filename"
    say "Scarico SOLO firmware ufficiale $model $FW_VERSION da GitHub"
    curl -k -fL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 180 "$url" -o "$out.new" \
      || fatal "download firmware $model $FW_VERSION fallito"
  fi
  [ "$(sha256sum "$out.new" | awk '{print $1}')" = "$OFFICIAL_SHA" ] || fatal "hash firmware $model $FW_VERSION non valido"
  [ "$(wc -c < "$out.new" | tr -d ' ')" = "$OFFICIAL_SIZE" ] || fatal "dimensione firmware $model $FW_VERSION inattesa"
  mv -f "$out.new" "$out"
  chmod 600 "$out"
}

hex_to_bytes() { local h="$1" o=""; while [ -n "$h" ]; do o="$o\\x${h:0:2}"; h="${h:2}"; done; printf '%b' "$o"; }

make_serial_mha() {
  local model="$1" pad="$2" num="$3" out official orig_hook blank shell_hex rb_hook rb_serial rb_cfg size b0 b1 b2 b3
  model_constants "$model"
  extract_official_payload "$model"
  official="$(official_path "$model")"
  out="$PAYLOADS/UsbUpdate_${model}_${FW_VERSION}_SERIAL_${pad}.mha"
  cp -f "$official" "$out"

  orig_hook="$(od -An -tx1 -N4 -j "$HOOK_OFF" "$out" | tr -d ' \n')"
  [ "$orig_hook" = "$HOOK_ORIG" ] || fatal "hook $model inatteso a $HOOK_OFF: $orig_hook"

  blank="$(od -An -v -tx1 -N60 -j "$SHELL_OFF" "$out" | tr -d ' \n0')"
  [ -z "$blank" ] || fatal "code-cave $model non vuoto nel firmware ufficiale"

  hex_to_bytes "$HOOK_BRANCH_HEX" | dd of="$out" bs=1 seek="$HOOK_OFF" conv=notrunc 2>/dev/null
  printf '%s' "$SHELL_B64" | base64 -d | dd of="$out" bs=1 seek="$SHELL_OFF" conv=notrunc 2>/dev/null

  b0=$(( num & 255 )); b1=$(( (num >> 8) & 255 )); b2=$(( (num >> 16) & 255 )); b3=$(( (num >> 24) & 255 ))
  printf "\\$(printf '%03o' "$b0")\\$(printf '%03o' "$b1")\\$(printf '%03o' "$b2")\\$(printf '%03o' "$b3")" \
    | dd of="$out" bs=1 seek="$SERIAL_PATCH_OFF" conv=notrunc 2>/dev/null
  sync

  rb_hook="$(od -An -tx1 -N4 -j "$HOOK_OFF" "$out" | tr -d ' \n')"
  rb_serial="$(od -An -tu4 -N4 -j "$SERIAL_PATCH_OFF" "$out" | tr -d ' \n')"
  rb_cfg="$(od -An -tx1 -N4 -j $((SHELL_OFF+48-4)) "$out" 2>/dev/null | tr -d ' \n')"
  size="$(wc -c < "$out" | tr -d ' ')"
  [ "$rb_hook" = "$HOOK_BRANCH_HEX" ] || fatal "branch patch $model non applicato"
  [ "$rb_serial" = "$num" ] || fatal "readback matricola $model fallito: $rb_serial != $num"
  [ "$size" = "$OFFICIAL_SIZE" ] || fatal "dimensione MHA patchato $model inattesa: $size"
  echo "$out"
}

# The serial literal is 0x30 bytes into the 60-byte shell. This independent
# validator protects against future changes to the embedded shell template.
verify_shell_template() {
  local model="$1" tmp cfg serial save resume
  model_constants "$model"
  tmp="$(mktemp)"
  printf '%s' "$SHELL_B64" | base64 -d > "$tmp"
  [ "$(wc -c < "$tmp" | tr -d ' ')" = 60 ] || { rm -f "$tmp"; return 1; }
  cfg="$(od -An -tx1 -N4 -j 44 "$tmp" | tr -d ' \n')"
  serial="$(od -An -tx1 -N4 -j 48 "$tmp" | tr -d ' \n')"
  save="$(od -An -tx1 -N4 -j 52 "$tmp" | tr -d ' \n')"
  resume="$(od -An -tx1 -N4 -j 56 "$tmp" | tr -d ' \n')"
  [ "$cfg" = "$CONFIG_RAM_HEX" ] || { rm -f "$tmp"; return 1; }
  [ "$serial" = "efbeadde" ] || { rm -f "$tmp"; return 1; }
  [ "$save" = "$SAVE_HEX" ] || { rm -f "$tmp"; return 1; }
  [ "$resume" = "$RESUME_HEX" ] || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

remove_ddx_package() {
  [ -e "$DDX_REMOVED" ] && { say "Bonifica pacchetto DDX gia' eseguita"; return 0; }
  say "Bonifica pacchetto USB Update DDX"
  local pkgs p dirs
  pkgs="$(pacman -Qq 2>/dev/null | grep -Ei 'usbupdate.*ddx|ddx.*usbupdate' || true)"
  if [ -n "$pkgs" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      echo "Rimuovo package pacman: $p"
      pacman -Rdd --noconfirm "$p" >/dev/null 2>&1 || echo "WARN: pacman non ha rimosso $p; bonifico metadata residui"
    done <<EOF
$pkgs
EOF
  fi
  find /var/lib/pacman/local -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
    | grep -Ei 'usbupdate.*ddx|ddx.*usbupdate' \
    | while IFS= read -r p; do echo "Rimuovo metadata DDX residuo: $p"; rm -rf -- "$p"; done || true
  find /var/cache/pacman/pkg -maxdepth 1 -type f 2>/dev/null \
    | grep -Ei 'usbupdate.*ddx|ddx.*usbupdate' \
    | while IFS= read -r p; do echo "Rimuovo cache DDX: $p"; rm -f -- "$p"; done || true
  if find /var/lib/pacman/local -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -Eqi 'usbupdate.*ddx|ddx.*usbupdate'; then
    fatal "metadata DDX ancora presente in /var/lib/pacman/local"
  fi
  date -Is > "$DDX_REMOVED"
  say "Bonifica DDX completata"
}

analyze_history_and_config() {
  [ -e "$PLAN_READY" ] && return 0
  local phpfile="$STATE/analyze.php"
  mkdir -p "$STATE"
  cat > "$phpfile" <<'PHP'
<?php
$dirs=array('/root/sent','/root/send','/root/delayedsend');
$rows=array();
foreach($dirs as $dir){
  if(!is_dir($dir)) continue;
  foreach(glob($dir.'/*.xml') ?: array() as $f){
    $s=@file_get_contents($f); if($s===false) continue;
    if(!preg_match('/<(DP18|DP30|DP60|DD40)\\s+SerialNumber=["\']([0-9]{5})["\'][^>]*TimeStamp=["\']([^"\']+)["\']/', $s,$m)) continue;
    if($m[2]==='00000') continue;
    $fw='unknown'; if(preg_match('/MH430:\\s*Ver\\.([0-9]+\\.[0-9]+)/',$s,$v)) $fw=$v[1];
    $rows[]=array('model'=>$m[1],'serial'=>$m[2],'ts'=>$m[3],'fw'=>$fw,'file'=>$f,'xml'=>$s);
  }
}
if(!$rows){fwrite(STDERR,"Nessun Pardata storico non-zero trovato\n"); exit(20);} 
usort($rows,function($a,$b){return strcmp($b['ts'],$a['ts']);});
$pairs=array(); foreach($rows as $r) $pairs[$r['model'].'-'.$r['serial']]=1;
if(count($pairs)!==1){fwrite(STDERR,"Identita storiche multiple: ".implode(',',array_keys($pairs))."\n"); exit(21);} 
$best=$rows[0]; $model=$best['model']; $serial=$best['serial'];
$evidence=0; foreach($rows as $r) if($r['model']===$model && $r['serial']===$serial) $evidence++;
file_put_contents($argv[1],$model."\n"); file_put_contents($argv[2],$serial."\n"); file_put_contents($argv[3],$best['fw']."\n"); file_put_contents($argv[4],$best['file']."\n");
if($model==='DP18'){
  file_put_contents($argv[8],"DP18\n");
  $plan="================================================\nRECOVERY LEGACY - PIANO PRIMA DEL FLASH\n================================================\n";
  $plan.="Modello storico    : $model\nMatricola          : $serial\nMH430 storico      : {$best['fw']}\nPardata coerenti   : $evidence\nUltimo Pardata     : {$best['ts']}\nFile evidenza      : {$best['file']}\n\n";
  $plan.="Classificazione    : DP18\nAzione             : NON ARMATO - usare DP18 FULL RECOVERY v1.13\n";
  file_put_contents($argv[7],$plan); exit(0);
}
if(preg_match('/^4\./',$best['fw'])){
  file_put_contents($argv[8],"DDX\n");
  $plan="================================================\nRECOVERY LEGACY - PIANO PRIMA DEL FLASH\n================================================\n";
  $plan.="Modello storico    : $model\nMatricola          : $serial\nMH430 storico      : {$best['fw']}\nPardata coerenti   : $evidence\nUltimo Pardata     : {$best['ts']}\nFile evidenza      : {$best['file']}\n\n";
  $plan.="Classificazione    : DDX NATIVO (MH430 4.x)\nAzione             : NON MODIFICARE firmware/configurazione\nRegistro GitHub    : SKIPPED_DDX\n";
  file_put_contents($argv[7],$plan); exit(0);
}
file_put_contents($argv[8],"LEGACY\n");
$config=''; foreach(array('/mhdata/'.$model.'Config.txt','/root/'.$model.'Config.txt') as $c){if(is_file($c)){ $config=$c; break; }}
if(!$config){fwrite(STDERR,"Config storico esatto $model non trovato\n"); exit(22);} 
$cfg=@file_get_contents($config); if($cfg===false){fwrite(STDERR,"Config illeggibile\n"); exit(23);} 
if(strpos($cfg,'[Products]')===false || strpos($cfg,'[Network]')===false){fwrite(STDERR,"Config privo di sezioni Products/Network\n"); exit(24);} 
preg_match_all('/^product-size_[0-9]+=([0-9]+)$/m',$cfg,$mm); $sizes=count($mm[0]);
preg_match_all('/^product-width_[0-9]+=([0-9]+)$/m',$cfg,$mm); $widths=count($mm[0]);
$minSizes=array('DP30'=>30,'DP60'=>50,'DD40'=>42); $minWidths=array('DP30'=>30,'DP60'=>45,'DD40'=>42);
if($sizes<$minSizes[$model] || $widths<$minWidths[$model]){fwrite(STDERR,"Geometria insufficiente: size=$sizes width=$widths\n");exit(25);} 
$contrast=''; if(preg_match('/^screen-contrast=([0-9]+)$/m',$cfg,$c)) $contrast=$c[1];
$products=array();
foreach($rows as $r){
  if($r['model']!==$model || $r['serial']!==$serial) continue;
  if(!preg_match_all('/<Product\\s+([^>]*)>(.*?)<\\/Product>/s',$r['xml'],$pm,PREG_SET_ORDER)) continue;
  foreach($pm as $p){
    $attrs=$p[1]; $body=$p[2];
    if(!preg_match('/\\bid=["\']([0-9]+)["\']/',$attrs,$idM)) continue; $id=(int)$idM[1];
    if(!isset($products[$id])) $products[$id]=array('id'=>$id,'name'=>'','price'=>'','ts'=>$r['ts'],'source'=>$r['file']);
    if($products[$id]['name']==='' && preg_match('/\\bDescr=["\']([^"\']*)["\']/',$attrs,$nM)) $products[$id]['name']=html_entity_decode($nM[1],ENT_QUOTES,'UTF-8');
    if($products[$id]['price']===''){
      $amount=0; $count=0;
      if(preg_match('/<StandardTime\\s+[^>]*Amount=["\']([0-9]+)["\'][^>]*Count=["\']([0-9]+)["\']/', $body,$st)){$amount=(int)$st[1];$count=(int)$st[2];}
      if($count<=0 && preg_match('/\\bAmount=["\']([0-9]+)["\']/',$attrs,$aM) && preg_match('/\\bCount=["\']([0-9]+)["\']/',$attrs,$ctM)){$amount=(int)$aM[1];$count=(int)$ctM[1];}
      if($count>0 && $amount>0) $products[$id]['price']=(string)round($amount/$count);
    }
  }
}
ksort($products);
copy($config,$argv[5]);
$out=''; foreach($products as $p) if($p['name']!=='' || $p['price']!=='') $out.=$p['id']."\t".$p['price']."\t".str_replace(array("\t","\r","\n"),' ',$p['name'])."\t".$p['ts']."\t".$p['source']."\n";
file_put_contents($argv[6],$out);
$fallback=array('DP30'=>60,'DP60'=>48,'DD40'=>45); if($contrast==='' || (int)$contrast<0 || (int)$contrast>100) $contrast=(string)$fallback[$model];
$ddx=array(); exec("pacman -Qq 2>/dev/null | grep -Ei 'usbupdate.*ddx|ddx.*usbupdate'",$ddx);
$ddxMeta=array(); exec("find /var/lib/pacman/local -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -Ei 'usbupdate.*ddx|ddx.*usbupdate'",$ddxMeta);
$plan="================================================\nRECOVERY LEGACY - PIANO PRIMA DEL FLASH\n================================================\n";
$plan.="Modello storico    : $model\nMatricola          : $serial\nMH430 storico      : {$best['fw']}\nPardata coerenti   : $evidence\nUltimo Pardata     : {$best['ts']}\nFile evidenza      : {$best['file']}\n\n";
$plan.="Config autorevole  : $config\nContrasto preservato: $contrast\nProfondita presenti : $sizes\nLarghezze presenti  : $widths\nProdotti storici    : ".count($products)."\n\n";
$target=array('DP30'=>'DP30 3.12','DP60'=>'DP60 2.13','DD40'=>'DD40 2.13');
$plan.="Installeremo       : $model-$serial\nFirmware target    : {$target[$model]}\nMatricola EEPROM   : $serial\nConfig finale      : base storica + rete SFTP + eventuale riparazione campi mancanti\nTrigger config     : /tmp/uploads/config-ready\n";
$plan.="Pacchetto DDX      : ".($ddx?implode(',',$ddx):'non registrato in pacman')."\n";
$plan.="Metadata DDX       : ".($ddxMeta?implode(',',$ddxMeta):'non rilevati in /var/lib/pacman/local')."\n";
$plan.="Azione DDX         : bonifica pacman/local + cache prima del flash\n";
file_put_contents($argv[7],$plan);
?>
PHP
  php -d open_basedir= -d date.timezone=UTC "$phpfile" \
    "$TARGET_MODEL_FILE" "$TARGET_SERIAL_FILE" "$TARGET_FW_HIST_FILE" "$TARGET_SOURCE_FILE" "$BASE_CONFIG" "$PRODUCTS_FILE" "$PLAN" "$CLASSIFICATION_FILE" \
    || fatal "preflight legacy fallito: nessuna modifica eseguita"
  [ -f "$BASE_CONFIG" ] && chmod 600 "$BASE_CONFIG" 2>/dev/null || true
  [ -f "$PRODUCTS_FILE" ] && chmod 600 "$PRODUCTS_FILE" 2>/dev/null || true
}

prepare_prearm() {
  [ -e "$PLAN_READY" ] && return 0
  analyze_history_and_config
  local class model fwsha cfghash
  class="$(tr -d '\r\n ' < "$CLASSIFICATION_FILE" 2>/dev/null || true)"
  case "$class" in
    DP18)
      date -Is > "$PLAN_READY"
      return 0
      ;;
    DDX)
      registry_dispatch SKIPPED_DDX || true
      date -Is > "$PLAN_READY"
      return 0
      ;;
    LEGACY)
      model="$(tr -d '\r\n ' < "$TARGET_MODEL_FILE")"
      extract_official_payload "$model"
      prepare_expected_config
      model_constants "$model"
      fwsha="$(sha256sum "$(official_path "$model")" | awk '{print $1}')"
      cfghash="$(sha256sum "$EXPECTED_CONFIG" | awk '{print $1}')"
      {
        echo
        echo "Firmware payload   : VERIFICATO SHA256=$fwsha"
        echo "Config finale      : PREPARATO SHA256=$cfghash"
        echo "Geometria finale   : VERIFICATA INVARIATA"
        echo "Stato pre-arm      : PRONTO; nessun flash ancora eseguito"
      } >> "$PLAN"
      date -Is > "$PLAN_READY"
      ;;
    *) fatal "classificazione preflight inattesa: ${class:-vuota}" ;;
  esac
}

prepare_expected_config() {
  [ -f "$EXPECTED_CONFIG" ] && return 0
  local model pad sftp_password fallback
  model="$(tr -d '\r\n ' < "$TARGET_MODEL_FILE")"; pad="$(tr -d '\r\n ' < "$TARGET_SERIAL_FILE")"
  model_constants "$model"; fallback="$FALLBACK_CONTRAST"
  [ -r "$SECRET_FILE" ] || fatal "password SFTP non disponibile"
  sftp_password="$(cat "$SECRET_FILE")"
  php -d open_basedir= -d date.timezone=UTC -r '
function section($s,$name){$p="/(?ms)^\\[".preg_quote($name,"/")."\\]\\R.*?(?=^\\[|\\z)/";return preg_match($p,$s,$m)?$m[0]:null;}
function getkey($s,$sec,$key){$b=section($s,$sec);if($b===null)return null;if(preg_match("/^".preg_quote($key,"/")."=(.*)$/m",$b,$m))return $m[1];return null;}
function setkey($s,$sec,$key,$val){$p="/(?ms)^\\[".preg_quote($sec,"/")."\\]\\R.*?(?=^\\[|\\z)/";if(!preg_match($p,$s,$m,PREG_OFFSET_CAPTURE)){fwrite(STDERR,"missing section $sec\\n");exit(40);} $b=$m[0][0];$off=$m[0][1];$line=$key."=".$val;if(preg_match("/^".preg_quote($key,"/")."=.*$/m",$b))$b=preg_replace("/^".preg_quote($key,"/")."=.*$/m",$line,$b,1);else $b=rtrim($b,"\\r\\n")."\\n".$line."\\n";return substr($s,0,$off).$b.substr($s,$off+strlen($m[0][0]));}
$s=file_get_contents($argv[1]);$prod=$argv[2];$pwd=$argv[3];$fallback=(int)$argv[4];
$c=getkey($s,"General","screen-contrast");if($c===null || !preg_match("/^[0-9]+$/",$c) || (int)$c>100)$s=setkey($s,"General","screen-contrast",(string)$fallback);
$net=array("server-protocol"=>"sftp","server-port"=>"22","server-address"=>"vnd.microhard.it","server-username"=>"uploads","server-password"=>$pwd,"alarm-email"=>"","transmission-interval-hours"=>"24","transmission-time-year"=>"26","transmission-time-month"=>"9","transmission-time-day"=>"5","transmission-time-hh"=>"1","transmission-time-mm"=>"0");foreach($net as $k=>$v)$s=setkey($s,"Network",$k,$v);
foreach(file($prod,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES)?:array() as $line){$p=explode("\t",$line,5);$id=$p[0];$price=$p[1]??"";$name=$p[2]??"";$nk="product-name_".$id;$cur=getkey($s,"Products",$nk);if($name!=="" && ($cur===null || trim($cur)==="" || preg_match("/^(Nome Vuoto!!!|Prodotto [0-9]+)$/i",trim($cur))))$s=setkey($s,"Products",$nk,$name);
  if($price!=="" && ctype_digit($price) && (int)$price>0){$b=section($s,"Products");$hasPositive=false;if($b!==null && preg_match_all("/^product-price-(?:normal|happy)_".preg_quote($id,"/")."_[0-9]+_[0-9]+=([0-9]+)$/m",$b,$mm)){foreach($mm[1] as $v)if((int)$v>0){$hasPositive=true;break;}}if(!$hasPositive && $b!==null){$b2=preg_replace_callback("/^(product-price-(?:normal|happy)_".preg_quote($id,"/")."_[0-9]+_[0-9]+)=([0-9]+)$/m",function($m)use($price){return $m[1]."=".$price;},$b);$sp="/(?ms)^\\[Products\\]\\R.*?(?=^\\[|\\z)/";preg_match($sp,$s,$sm,PREG_OFFSET_CAPTURE);$s=substr($s,0,$sm[0][1]).$b2.substr($s,$sm[0][1]+strlen($sm[0][0]));}}
}
file_put_contents($argv[5],$s);
' "$BASE_CONFIG" "$PRODUCTS_FILE" "$sftp_password" "$fallback" "$EXPECTED_CONFIG" || fatal "costruzione Config finale fallita"

  # Geometry must be byte-for-byte identical key/value data versus the saved historical config.
  grep -E '^product-(size|width)_[0-9]+=' "$BASE_CONFIG" | sort > "$STATE/geom.base"
  grep -E '^product-(size|width)_[0-9]+=' "$EXPECTED_CONFIG" | sort > "$STATE/geom.expected"
  cmp -s "$STATE/geom.base" "$STATE/geom.expected" || fatal "la costruzione Config ha alterato size/width: BLOCCO"
}

trigger_update() {
  local src="$1" label="$2" tmp="/mhdata/UsbUpdate.mha.new.$$" i
  wait_paypoint 300 || fatal "paypoint.service non attivo per update"
  [ -f "$src" ] || fatal "MHA non trovato: $src"
  say "MH430 update: $label"
  cp -f "$src" "$tmp"; sync; mv -f "$tmp" /mhdata/UsbUpdate.mha; sync
  rm -f /tmp/uploads/update-ready; touch /tmp/uploads/update-ready; sync
  for i in $(seq 1 180); do [ ! -e /tmp/uploads/update-ready ] && { echo "update-ready consumato dalla MH430"; return 0; }; sleep 1; done
  fatal "timeout: update-ready non consumato ($label)"
}

trigger_empty_mha() {
  local i
  wait_paypoint 300 || fatal "paypoint.service non attivo per reboot MH430"
  say "Forzo reboot MH430 con MHA vuoto"
  : > /mhdata/UsbUpdate.mha; sync; rm -f /tmp/uploads/update-ready; touch /tmp/uploads/update-ready; sync
  for i in $(seq 1 180); do [ ! -e /tmp/uploads/update-ready ] && { echo "MHA vuoto consumato dalla MH430"; return 0; }; sleep 1; done
  fatal "timeout: MHA vuoto non consumato"
}

wait_target_identity() {
  local model="$1" num="$2" timeout="${3:-900}" i n s
  for i in $(seq 1 "$timeout"); do
    n="$(read_machine_name)"; s="$(read_machine_serial || true)"
    [ "$n" = "$model" ] && [ "$s" = "$num" ] && return 0
    sleep 1
  done
  return 1
}

ensure_target_firmware_and_serial() {
  local model pad num current_name current_serial patched
  model="$(tr -d '\r\n ' < "$TARGET_MODEL_FILE")"; pad="$(tr -d '\r\n ' < "$TARGET_SERIAL_FILE")"; num=$((10#$pad))
  current_name="$(read_machine_name)"; current_serial="$(read_machine_serial || true)"
  if [ "$current_name" = "$model" ] && [ "$current_serial" = "$num" ]; then say "Modello e matricola gia' corretti: $model-$pad"; return 0; fi
  case "$current_serial" in ''|*[!0-9]*) fatal "machine.serial illeggibile";; esac
  [ "$current_serial" = "0" ] || fatal "matricola corrente $current_serial diversa dal target $num: non sovrascrivo"
  extract_official_payload "$model"
  patched="$(make_serial_mha "$model" "$pad" "$num")"
  if [ ! -e "$PATCH_SENT" ]; then
    date -Is > "$PATCH_SENT"
    trigger_update "$patched" "conversione a $model $FW_VERSION + matricola $pad"
    say "Firmware patchato consegnato; eventuale reboot Raspberry e' gestito da systemd"
  else
    say "Firmware patchato gia' richiesto; attendo identita target $model-$pad"
  fi
  wait_target_identity "$model" "$num" 900 || fatal "target $model-$pad non comparso dopo firmware patchato"
  say "Conversione riuscita: Raspberry vede $model-$pad"
}

confirm_serial_persistence() {
  local model pad num
  [ -e "$SERIAL_PERSIST_OK" ] && { say "Persistenza EEPROM gia' confermata"; return 0; }
  model="$(tr -d '\r\n ' < "$TARGET_MODEL_FILE")"; pad="$(tr -d '\r\n ' < "$TARGET_SERIAL_FILE")"; num=$((10#$pad))
  wait_target_identity "$model" "$num" 30 || fatal "identita target assente prima del test EEPROM"
  say "Matricola $pad visibile; confermo persistenza EEPROM con reboot MH430"
  sleep 10; trigger_empty_mha; sleep 45
  wait_target_identity "$model" "$num" 300 || fatal "matricola $pad persa dopo reboot MH430"
  date -Is > "$SERIAL_PERSIST_OK"
  say "Persistenza EEPROM confermata: $model-$pad"
}

ensure_final_official() {
  local model pad num official
  model="$(tr -d '\r\n ' < "$TARGET_MODEL_FILE")"; pad="$(tr -d '\r\n ' < "$TARGET_SERIAL_FILE")"; num=$((10#$pad))
  model_constants "$model"; extract_official_payload "$model"; official="$(official_path "$model")"
  if [ ! -e "$FINAL_SENT" ]; then
    trigger_update "$official" "firmware finale ufficiale $model $FW_VERSION"
    date -Is > "$FINAL_SENT"
    say "Firmware ufficiale pulito consegnato"
  else
    say "Firmware finale ufficiale gia' richiesto; non ripeto il flash"
  fi
  wait_target_identity "$model" "$num" 900 || fatal "identita $model-$pad assente dopo firmware finale"
  wait_paypoint 300 || fatal "paypoint non attivo dopo firmware finale"
}

request_config_backup() {
  local dest="$1" tag="$2" model config i
  model="$(tr -d '\r\n ' < "$TARGET_MODEL_FILE")"; config="/mhdata/${model}Config.txt"
  wait_paypoint 300 || fatal "paypoint non attivo per backup Config"
  if [ -e /tmp/uploads/config-needed ]; then wait_marker_gone /tmp/uploads/config-needed 60 || fatal "config-needed precedente non consumato"; fi
  rm -f /tmp/config-file-ready; touch /tmp/uploads/config-needed; sync
  for i in $(seq 1 180); do
    if [ ! -e /tmp/uploads/config-needed ] && [ -e /tmp/config-file-ready ]; then
      sleep 2; sync
      if [ -f "$config" ] && grep -q '^;;BEGIN' "$config" && grep -q '^\[Products\]' "$config" && grep -q '^\[Network\]' "$config"; then
        cp -a "$config" "$dest"; rm -f /tmp/config-file-ready; say "Backup Config reale acquisito dalla MH430 ($tag)"; return 0
      fi
    fi
    sleep 1
  done
  fatal "timeout: Config $model non restituito dalla MH430 ($tag)"
}

verify_config() {
  local expected="$1" actual="$2" e a
  grep -E '^(screen-contrast|product-(name|size|width|price-normal|price-happy|code|flag)_[^=]+|host-method|host-ip|host-gateway|host-dns|host-netmask|server-protocol|server-port|server-address|server-username|server-password|alarm-email|transmission-[^=]+)=' "$expected" | sort > "$STATE/verify.expected.keys"
  grep -E '^(screen-contrast|product-(name|size|width|price-normal|price-happy|code|flag)_[^=]+|host-method|host-ip|host-gateway|host-dns|host-netmask|server-protocol|server-port|server-address|server-username|server-password|alarm-email|transmission-[^=]+)=' "$actual" | sort > "$STATE/verify.actual.keys"
  if ! cmp -s "$STATE/verify.expected.keys" "$STATE/verify.actual.keys"; then
    echo "=== DIFFERENZE CONFIG ==="
    diff -u "$STATE/verify.expected.keys" "$STATE/verify.actual.keys" | head -120 || true
    return 1
  fi
  return 0
}

apply_configuration() {
  [ -e "$CONFIG_DONE" ] && { say "Configurazione legacy gia' applicata e verificata"; return 0; }
  local model config tmp
  model="$(tr -d '\r\n ' < "$TARGET_MODEL_FILE")"; config="/mhdata/${model}Config.txt"; tmp="$config.new.$$"
  prepare_expected_config
  say "Ripristino Config $model: preservo geometria/contrasto e applico SOLO config-ready"
  cp -f "$EXPECTED_CONFIG" "$tmp"; sync; mv -f "$tmp" "$config"; sync
  rm -f /tmp/uploads/config-ready; touch /tmp/uploads/config-ready; sync
  wait_marker_gone /tmp/uploads/config-ready 180 || fatal "config-ready non consumato dalla MH430"
  say "config-ready consumato; attendo commit MH430"
  sleep 10
  request_config_backup "$VERIFY_CONFIG" "verify-final"
  verify_config "$EXPECTED_CONFIG" "$VERIFY_CONFIG" || fatal "Config reale MH430 diversa dal Config ripristinato"
  printf 'LEGACY_CONFIG_READY_APPLIED=1\nDATE=%s\n' "$(date -Is)" > "$CONFIG_DONE"
  say "CONFIGURAZIONE $model RIPRISTINATA E RILETTA DALLA MH430"
}

registry_dispatch() {
  local status="$1" model serial token payload code
  [ -s "$GITHUB_TOKEN_FILE" ] || { echo "REGISTRO GITHUB: token assente, salto"; return 0; }
  if [ -r "$GITHUB_REGISTRY_LAST" ] && [ "$(cat "$GITHUB_REGISTRY_LAST")" = "$status" ]; then return 0; fi
  model="$(tr -d '\r\n ' < "$TARGET_MODEL_FILE")"; serial="$(tr -d '\r\n ' < "$TARGET_SERIAL_FILE")"; token="$(cat "$GITHUB_TOKEN_FILE")"
  payload="$(php -r 'echo json_encode(array("ref"=>"main","inputs"=>array("model"=>$argv[1],"serial"=>$argv[2],"status"=>$argv[3],"source"=>"legacy-recovery")));' "$model" "$serial" "$status")"
  code="$(curl -k -sS -o "$STATE/github_registry.response" -w '%{http_code}' -X POST \
    -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $token" -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$GITHUB_REGISTRY_REPO/actions/workflows/$GITHUB_REGISTRY_WORKFLOW/dispatches" -d "$payload" || true)"
  if [ "$code" = "204" ]; then echo "$status" > "$GITHUB_REGISTRY_LAST"; say "REGISTRO GITHUB INVIATO: $model-$serial -> $status"; else echo "WARN: registro GitHub HTTP $code (recovery continua)"; fi
}

dispatch_dp18() {
  local pad model fw tmp sftp token
  model="$(tr -d '\r\n ' < "$TARGET_MODEL_FILE")"
  pad="$(tr -d '\r\n ' < "$TARGET_SERIAL_FILE")"
  [ "$model" = "DP18" ] || fatal "dispatch_dp18 chiamato per modello $model"

  say "ROUTING UNIVERSALE: $model-$pad -> recovery DP18 v1.13 validata"
  remove_ddx_package

  tmp="/root/DP18-FULL-RECOVERY.sh.new"
  curl -k -fL --retry 3 --connect-timeout 15 \
    "https://raw.githubusercontent.com/MicrohardAssistenza/dp18-recovery/${DP18_REF}/DP18-FULL-RECOVERY.sh" \
    -o "$tmp" || fatal "download DP18 v1.13 fallito"
  [ "$(sha256sum "$tmp" | awk '{print $1}')" = "$DP18_SCRIPT_SHA" ] \
    || fatal "SHA DP18 v1.13 non valido"
  bash -n "$tmp" || fatal "sintassi DP18 v1.13 non valida"
  mv -f "$tmp" /root/DP18-FULL-RECOVERY.sh
  chmod 700 /root/DP18-FULL-RECOVERY.sh

  sftp="$(cat "$SECRET_FILE")"
  token="$(cat "$GITHUB_TOKEN_FILE" 2>/dev/null || true)"

  # Il servizio universale non serve piu': da qui prende il controllo il servizio DP18.
  cleanup_service
  say "Avvio DP18 FULL RECOVERY v1.13; da questo momento SSH/VPN puo' cadere"
  env DP18_SFTP_PASSWORD="$sftp" DP18_GITHUB_TOKEN="$token" \
    /root/DP18-FULL-RECOVERY.sh --bootstrap

  rm -f "$SECRET_FILE" "$GITHUB_TOKEN_FILE" 2>/dev/null || true
}

finish_success() {
  local model pad
  model="$(tr -d '\r\n ' < "$TARGET_MODEL_FILE")"; pad="$(tr -d '\r\n ' < "$TARGET_SERIAL_FILE")"
  date -Is > "$DONE"
  registry_dispatch RECOVERED || true
  {
    echo "RESULT=RECOVERED"; echo "MODEL=$model"; echo "SERIAL=$pad"; echo "DATE=$(date -Is)"; echo "SCRIPT_VERSION=$SCRIPT_VERSION"
  } > "/root/MH430_LEGACY_RECOVERY_OK_${model}_${pad}.txt"
  say "==============================================="
  say "MH430 UNIVERSAL RECOVERY COMPLETATO"
  echo "Modello    : $model"; echo "Matricola  : $pad"; echo "Log        : $LOG"
  cleanup_service
  rm -f "$SECRET_FILE" "$GITHUB_TOKEN_FILE" 2>/dev/null || true
  say "Servizio temporaneo rimosso: recovery terminato"
}

resume_main() {
  require_root
  mkdir -p "$STATE" "$PAYLOADS"; chmod 700 "$STATE" "$PAYLOADS"
  exec > >(tee -a "$LOG") 2>&1
  say "MH430 UNIVERSAL RECOVERY v$SCRIPT_VERSION - resume"
  echo "Hostname attuale : $(hostname)"; echo "machine.name     : $(read_machine_name)"; echo "machine.serial   : $(read_machine_serial || true)"
  capture_original_info
  prepare_prearm
  local class i
  class="$(tr -d '\r\n ' < "$CLASSIFICATION_FILE" 2>/dev/null || true)"

  case "$class" in
    DDX)
      say "DDX NATIVO: SKIPPED_DDX - nessuna modifica firmware/configurazione"
      registry_dispatch SKIPPED_DDX || true
      cleanup_service
      rm -f "$SECRET_FILE" "$GITHUB_TOKEN_FILE" 2>/dev/null || true
      return 0
      ;;
    DP18|LEGACY)
      if [ ! -e "$ARMED" ]; then
        say "Piano pronto. Attendo fino a 15 secondi il bootstrap per mostrarlo; poi AUTO-ARM se la VPN/SSH e' gia' caduta."
        for i in $(seq 1 15); do
          [ -e "$ARMED" ] && break
          sleep 1
        done
        if [ ! -e "$ARMED" ]; then
          date -Is > "$ARMED"
          say "AUTO-ARM SYSTEMD: sessione bootstrap non necessaria; recovery prosegue autonomamente"
        fi
      fi
      ;;
    *) fatal "classificazione inattesa nel servizio: ${class:-vuota}" ;;
  esac

  if [ "$class" = "DP18" ]; then
    dispatch_dp18
    return 0
  fi

  registry_dispatch RECOVERY_LEGACY || true
  remove_ddx_package
  ensure_target_firmware_and_serial
  confirm_serial_persistence
  ensure_final_official
  apply_configuration
  finish_success
}

install_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MH430 Universal Full Automatic Recovery
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
}

bootstrap() {
  require_root
  for c in bash php base64 xz tar od dd awk sed grep sort cp mv sync sha256sum seq tee wc tr date hostname sleep systemctl stat find head cat mkdir rm chmod curl pacman cmp diff; do need "$c"; done
  mkdir -p "$STATE" "$PAYLOADS"; chmod 700 "$STATE" "$PAYLOADS"
  cp -f "$0" "$SELF" 2>/dev/null || true; chmod 700 "$SELF"
  if [ -n "${DP18_SFTP_PASSWORD:-${MH430_SFTP_PASSWORD:-}}" ]; then umask 077; printf '%s' "${DP18_SFTP_PASSWORD:-${MH430_SFTP_PASSWORD:-}}" > "$SECRET_FILE"; chmod 600 "$SECRET_FILE"; fi
  [ -s "$SECRET_FILE" ] || fatal "password SFTP non fornita (DP18_SFTP_PASSWORD o MH430_SFTP_PASSWORD)"
  if [ -n "${DP18_GITHUB_TOKEN:-${MH430_GITHUB_TOKEN:-}}" ]; then umask 077; printf '%s' "${DP18_GITHUB_TOKEN:-${MH430_GITHUB_TOKEN:-}}" > "$GITHUB_TOKEN_FILE"; chmod 600 "$GITHUB_TOKEN_FILE"; fi
  capture_original_info
  install_service
  rm -f "$FAILED"
  systemctl restart "$SERVICE"

  local i
  for i in $(seq 1 180); do
    if [ -e "$PLAN_READY" ]; then
      echo; cat "$PLAN"; echo
      echo "================================================"
      echo "ARMAMENTO RECOVERY"
      echo "================================================"
      echo "Il piano sopra e' stato calcolato e salvato PRIMA del primo flash."
      local class
      class="$(tr -d '\r\n ' < "$CLASSIFICATION_FILE" 2>/dev/null || true)"
      case "$class" in
        DP18)
          echo "Classificazione   : DP18"
          echo "Routing           : DP18 FULL RECOVERY v1.13"
          echo "Firmware          : DP18 3.12"
          echo "Armo il servizio persistente; il routing DP18 avviene in systemd."
          date -Is > "$ARMED"; sync
          systemctl restart "$SERVICE"
          echo "Servizio         : $SERVICE"
          echo "Log persistente  : $LOG"
          echo "Stato             : RECOVERY DP18 AUTONOMO AVVIATO"
          return 0
          ;;
        DDX)
          echo "Classificazione   : DDX NATIVO"
          echo "Stato             : SKIPPED_DDX - nessuna modifica eseguita"
          cleanup_service
          rm -f "$SECRET_FILE" "$GITHUB_TOKEN_FILE" 2>/dev/null || true
          return 0
          ;;
        LEGACY)
          echo "Armo ora il servizio persistente. Da questo momento SSH/VPN puo' cadere."
          touch "$ARMED"; sync
          systemctl restart "$SERVICE"
          echo "Servizio         : $SERVICE"
          echo "Log persistente  : $LOG"
          echo "Stato             : RECOVERY AUTONOMO AVVIATO"
          return 0
          ;;
        *)
          fatal "classificazione inattesa nel bootstrap: ${class:-vuota}"
          ;;
      esac
    fi
    if [ -e "$FAILED" ]; then cat "$FAILED" >&2; exit 1; fi
    sleep 1
  done
  fatal "timeout: preflight persistente non ha prodotto il piano entro 180 secondi"
}

status() {
  echo "=== MACCHINA ==="; hostname 2>/dev/null || true; echo "machine.name=$(read_machine_name)"; echo "machine.serial=$(read_machine_serial || true)"; echo "MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
  echo "=== SERVICE ==="; systemctl is-active "$SERVICE" 2>/dev/null || true
  echo "=== UNIVERSAL PLAN ==="; cat "$PLAN" 2>/dev/null || echo "non ancora disponibile"
  echo "=== LOG ==="; tail -100 "$LOG" 2>/dev/null || true
  echo "=== RESULT ==="; [ -e "$DONE" ] && echo DONE || true; [ -e "$FAILED" ] && cat "$FAILED" || true
}

selftest() {
  local old_state="$STATE" old_payloads="$PAYLOADS" tmp model pad num f
  tmp="$(mktemp -d)"; trap "rm -rf -- '$tmp'" EXIT
  STATE="$tmp/state"; PAYLOADS="$STATE/payloads"; LOG="$STATE/recovery.log"; FAILED="$STATE/FAILED"; mkdir -p "$PAYLOADS"
  for model in DP30 DP60 DD40; do
    verify_shell_template "$model" || { echo "SELFTEST FAIL shell $model"; exit 1; }
    case "$model" in DP30) pad=00396;; DP60) pad=60849;; DD40) pad=40110;; esac
    num=$((10#$pad)); extract_official_payload "$model"; f="$(make_serial_mha "$model" "$pad" "$num")"
    [ "$(od -An -tu4 -N4 -j "$SERIAL_PATCH_OFF" "$f" | tr -d ' \n')" = "$num" ] || exit 1
    echo "SELFTEST $model OK -> $pad"
  done
  echo "SELFTEST_OK"
}

case "$MODE" in
  --bootstrap) bootstrap ;;
  --resume) resume_main ;;
  --status) status ;;
  --selftest) selftest ;;
  *) echo "Uso: $0 [--bootstrap|--resume|--status|--selftest]" >&2; exit 2 ;;
esac

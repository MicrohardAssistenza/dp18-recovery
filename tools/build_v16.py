#!/usr/bin/env python3
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

s = s.replace('# SCRIPT_VERSION=1.5.0', '# SCRIPT_VERSION=1.6.0', 1)
s = s.replace('SCRIPT_VERSION="1.5.0-github"', 'SCRIPT_VERSION="1.6.0-github"', 1)

anchor = 'SECRET_FILE="$STATE/sftp_password"'
repl = '''HIST_MODEL_FILE="$STATE/historical_model"
HIST_SERIAL_FILE="$STATE/historical_serial"
HIST_SOURCE_FILE="$STATE/historical_source"
CENSUS_FILE="/root/DD40_RECOVERY_CENSUS.tsv"
SECRET_FILE="$STATE/sftp_password"'''
if anchor not in s:
    raise SystemExit('state anchor missing')
s = s.replace(anchor, repl, 1)

insert_before = 'discover_history() {'
pos = s.find(insert_before)
if pos < 0:
    raise SystemExit('discover_history insertion point missing')

helpers = r'''detect_historical_identity() {
  local out="$STATE/historical_identity.detected.tsv"
  local model serial source

  if [ -s "$HIST_MODEL_FILE" ] && [ -s "$HIST_SERIAL_FILE" ]; then
    return 0
  fi

  php -d open_basedir= -r '
$dirs=array("/root/sent","/root/send","/root/delayedsend");
$best=false;
foreach($dirs as $dir){
  if(!is_dir($dir)) continue;
  $files=glob($dir."/*.xml");
  if(!$files) continue;
  foreach($files as $file){
    $txt=@file_get_contents($file);
    if($txt===false) continue;
    if(!preg_match("/<([A-Za-z][A-Za-z0-9_-]*)\\s+([^>]*)>/s",$txt,$rm)) continue;
    $tag=$rm[1]; $attrs=$rm[2];
    if(!preg_match("/\\bSerialNumber\\s*=\\s*([\"\\x27])([^\"\\x27]+)\\1/i",$attrs,$sm)) continue;
    $sd=preg_replace("/[^0-9]/","",$sm[2]);
    if($sd==="" || strlen($sd)>5) continue;
    $si=intval($sd,10);
    if($si<=0 || $si>99999) continue;
    $serial=sprintf("%05d",$si);

    $model="";
    foreach(array($tag,basename($file)) as $candidate){
      if(preg_match("/([A-Za-z]{2}[0-9]{2})/",$candidate,$mm)){
        $model=strtoupper($mm[1]);
        break;
      }
    }
    if($model==="") continue;

    $rank=@filemtime($file); if($rank===false) $rank=0;
    if(preg_match("/([0-9]{8})_([0-9]{6})/",basename($file),$tm)){
      $r=strtotime(substr($tm[1],0,4)."-".substr($tm[1],4,2)."-".substr($tm[1],6,2)." ".substr($tm[2],0,2).":".substr($tm[2],2,2).":".substr($tm[2],4,2));
      if($r!==false) $rank=$r;
    } elseif(preg_match("/\\bTimeStamp\\s*=\\s*([\"\\x27])([^\"\\x27]+)\\1/i",$attrs,$tm)){
      $r=strtotime(html_entity_decode($tm[2],ENT_QUOTES,"UTF-8"));
      if($r!==false) $rank=$r;
    }

    if($best===false || $rank>$best[0]) $best=array($rank,$model,$serial,$file);
  }
}
if($best!==false) echo $best[1]."\t".$best[2]."\t".$best[3]."\n";
' > "$out"

  [ -s "$out" ] || return 1
  model="$(awk -F '\t' 'NR==1{print $1}' "$out")"
  serial="$(awk -F '\t' 'NR==1{print $2}' "$out")"
  source="$(awk -F '\t' 'NR==1{print $3}' "$out")"

  case "$serial" in
    [0-9][0-9][0-9][0-9][0-9]) ;;
    *) return 1 ;;
  esac
  [ "$serial" != "00000" ] || return 1
  [ -n "$model" ] || return 1

  printf '%s\n' "$model" > "$HIST_MODEL_FILE"
  printf '%s\n' "$serial" > "$HIST_SERIAL_FILE"
  printf '%s\n' "$source" > "$HIST_SOURCE_FILE"
  chmod 600 "$HIST_MODEL_FILE" "$HIST_SERIAL_FILE" "$HIST_SOURCE_FILE" 2>/dev/null || true
  return 0
}

record_census() {
  local model="$1" serial="$2" status="$3" source="${4:-}"
  local mac host now
  mac="$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
  host="$(hostname 2>/dev/null || true)"
  now="$(date -Is 2>/dev/null || date '+%F %T')"
  source="$(printf '%s' "$source" | tr '\t\r\n' '   ')"

  if [ ! -f "$CENSUS_FILE" ]; then
    printf 'detected_at\tmodel\tserial\tstatus\tmac\thostname\tsource\n' > "$CENSUS_FILE"
  fi

  if ! awk -F '\t' -v m="$model" -v s="$serial" -v mac="$mac" 'NR>1 && $2==m && $3==s && $5==mac {found=1} END{exit found?0:1}' "$CENSUS_FILE"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$model" "$serial" "$status" "$mac" "$host" "$source" >> "$CENSUS_FILE"
    sync
  fi

  cp -f "$CENSUS_FILE" "$STATE/census.tsv" 2>/dev/null || true
  say "CENSIMENTO: modello=$model matricola=$serial stato=$status"
}

stop_non_dp18() {
  local model="$1" serial="$2" source="$3"
  local marker="/root/DD40_RECOVERY_NON_DP18_${model}_${serial}.txt"
  record_census "$model" "$serial" "SKIPPED_NON_DP18" "$source"
  {
    echo "RESULT=SKIPPED_NON_DP18"
    echo "DATE=$(date -Is 2>/dev/null || date)"
    echo "HISTORICAL_MODEL=$model"
    echo "HISTORICAL_SERIAL=$serial"
    echo "SOURCE=$source"
    echo "ACTION=NONE"
  } > "$marker"
  say "Storico identificato come $model-$serial: NON E' DP18, NON MODIFICO LA MACCHINA"
  echo "Registro locale : $CENSUS_FILE"
  echo "Marker sicurezza: $marker"
  cleanup_service
  rm -f "$SECRET_FILE" 2>/dev/null || true
  exit 0
}

'''
s = s[:pos] + helpers + s[pos:]

old = '''discover_history() {
  if [ -s "$TARGET_FILE" ] && [ -f "$PRODUCTS_FILE" ]; then'''
new = '''discover_history() {
  local hist_model hist_serial hist_source

  if [ -s "$TARGET_FILE" ] && [ -f "$PRODUCTS_FILE" ]; then
    hist_serial="$(tr -d '\\r\\n ' < "$TARGET_FILE")"
    record_census "DP18" "$hist_serial" "RECOVERY_DP18" "stato persistente"
'''
if old not in s:
    raise SystemExit('discover_history start anchor missing')
s = s.replace(old, new, 1)

# The replacement above intentionally added the existing if-body opening logic;
# remove the duplicated local saved_pad declaration introduced by the base v1.5 body.
s = s.replace('''    local saved_pad
    saved_pad="$(tr -d '\\r\\n ' < "$TARGET_FILE")"''', '''    local saved_pad
    saved_pad="$hist_serial"''', 1)

# Before the DP18-specific PHP analysis, census any historical model and stop safely if not DP18.
needle = '''  local phpfile="$STATE/analyze.php"'''
prelude = '''  if detect_historical_identity; then
    hist_model="$(tr -d '\\r\\n ' < "$HIST_MODEL_FILE")"
    hist_serial="$(tr -d '\\r\\n ' < "$HIST_SERIAL_FILE")"
    hist_source="$(cat "$HIST_SOURCE_FILE" 2>/dev/null || true)"
    if [ "$hist_model" != "DP18" ]; then
      stop_non_dp18 "$hist_model" "$hist_serial" "$hist_source"
    fi
    record_census "$hist_model" "$hist_serial" "RECOVERY_DP18" "$hist_source"
    say "Storico generale conferma DP18-$hist_serial; procedo con analisi prodotti DP18"
  fi

  local phpfile="$STATE/analyze.php"'''
if needle not in s:
    raise SystemExit('DP18 analyzer anchor missing')
s = s.replace(needle, prelude, 1)

# Make the legacy error message explicit: a non-DP18 would already have been stopped above.
s = s.replace('Nessun DP18Data storico trovato', 'Nessun DP18Data storico valido trovato dopo il censimento generale', 1)

for needle in [
  'SCRIPT_VERSION="1.6.0-github"',
  'detect_historical_identity() {',
  'stop_non_dp18() {',
  'SKIPPED_NON_DP18',
  'NON MODIFICO LA MACCHINA',
  'DD40_RECOVERY_CENSUS.tsv',
]:
    if needle not in s:
        raise SystemExit('missing expected v1.6 marker: ' + needle)

p.write_text(s)

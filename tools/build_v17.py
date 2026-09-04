#!/usr/bin/env python3
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

s = s.replace('# SCRIPT_VERSION=1.6.0', '# SCRIPT_VERSION=1.7.0', 1)
s = s.replace('SCRIPT_VERSION="1.6.0-github"', 'SCRIPT_VERSION="1.7.0-github"', 1)

anchor = 'CENSUS_FILE="/root/DD40_RECOVERY_CENSUS.tsv"\nSECRET_FILE="$STATE/sftp_password"'
repl = '''CENSUS_FILE="/root/DD40_RECOVERY_CENSUS.tsv"
GITHUB_TOKEN_FILE="$STATE/github_token"
GITHUB_REGISTRY_REPO="MicrohardAssistenza/dp18-recovery"
GITHUB_REGISTRY_PATH="registry/machines.tsv"
SECRET_FILE="$STATE/sftp_password"'''
if anchor not in s:
    raise SystemExit('github registry state anchor missing')
s = s.replace(anchor, repl, 1)

insert_before = 'record_census() {'
pos = s.find(insert_before)
if pos < 0:
    raise SystemExit('record_census insertion point missing')

helpers = r'''github_registry_sync() {
  local model="$1" serial="$2" status="$3" source="${4:-}"
  local token api cfg tmp meta current merged body resp sha http try now msg

  [ -s "$GITHUB_TOKEN_FILE" ] || {
    say "REGISTRO GITHUB: token non disponibile, record conservato solo localmente"
    return 1
  }

  token="$(cat "$GITHUB_TOKEN_FILE")"
  api="https://api.github.com/repos/${GITHUB_REGISTRY_REPO}/contents/${GITHUB_REGISTRY_PATH}"
  tmp="$STATE/github-registry.$$.tmp"
  cfg="$tmp.curl"
  meta="$tmp.meta"
  current="$tmp.current"
  merged="$tmp.merged"
  body="$tmp.body"
  resp="$tmp.resp"
  now="$(date -Is 2>/dev/null || date '+%F %T')"
  source="$(printf '%s' "$source" | tr '\t\r\n' '   ')"

  umask 077
  {
    printf 'header = "Authorization: Bearer %s"\n' "$token"
    printf 'header = "Accept: application/vnd.github+json"\n'
    printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
  } > "$cfg"

  try=1
  while [ "$try" -le 8 ]; do
    http="$(curl -sS --connect-timeout 15 --max-time 45 --config "$cfg" -o "$meta" -w '%{http_code}' "$api?ref=main" 2>/dev/null || true)"
    if [ "$http" != "200" ]; then
      say "REGISTRO GITHUB: lettura fallita HTTP ${http:-000}, tentativo $try/8"
      sleep 3
      try=$((try+1))
      continue
    fi

    sha="$(php -d open_basedir= -r '$j=json_decode(file_get_contents($argv[1]),true); echo isset($j["sha"])?$j["sha"]:"";' "$meta")"
    [ -n "$sha" ] || {
      say "REGISTRO GITHUB: SHA non leggibile, tentativo $try/8"
      sleep 2
      try=$((try+1))
      continue
    }

    php -d open_basedir= -r '$j=json_decode(file_get_contents($argv[1]),true); if(!isset($j["content"])) exit(2); file_put_contents($argv[2],base64_decode(str_replace(array("\r","\n"),"",$j["content"])));' "$meta" "$current" || {
      say "REGISTRO GITHUB: contenuto TSV non decodificabile"
      sleep 2
      try=$((try+1))
      continue
    }

    php -d open_basedir= -r '
$in=$argv[1]; $out=$argv[2]; $now=$argv[3]; $model=$argv[4]; $serial=$argv[5]; $status=$argv[6]; $source=$argv[7];
$lines=@file($in, FILE_IGNORE_NEW_LINES); if($lines===false) $lines=array();
$header="detected_at\tmodel\tserial\tstatus\tsource";
$result=array($header); $done=false;
foreach($lines as $i=>$line){
  if($i===0 && strpos($line,"detected_at\tmodel\tserial\tstatus\tsource")===0) continue;
  if(trim($line)==="") continue;
  $f=explode("\t",$line,5);
  if(count($f)<5) continue;
  if($f[1]===$model && $f[2]===$serial){
    $old=$f[3];
    if($old==="RECOVERED" && $status!=="RECOVERED"){
      $result[]=$line;
    } elseif($old==="SKIPPED_NON_DP18" && $status!=="RECOVERED"){
      $result[]=$line;
    } else {
      $result[]=implode("\t",array($now,$model,$serial,$status,$source));
    }
    $done=true;
  } else {
    $result[]=$line;
  }
}
if(!$done) $result[]=implode("\t",array($now,$model,$serial,$status,$source));
file_put_contents($out,implode("\n",$result)."\n");
' "$current" "$merged" "$now" "$model" "$serial" "$status" "$source" || {
      say "REGISTRO GITHUB: merge TSV fallito"
      sleep 2
      try=$((try+1))
      continue
    }

    msg="Registry ${model}-${serial} ${status}"
    php -d open_basedir= -r '$content=base64_encode(file_get_contents($argv[1])); echo json_encode(array("message"=>$argv[2],"content"=>$content,"sha"=>$argv[3],"branch"=>"main"));' "$merged" "$msg" "$sha" > "$body"

    http="$(curl -sS --connect-timeout 15 --max-time 45 --config "$cfg" -X PUT -H 'Content-Type: application/json' --data-binary "@$body" -o "$resp" -w '%{http_code}' "$api" 2>/dev/null || true)"
    case "$http" in
      200|201)
        say "REGISTRO GITHUB AGGIORNATO: $model-$serial -> $status"
        rm -f "$cfg" "$meta" "$current" "$merged" "$body" "$resp"
        return 0
        ;;
      409)
        say "REGISTRO GITHUB: conflitto concorrente, rileggo e riprovo ($try/8)"
        sleep 2
        ;;
      *)
        say "REGISTRO GITHUB: scrittura fallita HTTP ${http:-000}, tentativo $try/8"
        sleep 3
        ;;
    esac
    try=$((try+1))
  done

  rm -f "$cfg" "$meta" "$current" "$merged" "$body" "$resp"
  say "ATTENZIONE: registro GitHub non aggiornato dopo 8 tentativi; record locale conservato in $CENSUS_FILE"
  return 1
}

'''
s = s[:pos] + helpers + s[pos:]

needle = '  say "CENSIMENTO: modello=$model matricola=$serial stato=$status"\n}'
replacement = '''  say "CENSIMENTO: modello=$model matricola=$serial stato=$status"
  github_registry_sync "$model" "$serial" "$status" "$source" || true
}'''
if needle not in s:
    raise SystemExit('record_census tail anchor missing')
s = s.replace(needle, replacement, 1)

needle = '[ -s "$SECRET_FILE" ] || fatal "DP18_SFTP_PASSWORD non fornita al bootstrap"\n  capture_original_info'
replacement = '''[ -s "$SECRET_FILE" ] || fatal "DP18_SFTP_PASSWORD non fornita al bootstrap"

  if [ -n "${DP18_GITHUB_TOKEN:-}" ]; then
    umask 077
    printf "%s" "$DP18_GITHUB_TOKEN" > "$GITHUB_TOKEN_FILE"
    chmod 600 "$GITHUB_TOKEN_FILE"
  fi
  [ -s "$GITHUB_TOKEN_FILE" ] || fatal "DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub"

  capture_original_info'''
if needle not in s:
    raise SystemExit('bootstrap secret anchor missing')
s = s.replace(needle, replacement, 1)

# Cleanup di entrambe le credenziali temporanee in tutti i percorsi terminali.
s = s.replace('rm -f "$SECRET_FILE" 2>/dev/null || true', 'rm -f "$SECRET_FILE" "$GITHUB_TOKEN_FILE" 2>/dev/null || true')

needle = '  cp -f "$DONE_FILE" "/root/DP18_RECOVERY_OK_${pad}.txt"\n'
replacement = '''  cp -f "$DONE_FILE" "/root/DP18_RECOVERY_OK_${pad}.txt"
  record_census "DP18" "$pad" "RECOVERED" "recovery completato" || true
'''
if needle not in s:
    raise SystemExit('finish_success anchor missing')
s = s.replace(needle, replacement, 1)

for needle in [
  'SCRIPT_VERSION="1.7.0-github"',
  'github_registry_sync() {',
  'GITHUB_REGISTRY_PATH="registry/machines.tsv"',
  'DP18_GITHUB_TOKEN non fornito',
  'REGISTRO GITHUB AGGIORNATO',
  'record_census "DP18" "$pad" "RECOVERED"',
]:
    if needle not in s:
        raise SystemExit('missing expected v1.7 marker: ' + needle)

p.write_text(s)

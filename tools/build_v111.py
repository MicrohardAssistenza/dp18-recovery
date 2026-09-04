#!/usr/bin/env python3
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text()
s=s.replace('# SCRIPT_VERSION=1.10.0','# SCRIPT_VERSION=1.11.0',1)
s=s.replace('SCRIPT_VERSION="1.10.0-github"','SCRIPT_VERSION="1.11.0-github"',1)

def replace_func(text,name,new_body):
    start=text.find(name+'() {')
    if start<0: raise SystemExit(name+' function not found')
    end=text.find('\n}\n\n',start)
    if end<0: raise SystemExit(name+' function end not found')
    return text[:start]+new_body.rstrip()+'\n\n'+text[end+4:]

request=r'''request_config_backup() {
  local dest="$1" tag="${2:-backup}"
  local config="/mhdata/DP18Config.txt"
  local config_needed="/tmp/uploads/config-needed"
  local config_file_ready="/tmp/config-file-ready"
  local saved="$STATE/config-work/DP18Config.pre-request.${tag}.$$"
  local i

  wait_paypoint 300 || fatal "paypoint.service non attivo per richiesta configurazione"
  mkdir -p "$STATE/config-work"

  if [ -e "$config_needed" ]; then
    wait_marker_gone "$config_needed" 60 || rm -f "$config_needed"
  fi

  # FONDAMENTALE: togliamo il file corrente prima della richiesta. In questo modo
  # il backup accettato non puo' essere il DP18Config.txt che abbiamo scritto noi:
  # deve essere un file ricreato dalla MH430 dopo config-needed.
  rm -f "$config_file_ready"
  if [ -f "$config" ]; then
    cp -a "$config" "$saved"
    rm -f "$config"
    sync
  fi

  touch "$config_needed"
  sync

  for i in $(seq 1 180); do
    if [ ! -e "$config_needed" ] && [ -e "$config_file_ready" ] && [ -f "$config" ]; then
      # Su alcune MH430 CLOSE/config-file-ready precede di qualche secondo il
      # completamento della scrittura del file. Diamo margine prima di acquisirlo.
      sleep 6
      sync
      if [ -f "$config" ] \
         && grep -q '^;;BEGIN' "$config" \
         && grep -q '^\[Products\]' "$config" \
         && grep -q '^\[Network\]' "$config" \
         && [ "$(wc -c < "$config" | tr -d ' ')" -ge 200 ]; then
        cp -a "$config" "$dest"
        rm -f "$config_file_ready" "$saved"
        say "Backup FRESCO acquisito dalla MH430 ($tag)"
        return 0
      fi
    fi
    sleep 1
  done

  # Se il backup fallisce, non lasciamo /mhdata senza configurazione.
  if [ ! -f "$config" ] && [ -f "$saved" ]; then
    cp -a "$saved" "$config"
    sync
  fi
  rm -f "$config_file_ready"
  fatal "timeout: nessun DP18Config.txt fresco restituito dalla MH430 ($tag)"
}'''

s=replace_func(s,'request_config_backup',request)

verify=r'''verify_expected_config() {
  local cfg="$1" check_flags="${2:-1}"
  local recovered_ids="$STATE/config-work/recovered.ids"
  local verified=1 id idx line rid price name ts basis src expected sftp_password
  sftp_password="$(cat "$SECRET_FILE")"

  for id in $(seq 1 18); do
    idx=$((id-1))
    if grep -qx "$id" "$recovered_ids"; then
      line="$(awk -F '\t' -v want="$id" '$1==want{print; exit}' "$PRODUCTS_FILE")"
      IFS=$'\t' read -r rid price name ts basis src <<< "$line"
      grep -Fqx "product-name_${idx}=${name}" "$cfg" || { echo "MISMATCH nome canale $id"; verified=0; }
      grep -Fqx "product-price-normal_${idx}_0_0=${price}" "$cfg" || { echo "MISMATCH prezzo canale $id"; verified=0; }
      if [ "$check_flags" = "1" ]; then
        grep -Fqx "product-flag_${idx}=3" "$cfg" || { echo "MISMATCH flag vendibile canale $id"; verified=0; }
      fi
    else
      grep -Fqx "product-name_${idx}=Nome Vuoto!!!" "$cfg" || { echo "MISMATCH nome vuoto canale $id"; verified=0; }
      if [ "$check_flags" = "1" ]; then
        grep -Fqx "product-flag_${idx}=0" "$cfg" || { echo "MISMATCH flag NON vendibile canale $id"; verified=0; }
      fi
    fi
  done

  while IFS= read -r expected; do
    [ -n "$expected" ] || continue
    grep -Fqx "$expected" "$cfg" || { echo "MISMATCH Network: $expected"; verified=0; }
  done <<'NETWORK_EXPECTED'
server-protocol=sftp
server-port=22
server-address=vnd.microhard.it
server-username=uploads
alarm-email=
transmission-interval-hours=24
transmission-time-year=26
transmission-time-month=9
transmission-time-day=5
transmission-time-hh=1
transmission-time-mm=0
NETWORK_EXPECTED
  grep -Fqx "server-password=${sftp_password}" "$cfg" || { echo "MISMATCH Network: server-password"; verified=0; }
  [ "$verified" -eq 1 ]
}'''

# Insert verification helper immediately before apply_configuration.
anchor='apply_configuration() {'
pos=s.find(anchor)
if pos<0: raise SystemExit('apply_configuration insertion point missing')
if 'verify_expected_config() {' not in s:
    s=s[:pos]+verify+'\n\n'+s[pos:]

apply=r'''apply_configuration() {
  local sftp_password
  [ -r "$SECRET_FILE" ] || fatal "password SFTP recovery non disponibile"
  sftp_password="$(cat "$SECRET_FILE")"
  [ -n "$sftp_password" ] || fatal "password SFTP recovery vuota"

  # Solo una verifica FRESCA v1.11 puo' far saltare questa fase. I marker creati
  # dalle versioni precedenti vengono deliberatamente ignorati/rimossi.
  if [ -e "$CONFIG_DONE" ] && grep -q '^FRESH_MH430_VERIFIED=1$' "$CONFIG_DONE" 2>/dev/null; then
    say "Configurazione gia' verificata con backup fresco MH430"
    return 0
  fi
  rm -f "$CONFIG_DONE"

  local work="$STATE/config-work"
  local config="/mhdata/DP18Config.txt"
  local config_ready="/tmp/uploads/config-ready"
  local products_needed="/tmp/uploads/products-needed"
  local basecfg="$work/DP18Config.before.txt"
  local recoveredcfg="$work/DP18Config.recovered.txt"
  local verifycfg="$work/DP18Config.verify.txt"
  local recovered_ids="$work/recovered.ids"
  local attempt recovered_count disabled_count tmp

  mkdir -p "$work"

  say "Richiedo alla MH430 un backup FRESCO della configurazione corrente"
  request_config_backup "$basecfg" "before"

  php -d open_basedir= -d date.timezone=UTC -r '
function set_section_key($s,$section,$key,$value){
  $sp="/(?ms)^\\[".preg_quote($section,"/")."\\]\\R.*?(?=^\\[|\\z)/";
  if(!preg_match($sp,$s,$m,PREG_OFFSET_CAPTURE)){fwrite(STDERR,"Sezione mancante: [".$section."]\\n");exit(20);}
  $block=$m[0][0]; $off=$m[0][1];
  $kp="/(?m)^".preg_quote($key,"/")."=.*$/";
  if(preg_match($kp,$block)){
    $block=preg_replace($kp,$key."=".$value,$block,1,$n);
    if($n!==1){fwrite(STDERR,"Impossibile aggiornare chiave: ".$key."\\n");exit(21);}
  } else {
    $trimmed=rtrim($block,"\r\n"); $block=$trimmed."\n".$key."=".$value."\n\n";
  }
  return substr_replace($s,$block,$off,strlen($m[0][0]));
}
$base=$argv[1]; $tsv=$argv[2]; $out=$argv[3]; $sftpPassword=$argv[4];
$s=file_get_contents($base); if($s===false) exit(2);
$rows=file($tsv, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES); $rec=array();
foreach($rows as $line){
  $p=explode("\t",$line,6); if(count($p)<3) continue;
  $id=intval($p[0]); $price=intval($p[1]); $name=trim($p[2]);
  if($id<1||$id>18||$price<=0||$name==="") continue;
  $name=str_replace(array("\r","\n")," ",$name);
  if(strpos($name,"=")!==false){fwrite(STDERR,"Nome prodotto con = non supportato: ".$name."\n");exit(3);}
  $rec[$id]=array("name"=>$name,"price"=>$price);
}
for($id=1;$id<=18;$id++){
  $idx=$id-1; $kn="product-name_".$idx; $kp="product-price-normal_".$idx."_0_0"; $kf="product-flag_".$idx;
  if(isset($rec[$id])){
    $s=set_section_key($s,"Products",$kn,$rec[$id]["name"]);
    $s=set_section_key($s,"Products",$kp,strval($rec[$id]["price"]));
    $s=set_section_key($s,"Products",$kf,"3");
  } else {
    $s=set_section_key($s,"Products",$kn,"Nome Vuoto!!!");
    $s=set_section_key($s,"Products",$kf,"0");
  }
}
$network=array(
  "server-protocol"=>"sftp","server-port"=>"22","server-address"=>"vnd.microhard.it",
  "server-username"=>"uploads","server-password"=>$sftpPassword,"alarm-email"=>"",
  "transmission-interval-hours"=>"24","transmission-time-year"=>"26","transmission-time-month"=>"9",
  "transmission-time-day"=>"5","transmission-time-hh"=>"1","transmission-time-mm"=>"0"
);
foreach($network as $k=>$v) $s=set_section_key($s,"Network",$k,$v);
if(file_put_contents($out,$s)===false) exit(6);
' "$basecfg" "$PRODUCTS_FILE" "$recoveredcfg" "$sftp_password" || fatal "ricostruzione DP18Config fallita"

  grep -q '^;;BEGIN' "$recoveredcfg" || fatal "config ricostruita non valida"
  grep -q '^\[Products\]' "$recoveredcfg" || fatal "config ricostruita senza [Products]"
  grep -q '^\[Network\]' "$recoveredcfg" || fatal "config ricostruita senza [Network]"

  cut -f1 "$PRODUCTS_FILE" > "$recovered_ids"
  recovered_count="$(wc -l < "$recovered_ids" | tr -d ' ')"
  disabled_count=$((18-recovered_count))
  [ "$recovered_count" -gt 0 ] || fatal "nessun prodotto storico ricostruito: non applico una configurazione vuota"

  say "Configurazione DA RIPRISTINARE: $recovered_count canali recuperati, $disabled_count non vendibili"
  awk -F '\t' '{printf "  CH%02d  %4d  %s\n",$1,$2,$3}' "$PRODUCTS_FILE"
  echo "  Network -> sftp://vnd.microhard.it:22 user=uploads"

  # Se abbiamo prodotti storici, il file ricostruito deve differire dal backup
  # attuale almeno nei campi che ci interessano.
  if cmp -s "$basecfg" "$recoveredcfg"; then
    fatal "DP18Config ricostruito identico al backup corrente: dati Pardata non applicabili"
  fi

  for attempt in 1 2 3; do
    say "APPLICAZIONE CONFIGURAZIONE MH430 - tentativo $attempt/3"

    [ ! -e "$config_ready" ] || { wait_marker_gone "$config_ready" 60 || rm -f "$config_ready"; }
    [ ! -e "$products_needed" ] || { wait_marker_gone "$products_needed" 60 || rm -f "$products_needed"; }

    # Fase 1: file completo + config-ready. Questo e' il percorso che deve
    # ripristinare nomi, prezzi e Network.
    tmp="/mhdata/DP18Config.txt.new.$$"
    cp "$recoveredcfg" "$tmp"
    sync
    mv -f "$tmp" "$config"
    sync
    touch "$config_ready"
    sync
    wait_marker_gone "$config_ready" 180 || fatal "timeout: config-ready non consumato"
    say "config-ready consumato; attendo commit configurazione MH430"
    sleep 12

    # Rilettura FRESCA: il file corrente viene rimosso e deve essere rigenerato
    # dalla MH430. Verifichiamo prima i dati core senza dipendere dai flag.
    rm -f "$verifycfg"
    request_config_backup "$verifycfg" "core-attempt-${attempt}"
    if verify_expected_config "$verifycfg" 0; then
      say "Nomi, prezzi e Network realmente presenti nella MH430"

      # Fase 2: product flags. Riscriviamo il file desiderato e notifichiamo
      # products-needed separatamente, evitando la race dei due marker simultanei.
      cp "$recoveredcfg" "$tmp"
      sync
      mv -f "$tmp" "$config"
      sync
      touch "$products_needed"
      sync
      wait_marker_gone "$products_needed" 180 || fatal "timeout: products-needed non consumato"
      sleep 12

      rm -f "$verifycfg"
      request_config_backup "$verifycfg" "flags-attempt-${attempt}"
      if verify_expected_config "$verifycfg" 1; then
        {
          echo "RECOVERED_COUNT=$recovered_count"
          echo "DISABLED_COUNT=$disabled_count"
          echo "FRESH_MH430_VERIFIED=1"
          echo "VERIFIED_AT=$(date -Is 2>/dev/null || date)"
        } > "$CONFIG_DONE"
        say "CONFIGURAZIONE RIPRISTINATA E RILETTA DALLA MH430"
        return 0
      fi
      say "I dati core sono entrati ma i product-flag non coincidono; ritento"
    else
      say "La MH430 NON ha mantenuto nomi/prezzi/Network al tentativo $attempt"
    fi

    cp -a "$verifycfg" "$work/DP18Config.verify.failed.${attempt}.txt" 2>/dev/null || true

    if [ "$attempt" -lt 3 ]; then
      say "Riavvio controllato MH430 e nuovo tentativo di ripristino configurazione"
      trigger_empty_mha
      sleep 45
      wait_paypoint 300 || fatal "paypoint.service non attivo dopo reboot MH430 durante retry config"
      sleep 10
    fi
  done

  fatal "impossibile ripristinare realmente la configurazione MH430 dopo 3 tentativi"
}'''

s=replace_func(s,'apply_configuration',apply)

# A recovery marked successful by older versions must be reopened once, because
# v1.10 could falsely certify a stale DP18Config.txt.
old='''        if [ -f "/root/DP18_RECOVERY_OK_${boot_pad}.txt" ] || [ -e "$DONE_FILE" ]; then\n          say "Recovery $boot_pad gia\' completata: non eseguo nuovamente flash o configurazione"\n          cleanup_service\n          rm -f "$SECRET_FILE" "$GITHUB_TOKEN_FILE" 2>/dev/null || true\n          return 0\n        fi'''
new='''        if [ -f "/root/DP18_RECOVERY_OK_${boot_pad}.txt" ] || [ -e "$DONE_FILE" ]; then\n          if grep -q 'SCRIPT_VERSION=1.11.0-github' "$DONE_FILE" "/root/DP18_RECOVERY_OK_${boot_pad}.txt" 2>/dev/null \\\n             && grep -q '^FRESH_MH430_VERIFIED=1$' "$CONFIG_DONE" 2>/dev/null; then\n            say "Recovery $boot_pad gia\' completata e configurazione verificata realmente dalla MH430"\n            cleanup_service\n            rm -f "$SECRET_FILE" "$GITHUB_TOKEN_FILE" 2>/dev/null || true\n            return 0\n          fi\n          say "Recovery precedente $boot_pad riaperta: rifaccio la configurazione con verifica MH430 fresca"\n          rm -f "$DONE_FILE" "$CONFIG_DONE" "/root/DP18_RECOVERY_OK_${boot_pad}.txt" "$FAILED_FILE"\n        fi'''
if old not in s:
    raise SystemExit('old completed-recovery bootstrap block not found')
s=s.replace(old,new,1)

for needle in [
  'SCRIPT_VERSION="1.11.0-github"',
  'Backup FRESCO acquisito dalla MH430',
  'APPLICAZIONE CONFIGURAZIONE MH430 - tentativo',
  'CONFIGURAZIONE RIPRISTINATA E RILETTA DALLA MH430',
  'FRESH_MH430_VERIFIED=1',
  'Recovery precedente $boot_pad riaperta',
]:
    if needle not in s: raise SystemExit('missing v1.11 marker: '+needle)

p.write_text(s)

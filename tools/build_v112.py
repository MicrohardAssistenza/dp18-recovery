#!/usr/bin/env python3
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace('# SCRIPT_VERSION=1.11.0','# SCRIPT_VERSION=1.12.0',1)
s=s.replace('SCRIPT_VERSION="1.11.0-github"','SCRIPT_VERSION="1.12.0-github"',1)

def replace_between(text,start_marker,next_marker,new_text):
    a=text.find(start_marker)
    if a<0: raise SystemExit('missing '+start_marker)
    b=text.find(next_marker,a)
    if b<0: raise SystemExit('missing next '+next_marker)
    return text[:a]+new_text.rstrip()+'\n\n'+text[b:]

request=r'''request_config_backup() {
  local dest="$1" tag="${2:-backup}" i
  local config="/mhdata/DP18Config.txt"
  local config_needed="/tmp/uploads/config-needed"
  local config_file_ready="/tmp/config-file-ready"

  wait_paypoint 300 || fatal "paypoint.service non attivo per richiesta configurazione"

  # Protocollo NATIVO gia' validato fisicamente nella recovery v3.5:
  # NON cancellare DP18Config.txt. config-file-ready e' la prova che la MH430
  # ha completato la richiesta; il file aggiornato resta /mhdata/DP18Config.txt.
  if [ -e "$config_needed" ]; then
    wait_marker_gone "$config_needed" 60 || fatal "config-needed precedente non consumato"
  fi

  rm -f "$config_file_ready"
  touch "$config_needed"
  sync

  for i in $(seq 1 180); do
    if [ ! -e "$config_needed" ] && [ -e "$config_file_ready" ]; then
      sleep 2
      sync
      if [ -f "$config" ] \
         && grep -q '^;;BEGIN' "$config" \
         && grep -q '^\[Products\]' "$config" \
         && grep -q '^\[Network\]' "$config" \
         && [ "$(wc -c < "$config" | tr -d ' ')" -ge 200 ]; then
        cp -a "$config" "$dest"
        rm -f "$config_file_ready"
        say "Backup configurazione REALE acquisito dalla MH430 ($tag)"
        return 0
      fi
    fi
    sleep 1
  done

  echo "Diagnostica timeout backup reale:" >&2
  echo "  config-needed     : $([ -e "$config_needed" ] && echo PRESENTE || echo CONSUMATO)" >&2
  echo "  config-file-ready : $([ -e "$config_file_ready" ] && echo PRESENTE || echo ASSENTE)" >&2
  if [ -f "$config" ]; then
    echo "  DP18Config.txt    : presente, $(wc -c < "$config" | tr -d ' ') byte" >&2
  else
    echo "  DP18Config.txt    : ASSENTE" >&2
  fi
  fatal "timeout: la MH430 non ha restituito DP18Config.txt dopo config-file-ready ($tag)"
}'''
s=replace_between(s,'request_config_backup() {','verify_expected_config() {',request)

apply=r'''apply_configuration() {
  local sftp_password
  [ -r "$SECRET_FILE" ] || fatal "password SFTP recovery non disponibile"
  sftp_password="$(cat "$SECRET_FILE")"
  [ -n "$sftp_password" ] || fatal "password SFTP recovery vuota"

  # Solo la fase config eseguita col protocollo v3.5 validato fisicamente puo'
  # essere considerata conclusa. Ignoriamo marker delle versioni precedenti.
  if [ -e "$CONFIG_DONE" ] && grep -q '^PROTOCOL_V35_APPLIED=1$' "$CONFIG_DONE" 2>/dev/null; then
    say "Configurazione gia' applicata con protocollo v3.5 validato"
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
  local recovered_count disabled_count tmp verified id idx line rid price name ts basis src expected

  mkdir -p "$work"

  say "Richiedo alla MH430 il backup della configurazione corrente (protocollo v3.5)"
  request_config_backup "$basecfg" "before-v35"

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
    $trimmed=rtrim($block,"\r\n");
    $block=$trimmed."\n".$key."=".$value."\n\n";
  }
  return substr_replace($s,$block,$off,strlen($m[0][0]));
}
$base=$argv[1]; $tsv=$argv[2]; $out=$argv[3]; $sftpPassword=$argv[4];
$s=file_get_contents($base); if($s===false) exit(2);
$rows=file($tsv, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES); $rec=array();
foreach($rows as $line){
  $p=explode("\t",$line,6); if(count($p)<3) continue;
  $id=intval($p[0]); $price=intval($p[1]); $name=trim($p[2]);
  if($id<1 || $id>18 || $price<=0 || $name==="") continue;
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
  "server-protocol"=>"sftp",
  "server-port"=>"22",
  "server-address"=>"vnd.microhard.it",
  "server-username"=>"uploads",
  "server-password"=>$sftpPassword,
  "alarm-email"=>"",
  "transmission-interval-hours"=>"24",
  "transmission-time-year"=>"26",
  "transmission-time-month"=>"9",
  "transmission-time-day"=>"5",
  "transmission-time-hh"=>"1",
  "transmission-time-mm"=>"0"
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
  [ "$recovered_count" -gt 0 ] || fatal "nessun prodotto storico ricostruito"

  say "Configurazione ricostruita - protocollo v3.5"
  echo "Canali recuperati : $recovered_count"
  echo "Canali non vendibili: $disabled_count"
  for id in $(seq 1 18); do
    idx=$((id-1))
    if grep -qx "$id" "$recovered_ids"; then
      printf 'Canale %2d RECUPERATO -> ' "$id"
      grep -E "^product-name_${idx}=" "$recoveredcfg" | head -1
      printf '                       '
      grep -E "^product-price-normal_${idx}_0_0=" "$recoveredcfg" | head -1
    fi
  done

  # SEQUENZA IDENTICA ALLA v3.5 VALIDATA FISICAMENTE:
  # 1) installo il file completo
  # 2) creo config-ready E products-needed insieme
  # 3) aspetto che ENTRAMBI vengano consumati
  # 4) solo dopo richiedo config-needed per rilettura.
  [ ! -e "$config_ready" ] || fatal "esiste gia' config-ready: richiesta precedente pendente"
  [ ! -e "$products_needed" ] || fatal "esiste gia' products-needed: richiesta precedente pendente"

  say "Installo DP18Config e segnalo config-ready + products-needed (protocollo v3.5)"
  tmp="/mhdata/DP18Config.txt.new.$$"
  cp "$recoveredcfg" "$tmp"
  sync
  mv -f "$tmp" "$config"
  sync

  touch "$config_ready"
  touch "$products_needed"
  sync

  wait_marker_gone "$config_ready" 180 || fatal "timeout: la MH430 non ha consumato config-ready"
  wait_marker_gone "$products_needed" 180 || fatal "timeout: la MH430 non ha consumato products-needed"
  say "Configurazione e prodotti acquisiti dalla MH430 secondo protocollo v3.5"

  # Diamo piu' margine della v3.5 originale prima della rilettura, senza cambiare
  # il protocollo di commit.
  sleep 8
  say "Rileggo la configurazione dalla MH430 dopo il commit"
  request_config_backup "$verifycfg" "verify-v35"

  verified=1
  for id in $(seq 1 18); do
    idx=$((id-1))
    if grep -qx "$id" "$recovered_ids"; then
      line="$(awk -F '\t' -v want="$id" '$1==want{print; exit}' "$PRODUCTS_FILE")"
      IFS=$'\t' read -r rid price name ts basis src <<< "$line"
      grep -Fqx "product-name_${idx}=${name}" "$verifycfg" || { echo "Verifica fallita nome canale $id"; verified=0; }
      grep -Fqx "product-price-normal_${idx}_0_0=${price}" "$verifycfg" || { echo "Verifica fallita prezzo canale $id"; verified=0; }
      grep -Fqx "product-flag_${idx}=3" "$verifycfg" || { echo "Verifica fallita flag canale $id"; verified=0; }
    else
      grep -Fqx "product-name_${idx}=Nome Vuoto!!!" "$verifycfg" || { echo "Verifica fallita nome vuoto canale $id"; verified=0; }
      grep -Fqx "product-flag_${idx}=0" "$verifycfg" || { echo "Verifica fallita flag non vendibile canale $id"; verified=0; }
    fi
  done

  while IFS= read -r expected; do
    [ -n "$expected" ] || continue
    grep -Fqx "$expected" "$verifycfg" || { echo "Verifica fallita Network: $expected"; verified=0; }
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
  grep -Fqx "server-password=${sftp_password}" "$verifycfg" || { echo "Verifica fallita Network: server-password"; verified=0; }

  [ "$verified" -eq 1 ] || fatal "protocollo v3.5 eseguito ma configurazione riletta non coincide"

  {
    echo "RECOVERED_COUNT=$recovered_count"
    echo "DISABLED_COUNT=$disabled_count"
    echo "PROTOCOL_V35_APPLIED=1"
    echo "VERIFIED_AT=$(date -Is 2>/dev/null || date)"
  } > "$CONFIG_DONE"

  say "CONFIGURAZIONE RIPRISTINATA CON PROTOCOLLO v3.5 VALIDATO"
}'''
s=replace_between(s,'apply_configuration() {','wait_hostname_target() {',apply)

# Old successful markers must not skip the v3.5 application.
s=s.replace('FRESH_MH430_VERIFIED=1','PROTOCOL_V35_APPLIED=1')

for needle in [
 'SCRIPT_VERSION="1.12.0-github"',
 'protocollo v3.5',
 'touch "$config_ready"',
 'touch "$products_needed"',
 'PROTOCOL_V35_APPLIED=1',
 'CONFIGURAZIONE RIPRISTINATA CON PROTOCOLLO v3.5 VALIDATO']:
    if needle not in s: raise SystemExit('missing marker '+needle)
p.write_text(s)

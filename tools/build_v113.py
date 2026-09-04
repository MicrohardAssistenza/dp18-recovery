#!/usr/bin/env python3
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

s=s.replace('# SCRIPT_VERSION=1.12.0','# SCRIPT_VERSION=1.13.0',1)
s=s.replace('SCRIPT_VERSION="1.12.0-github"','SCRIPT_VERSION="1.13.0-github"',1)
s=s.replace('SCRIPT_VERSION=1.12.0-github','SCRIPT_VERSION=1.13.0-github')

anchor='GITHUB_REGISTRY_WORKFLOW="registry-dispatch.yml"\n'
if anchor not in s: raise SystemExit('missing github workflow anchor')
s=s.replace(anchor, anchor+'GITHUB_REGISTRY_LAST="$STATE/github_registry.last"\n',1)

# TOUCH machines: WebFrontend applies the complete DP18Config by writing
# /mhdata/DP18Config.txt then touching ONLY /tmp/uploads/config-ready.
s=s.replace('PROTOCOL_V35_APPLIED=1','TOUCH_CONFIG_READY_APPLIED=1')
s=s.replace('Configurazione gia\' applicata con protocollo v3.5 validato','Configurazione gia\' applicata tramite config-ready TOUCH')
s=s.replace('Configurazione ricostruita - protocollo v3.5','Configurazione ricostruita per TOUCH')
s=s.replace('CONFIGURAZIONE RIPRISTINATA CON PROTOCOLLO v3.5 VALIDATO','CONFIGURAZIONE RIPRISTINATA VIA CONFIG-READY TOUCH')
s=s.replace('protocollo v3.5 eseguito ma configurazione riletta non coincide','config-ready TOUCH consumato ma configurazione riletta non coincide')
s=s.replace('Richiedo alla MH430 il backup della configurazione corrente (protocollo v3.5)','Richiedo il DP18Config corrente prima del ripristino TOUCH')
s=s.replace('request_config_backup "$basecfg" "before-v35"','request_config_backup "$basecfg" "before-touch"')
s=s.replace('request_config_backup "$verifycfg" "verify-v35"','request_config_backup "$verifycfg" "verify-touch"')

s=s.replace('  local products_needed="/tmp/uploads/products-needed"\n','',1)

start='''  # SEQUENZA IDENTICA ALLA v3.5 VALIDATA FISICAMENTE:\n  # 1) installo il file completo\n  # 2) creo config-ready E products-needed insieme\n  # 3) aspetto che ENTRAMBI vengano consumati\n  # 4) solo dopo richiedo config-needed per rilettura.\n  [ ! -e "$config_ready" ] || fatal "esiste gia' config-ready: richiesta precedente pendente"\n  [ ! -e "$products_needed" ] || fatal "esiste gia' products-needed: richiesta precedente pendente"\n\n  say "Installo DP18Config e segnalo config-ready + products-needed (protocollo v3.5)"\n  tmp="/mhdata/DP18Config.txt.new.$$"\n  cp "$recoveredcfg" "$tmp"\n  sync\n  mv -f "$tmp" "$config"\n  sync\n\n  touch "$config_ready"\n  touch "$products_needed"\n  sync\n\n  wait_marker_gone "$config_ready" 180 || fatal "timeout: la MH430 non ha consumato config-ready"\n  wait_marker_gone "$products_needed" 180 || fatal "timeout: la MH430 non ha consumato products-needed"\n  say "Configurazione e prodotti acquisiti dalla MH430 secondo protocollo v3.5"\n'''
repl='''  # Protocollo TOUCH / WebFrontend: il file completo e' gia' pronto in /mhdata.\n  # L'unico trigger necessario e' /tmp/uploads/config-ready.\n  if [ -e "$config_ready" ]; then\n    wait_marker_gone "$config_ready" 60 || fatal "config-ready precedente non consumato"\n  fi\n\n  say "Installo DP18Config completo in /mhdata e segnalo SOLO config-ready (TOUCH)"\n  tmp="/mhdata/DP18Config.txt.new.$$"\n  cp "$recoveredcfg" "$tmp"\n  sync\n  mv -f "$tmp" "$config"\n  sync\n\n  touch "$config_ready"\n  sync\n\n  wait_marker_gone "$config_ready" 180 || fatal "timeout: la TOUCH non ha consumato config-ready"\n  say "config-ready consumato: configurazione completa consegnata alla TOUCH"\n'''
if start not in s: raise SystemExit('missing v1.12 config marker block')
s=s.replace(start,repl,1)

# Stop flooding GitHub Actions: send a registry state only once per machine/state.
old='''  cp -f "$CENSUS_FILE" "$STATE/census.tsv" 2>/dev/null || true\n  say "CENSIMENTO: modello=$model matricola=$serial stato=$status"\n  github_registry_sync "$model" "$serial" "$status" "$source" || true\n}\n'''
new='''  cp -f "$CENSUS_FILE" "$STATE/census.tsv" 2>/dev/null || true\n  say "CENSIMENTO: modello=$model matricola=$serial stato=$status"\n\n  local registry_key last_key\n  registry_key="${model}|${serial}|${status}"\n  last_key=""\n  [ -r "$GITHUB_REGISTRY_LAST" ] && last_key="$(cat "$GITHUB_REGISTRY_LAST" 2>/dev/null || true)"\n  if [ "$last_key" = "$registry_key" ]; then\n    say "REGISTRO GITHUB: stato $status gia' inviato per $model-$serial; non duplico il workflow"\n  elif github_registry_sync "$model" "$serial" "$status" "$source"; then\n    printf '%s' "$registry_key" > "$GITHUB_REGISTRY_LAST"\n    chmod 600 "$GITHUB_REGISTRY_LAST" 2>/dev/null || true\n  fi\n}\n'''
if old not in s: raise SystemExit('missing record_census tail')
s=s.replace(old,new,1)

# A v1.12/v1.11 DONE is intentionally reopened; only v1.13 + TOUCH marker is final.
for needle in [
    'SCRIPT_VERSION="1.13.0-github"',
    'GITHUB_REGISTRY_LAST="$STATE/github_registry.last"',
    'Installo DP18Config completo in /mhdata e segnalo SOLO config-ready (TOUCH)',
    'touch "$config_ready"',
    'TOUCH_CONFIG_READY_APPLIED=1',
    'CONFIGURAZIONE RIPRISTINATA VIA CONFIG-READY TOUCH',
    'non duplico il workflow']:
    if needle not in s: raise SystemExit('missing v1.13 marker: '+needle)

# products-needed must no longer appear inside apply_configuration.
a=s.index('apply_configuration() {')
b=s.index('wait_hostname_target() {',a)
apply=s[a:b]
if 'products-needed' in apply or 'products_needed' in apply:
    raise SystemExit('v1.13 apply still references products-needed')

p.write_text(s)

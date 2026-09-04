#!/usr/bin/env python3
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

s = s.replace('# SCRIPT_VERSION=1.7.0', '# SCRIPT_VERSION=1.8.0', 1)
s = s.replace('SCRIPT_VERSION="1.7.0-github"', 'SCRIPT_VERSION="1.8.0-github"', 1)
s = s.replace('GITHUB_REGISTRY_PATH="registry/machines.tsv"', 'GITHUB_REGISTRY_WORKFLOW="registry-dispatch.yml"', 1)

def replace_func(text, name, new_body):
    start = text.find(name + '() {')
    if start < 0:
        raise SystemExit(name + ' function not found')
    end = text.find('\n}\n\n', start)
    if end < 0:
        raise SystemExit(name + ' function end not found')
    return text[:start] + new_body.rstrip() + '\n\n' + text[end+4:]

new_sync = r'''github_registry_sync() {
  local model="$1" serial="$2" status="$3" source="${4:-}"
  local token api cfg body resp http try

  [ -s "$GITHUB_TOKEN_FILE" ] || {
    say "REGISTRO GITHUB: token non disponibile, record conservato solo localmente"
    return 1
  }

  token="$(cat "$GITHUB_TOKEN_FILE")"
  api="https://api.github.com/repos/${GITHUB_REGISTRY_REPO}/actions/workflows/${GITHUB_REGISTRY_WORKFLOW}/dispatches"
  cfg="$STATE/github-dispatch.$$.curl"
  body="$STATE/github-dispatch.$$.json"
  resp="$STATE/github-dispatch.$$.resp"
  source="$(printf '%s' "$source" | tr '\t\r\n' '   ')"

  umask 077
  {
    printf 'header = "Authorization: Bearer %s"\n' "$token"
    printf 'header = "Accept: application/vnd.github+json"\n'
    printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
  } > "$cfg"

  php -d open_basedir= -r '
$payload=array(
  "ref"=>"main",
  "inputs"=>array(
    "model"=>$argv[1],
    "serial"=>$argv[2],
    "status"=>$argv[3],
    "source"=>$argv[4]
  )
);
echo json_encode($payload);
' "$model" "$serial" "$status" "$source" > "$body"

  try=1
  while [ "$try" -le 8 ]; do
    http="$(curl -sS --connect-timeout 15 --max-time 45 --config "$cfg" -X POST -H 'Content-Type: application/json' --data-binary "@$body" -o "$resp" -w '%{http_code}' "$api" 2>/dev/null || true)"
    case "$http" in
      200|201|204)
        say "REGISTRO GITHUB INVIATO: $model-$serial -> $status"
        rm -f "$cfg" "$body" "$resp"
        return 0
        ;;
      401|403)
        say "REGISTRO GITHUB: token senza permesso Actions:write o non valido (HTTP $http)"
        rm -f "$cfg" "$body" "$resp"
        return 1
        ;;
      *)
        say "REGISTRO GITHUB: dispatch fallito HTTP ${http:-000}, tentativo $try/8"
        sleep 3
        ;;
    esac
    try=$((try+1))
  done

  rm -f "$cfg" "$body" "$resp"
  say "ATTENZIONE: evento registro GitHub non inviato dopo 8 tentativi; record locale conservato in $CENSUS_FILE"
  return 1
}'''

s = replace_func(s, 'github_registry_sync', new_sync)

for needle in [
  'SCRIPT_VERSION="1.8.0-github"',
  'GITHUB_REGISTRY_WORKFLOW="registry-dispatch.yml"',
  '/actions/workflows/${GITHUB_REGISTRY_WORKFLOW}/dispatches',
  'REGISTRO GITHUB INVIATO',
  'Actions:write',
]:
    if needle not in s:
        raise SystemExit('missing expected v1.8 marker: ' + needle)

p.write_text(s)

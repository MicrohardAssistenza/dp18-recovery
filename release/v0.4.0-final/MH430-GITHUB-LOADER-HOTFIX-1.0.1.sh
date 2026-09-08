#!/bin/bash
set -e
SRC="https://raw.githubusercontent.com/MicrohardAssistenza/dp18-recovery/2b31f19743d5b7f7b687ae4b1878529a7fa680ee/release/v0.4.0-final/MH430-GITHUB-LOADER.sh"
OLD_SHA="db9ffac23bffc678b01ad03eea275313aa2e17626523daa7e4fa09862e9998a1"
OLD="/root/MH430-GITHUB-LOADER-1.0.0.sh"
NEW="/root/MH430-GITHUB-LOADER-1.0.1.sh"

curl -k -fL --connect-timeout 8 --max-time 20 "$SRC" -o "$OLD"
echo "$OLD_SHA  $OLD" | sha256sum -c -

awk '
$0 == "VERSION=\"1.0.0\"" { print "VERSION=\"1.0.1\""; next }
$0 == "  local name=\"$1\" tmp=\"$STATE/$name.tmp\" dst=\"$STATE/$name\" n" {
  print "  local name tmp dst n"
  print "  name=\"$1\""
  print "  tmp=\"$STATE/$name.tmp\""
  print "  dst=\"$STATE/$name\""
  next
}
{ print }
' "$OLD" > "$NEW"

if grep -Fq 'local name="$1" tmp="$STATE/$name.tmp"' "$NEW"; then
  echo "ERRORE: vecchia dichiarazione ancora presente"
  exit 41
fi
grep -Fq 'VERSION="1.0.1"' "$NEW"
grep -Fq '  local name tmp dst n' "$NEW"
grep -Fq '  name="$1"' "$NEW"
bash -n "$NEW"
chmod 700 "$NEW"

echo "HOTFIX_1.0.1_OK"
exec "$NEW" --install

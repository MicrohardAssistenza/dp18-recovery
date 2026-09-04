#!/usr/bin/env python3
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

s = s.replace('# SCRIPT_VERSION=1.9.0', '# SCRIPT_VERSION=1.10.0', 1)
s = s.replace('SCRIPT_VERSION="1.9.0-github"', 'SCRIPT_VERSION="1.10.0-github"', 1)

final_func = r'''ensure_final_312() {
  if [ -e "$FINAL312_SENT" ]; then
    say "Firmware finale DP18 3.12 gia' richiesto; non ripeto il flash"
    wait_paypoint 300 || fatal "paypoint.service non attivo dopo firmware finale"
    return 0
  fi

  trigger_update "$OFFICIAL312" "ripristino firmware finale ufficiale DP18 3.12"
  date +%s > "$FINAL312_SENT"
  say "Firmware finale DP18 3.12 consegnato. Eventuali reboot Raspberry sono gestiti automaticamente."
}'''

if 'ensure_final_312() {' not in s:
    anchor = 'resume_main() {'
    pos = s.find(anchor)
    if pos < 0:
        raise SystemExit('resume_main insertion point missing')
    s = s[:pos] + final_func + '\n\n' + s[pos:]

# Fail cleanly instead of entering a systemd restart loop if a required stage
# function is ever lost by a future generated transformation.
old = '  ensure_final_312\n'
new = '  declare -F ensure_final_312 >/dev/null || fatal "funzione interna ensure_final_312 assente: recovery interrotto in sicurezza"\n  ensure_final_312\n'
if old not in s:
    raise SystemExit('ensure_final_312 call anchor missing')
s = s.replace(old, new, 1)

required_defs = [
    'discover_history',
    'extract_payloads',
    'ensure_dp18_software',
    'recover_serial',
    'ensure_final_312',
    'apply_configuration',
    'finish_success',
    'resume_main',
    'bootstrap',
]
for name in required_defs:
    if name + '() {' not in s:
        raise SystemExit('required function missing after v1.10 build: ' + name)

for needle in [
    'SCRIPT_VERSION="1.10.0-github"',
    'ripristino firmware finale ufficiale DP18 3.12',
    'Firmware finale DP18 3.12 consegnato',
    'funzione interna ensure_final_312 assente',
    'apply_configuration',
    'finish_success',
]:
    if needle not in s:
        raise SystemExit('missing expected v1.10 marker: ' + needle)

p.write_text(s)

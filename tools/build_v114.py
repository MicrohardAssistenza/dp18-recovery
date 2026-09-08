#!/usr/bin/env python3
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

s = s.replace('# SCRIPT_VERSION=1.13.0', '# SCRIPT_VERSION=1.14.0', 1)
s = s.replace('SCRIPT_VERSION="1.13.0-github"', 'SCRIPT_VERSION="1.14.0-github"', 1)
s = s.replace('SCRIPT_VERSION=1.13.0-github', 'SCRIPT_VERSION=1.14.0-github')

old = '''  [ -s "$GITHUB_TOKEN_FILE" ] || fatal "DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub"\n'''
new = '''  if [ ! -s "$GITHUB_TOKEN_FILE" ]; then\n    say "REGISTRO GITHUB: token non fornito; recovery continua senza sincronizzazione remota"\n  fi\n'''
if old not in s:
    raise SystemExit('missing mandatory GitHub token guard from v1.13')
s = s.replace(old, new, 1)

# Safety invariants: registry is optional, recovery is not.
if 'SCRIPT_VERSION="1.14.0-github"' not in s:
    raise SystemExit('v1.14 version marker missing')
if 'DP18_GITHUB_TOKEN non fornito: necessario per il registro automatico GitHub' in s:
    raise SystemExit('mandatory GitHub token guard still present')
if 'REGISTRO GITHUB: token non fornito; recovery continua senza sincronizzazione remota' not in s:
    raise SystemExit('optional registry warning missing')
if 'REGISTRO GITHUB: token non disponibile, record conservato solo localmente' not in s:
    raise SystemExit('github_registry_sync no-token fallback missing')

# Do not change the proven EEPROM/config/final-firmware path.
for marker in [
    'ensure_final_312() {',
    'recover_serial() {',
    'apply_configuration() {',
    'Installo DP18Config completo in /mhdata e segnalo SOLO config-ready (TOUCH)',
    'TOUCH_CONFIG_READY_APPLIED=1',
    'CONFIGURAZIONE RIPRISTINATA VIA CONFIG-READY TOUCH',
]:
    if marker not in s:
        raise SystemExit('proven recovery marker missing: ' + marker)

p.write_text(s)

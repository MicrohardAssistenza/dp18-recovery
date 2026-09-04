#!/usr/bin/env python3
from pathlib import Path
import ast, sys

shell_path=Path(sys.argv[1])
builder_path=Path(__file__).with_name('build_v111.py')
source=builder_path.read_text()
tree=ast.parse(source)
apply_body=None
for node in tree.body:
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == 'apply':
                apply_body=ast.literal_eval(node.value)
                break
    if apply_body is not None:
        break
if not apply_body:
    raise SystemExit('cannot extract apply body from build_v111.py')

s=shell_path.read_text()
start=s.find('apply_configuration() {')
end=s.find('wait_hostname_target() {', start)
if start < 0 or end < 0 or end <= start:
    raise SystemExit('cannot locate apply_configuration -> wait_hostname_target span')
s=s[:start]+apply_body.rstrip()+'\n\n'+s[end:]
shell_path.write_text(s)

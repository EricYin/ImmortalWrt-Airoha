#!/usr/bin/env python3
"""Re-cut the recovery guide's embedded page from the U-Boot source of truth.

guide/recovery-guide.html carries page.html verbatim as a JS string and drives
it into the states the walkthrough talks about, with a stub answering every
request the page makes.  Nothing keeps the two in sync on its own, and the
failure is quiet: the guide keeps showing last release's page, and anything the
stub does not answer turns into a wrong screenshot -- an unanswered /ping is two
missed heartbeats away from the "disconnected" overlay covering every mock.

So run this after touching files/httpd/page.html:

    scripts/sync-guide-page.py [path/to/immortalwrt]

The fake device's data comes from files/httpd/preview.py, so the guide and the
local preview always show the same machine.

Prose is not touched -- new pages still need their own row in "页面里有什么"
and their own entry under "新版本有什么变化".
"""
import importlib.util
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GUIDE = os.path.join(ROOT, 'guide', 'recovery-guide.html')

fork = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, '..', 'immortalwrt')
HTTPD = os.path.join(fork, 'package', 'boot', 'uboot-airoha', 'files', 'httpd')
if not os.path.isdir(HTTPD):
    sys.exit('no httpd sources at %s -- pass the immortalwrt checkout as $1'
             % HTTPD)

spec = importlib.util.spec_from_file_location(
    'preview', os.path.join(HTTPD, 'preview.py'))
pv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pv)

s = io.open(GUIDE, encoding='utf-8', newline='').read()


def js(t):
    """A JS double-quoted literal, safe to sit inside a <script> block."""
    return (t.replace('\\', '\\\\').replace('"', '\\"')
             .replace('\n', '\\n').replace('</', '<\\/'))


def replace_var(name, literal):
    """Swap the value of `var NAME="...";`, whatever it currently holds."""
    global s
    mark = 'var %s="' % name
    a = s.index(mark)
    i = a + len(mark)
    while True:
        if s[i] == '\\':
            i += 2
            continue
        if s[i] == '"':
            break
        i += 1
    s = s[:a + len(mark)] + literal + s[i:]


page = io.open(os.path.join(HTTPD, 'page.html'),
               encoding='utf-8', newline='').read()
# the theme follows the guide, not the visitor's localStorage
page = '\n'.join(l for l in page.split('\n') if 'localStorage.getItem' not in l)
for k, v in pv.MACROS.items():
    page = page.replace('@@%s@@' % k, v)
assert '@@' not in page, 'unsubstituted macro left in the page'

replace_var('PAGE', js(page))
replace_var('INFO', js(json.dumps(pv.INFO, ensure_ascii=False)))
replace_var('CHECK', js(json.dumps(
    {'items': [{'n': r[0], 's': r[1], 'v': r[2], 'g': r[3]} for r in pv.CHECK]},
    ensure_ascii=False)))
replace_var('LOG', js(pv.LOG))
replace_var('ENV', js(json.dumps(
    {'env': [{'k': k, 'v': v} for k, v in pv.ENV], 'cut': 0},
    ensure_ascii=False)))

io.open(GUIDE, 'w', encoding='utf-8', newline='').write(s)
print('guide updated: page %d chars, %d env vars, %d check items'
      % (len(page), len(pv.ENV), len(pv.CHECK)))

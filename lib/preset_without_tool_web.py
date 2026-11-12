"""Print dsh's shipped 'standard' agent preset without its tool-web row.

usage: python3 -I preset_without_tool_web.py <dsh-web-app>/presets/standard.patch.yml insert|patch
  insert  the shipped `- insert:` declaration (for profiles that have no preset rows, e.g. dsh-tui)
  patch   an id-targeted row replacing the existing preset-standard config (for the web profile)
Generated from the installed dsh at install time, so this repo carries no copy of dsh's preset.
"""
import sys

src, mode = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().rstrip("\n").split("\n")
body = lines[lines.index("- insert:"):]
start = body.index("    - id: preset-standard")
# the tool-web row starts at a plugin-list item and ends at the next item of the same indent
indent = next(l for l in body if l.lstrip().startswith("- id: tool-web"))
pad = indent[: len(indent) - len(indent.lstrip())]
t = body.index(indent)
u = next(i for i in range(t + 1, len(body)) if body[i].startswith(pad + "- ") or not body[i].startswith(pad + " "))
removed, body = body[t:u], body[:t] + body[u:]
if not any("dsh-tool-web" in l for l in removed) or any("tool-web" in l for l in body):
    sys.exit("unexpected preset layout; refusing to guess")
if mode == "insert":
    print("\n".join(body))
elif mode == "patch":
    row = body[start:]
    print("\n".join(l[4:] if l.startswith("    ") else l for l in row))
else:
    sys.exit("mode must be insert or patch")

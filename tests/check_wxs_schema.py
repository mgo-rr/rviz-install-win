#!/usr/bin/env python3
"""Check every element/attribute in windows/rviz.wxs against the WiX compiler
source (each element's Parse*Element switch). Usage:
    python tests/check_wxs_schema.py <path-to-wix-source-checkout>
The checkout should be wixtoolset/wix at the pinned tag (v5.0.2)."""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

WXS = Path(__file__).resolve().parents[1] / "windows" / "rviz.wxs"
NS = {"http://wixtoolset.org/schemas/v4/wxs": "",
      "http://wixtoolset.org/schemas/v4/wxs/util": "util:",
      "http://wixtoolset.org/schemas/v4/wxs/ui": "ui:"}
# Element-name -> parse function name when it differs from Parse<Name>Element
ALIASES = {"util:RemoveFolderEx": "ParseRemoveFolderExElement",
           "ui:WixUI": "ParseWixUIElement"}
SKIP_ATTRS = {"xmlns"}


def method_bodies(src_root: Path):
    files = list((src_root / "src/wix/WixToolset.Core").glob("Compiler*.cs"))
    files += [src_root / "src/ext/Util/wixext/UtilCompiler.cs", src_root / "src/ext/UI/wixext/UICompiler.cs"]
    bodies = {}
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        for m in re.finditer(r"(?:private|public|internal)[^\n(]*\s(Parse\w+Element)\s*\(", text):
            start = m.start()
            nxt = re.search(r"\n\s*(?:private|public|internal|protected)\s", text[m.end():])
            end = m.end() + nxt.start() if nxt else len(text)
            bodies.setdefault(m.group(1), "")
            bodies[m.group(1)] += text[start:end]
    return bodies


def local(tag):
    uri, name = tag[1:].split("}")
    return NS.get(uri, "?") + name


def main():
    root_src = Path(sys.argv[1])
    bodies = method_bodies(root_src)
    errors, checked = [], 0
    tree = ET.parse(WXS)

    def visit(el, parent_fn):
        nonlocal checked
        name = local(el.tag)
        short = name.split(":")[-1]
        fn = ALIASES.get(name, f"Parse{short}Element")
        body = bodies.get(fn)
        if name != "Wix":
            if body is None:
                errors.append(f"<{name}>: no {fn} in WiX source")
            if parent_fn and f'case "{short}"' not in bodies.get(parent_fn, "") and not name.startswith(("util:", "ui:")):
                errors.append(f"<{name}> not accepted as child by {parent_fn}")
            for attr in el.attrib:
                a = attr.split("}")[-1]
                if a in SKIP_ATTRS:
                    continue
                checked += 1
                if body is not None and f'case "{a}"' not in body:
                    errors.append(f"<{name} {a}=...>: attribute not handled by {fn}")
        for child in el:
            visit(child, fn if name != "Wix" else None)

    visit(tree.getroot(), None)
    for e in errors:
        print("ERROR", e)
    print(f"checked {checked} attributes; {len(errors)} problems")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())

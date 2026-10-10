#!/usr/bin/env python3
"""Insert tools/touch-shim.js into each games/*.html (idempotent), next to the gamepad shim.

The block is placed right after the `// </gamepad-shim>` marker when the game has one (so both shims share the game's module scope and the
contract globals keys / padFire / padPlace / padLook / padMenu), otherwise just before the LAST </script>. Re-running replaces the previous copy,
whatever position it was in. It also makes sure the page has a viewport meta containing user-scalable=no + maximum-scale=1 (adds one if missing).

  python3 tools/inject_touch.py games/foo.html [games/bar.html ...]
  python3 tools/inject_touch.py --remove games/foo.html     # strip the touch block again
  python3 tools/inject_touch.py --check games/*.html        # report only (exit 1 if any file lacks an up-to-date block)
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent
shim = (root / "touch-shim.js").read_text().rstrip() + "\n"
BEGIN, END = "// <touch-shim>\n", "// </touch-shim>\n"
GP_END = "// </gamepad-shim>\n"
block = BEGIN + shim + END
BLOCK_RE = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END), re.S)
VIEWPORT_RE = re.compile(r"<meta\s+name=[\"']viewport[\"'][^>]*>", re.I)


def fix_viewport(s):
    """Guarantee <meta name=viewport> has user-scalable=no and maximum-scale=1 (never touches viewport-fit, so HUD layouts stay as they were)."""
    m = VIEWPORT_RE.search(s)
    if not m:
        tag = '<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">'
        i = s.lower().find("</head>")
        if i < 0:
            return s
        return s[:i] + tag + "\n" + s[i:]
    tag = m.group(0)
    new = tag
    c = re.search(r"content=([\"'])(.*?)\1", tag, re.S)
    if not c:
        return s
    content = c.group(2)
    if not re.search(r"user-scalable\s*=\s*(no|0)", content):
        content = re.sub(r"user-scalable\s*=\s*[^,;]+,?\s*", "", content).rstrip(", ") + ",user-scalable=no"
    if "maximum-scale" not in content:
        content += ",maximum-scale=1"
    new = tag[:c.start(2)] + content + tag[c.end(2):]
    return s[:m.start()] + new + s[m.end():]


def process(p, mode):
    s = p.read_text()
    had = BLOCK_RE.search(s)
    s = BLOCK_RE.sub("", s)
    if mode == "remove":
        p.write_text(s)
        print(f"{p}: touch shim removed" if had else f"{p}: no touch shim")
        return True
    if mode == "check":
        ok = bool(had) and had.group(0) == block
        print(f"{p}: {'up to date' if ok else ('STALE' if had else 'MISSING')}")
        return ok
    j = s.find(GP_END)
    if j >= 0:
        j += len(GP_END)
    else:
        j = s.rfind("</script>")
        if j < 0:
            sys.exit(f"{p}: no </script> found")
    s = s[:j] + block + s[j:]
    s = fix_viewport(s)
    p.write_text(s)
    where = "after the gamepad shim" if GP_END in s else "before the last </script>"
    print(f"{p}: touch shim injected ({len(block)} bytes, {where})")
    return True


def main(argv):
    mode = "inject"
    files = []
    for a in argv:
        if a == "--remove":
            mode = "remove"
        elif a == "--check":
            mode = "check"
        else:
            files.append(a)
    if not files:
        sys.exit(__doc__)
    ok = all([process(pathlib.Path(f), mode) for f in files])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main(sys.argv[1:])

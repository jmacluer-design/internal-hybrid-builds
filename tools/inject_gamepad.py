#!/usr/bin/env python3
"""Insert tools/gamepad-shim.js into each games/*.html (idempotent).

The shim goes just before the LAST </script> in the file, so it lands inside the game's module scope and can see
the contract globals (keys, padFire, padPlace, padLook, padMenu). Re-running replaces the previous copy.

  python3 tools/inject_gamepad.py games/foo.html [games/bar.html ...]
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent
shim = (root / "gamepad-shim.js").read_text().rstrip() + "\n"
BEGIN, END = "// <gamepad-shim>\n", "// </gamepad-shim>\n"
block = BEGIN + shim + END

for arg in sys.argv[1:]:
    p = pathlib.Path(arg)
    s = p.read_text()
    s = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END), "", s, flags=re.S)
    i = s.rfind("</script>")
    if i < 0:
        sys.exit(f"{arg}: no </script> found")
    p.write_text(s[:i] + block + s[i:])
    print(f"{arg}: shim injected ({len(block)} bytes)")

#!/usr/bin/env python3
"""Bake the animated Clawd pets (CSS-animated SVGs from github.com/abderrahimghazali/clawd-pet)
into PNG frame sheets that SpriteKit can play.

For each state we inline N copies of the SVG into one HTML page, freeze every copy's animations at
a different time with the Web Animations API, and screenshot the page once with headless Chrome.
Output: Assets/pets/<state>.png (grid of frames) + Assets/pets/manifest.json.

Usage: tools/render-pets.py [path/to/clawd-pet/public/pets]   (defaults to Assets/pets/src)
"""
import json, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Assets", "pets")
SRC_VENDOR = os.path.join(OUT, "src")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# state -> pet name (file is clawd-<name>.svg)
STATES = {
    "moving": "crab-walking",
    "needsPermission": "praying",
    "needsQuestion": "confused",
    "doneUnseen": "celebrating",
    "doneSeen": "idle-living",
    "dormant": "sleeping",
    "error": "dizzy",
    "leaving": "going-away",
}

# A working crab picks one of these and keeps it for life, so each session has its own
# working personality. Baked as states "working:<pet>"; the order is the rotation order.
WORKING_PETS = [
    "working-thinking",
    "working-juggling",
    "working-debugger",
    "working-building",
    "working-beacon",
    "working-tool-calling",
    "dj",
    "working-firefighting",
    "magic",
]
for _p in WORKING_PETS:
    STATES[f"working:{_p}"] = _p
CELL = 240          # px per frame (rendered 2x; shown at 120 pt)
COLS, ROWS = 8, 4   # 32 frames
LOOP_MS = 4000      # animation loop we sample
FPS = COLS * ROWS / (LOOP_MS / 1000)

def main():
    src = sys.argv[1] if len(sys.argv) > 1 else SRC_VENDOR
    os.makedirs(SRC_VENDOR, exist_ok=True)
    manifest = {"cell": CELL, "cols": COLS, "rows": ROWS, "fps": FPS,
                "workingVariants": [f"working:{p}" for p in WORKING_PETS], "states": {}}
    with tempfile.TemporaryDirectory() as tmp:
        for state, pet in STATES.items():
            svg_path = os.path.join(src, f"clawd-{pet}.svg")
            svg = open(svg_path).read()
            if os.path.abspath(src) != os.path.abspath(SRC_VENDOR):
                shutil.copy(svg_path, os.path.join(SRC_VENDOR, f"clawd-{pet}.svg"))
            svg = re.sub(r'<svg([^>]*?)\swidth="[^"]*"\sheight="[^"]*"',
                         rf'<svg\1 width="{CELL}" height="{CELL}"', svg, count=1)
            n = COLS * ROWS
            cells = "".join(f'<div class="c" data-i="{i}">{svg}</div>' for i in range(n))
            html = f"""<!doctype html><html><head><style>
html,body{{margin:0;background:transparent;width:{CELL*COLS}px;height:{CELL*ROWS}px;overflow:hidden}}
body{{display:flex;flex-wrap:wrap}} .c{{width:{CELL}px;height:{CELL}px}} svg{{display:block}}
</style></head><body>{cells}<script>
const step = {LOOP_MS} / {n};
document.querySelectorAll('.c').forEach(c => {{
  const t = Number(c.dataset.i) * step;
  for (const a of c.getAnimations({{subtree: true}})) {{ a.pause(); a.currentTime = t; }}
}});
</script></body></html>"""
            name = state.replace(":", "-")
            page = os.path.join(tmp, f"{name}.html")
            open(page, "w").write(html)
            out_png = os.path.join(OUT, f"{name}.png")
            subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                            "--default-background-color=00000000",
                            f"--window-size={CELL*COLS},{CELL*ROWS}", "--virtual-time-budget=600",
                            f"--screenshot={out_png}", f"file://{page}"],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            manifest["states"][state] = {"file": f"{name}.png", "pet": pet, "frames": n}
            print(f"  {state:28} <- clawd-{pet}.svg  ({os.path.getsize(out_png)//1024} KB)")
    json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=2)
    print("wrote manifest.json")

if __name__ == "__main__":
    main()

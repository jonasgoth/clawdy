# Clawdy

Little crab pets on your Mac desktop. One crab per Claude session.
They tell you who is working, who is done, and who needs you.

**Status: Phase 0.** One crab, in a see-through strip along the bottom of the screen.
You can drag it. Clicks anywhere else go straight through to your apps.
Nothing is connected to Claude yet. See [PLAN.md](PLAN.md) for what comes next.

## Run it

You need Xcode (or the Xcode command line tools). Then:

```bash
./build.sh --run
```

That builds `build/Clawdy.app` and launches it. A crab appears in your menu bar.
Click it for the menu. Quit from there.

To open the code in Xcode, double-click `Package.swift`.

## Not affiliated

Unofficial. Not made by Anthropic. "Claude" and the Clawd crab belong to Anthropic.
See [Assets/ATTRIBUTION.md](Assets/ATTRIBUTION.md). Code is MIT.

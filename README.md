# Clawdy

Little Clawd pets on your Mac desktop, one per Claude session. They show you who is working, who is done, and who needs you.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey.svg)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)
![Unofficial](https://img.shields.io/badge/unofficial-not%20affiliated%20with%20Anthropic-lightgrey.svg)

![Clawdy pets along the bottom of a Mac screen](docs/screenshot.png)

## What it does

Clawdy is a menu-bar app. Every live Claude session gets an animated pet: Claude Code in the terminal, the Claude Desktop Code tab, and Cowork. The pets sit along the bottom of your screen, in the wallpaper gaps beside the Dock. Never under it.

The pose tells you the state:

- **Coding** while it works (also while running tools)
- **Praying** when it is waiting for permission
- **Confused** when it asked you a question
- **Celebrating** when it is done
- **Idle** once you have seen the result
- **Dizzy** on errors
- **Walking off** when the chat closes

A few more details:

- Each pet gets its own color, so you can tell sessions apart.
- Sub-agents show up as tiny pixel baby crabs beside their parent.
- The "done" state clears only when you actually look at the chat. Clicking the pet never clears it.
- A pet leaves after 5 minutes idle, unless it still needs you.
- Drag pets around. Clicks anywhere else pass through to your apps.
- The menu bar icon shows how many pets are alive and turns red when one needs you.

Nothing leaves your Mac. Clawdy only reads files Claude already writes.

## Install

### Download

Grab the latest `Clawdy-<version>.dmg` from [Releases](https://github.com/jonasgoth/clawdy/releases), drag Clawdy to Applications, and open it.

The build is ad-hoc signed, not notarized. The first time, right-click the app and choose **Open**.

### Build from source

You need Xcode or the Command Line Tools.

```bash
git clone https://github.com/jonasgoth/clawdy.git
cd clawdy
./build.sh --run
```

This builds `build/Clawdy.app` and launches it. To make your own installer:

```bash
tools/make-dmg.sh
```

## Menu

Click the crab in the menu bar. It lists your sessions and offers:

- **Turn on instant updates…** installs Claude Code hooks so pets react the moment a chat needs permission or finishes. It edits `~/.claude/settings.json` and backs it up first. Optional.
- **Allow window checks…** grants Accessibility access. Clawdy uses it for exact Dock bounds and to tell when you have looked at a Cowork chat. Optional.
- **Sounds** plays a soft chime when a job finishes and a pop when one needs you. Off by default.
- **Tidy crabs** lines everyone up.
- **Show playpen** / **Hide playpen** toggles the pets.

## How it works

Clawdy watches the files Claude writes to disk: the live-session list in `~/.claude/sessions`, the chat transcripts in `~/.claude/projects`, the Desktop app's chat metadata (which records when you last opened a chat), and Cowork's audit log. Folders are watched with FSEvents, so it idles at a few percent CPU. With hooks turned on, state changes arrive instantly instead of a moment later.

See [PLAN.md](PLAN.md) for the full design, including the "seen" rule.

To see what Clawdy is thinking, run it from a terminal with debug logging:

```bash
CLAWDY_DEBUG=1 build/Clawdy.app/Contents/MacOS/Clawdy
```

## Rebuilding the pets

The pets are animated SVGs baked into PNG frame sheets. To re-bake them (needs Google Chrome):

```bash
tools/render-pets.py
```

This writes `Assets/pets/<state>.png` and `Assets/pets/manifest.json`.

## Contributing

Issues and pull requests are welcome. If something looks wrong, a debug log (see above) helps a lot.

## Credits

- The animated pets are **[clawd-pet](https://github.com/abderrahimghazali/clawd-pet)** by Abderrahim Ghazali (MIT). You can browse them at [clawd-pet.vercel.app](https://clawd-pet.vercel.app).
- The pixel baby crab frames come from [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) by m1ckc3s (MIT).
- Inspired by [so-agentbar](https://github.com/sotthang/so-agentbar).

"Claude" and Clawd belong to Anthropic. Clawdy is an unofficial side project, not affiliated with or endorsed by Anthropic. See [Assets/ATTRIBUTION.md](Assets/ATTRIBUTION.md) for details.

## License

[MIT](LICENSE). This covers the code in this repository only and conveys no rights to Anthropic's trademarks or artwork.

<p align="center">
  <img src="docs/icon.png" width="176" alt="The Clawdy icon: a smiling terracotta crab on a warm cream squircle">
</p>

<h1 align="center">Clawdy</h1>

<p align="center">
  <b>A little crab for every Claude session, living along the bottom of your Mac screen.</b><br>
  One glance tells you who is working, who is done, and who needs you.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-lightgrey.svg">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-orange.svg">
  <img alt="Unofficial" src="https://img.shields.io/badge/unofficial-not%20affiliated%20with%20Anthropic-lightgrey.svg">
</p>

---

## Why

You set Claude off on something long, switch to another window, and then keep
going back to check: is it still thinking, or has it been sitting there for ten
minutes waiting for me to say yes?

Clawdy answers that without the check. Every live session — Claude Code in the
terminal, the Claude Desktop Code tab, Cowork — gets an animated pet that sits in
the wallpaper gap beside your Dock, never underneath it. The pose it holds is the
answer.

## What the poses mean

| The pet is… | The session is… |
| --- | --- |
| busy — thinking, juggling, debugging, firefighting | working, or running a tool |
| praying | waiting for you to approve something |
| looking puzzled | done, but it asked you a question |
| celebrating | done, and you have not looked yet |
| pottering about | done, and you have seen it |
| dizzy | stopped on an error |
| asleep | quiet for ten minutes |
| walking off screen | gone — the session ended, or it went idle |

Each session picks its own working animation and keeps it, so the same crab
behaves the same way all the way through a job.

## The small print that makes it work

- **"Done" clears when you look, not when you click a badge away.** Clawdy
  watches which app is in front, which Claude window has focus, and which
  terminal tab is selected. Nothing counts as seen while the screen is locked or
  asleep.
- **Click a pet to jump to its chat.** Desktop sessions open through a
  `claude://` link; a terminal session raises its window and, where the terminal
  can be scripted, its tab. Arriving there also counts as having seen it.
- **Shell colour is per project, not per session.** Every crab running in the
  same folder wears the same shell. The folder you start in wears the pets' own
  terracotta, the next one blue, then green, and so on. After four quiet hours
  the colours start over.
- **Sub-agents show up as tiny pixel baby crabs** that trail their parent.
  Clicking a baby opens the parent's chat.
- **Hover for a speech bubble:** what the session is doing, how long it has been
  at it, which project it is in, and how many helpers it has out.
- **Drag pets wherever you like.** They fall back to the floor when you let go.
  Clicks on empty desktop pass straight through to whatever is underneath.
- **A pet leaves after five minutes idle** unless it still needs you. The menu
  keeps listing it for another five.
- **The menu bar crab** carries a live count, and turns red the moment a session
  needs you.

Nothing leaves your Mac. Clawdy only reads files Claude already writes.

## Install

### Download

Grab the latest `Clawdy-<version>.dmg` from
[Releases](https://github.com/jonasgoth/clawdy/releases) and open it, then drag
the crab onto Applications.

![The Clawdy installer window: drag the crab into Applications](docs/install.png)

The build is ad-hoc signed and not notarized, so the first time you launch it,
right-click Clawdy in Applications and choose **Open**.

### Build from source

You need Xcode or the Command Line Tools.

```bash
git clone https://github.com/jonasgoth/clawdy.git
cd clawdy
./build.sh --run
```

That assembles `build/Clawdy.app` — with the pet artwork copied into its
`Resources` — and launches it. Run the binary in `.build/` directly and the pets
fall back to a plain pixel crab, which looks like a bug and is not one.

To roll your own installer:

```bash
tools/make-dmg.sh
```

This writes `build/Clawdy-<version>.dmg` with the drag-to-Applications layout. It
asks for permission to control Finder the first time, because Finder is what
arranges the window; decline and you still get a working DMG, just a plain file
list.

## The menu

Click the crab in the menu bar. It lists your live sessions — click a row to go
to that chat — over a grid of switches:

- **Crab visibility** — show or hide the pets without quitting.
- **Sounds** — a soft chime when a job finishes, a pop when one needs you. Off by
  default, since Claude Code already makes its own noise.
- **Instant updates** — installs Claude Code hooks so pets react the moment a
  chat needs permission or finishes, instead of a beat later. It edits
  `~/.claude/settings.json` and backs it up first. Optional.
- **Crab positions** — line everyone back up.
- **Window checks** — appears only until you grant it. Accessibility access buys
  exact Dock bounds and tells Clawdy when you have really looked at a Cowork
  chat. Optional.

## How it works

Clawdy reads what Claude already leaves on disk: the live-session list in
`~/.claude/sessions`, the transcripts in `~/.claude/projects`, the Desktop app's
chat metadata (which records when you last opened a chat), and Cowork's audit
log. Folders are watched with FSEvents, so it idles at a few percent CPU. With
instant updates on, hooks push state changes the moment they happen.

[PLAN.md](PLAN.md) has the full design, including exactly how the "seen" rule
decides you have looked.

To watch it think:

```bash
CLAWDY_DEBUG=1 build/Clawdy.app/Contents/MacOS/Clawdy
```

## Redrawing the art

The pets are animated SVGs in `Assets/pets/src/`, baked into PNG frame sheets.
The app icon and the installer backdrop are drawn by script too — no hand-editing
of pixels anywhere. All three need Google Chrome, which does the SVG-to-PNG pass.

```bash
tools/render-pets.py           # Assets/pets/<state>.png + manifest.json
tools/make-icon.py             # Assets/AppIcon.svg + .png + .icns
tools/make-dmg-background.py   # Assets/dmg/background.tiff
```

`tools/make-icon.py --theme dark` swaps the cream plate for a dark one.

## Contributing

Issues and pull requests are welcome. If something looks wrong, a debug log (see
above) helps a lot.

## Credits

- The animated pets are **[clawd-pet](https://github.com/abderrahimghazali/clawd-pet)**
  by Abderrahim Ghazali (MIT). Browse them at
  [clawd-pet.vercel.app](https://clawd-pet.vercel.app).
- The pixel baby crab frames come from
  [claude-status-bar](https://github.com/m1ckc3s/claude-status-bar) by m1ckc3s (MIT).
- Inspired by [so-agentbar](https://github.com/sotthang/so-agentbar).

"Claude" and Clawd belong to Anthropic. Clawdy is an unofficial side project, not
affiliated with or endorsed by Anthropic. See
[Assets/ATTRIBUTION.md](Assets/ATTRIBUTION.md) for details.

## License

[MIT](LICENSE). This covers the code in this repository only and conveys no
rights to Anthropic's trademarks or artwork.

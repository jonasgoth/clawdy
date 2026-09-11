# Clawdy

Little Clawd pets on your Mac desktop. One per Claude session.
They tell you who is working, who is done, and who needs you.

![Clawdy crabs along the bottom of a Mac screen](docs/screenshot.png)

- Every Claude session gets a pet: Claude Code in the terminal, the Desktop app's Code tab, and Cowork.
- The pose says what it's doing: coding, holding a tool, celebrating, sleeping, dizzy.
- A badge says what it needs: green check = done, red ! = wants permission, orange ? = asked you something.
- The "done" badge clears only when you actually look at that chat. Never from clicking the pet.
- Sub-agents show up as tiny pixel baby crabs next to their parent.
- Pets wander in a loose group along the bottom of the screen. Drag them; clicks anywhere else pass through.
- The menu bar icon shows how many are alive and turns red when one needs you.

## Install

Download `Clawdy-<version>.dmg` from Releases, drag Clawdy to Applications, open it.
The first time, right-click → Open (the build is not notarized yet).

Or build it yourself (needs Xcode or the command line tools):

```bash
./build.sh --run
```

## Menu

- **Turn on instant updates** installs Claude Code hooks so pets react the instant a chat needs
  permission or finishes. It edits `~/.claude/settings.json` (backed up first). Optional.
- **Allow window checks** grants Accessibility so Cowork "done" badges clear precisely. Optional.
- **Sounds** plays a soft chime when a job finishes and a pop when one needs you. Off by default.
- **Tidy crabs** lines everyone up.

## How it works

Clawdy reads the files Claude already writes: the live-session list in `~/.claude/sessions`, the
chat transcripts in `~/.claude/projects`, the Desktop app's chat metadata (which records when you
last opened a chat), and Cowork's audit log. Nothing leaves your Mac. Folders are watched with
FSEvents, so it idles at a few percent CPU. See [PLAN.md](PLAN.md) for the full design.

Debugging: `CLAWDY_DEBUG=1 build/Clawdy.app/Contents/MacOS/Clawdy` logs status changes and the
inputs to the "seen" rule.

## Rebuilding the pets

The animated pets come from [clawd-pet](https://github.com/abderrahimghazali/clawd-pet). To re-bake
the frame sheets (needs Google Chrome):

```bash
tools/render-pets.py
```

## Not affiliated

Unofficial. Not made by Anthropic. "Claude" and Clawd belong to Anthropic.
See [Assets/ATTRIBUTION.md](Assets/ATTRIBUTION.md). Code is MIT.

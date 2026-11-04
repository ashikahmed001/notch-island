# Island API

Show alerts and progress on Notch Island from Terminal, scripts, Shortcuts and AI coding agents.

Everything is **local to your Mac**. The app listens on `127.0.0.1:47290` only, and every request needs the secret token in `~/.notchisland/token`, which only your user can read. Turn it on or off in **Settings ▸ Features ▸ Terminal & Island API**.

## The `notch` command

The app writes it to `~/.notchisland/bin/notch` on every launch. Once the shell hook is installed, it's on your `PATH`; otherwise use the full path.

```bash
notch "Build passed ✓" --icon hammer --color green          # quick alert (~3.5 s)
notch "Deploy" --subtitle "staging · v1.4.2" --duration 6   # two-line alert

notch progress deploy "Deploying to staging" 0.4            # start or update a live activity
notch progress deploy "Deploying to staging" 90%            # 0.9, 90 or 90% all work
notch done deploy "Deployed ✓"                              # finish it: green ✓ alert

notch clear                                                  # remove every progress activity
notch ping                                                   # is the app listening?
```

| Option | Meaning |
|---|---|
| `--subtitle text` | Second line, in grey |
| `--icon name` | Any [SF Symbol](https://developer.apple.com/sf-symbols/) name: `hammer`, `sparkles`, `house`… |
| `--color name` | `green red blue orange yellow pink purple cyan teal indigo mint gray white` |
| `--duration s` | How long an alert stays, 1–15 s |
| `--badge text` | Short text beside the camera, e.g. `v1.4` |

## Long-running command alerts (shell hook)

```bash
notch install-hook      # or Settings ▸ Terminal ▸ Shell hook ▸ Connect
```

This adds one line to `~/.zshrc`:

```zsh
[ -f ~/.notchisland/hook.zsh ] && source ~/.notchisland/hook.zsh  # Notch Island
```

From then on, any command that takes longer than your threshold (30 s by default) flashes the island when it finishes: **✓ npm install · 1m 12s** in green, or **✗ swift build · exit 1** in red. It works in every terminal that runs zsh: Terminal, iTerm2, VS Code, Ghostty and others.

**Skipped:**
- commands you stop with Ctrl+C
- interactive tools (`vim`, `ssh`, `less`, `top`…)
- commands typed with a leading space

The threshold, the ignore list and "show command text" are in **Settings ▸ Terminal**. To remove it, run `notch uninstall-hook`.

## AI coding agents

**Claude Code:** Settings ▸ Terminal ▸ AI agents ▸ Claude Code ▸ **Connect**. This adds two hooks to `~/.claude/settings.json`. A copy of your original is saved next to it as `settings.json.before-notch-island`.
- **Stop:** "✨ Claude finished · *project*" in orange
- **Notification:** "✋ Claude needs your input · *project*" in yellow, when it's waiting for permission or idle

Or add them yourself:

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "timeout": 5,
        "command": "~/.notchisland/bin/notch \"Claude finished\" --subtitle \"${CLAUDE_PROJECT_DIR##*/}\" --icon sparkles --color orange" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "timeout": 5,
        "command": "~/.notchisland/bin/notch \"Claude needs your input\" --subtitle \"${CLAUDE_PROJECT_DIR##*/}\" --icon hand.raised.fill --color yellow" } ] }
    ]
  }
}
```

**GitHub Copilot CLI:** Settings ▸ Terminal ▸ AI agents ▸ GitHub Copilot CLI ▸ **Connect**. This writes `~/.copilot/hooks/notch-island.json`:

```json
{
  "version": 1,
  "hooks": {
    "agentStop": [
      { "type": "command", "timeoutSec": 5,
        "bash": "~/.notchisland/bin/notch \"Copilot finished\" --subtitle \"${PWD##*/}\" --icon sparkles --color blue" }
    ]
  }
}
```

Restart running Claude Code or Copilot CLI sessions after connecting, because both read their hooks at startup.

## Shortcuts

In the Shortcuts app, add a **Run Shell Script** action:

```bash
~/.notchisland/bin/notch "Leaving home" --icon house --color blue
```

Combine it with Shortcuts **Automations** (time of day, Focus changes, joining Wi-Fi, opening an app) to make the island react to anything.

Alternatively, use **Get Contents of URL**:
- **URL:** `http://127.0.0.1:47290/v1/show`
- **Method:** POST
- **Header:** `Authorization: Bearer <your token>` (Settings ▸ Terminal ▸ Copy token)
- **Request Body:** JSON, with `title`, plus optional `subtitle`, `icon`, `color`

## HTTP reference

All endpoints take form-encoded or JSON bodies and return JSON (`{"ok": true}` or `{"ok": false, "error": "…"}`).

| Endpoint | Fields |
|---|---|
| `POST /v1/show` | `title`*, `subtitle`, `badge`, `icon`, `color`, `duration` |
| `POST /v1/progress` | `id`*, `title`*, `value` (`0.4`, `40`, `40%`), `icon`, `color` |
| `POST /v1/done` | `id`*, `title`, `subtitle`, `icon`, `color` |
| `POST /v1/clear` | none |
| `POST /v1/command-finished` | `cmd`, `seconds`, `exit`, `dir` (used by the shell hook) |
| `GET /v1/ping` | none; needs no token |

```bash
curl -s localhost:47290/v1/show \
  -H "Authorization: Bearer $(cat ~/.notchisland/token)" \
  -d title="Hello from curl" -d icon=sparkles -d color=pink
```

**Limits:**
- 10 requests per second
- titles up to 80 characters
- progress activities clear themselves after 10 minutes without an update
- requests from web browsers (anything sending an `Origin` header) are refused

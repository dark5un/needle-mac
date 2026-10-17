# needle-mac

Apple-Writing-Tools-style text actions on macOS, served by a **local** LLM
first and a secondary OpenAI-compatible endpoint as fallback. The macOS port
of [needle-writes](https://github.com/dark5un/needle-writes) (Hyprland/Wayland).

Select text, hit a hotkey (or right-click > Services), get it proofread /
shortened / retoned / summarized / translated / rewritten / agentified /
publisher-reviewed — the result lands back where your cursor is.

## Privacy

With only `endpoint` set (a local engine), nothing leaves your machine.
**Enabling `fallback_endpoint` means your selected text is sent to that
second server** whenever the local one fails — use an `https://` URL unless
you trust the network, and know that the text also passes through whatever
model that endpoint serves. Every fallback use is logged to
`~/Library/Logs/needle-mac.log`. API keys live in mode-600 env files, are
read at runtime, and are never logged or stored in the config.

## How it maps from Wayland to macOS

| needle-writes (Wayland) | needle-mac (macOS) |
| --- | --- |
| `ext_data_control` selection read/claim | `NSPasteboard` + synthesized Cmd+C |
| `zwp_virtual_keyboard` paste | `CGEvent` Cmd+V injection |
| fuzzel palette | native NSPanel palette (type to filter) |
| compositor keybind | Carbon global hotkey (default `ctrl+opt+o`) |
| one-shot binary | resident menu-bar daemon (launchd) |
| — (impossible on Wayland) | **Services menu**: every action in any app's text right-click menu, like Apple's Writing Tools — no Accessibility permission needed on that path |

## Install

### On another Mac (no dev tools needed)

Build a package here with `./make_package.sh` (needs the toolchain), then copy
`dist/needle-mac-<version>-macos.tar.gz` (or `.dmg`) to the other Mac:

```sh
tar xzf needle-mac-0.1-macos.tar.gz && cd needle-mac && ./install.sh
```

Connection details can be passed to the installer; they are written to that
Mac's local config and a mode-600 env file, never baked into the app:

```sh
./install.sh --endpoint http://127.0.0.1:8080/v1 --model qwen3.8-flash-next-iq3_xxs \
             --fallback-url https://api.example.com/v1 --fallback-model some-model \
             --fallback-key sk-...
```

(`--key` sets the primary endpoint's key the same way. No credential ships in
the package itself.)

### From source

Requirements: macOS 13+, Xcode Command Line Tools (`xcode-select --install`).

```sh
./install.sh
```

Builds `NeedleMac.app`, installs it to `~/Applications`, copies the config to
`~/.config/needle-mac/config` (existing config is never overwritten), and
enables autostart via launchd. `--no-autostart` skips the login item.

Then:
1. Edit `~/.config/needle-mac/config` — the primary endpoint should be your
   local engine (Strata on `http://127.0.0.1:8080/v1`, Ollama on
   `http://127.0.0.1:11434/v1`, ...). The `fallback_*` keys point at any other
   OpenAI-compatible server; it is used only when the primary fails.
2. Grant Accessibility (System Settings > Privacy & Security > Accessibility)
   — only needed for the hotkey capture/paste path. The Services menu works
   without it.

## Usage

```
ctrl+opt+o                 palette: pick an action, result pasted back (replaces the selection)
ctrl+opt+i                 same palette, but the result goes only to the clipboard
right-click selection      Services > needle: <action>   (result replaces the selection)
needle-mac -list           list actions
echo "text" | needle-mac proofread    one-shot: result on stdout + clipboard
```

Flags: `--no-paste` (result stays on the clipboard, nothing injected),
`--hold` (keep the result claim for a manual paste).

Actions: proofread, shorten, professional, casual, summarize, translate-en,
translate-el, agentify, agentify+, publisher-opinion (original text followed
by a book publisher's assessment of it), book-reviewer (original text followed
by a literary reviewer's critique, aimed at novels and poetry).

## Config

`~/.config/needle-mac/config` (or `$XDG_CONFIG_HOME/needle-mac/config`),
`KEY = VALUE` lines, `#` comments. Precedence: env > config file > default.
An unknown key is a startup error (typos in `key_file` are worse than failing
loud). Keys: `endpoint`, `model`, `key_file`, `key_var`, `fallback_endpoint`,
`fallback_model`, `fallback_key_file`, `fallback_key_var`, `hotkey`,
`copy_combo`, `paste_combo`, `max_tokens`, `timeout`.

API keys come from `NEEDLE_API_KEY` / `NEEDLE_FALLBACK_API_KEY` in the
environment, or from an env-format file named by `key_file` /
`fallback_key_file` (variable `key_var` / `fallback_key_var`, default
`API_KEY`). Keys are read at runtime, never logged.

## Exit codes (one-shot mode)

| Code | Meaning |
| --- | --- |
| 0 | result claimed / printed |
| 1 | engine failed on both endpoints (nothing pasted) |
| 2 | nothing selected |
| 3 | selection larger than the model budget |
| 64 | usage / config error |

## Development

```sh
./build.sh        # -> needle-mac + NeedleMac.app (ad-hoc signed)
```

Single Swift file (`Sources/needle-mac/main.swift`), no dependencies beyond
Cocoa/Carbon. The Services menu requires the .app bundle with the `NSServices`
entries in `Info.plist`; ad-hoc signing keeps the Accessibility grant stable
across rebuilds.

MIT

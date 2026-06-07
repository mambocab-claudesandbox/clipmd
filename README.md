# clipmd

Transform URLs on your **clipboard** — or in a **Unix pipe** — into clean
Markdown links *and* real rich-text hyperlinks, driven by rules in a config
file.

Copy a ticket URL like `https://acme.ticketsystem.com/ABC-123`, hit the menu-bar
item (or a global hotkey), and your clipboard now holds:

| Representation | Pasted into | Result |
| --- | --- | --- |
| plain text (Markdown) | editor, Slack, code | `[ABC-123](https://acme.ticketsystem.com/ABC-123)` |
| rich text (HTML/RTF) | Mail, Pages, docs | [ABC-123](#) (a real clickable link showing `ABC-123`) |

The exact same transformation is available from the command line over pipes, and
there's a daemon mode that backs both the menu bar and the CLI.

Written in [Zig](https://ziglang.org) (0.16). The macOS GUI talks directly to
AppKit/Carbon through the Objective-C runtime — no Objective-C, Swift, or
third-party packages.

---

## What it does

* **Menu-bar item** (NSStatusItem): click **Transform Clipboard**.
* **Global hotkey**: <kbd>⌘</kbd><kbd>⇧</kbd><kbd>M</kbd>, registered via Carbon
  `RegisterEventHotKey` (no Accessibility permission required).
* On trigger it reads the clipboard, rewrites matching URLs, and writes back
  **three** representations (plain Markdown, HTML, RTF) so every app pastes the
  richest form it understands.
* **CLI / pipes**: every transformation is exposed for stdin → stdout use.
* **Daemon mode**: a background process serves a Unix socket so the CLI can
  trigger a clipboard transform (`clipmd run`) or transform a pipe through the
  daemon (`clipmd send`). On macOS the daemon also owns the menu bar + hotkey.

## Rules

Rules live in a line-oriented config file (default
`~/.config/clipmd/rules.conf`, override with `-c` or `$CLIPMD_CONFIG`):

```
# <url-pattern>  =>  <display-template>
*.ticketsystem.com/{id}              => {id}
github.com/{owner}/{repo}/pull/{n}   => {owner}/{repo}#{n}
*.atlassian.net/browse/{key}         => {key}
```

Pattern syntax (a small, predictable wildcard language — anchored, whole-URL):

| Token | Matches |
| --- | --- |
| `*` | any run of characters except `/` |
| `{name}` | a captured run of `[^/?#]+` |
| `{name...}` | a captured run that may span `/` |
| anything else | matched literally |

The scheme (`https://`) and a leading `www.` are ignored unless the pattern
itself contains `://`. The display template substitutes `{name}` with the
captured value (`{{`/`}}` produce literal braces).

Behavior by output format:

* **Markdown** — a matched URL becomes `[display](url)`; unmatched URLs are left
  untouched so plain text stays clean.
* **HTML / RTF** — a matched URL becomes a real hyperlink showing `display`;
  unmatched URLs are still linkified (URL as its own text), so the rich
  clipboard always has clickable links.

URLs embedded in prose are detected and trailing sentence punctuation is
trimmed, so `Fixed in https://github.com/ziglang/zig/pull/42.` works.

---

## Build

Requires Zig **0.16.0**.

### Portable core + CLI (any OS)

```sh
zig build              # produces zig-out/bin/clipmd
zig build test         # run the unit tests
```

On non-macOS systems the pipe and daemon transforms work; the OS-clipboard
commands (`clip`, `run`) report that the system clipboard is macOS-only.

### macOS app bundle

On a Mac with the Xcode command-line tools:

```sh
macos/bundle.sh -Doptimize=ReleaseFast
open zig-out/clipmd.app          # menu-bar item appears
```

To use the CLI too, symlink the bundled binary onto your `PATH`:

```sh
ln -s "$PWD/zig-out/clipmd.app/Contents/MacOS/clipmd" /usr/local/bin/clipmd
```

> This project is developed in a Linux sandbox without the macOS SDK, so it
> cannot *link* the final Mac binary here. The macOS sources are continuously
> compile-checked for the `aarch64-macos` target with `zig build check-macos`
> (full semantic analysis + codegen, no link). Linking happens on a Mac via
> `zig build` / `macos/bundle.sh`.

---

## Usage

```
clipmd [transform] [-f md|html|rtf] [-c CONFIG]   transform stdin -> stdout (default)
clipmd clip [-c CONFIG]                           transform the macOS clipboard in place
clipmd daemon [-c CONFIG]                         run the menu-bar / socket daemon
clipmd run                                        ask the daemon to transform the clipboard
clipmd send [-f md|html|rtf]                      pipe stdin through the daemon
clipmd config path|init|show [-c CONFIG]          manage configuration
clipmd version | help
```

### Pipes

```sh
$ echo -n 'https://acme.ticketsystem.com/ABC-123' | clipmd
[ABC-123](https://acme.ticketsystem.com/ABC-123)

$ echo -n 'https://acme.ticketsystem.com/ABC-123' | clipmd -f html
<a href="https://acme.ticketsystem.com/ABC-123">ABC-123</a>

$ echo -n 'https://team.atlassian.net/browse/PROJ-7' | clipmd -f rtf
{\rtf1\ansi...{\field{\*\fldinst{HYPERLINK "..."}}{\fldrslt \cf1 \ul PROJ-7}}}
```

### Clipboard (macOS)

```sh
clipmd clip          # one-shot: transform whatever's on the clipboard now
```

### Daemon + trigger

```sh
clipmd daemon &      # menu bar + hotkey + socket (foreground service)
clipmd run           # same effect as clicking the menu item
echo -n 'https://github.com/a/b/pull/3' | clipmd send -f html   # via the daemon
```

### Config

```sh
clipmd config init   # write an example rules file to the default path
clipmd config show   # list loaded rules
clipmd config path   # print the resolved config path
```

### Environment

| Variable | Purpose | Default |
| --- | --- | --- |
| `CLIPMD_CONFIG` | rules file path | `~/.config/clipmd/rules.conf` |
| `CLIPMD_SOCK` | daemon socket path | `$TMPDIR/clipmd.sock` |

---

## Architecture

```
src/
  main.zig            CLI: argument parsing and subcommand dispatch
  transform.zig       engine: scan text for URLs, apply rules, render md/html/rtf
  pattern.zig         wildcard pattern matcher with named captures
  config.zig          rules-file parser
  rtf.zig             RTF document + hyperlink-field generation
  ipc.zig             Unix-socket daemon server + client (libc sockets)
  clipboard.zig       platform clipboard abstraction
  macos/
    objc.zig          minimal Objective-C runtime bindings + msgSend
    pasteboard.zig    NSPasteboard read / multi-type write
    menubar -> app.zig NSStatusItem menu, app lifecycle, event loop
    hotkey.zig        Carbon global hotkey (⌘⇧M)
    Info.plist        accessory (LSUIElement) bundle metadata
    bundle.sh         package zig-out/clipmd.app
```

The portable core (`pattern`, `config`, `rtf`, `transform`, `ipc`) is unit
tested and runs on any platform. The macOS layer is isolated behind
`clipboard.zig` and only compiled into the binary for macOS targets.

### Wire protocol

One request per connection; the client half-closes its write side, the server
reads to EOF, replies, and closes:

```
PING\n                      -> PONG\n
CLIP\n                      -> OK matched=<n> total=<m>\n   (or ERR ...)
TRANSFORM:<fmt>\n<body...>  -> <transformed body>
```

## Limitations / notes

* The pattern language is intentionally not full regex (the Zig standard library
  has none); the wildcard + capture syntax covers the URL-rewriting use case.
* Astral-plane Unicode in display text is emitted as RTF surrogate pairs; very
  exotic clipboard content falls back gracefully.
* The global hotkey (⌘⇧M) and menu title are currently fixed; both are small,
  localized changes in `macos/hotkey.zig` / `macos/app.zig`.

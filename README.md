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
third-party packages, and **no `.app` bundle**: the CLI hosts the menu bar
itself when run as `clipmd daemon`.

---

## What it does

* **Menu-bar item** (NSStatusItem): click **Transform Clipboard**.
* **Global hotkey**: configurable (default <kbd>⌘</kbd><kbd>⇧</kbd><kbd>M</kbd>),
  registered via Carbon `RegisterEventHotKey` (no Accessibility permission
  required).
* On trigger it reads the clipboard, rewrites matching URLs, and writes back
  **three** representations (plain Markdown, HTML, RTF) so every app pastes the
  richest form it understands.
* **CLI / pipes**: every transformation is exposed for stdin → stdout use.
* **Daemon mode** (`clipmd daemon`): a background process that, on macOS, owns the
  menu bar + hotkey, and on every platform serves a Unix socket so the CLI can
  trigger a clipboard transform (`clipmd run`) or transform a pipe through the
  daemon (`clipmd send`).

## Configuration

Config is a [ZON](https://ziglang.org/documentation/master/std/#std.zon) file
(Zig Object Notation — Zig's own data-literal syntax), parsed with `std.zon`. The
default path is `~/.config/clipmd/config.zon` (override with `-c` or
`$CLIPMD_CONFIG`). Run `clipmd config init` to write a commented starter file.

```zig
.{
    .hotkey = "cmd+shift+m",
    .rules = .{
        .{ .match = "*.ticketsystem.com/{id}", .display = "{id}" },
        .{ .match = "github.com/{owner}/{repo}/pull/{n}", .display = "{owner}/{repo}#{n}" },
        .{ .match = "*.atlassian.net/browse/{key}", .display = "{key}" },
    },
}
```

Both fields are optional: omit `.rules` for none, omit `.hotkey` for the default.
ZON supports `//` comments and multiline strings.

**Why ZON?** It's the one config language with a Zig-team-maintained parser in
the standard library (the alternatives in `std` are JSON, which has no comments,
and parsing Zig source itself). ZON is native, hand-editable, gives typed
deserialization straight into a struct, and yields good `line:column` error
messages for free.

**Invalid config is fatal.** clipmd fails hard on startup (non-zero exit) for
malformed ZON, an unknown field, an invalid `hotkey`, or an empty `match` —
rather than silently ignoring it. ZON errors include the location, e.g.
`1:17: error: missing required field display`. A *missing* file is only an error
when you named it explicitly with `-c`/`$CLIPMD_CONFIG`; the default location may
be absent (pipe transforms then just pass unmatched URLs through).

### Keybinding (`hotkey`)

The global hotkey is configurable. Combine modifiers and one key with `+`
(case- and whitespace-insensitive):

* modifiers: `cmd`/`command`/`super`, `shift`, `opt`/`option`/`alt`,
  `ctrl`/`control`
* key: a letter/digit/punctuation character, or a named key (`space`, `return`,
  `tab`, `escape`, `delete`)

Examples: `.hotkey = "cmd+shift+m"`, `"ctrl+opt+t"`, `"cmd+1"`. An invalid spec
is a hard startup error (see "Invalid config is fatal" above). The default when
`.hotkey` is omitted is `cmd+shift+m`.

### Rules

Pattern syntax — a small, predictable wildcard language (anchored, whole-URL):

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

```sh
zig build              # produces zig-out/bin/clipmd
zig build test         # run the unit tests
```

On non-macOS systems the pipe and daemon transforms work; the OS-clipboard
commands (`clip`, `run`) report that the system clipboard is macOS-only.

### Testing

Unit tests (the portable core) run anywhere:

```sh
zig build test
```

End-to-end CLI tests use [bats](https://github.com/bats-core/bats-core)
(`brew install bats-core`):

```sh
bats test/                 # runs both suites
```

* `test/transform.bats` — pipes, daemon, and config behavior; portable.
* `test/clipboard.bats` — exercises the real macOS pasteboard via `clipmd clip`
  and the daemon's `run` trigger, using `pbcopy`/`pbpaste`/`osascript`. These
  **auto-skip off macOS**, so the suite is green everywhere and meaningful on a
  Mac.

### Running on macOS

There is no app bundle. Build on a Mac (Xcode command-line tools provide the SDK
Zig links against), put the binary on your `PATH`, and start the daemon:

```sh
zig build -Doptimize=ReleaseFast
cp zig-out/bin/clipmd /usr/local/bin/clipmd
clipmd daemon &        # menu-bar item appears; global hotkey is active
```

A plain (unbundled) Mach-O binary can host an `NSStatusItem` and a Carbon global
hotkey, so `clipmd daemon` is all you need. To start it at login, point a
launchd agent at `clipmd daemon` (`~/Library/LaunchAgents/…plist` with
`ProgramArguments` `["/usr/local/bin/clipmd", "daemon"]`).

> This project is developed in a Linux sandbox without the macOS SDK, so it
> cannot *link* the final Mac binary here. The macOS sources are continuously
> compile-checked for the `aarch64-macos` target with `zig build check-macos`
> (full semantic analysis + codegen, no link). Linking happens on a Mac via
> `zig build`.

---

## Usage

```
clipmd [transform] [-f md|html|rtf] [-c CONFIG]   transform stdin -> stdout (default)
clipmd daemon [-c CONFIG]                         run the menu-bar / socket daemon
clipmd clip [-c CONFIG]                           transform the macOS clipboard in place
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
clipmd config init   # write a commented ZON config to the default path
clipmd config show   # list loaded rules
clipmd config path   # print the resolved config path
```

### Environment

| Variable | Purpose | Default |
| --- | --- | --- |
| `CLIPMD_CONFIG` | config file path | `~/.config/clipmd/config.zon` |
| `CLIPMD_SOCK` | daemon socket path | `$TMPDIR/clipmd.sock` |

---

## Architecture

```
src/
  main.zig            CLI: argument parsing and subcommand dispatch
  transform.zig       engine: scan text for URLs, apply rules, render md/html/rtf
  pattern.zig         wildcard pattern matcher with named captures
  config.zig          ZON config parser (std.zon) -> rules + settings
  keybind.zig         parse "cmd+shift+m" -> Carbon key code + modifier mask
  rtf.zig             RTF document + hyperlink-field generation
  ipc.zig             Unix-socket daemon server + client (libc sockets)
  clipboard.zig       platform clipboard abstraction
  macos/
    objc.zig          minimal Objective-C runtime bindings + msgSend
    pasteboard.zig    NSPasteboard read / multi-type write
    app.zig           NSStatusItem menu, app lifecycle, event loop
    hotkey.zig        Carbon global hotkey (configurable)
test/
  transform.bats     portable end-to-end CLI tests (pipes, daemon, config)
  clipboard.bats     macOS pasteboard tests (skip off macOS)
  helper.bash        shared bats setup
```

The portable core (`pattern`, `config`, `keybind`, `rtf`, `transform`, `ipc`) is
unit tested and runs on any platform. The macOS layer is isolated behind
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

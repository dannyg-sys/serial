# Serial Terminal (macOS) + Claude Code skill

A native macOS SwiftUI terminal for talking to serial devices — **locally** over
USB/Bluetooth serial, or **remotely over SSH** (a login shell, or a serial device
attached to a remote box, e.g. a scale on a deployed Linux terminal). It's a real
VT100/xterm terminal (arrow keys, Ctrl-C, colors, TUIs), and it exposes a small
**loopback HTTP control API** so **Claude Code can watch the live traffic, send
data, and open/close connections** through the bundled skill — sharing the one
open connection.

```
 SerialTerminal.app  ──HTTP 127.0.0.1:8765──►  Claude Code `serial` skill
   owns the connection    /status /read /write        curl-based helper
   termios | ssh (PTY)    /connect /sessions …
        │
   ├─ /dev/cu.*  (local serial, via termios)
   ├─ ssh host  (system ssh in a PTY: shell, or bridge a remote /dev/tty*)
   └─ HID bridge (Bluetooth dongle that types as a USB keyboard on its host)
```

Claude Desktop reaches the same API through the bundled MCP shim (see below).

## Requirements
- macOS 13+, Swift 5.9+ (`swift --version`).
- One dependency: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT)
  — the VT/xterm terminal emulator. Fetched automatically by SwiftPM.

## Build & run

Dev (terminal):
```bash
swift run SerialTerminal
```

Double-clickable app bundle (with icon):
```bash
scripts/build-app.sh          # produces ./SerialTerminal.app
open SerialTerminal.app        # or drag it to /Applications
```

## Using the GUI

On launch (or **Open Connection…**) a picker appears with a **USB / Network /
Bluetooth / Other** sidebar:

- **USB / Bluetooth / Other** — local serial ports. Pick one, set baud / data /
  parity / stop, **Open**. Baud is free-text: `115200`, `1500000`, `1.5M`, `1500k`.
- **Bluetooth ▸ T-Dongle HID bridge** — type on a device that has no keyboard
  (see *HID keyboard bridge* below).
- **Network** — connect over SSH. Filter your `~/.ssh/config` hosts (type `tora`
  to narrow), or type `user@host`. Either open a **login shell**, or tick
  **Attach serial device** to bridge a remote `/dev/tty*` right away.

Once connected it's a real terminal — click it and type. The window **title**
shows the connection. Toolbar:
- **Echo** — local echo (leave off; most devices echo).
- **Send Size** / **Auto** (serial only) — push `stty rows/cols` so the remote
  TTY matches the window (fixes readline/TUI wrapping). Auto does it on
  connect/resize. SSH negotiates its PTY size automatically, so this is hidden.
- **Attach Device…** (SSH only) — scan the remote host for serial devices and
  bridge the chosen one into the terminal (Ctrl-C returns to the shell).

### SSH details
The app runs the **system `ssh`** inside a PTY, so it reuses your `~/.ssh/config`
(including `Include`s), keys, agent, `HostName`/`User`/`ProxyJump`, and inline
password/2FA prompts — nothing is reimplemented. Remote device discovery runs a
separate non-interactive `ssh host 'find /dev …'` and prefers `socat` for the
bridge, falling back to `cat` (read works) when socat isn't installed.

### Multiple connections
Each **window is its own connection** with its own API port (8765, 8766, …).
Open another with **⌘N**. The status bar shows that window's API port.

### HID keyboard bridge
For devices with no keyboard and no network (a TV browser, a login prompt, a
headless box): a LilyGO T-Dongle-S3 running the
[t-dongle-hid-bridge](../t-dongle-hid-bridge) firmware plugs into the target's
USB port and shows up there as a keyboard. Pick **Bluetooth ▸ T-Dongle HID
bridge** in the picker; the app finds the dongle and links to it.

- Whatever you type in the terminal is typed on the target, including arrows,
  Tab, Esc, Backspace and Ctrl-combinations. Paste works the same way.
- Typing is paced at about 30 characters a second and each chunk is confirmed by
  the dongle. The terminal shows what has been confirmed; the dongle is
  write-only, so nothing from the target's screen comes back.
- ASCII only, US keyboard layout on the target.
- If the dongle is unplugged (e.g. moved to another device) the app waits and
  relinks by itself. Input typed while unlinked is dropped, not queued.
- If the dongle's USB side is plugged into this same Mac, keyboard input from the
  terminal is refused: it would be typed straight back into the window in a loop.
  The API can still type (useful for testing into another app).
- First use asks for Bluetooth permission. The app is ad-hoc signed, so macOS may
  ask again after a rebuild.

## Using it from Claude Code
The skill lives at `.claude/skills/serial-terminal/` (symlink it into
`~/.claude/skills/` to use it from any project). Ask things like *"what is the
serial port showing?"*, *"connect to pos_scangle and watch the scale"*, or
*"send AT and read the reply"*.

Manual helper usage:
```bash
serial=.claude/skills/serial-terminal/serial

$serial sessions                      # list open windows (each is a port)
$serial --port 8766 status            # target a specific window

# Local serial
$serial ports
$serial connect /dev/cu.usbserial-1130 1500000
$serial send "AT"; sleep 1; $serial read
$serial watch 30                       # live stream
$serial hex 01 ff 0d                   # raw bytes

# SSH
$serial sshhosts tora                  # discover ~/.ssh/config hosts
$serial ssh pos_scangle                # login shell
$serial rdevices                       # list the remote's serial devices
$serial attach /dev/ttyUSB0 9600       # bridge a remote device
$serial ssh pos_scangle /dev/ttyUSB0 9600   # connect + attach in one step

# HID keyboard bridge
$serial hid                            # link to the dongle
$serial send "https://example.com"     # type it, then Enter
$serial sendraw "admin"; $serial key tab
$serial combo ctrl+alt+t
$serial keydelay 40                    # slower typing for a sluggish target
```

## Using it from Claude Desktop (MCP)
Claude Desktop needs MCP rather than a skill, so the app bundle includes a small
stdio shim, `SerialTerminal.app/Contents/MacOS/serial-mcp`. It owns no
connection: every tool call is forwarded to the running app's loopback API, so
Claude, the GUI and the skill all share the one link. Add it to
`~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
"serial-terminal": {
  "command": "/path/to/SerialTerminal.app/Contents/MacOS/serial-mcp"
}
```

Tools: `sessions`, `status`, `connect_serial`, `connect_ssh`, `connect_hid`,
`disconnect`, `read`, `write`, and for the HID bridge `press_key`, `send_combo`,
`set_key_delay`. All take an optional `port` to address a specific window. The
app must be running; the shim says so if it is not.

## HTTP API (loopback only)
| Method | Path | Body / query | Notes |
|---|---|---|---|
| GET | `/sessions` | | all open windows: `{port,label,connected}` |
| GET | `/status` | | `{connected,kind,label,port,host,baud,…,rxBytes,txBytes}` |
| GET | `/ports` | | local `/dev/cu.*` devices |
| GET | `/sshhosts` | | `~/.ssh/config` host aliases |
| GET | `/read` | `?offset=N` | bytes since offset N (`text` + `base64`) |
| POST | `/write` | raw body, or `{text,newline,base64}` | on hid: types the text and answers when done (`typed`) |
| POST | `/connect` | serial: `{port,baud,dataBits,parity,stopBits}` · ssh: `{type:"ssh",host,device?,baud?,command?}` · hid: `{type:"hid",name?}` | hid links in the background; `/status` has `linked` |
| POST | `/hid` | `{key}` · `{combo}` · `{delay}` · `{layout}` | (hid) special key, combination, key gap in ms, target layout |
| POST | `/disconnect` | | |
| GET | `/rdevices` | | (ssh) `{devices,hasSocat}` |
| POST | `/attach` | `{device,baud}` | (ssh) bridge a remote device |

`GET /` returns a short help page. Any window's `/sessions` lists them all; use
`SERIAL_API_PORT` or `serial --port N` to target a specific one.

## Architecture
A `Transport` protocol abstracts the byte pipe so the session, terminal, and API
don't care what's underneath:
- `SerialTransport` — POSIX/termios; arbitrary baud via `IOSSIOSPEED`.
- `SSHTransport` — system `ssh` in a PTY (SwiftTerm `LocalProcess`).
- `HIDBridgeTransport` — CoreBluetooth link to the keyboard-bridge dongle. It
  translates the terminal's byte stream (text, CR, control bytes, xterm escape
  sequences) into the dongle's type / key / combo messages and sends them one at
  a time with acknowledged writes.

`Sources/SerialMCP` is the separate stdio MCP shim.

(TCP / RFC2217 network-serial backends can slot in the same way.)

## Loopback testing without hardware
```bash
brew install socat
socat -d -d pty,raw,echo=0 pty,raw,echo=0      # prints two /dev/ttys… paths
```
Connect the app to one PTY (type the `/dev/ttysNNN` path via
`serial connect /dev/ttysNNN`); write to the other and it appears in the terminal
and via `serial read`.

## Notes
- The API binds to `127.0.0.1` only — not reachable from other machines.
- The receive buffer retains the last ~1 MiB for the API.
- Non-standard baud rates use the macOS `IOSSIOSPEED` ioctl.

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
   └─ ssh host  (system ssh in a PTY: shell, or bridge a remote /dev/tty*)
```

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
```

## HTTP API (loopback only)
| Method | Path | Body / query | Notes |
|---|---|---|---|
| GET | `/sessions` | | all open windows: `{port,label,connected}` |
| GET | `/status` | | `{connected,kind,label,port,host,baud,…,rxBytes,txBytes}` |
| GET | `/ports` | | local `/dev/cu.*` devices |
| GET | `/sshhosts` | | `~/.ssh/config` host aliases |
| GET | `/read` | `?offset=N` | bytes since offset N (`text` + `base64`) |
| POST | `/write` | raw body, or `{text,newline,base64}` | |
| POST | `/connect` | serial: `{port,baud,dataBits,parity,stopBits}` · ssh: `{type:"ssh",host,device?,baud?,command?}` | |
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

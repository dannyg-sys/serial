# Serial Terminal (macOS) + Claude Code skill

A native macOS SwiftUI serial terminal. Pick a serial interface, set the port
parameters (baud / data bits / parity / stop bits), and type to send. The app
also runs a small **loopback HTTP control API** so **Claude Code can watch the
live serial traffic and send data** through the bundled skill — sharing the one
open connection (a serial device can only be opened by a single process).

```
 SerialTerminal.app  ──HTTP 127.0.0.1:8765──►  Claude Code `serial` skill
   owns /dev/cu.*        /ports /status /read        curl-based helper
   termios + Network     /write /connect /disconnect
```

## Requirements
- macOS 13+, Xcode command line tools / Swift 5.9+ (`swift --version`).
- No third-party dependencies (SwiftUI, AppKit, Network, Darwin only).

## Build & run

Dev (terminal):
```bash
swift run SerialTerminal
```

Double-clickable app bundle:
```bash
scripts/build-app.sh          # produces ./SerialTerminal.app
open SerialTerminal.app       # or drag it to /Applications
```

## Using the GUI
1. Pick a port from the dropdown (click ↻ to rescan after plugging in a device).
2. Set baud / data / parity / stop.
3. **Connect**. Received data streams into the monospaced view.
4. Type in the input box, choose a line ending (None/CR/LF/CRLF), press **Send**
   (or Return). Changing a setting while connected reconfigures the live port.

The status bar shows connection state, RX/TX byte counts, and the API address.

## Using it from Claude Code
The skill lives at `.claude/skills/serial-terminal/` and is auto-discovered when
Claude Code runs in this repo. Ask Claude things like *"what is the serial port
showing?"*, *"send AT and read the reply"*, or *"watch the serial output"*.

Manual helper usage:
```bash
.claude/skills/serial-terminal/serial status
.claude/skills/serial-terminal/serial ports
.claude/skills/serial-terminal/serial connect /dev/cu.usbserial-1420 115200
.claude/skills/serial-terminal/serial send "AT"
.claude/skills/serial-terminal/serial read        # incremental
.claude/skills/serial-terminal/serial watch 30     # live stream
.claude/skills/serial-terminal/serial hex 01 ff 0d # raw bytes
```

## HTTP API (loopback only)
| Method | Path | Body / query | Returns |
|---|---|---|---|
| GET | `/ports` | | `{"ports":[…]}` |
| GET | `/status` | | connection + settings + counters |
| GET | `/read` | `?offset=N` | bytes received since offset N (`text` + `base64`) |
| POST | `/write` | raw body, or `{text,newline,base64}` | `{written}` |
| POST | `/connect` | `{port,baud,dataBits,parity,stopBits}` | `{connected}` |
| POST | `/disconnect` | | `{connected:false}` |

`GET /` returns a short help page.

## Loopback testing without hardware
```bash
brew install socat
socat -d -d pty,raw,echo=0 pty,raw,echo=0      # prints two /dev/ttys… paths
```
Connect the app to one PTY; write to the other and it appears in the app / via
`serial read`. (Note: PTYs show up as `/dev/ttys…`, not `/dev/cu.*`; use
`serial connect /dev/ttysNNN` directly for loopback tests.)

## Notes
- Non-standard baud rates are applied via the macOS `IOSSIOSPEED` ioctl.
- The receive buffer retains the last ~1 MiB for the API; the on-screen log keeps
  the last ~200k characters.
- The API binds to `127.0.0.1` only — it is not reachable from other machines.

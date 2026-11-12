---
name: serial-terminal
description: Observe and drive a live serial connection owned by SerialTerminal.app. Use when the user is working with a serial device (UART, modem, microcontroller, USB-serial adapter) and wants Claude to see incoming serial data, send commands/bytes, or open/close/reconfigure the port while the GUI terminal is running. Also drives the Bluetooth HID keyboard-bridge dongle through the same app: typing text, keys and combos as a USB keyboard on a TV or headless box that has no keyboard. Triggers on "what is the serial port showing", "send this to the serial device", "watch the serial output", "connect to /dev/cu.*", AT commands, baud rate, "type this on the TV / on the box", "use the dongle".
---

# Serial Terminal skill

SerialTerminal.app (a native macOS SwiftUI app in this repo) owns the serial
port and exposes a **loopback HTTP API on `127.0.0.1:8765`**. A serial device can
only be opened by one process, so you never open `/dev/cu.*` directly — you share
the app's open connection through this API. The `serial` helper script in this
skill directory wraps it.

## Prerequisites
The app must be running. If `serial status` reports it's unreachable, tell the
user to launch it: `open SerialTerminal.app` (or `swift run SerialTerminal` from
the repo during dev). Do not try to open the serial device yourself.

## The `serial` helper
Run it from this skill directory (or add it to PATH):

```
.claude/skills/serial-terminal/serial <command>
```

| Command | What it does |
|---|---|
| `serial status` | JSON: connected?, kind (serial/ssh), label, port/host, settings, RX/TX bytes |
| `serial ports` | list available `/dev/cu.*` devices |
| `serial sshhosts [filter]` | list `~/.ssh/config` host aliases (optional substring filter) |
| `serial ssh <host> [dev] [baud]` | connect over SSH; with `dev` (e.g. `/dev/ttyUSB0`) bridge that remote serial device, else open a login shell |
| `serial read` | print serial data received **since your last read** (incremental) |
| `serial read --all` | print everything in the retained buffer (last ~1 MiB) |
| `serial watch [secs]` | stream new data live until the timeout (default 3600s) |
| `serial send <text>` | send text **+ LF newline** (typical for line-based protocols / AT) |
| `serial sendraw <text>` | send text with **no** trailing newline |
| `serial hex 01 ff 0d` | send raw bytes given as hex |
| `serial connect <port> [baud] [databits] [parity] [stopbits]` | open / reconfigure |
| `serial disconnect` | close the port |

`parity` is `none`, `even`, or `odd`. The API port can be overridden with the
`SERIAL_API_PORT` env var.

### SSH connections (remote boxes / remote serial devices)
The app can also connect by running the system `ssh`, so it uses the user's
`~/.ssh/config` (incl. `Include`s), keys, and agent automatically. Two modes:
- **Shell**: `serial ssh pos_scangle` → interactive remote shell.
- **Attach remote device**: `serial ssh pos_scangle /dev/ttyUSB0 9600` → bridges
  that remote serial device (e.g. a scale) to the terminal, so `serial read` /
  `serial watch` tail the device's stream from anywhere on the fleet.

Use `serial sshhosts tora` to find matching host aliases before connecting.

### HID keyboard bridge (type on a device that has no keyboard)
A LilyGO T-Dongle-S3 with the `t-dongle-hid-bridge` firmware plugs into the
target's USB port and appears there as a keyboard. The app links to it over
Bluetooth; whatever is written to that connection is typed on the target.

| Command | What it does |
|---|---|
| `serial hiddevices` | list the dongles in range; each is named `T-Dongle HID <id>` |
| `serial hid [id]` | connect to a dongle and wait until it is linked |
| `serial sendraw <text>` | type the text |
| `serial send <text>` | type the text, then press Enter |
| `serial key <name>` | enter, tab, esc, space, backspace, delete, up, down, left, right, home, end |
| `serial combo <combo>` | e.g. `ctrl+c`, `ctrl+alt+t`, `alt+tab` |
| `serial keydelay <ms>` | gap between keystrokes; default 20 (about 30 chars/s), raise it if the target drops characters |

- There can be several dongles, each plugged into a different device. With more
  than one in range `serial hid` without an id is refused. Never guess: the id is
  printed on each dongle's display, so ask the user which one is in the target.
- Typing is paced, and every command returns only once the dongle confirmed the
  keys went out (`"typed": true`). No sleep is needed between commands.
- The link is **write-only**: you cannot see the target's screen. `serial read`
  returns an echo of what was typed plus link messages, not output from the
  target. To see results, ask the user, or open a second window on the target's
  serial console / SSH and read that (`serial --port 8766 read`).
- Only ASCII is typed, using a US keyboard layout on the target.
- If `serial status` shows `"kind":"hid"` but `"linked":false`, the dongle is
  unplugged or out of range; the app relinks by itself when it returns.

## Typical workflow
1. `serial status` — is it connected, and to what?
2. If not connected, either ask the user to connect in the GUI, or do it:
   `serial connect /dev/cu.usbserial-1420 115200`
3. Send a command and read the reply:
   ```
   serial send "AT"
   sleep 1
   serial read
   ```
4. To follow a chatty device live: `serial watch 30`.

## Notes for Claude
- `serial read` is **incremental** — it remembers an offset per API port in
  `$TMPDIR/serial_offset_<port>`, so repeated calls only show new data. Use
  `--all` to re-dump the buffer from the start.
- After sending a command, give the device a moment (`sleep 0.5`–`2`) before
  `serial read`, since replies arrive asynchronously.
- Received data is decoded as UTF-8 for display; for binary protocols inspect the
  raw bytes via `serial read` output or the `base64` field of `GET /read`.
- The GUI reflects everything you do (and vice-versa) — you and the user share the
  one open connection.
- Raw API is available if you need it: `GET /ports /status /read?offset=N`,
  `POST /write /connect /disconnect`. See `GET /` for the built-in help.

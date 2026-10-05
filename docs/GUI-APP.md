# PM3 tools — Proxmark3 GUI on the stock TrimUI system

A graphical application for the handheld: one-touch Proxmark3 **HF (13.56 MHz)** and **LF (125 kHz)** scans,
with the results shown on screen, operated with the handheld's A / B / left-right keys. It installs on the SD card and appears in the stock "Apps" menu.

---

## Prerequisites

- A TrimUI handheld running the **stock TrimUI OS**, with SDL2 in `/usr/trimui/lib`.
- The PM3 client, either at `/mnt/UDISK/pm3-v423346/` or in `pm3/` next to the app
  (the card-copy layout) — see the [root README](../README.md) and `make-sdcard.sh`.
- The app built with `app/build-app.sh`, which produces `app/out/pm3scan`.

For the end-to-end install (client, firmware and app), see [QUICKSTART.md](../QUICKSTART.md).

---

## 1. What it looks like / how to use it

```
┌──────────────────────────────────────────────────────────┐
│ Proxmark3 Scanner                                        │
│ PM3 GENERIC  fw v4.23346-suspect | port /dev/ttyACM0     │
├────────────────────────┬─────────────────────────────────┤
│  HF SCAN               │  LF SCAN                        │
│  13.56 MHz ...         │  125 kHz ...                    │
├────────────────────────┴─────────────────────────────────┤
│  [+] UID: DE AD BE EF ( ONUID, re-used )                 │
│  [+] ATQA: 00 04                                         │
│  [+] SAK: 08 [2]                                         │
│  [+]   MIFARE Classic 1K                                 │
│  [+] Valid ISO 14443-A tag found                         │
├──────────────────────────────────────────────────────────┤
│  (Raw client output, scrollable)                         │
├──────────────────────────────────────────────────────────┤
│ A/Enter scan   B/Esc cancel+quit   L/R switch  F12 shot  │
└──────────────────────────────────────────────────────────┘
```

| Key | Action |
|---|---|
| **A** (joystick button 1) | Scan the currently highlighted mode |
| **B** (joystick button 0) | While scanning → cancel; while idle → quit |
| **Left/Right / Up/Down** (hat 0) | Switch between HF / LF |
| **X** (button 2) | Rescan the previous mode |
| **Y** (button 3) | Clear the results area |
| F12 | Screenshot (when a path is given via `--screenshot`) |

The header also shows a **battery + clock widget** in the top-right, refreshed once
a second: battery state read from `/sys/class/power_supply/*/capacity`, and the
time from the local clock. It renders as `CHG [####] 66% 21:49` -- the percentage
and fill turn green while charging, the fill turns red at 15% or below, and the
battery path is logged at startup so a missing sysfs node is easy to diagnose.

On startup it first runs `hw version` once to probe the PM3, putting the model and firmware version into the status line of the title bar;
when it cannot connect or the client is missing, it states the reason directly in the title bar instead of failing silently.

---

## 2. Design notes

**No protocol reimplementation**. The application does only one thing: it forks the official client
(`proxmark3 <port> --incognito -f -c "hf search"`), reads its output stream in,
enlarges the meaningful lines, and at the same time keeps the **complete raw output** in the log area below.
That way, even if the keyword extraction misses a line, no information is lost.

- `-f` is mandatory: when the client's stdout is a pipe it is fully buffered by default, and without this flag nothing can be read before the process exits.
- `Searching for ...` is a progress line and goes to the progress bar instead of being treated as a result — otherwise the protocol names
  (Topaz/LEGIC/iCLASS…) would match the keyword table and flood the results area with false positives.
- A non-zero client exit code does not mean failure (the client often returns 246 when it finds a card), so the status line is based on
  "is there any finding", while the exit code is recorded in the log for reference.

**Display ownership**: the stock system's UI is held by `MainUI`; only after it exits does `runtrimui.sh`
execute `/tmp/cmd_to_run.sh`, and after the application exits `MainUI` is brought back up.
So launching the application directly from SSH is **invisible** (it gets covered by MainUI);
the launch has to go through this handoff procedure, which is exactly what happens when the app is launched from the "Apps" menu.

**The input mapping** uses the raw SDL joystick indices, and the application logs every input event so the
mapping can be checked against a log. The result is **A = button 1, B = button 0**
(not SDL's Xbox gamepad mapping, because `SDL_Joystick` raw indices are used),
and the D-pad goes through hat 0 (up 1 / down 4 / left 8 / right 2).

---

## 3. Building

The application source is `app/src/pm3scan.c`; the build script writes the aarch64 binary `app/out/pm3scan`:

```sh
app/build-app.sh
```

Reuses the aarch64 toolchain and the TrimUI SDK sysroot from `client/`:

| Dependency | Source | Notes |
|---|---|---|
| SDL2 / SDL2_ttf | SDK sysroot (2.26.1 headers) | The device runtime is SDL2 **2.30.8** (`/usr/trimui/lib`), same SONAME, ABI compatible |
| freetype / zlib / bzip2 | SDK sysroot | Link-time dependencies of SDL2_ttf; versions match the device |
| Font | `DejaVuSans.ttf` bundled with the application | Does not depend on system fonts |

At link time only the few needed `.so` files are exposed into `client/extra/lib`, and the **SDK's glibc component**
(2.23) is **not** put on the search path — that would conflict with the toolchain's 2.25 libc.

---

## 4. Deployment

```sh
TRIMUI_PASS=tina app/deploy-app.sh
```

(`TRIMUI_HOST` must name the handheld; see `device/rsh.sh`.) Installs to
`/mnt/SDCARD/Apps/Proxmark3Tools/` and registers it in `Apps/show.json`
(the original file is backed up as `show.json.bak`). The `config.json`, `launch.sh`
and `icon.png` it pushes come from `app/assets/`. Then restart MainUI so the menu refreshes:

```sh
device/rsh.sh 'kill -9 $(pgrep -x MainUI)'
```

In the end the application directory looks like this:

```
/mnt/SDCARD/Apps/Proxmark3Tools/
├── pm3scan              # 39 KB aarch64 GUI binary
├── DejaVuSans.ttf
├── config.json          # package/label/icon/launch/description
├── launch.sh            # sets LD_LIBRARY_PATH=/usr/trimui/lib, /tmp/stay_awake
└── icon.png             # 300x300 RGBA, 200x150 (4:3) tile, white text on black
```

### Icon format

The stock launcher draws an app icon **1:1 into a 300x300 slot, anchored at the
slot's top-left, with no scaling** -- anything larger is simply clipped. Every
stock icon is a 300x300 RGBA PNG with its artwork inside a 200x200 box inset 50 px
from the canvas edge, and the top margin is what decides how high the artwork sits
in the card.

Calibration on a 1024x768 screen:

| calibration mark | canvas coords | on-screen result |
|---|---|---|
| canvas edge | 0..299 | 300x300 at (362, 404) |
| stock artwork box | 50..249 | 200x200 at (412, 454) |
| centre | 140..159 | 20x20 at (502, 544) |

So scale = 1.0 exactly. The app icon is generated by `app/make-icon.py` (300x300
canvas, 200x150 tile at y=50, i.e. a 4:3 tile aligned to the same top line as stock
artwork).

The menu entry is labelled `PM3 tools` (from `config.json`). If the app was
previously installed under an older name, `app/deploy-app.sh` removes the stale
`Apps/<old-dir>` and the stale `show.json` entry after a verified install.

The client is resolved in this order: `$PM3_BIN` (or `--pm3`), then
`<app dir>/pm3/proxmark3`, then `/mnt/UDISK/pm3-v423346/proxmark3`
(overridable with `--pm3` or `PM3_BIN`).

---

## 5. Headless verification

The GUI can be verified even when it is not visible — the application ships with several non-interactive modes.
Run these on the handheld from the app directory (`/mnt/SDCARD/Apps/Proxmark3Tools/`):

```sh
./pm3scan --probe                     # SDL driver / resolution / gamepad enumeration
./pm3scan --scan-once hf              # no GUI, just run one scan and print it
./pm3scan --auto-scan lf --run-seconds 30 \
          --log /mnt/UDISK/pm3gui/x.log --screenshot /mnt/UDISK/pm3gui/x.bmp
```

Together with the stock `fbscreencap` (which saves `/dev/fb0` as a PNG), the screen can be captured remotely to check the UI:

```sh
# Trigger it through the MainUI handoff; once it is running, grab the real screen
cat > /tmp/cmd_to_run.sh <<'EOF'
#!/bin/sh
cd /mnt/SDCARD/Apps/Proxmark3Tools
./pm3scan --auto-scan hf --log /mnt/UDISK/pm3gui/hf.log &
sleep 16
/usr/trimui/bin/fbscreencap /mnt/UDISK/pm3gui/hf.png
kill $!
EOF
chmod +x /tmp/cmd_to_run.sh
device/rsh.sh 'kill -9 $(pgrep -x MainUI)'
```

---

## 6. Measured results

| Item | Result |
|---|---|
| Rendering | `mali` video driver, 1024×768@60Hz, `opengles2` renderer |
| Gamepad | Enumerated as "Xbox 360 Controller" (16 buttons / 1 hat / 6 axes) |
| HF scan | MIFARE Classic 1K, `UID: DE AD BE EF`, `SAK: 08` |
| LF scan | `[+] Chipset... T55xx` |
| Buttons | A triggers a scan, B quits, left/right switch |
| Menu entry | Visible and directly launchable on the stock "Apps" page |
| After exit | MainUI is restored automatically |

## 7. Known limitations

- Scanning is **blocking**: one `hf search` takes about 12 seconds, `lf search` about 10 seconds;
  during that time only cancel is available, nothing else can run in parallel.
- Result extraction relies on keyword matching against the client's text output, not a structured protocol. If the client's output format changes, this has to change with it.
- Only "scan + display" is implemented. Reading and writing cards (something like `hf mf dump`) would need extra speed keys or a submenu.
- Results are not persisted to disk; they are lost on exit.

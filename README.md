# PM3 tools — a Proxmark3 scanner for TrimUI handhelds

Turns a TrimUI handheld into a standalone Proxmark3 terminal: the Iceman client
runs **on the device**, talks to the Proxmark3 over the handheld's USB host port,
and a small GUI app gives one-press **HF (13.56 MHz)** and **LF (125 kHz)** scans
from the stock firmware's Apps menu. No PC, no Bluetooth bridge, no custom
firmware on the handheld.

**Everything runs on the stock TrimUI OS.** The only thing that gets flashed is
the Proxmark3 itself, and only so that its firmware matches the client.

---

## Verified hardware

Only combinations that have actually been tested are listed. "Verified" means the
full path was exercised: client running on the handheld, USB enumeration, and a
real tag read.

### Handheld

| Device | OS | Kernel | SoC | Screen | Status |
|---|---|---|---|---|---|
| **TrimUI Brick Pro (TG4040)** | stock TrimUI OS **1.1.2** | **4.9.191** (TinaLinux, `sun50iw10p1`) | Allwinner A133 | 1024×768 | ✅ verified end to end |

Other TrimUI models on the same stock OS (Brick TG3040, Smart Pro TG5040, Smart
Pro S TG5050) are expected to work — the app only relies on the `/Apps` menu, SDL2
in `/usr/trimui/lib` and `/sys/class/power_supply` — but they have **not** been
tested. Reports welcome.

### Proxmark3

| Hardware | Firmware | Status |
|---|---|---|
| PM3 Easy / generic clone, **AT91SAM7S512 (512 KB)** | Iceman **v4.23346**, `PLATFORM=PM3GENERIC` | ✅ verified |
| Proxmark3 RDV4 | would need `PLATFORM=PM3RDV4` | not tested |

Measured against that pair on the Brick Pro:

```
uC: AT91SAM7S512 Rev A      512K bytes (82% used)
LF antenna   121.21 kHz optimal  22.22 V   ( ok )
HF antenna   13.56 MHz           20.38 V   ( ok )
USB transfer 827424 bytes/s      1326 frames/s
card read    MIFARE Classic 1K   UID (sample in docs)
```

### Firmware version matching

The client and the Proxmark3 firmware handshake on a **capabilities version**.
They must come from the same tag:

| Iceman tag | Date | `CAPABILITIES_VERSION` |
|---|---|---|
| v4.17768 | 2024-01-03 | 6 |
| v4.19552 | 2024-11-22 | 6 |
| v4.21611 | 2026-04-14 | 7 |
| **v4.23346** ← used here | 2026-09-17 | **11** |
| master (`dd8bf6c`) | 2026-10-04 | 13 |

A mismatch prints `Capabilities structure version ... (vN != vM)` and the client
refuses to talk. That is a guard, not a bug — see
[docs/FIRMWARE.md](docs/FIRMWARE.md).

---

## Dependencies

### Required on the handheld

| Component | Version | Notes |
|---|---|---|
| TrimUI stock OS | 1.1.2 verified | provides `MainUI`, the `/Apps` menu, SSH |
| Kernel | 4.9.191 | must have `CONFIG_USB_ACM=y` — the verified device has it built in |
| glibc | 2.33 on device | the binaries only require **GLIBC_2.17**, so they run well below that |
| SDL2 | 2.30.8 in `/usr/trimui/lib` | the app links `libSDL2-2.0.so.0`, ABI-compatible with the 2.26.1 headers used to build |
| SDL2_ttf, freetype, zlib, bzip2 | as shipped by the firmware | app and client runtime dependencies |

### Required to build

| Component | Version | Where it comes from |
|---|---|---|
| TrimUI SDK + toolchain | release `20231018` | `trimui/toolchain_sdk_smartpro` on GitHub; fetched by `client/fetch-sources.sh` |
| Linaro GCC | **7.5.0** (`aarch64-linux-gnu`) | inside that SDK tarball |
| Target sysroot | `SDK_usr_tg5040_a133p` | same release; supplies SDL2, zlib, bzip2, freetype |
| Iceman proxmark3 | tag **`v4.23346`** | `RfidResearchGroup/proxmark3` |
| lz4 | **1.9.4** | built statically; not shipped by the SDK |
| Host tools | `bash`, `git`, `curl`, `tar`, `ssh`, `python3` | `python3` + Pillow only for regenerating the app icon |

### Required only to build Proxmark3 firmware

| Component | Version | Notes |
|---|---|---|
| `arm-none-eabi-gcc` | 13.2.1 (Ubuntu package) | cross-compiles the ARM7 firmware |
| Build options | `PLATFORM=PM3GENERIC`, `PLATFORM_SIZE=512` | 512 is the default; only 256 KB units override it |

Exact package lists are in [docs/FIRMWARE.md](docs/FIRMWARE.md).

---

## Install

Full walkthrough and troubleshooting: **[QUICKSTART.md](QUICKSTART.md)**.

### From a bundle (no compiler, no large download)

```sh
tar xzf trimui-pm3-v4.23346.tar.gz && cd trimui-pm3-v4.23346
./install.sh --host <handheld-ip> --restart-ui
```

### By copying onto the microSD card (no SSH, no network)

```sh
./make-sdcard.sh
```

produces `dist/sdcard/Apps/Proxmark3Tools/`, which is **self-contained**: the
Iceman client and its dictionaries/lua/scripts travel inside the app folder, and
the app prefers that copy over anything on internal storage. Copy the `Apps`
folder onto the card (merging it with the existing one), put the card back, and
launch `PM3 tools` from the menu. Instructions for the end user are written to
`dist/sdcard/HOW-TO-INSTALL.txt`.

This route needs no SSH and no network on the handheld, and it survives moving the
card to another handheld.

> One caveat: the launcher's `Apps/show.json` is its visibility list. MainUI scans
> the Apps folders itself and rewrites that file, but if `PM3 tools` does not show
> up, add `{"label":"PM3 tools","show":1}` to the array by hand.

### From source

```sh
git clone <this-repo> && cd trimui-pm3
./install.sh --host <handheld-ip> --restart-ui --build
```

`install.sh` pushes the client plus its dictionaries/lua/scripts to
`/mnt/UDISK/pm3-v423346/`, installs the GUI app to
`/mnt/SDCARD/Apps/Proxmark3Tools/`, registers it in the Apps menu, and verifies
both on the device. It is idempotent and accepts `--pass`, `--skip-client`,
`--skip-app` and `--force`.

Prerequisites on the handheld: Wi-Fi on, SSH reachable (stock user `root`,
password `tina` — the vendor default), and the Proxmark3 in the **top** USB-C
port.

---

## Using it

**From the Apps menu** — launch `PM3 tools`:

| Key | Action |
|---|---|
| A | scan the highlighted mode |
| B | cancel a scan, or leave the app |
| Left / Right | switch HF (13.56 MHz) / LF (125 kHz) |
| X | rescan · Y clear |

The header shows the PM3 model and firmware, plus a battery and clock widget.

**From a shell** — the client is a normal Iceman client:

```sh
ssh root@<handheld-ip>
cd /mnt/UDISK/pm3-v423346
./proxmark3 /dev/ttyACM0 -c "hf search"
./proxmark3 /dev/ttyACM0                     # interactive CLI
```

---

## Repository layout

```
install.sh          one-command install onto a handheld over SSH
make-bundle.sh      packs sources + built binaries into one distributable tarball
make-sdcard.sh      builds a folder that is installed by copying it onto the card
QUICKSTART.md       new-device walkthrough, prerequisites, troubleshooting

device/                talking to and diagnosing the handheld
  rsh.sh                 password SSH without sshpass (SSH_ASKPASS + setsid)
  collect.sh             dumps kernel/USB/tty/power/tooling in one go
  usb-watch.sh           watches for USB attach, for host-port testing
  askpass.sh             helper used by rsh.sh

client/                cross-compiling the Iceman client for aarch64
  fetch-sources.sh       downloads SDK, toolchain, lz4, proxmark3
  build-client.sh        builds the client and packages client/out artifacts
  patches/               port patches for the vendor toolchain

app/                   the GUI app ("PM3 tools")
  src/pm3scan.c          single-file SDL2 application
  build-app.sh           cross-compiles it
  deploy-app.sh          installs it and registers the Apps menu entry
  make-icon.py           generates the app icon (stock launcher format)
  assets/                config.json, launch.sh, icon.png

docs/
  DEVICE-NOTES.md     kernel/USB/launcher evidence for the verified device
  FIRMWARE.md         building and flashing matching Proxmark3 firmware
  GUI-APP.md          app design, icon format, headless verification
  evidence/           raw device report collected on the verified unit
```

Build inputs (SDK, toolchains, upstream sources, `client/out`, `app/out`) are
deliberately **not** committed; `client/fetch-sources.sh` and the two build scripts
recreate them.

---

## How it works

The handheld's stock kernel already contains the CDC-ACM driver, so a Proxmark3
plugged into the top USB-C port simply appears as `/dev/ttyACM0` — no kernel work
and no userspace USB stack. On top of that:

- **Client** — the Iceman host client cross-compiled for aarch64 against the
  vendor SDK, plus its dictionaries/lua/scripts, running from internal storage.
- **GUI app** — an SDL2 front-end that forks the client with
  `-c "hf search"` / `-c "lf search"`, streams its output, and surfaces the
  interesting lines. It is launched through the stock OS's own handoff
  (`MainUI` → `/tmp/cmd_to_run.sh`), so it owns the display properly.

Details, including why an oversized icon canvas gets clipped rather than scaled,
are in [docs/DEVICE-NOTES.md](docs/DEVICE-NOTES.md) and
[docs/GUI-APP.md](docs/GUI-APP.md).

---

## Status and caveats

- Verified only on the single handheld + PM3 pair listed above.
- The app scans and displays; it does not implement card writing (you can still
  run any client command over SSH).
- Scanning is blocking: `hf search` takes ~12 s and `lf search` ~10 s, cancellable.
- Findings are extracted by matching the client's text output, so a change in
  upstream wording can affect the summary (raw output stays visible).
- The handheld suspends when idle and drops off Wi-Fi; the app sets
  `/tmp/stay_awake` for the duration of a session.
- `usb1-vbus` does not expose its current limit, so sustained worst-case HF draw
  is untested — see the open questions in [docs/DEVICE-NOTES.md](docs/DEVICE-NOTES.md).

---

## License and credits

This project is licensed under the **GNU General Public License v3.0**
(see [LICENSE](LICENSE)). GPL-3.0 is required in practice: `client/patches/` are
patches against GPL-3.0 code, and the bundle produced by `make-bundle.sh`
redistributes a compiled GPL-3.0 binary. Anyone redistributing that bundle must
also make the corresponding source available — `client/fetch-sources.sh` and
`client/build-client.sh` document exactly how to obtain and rebuild it.

Third-party components:

| Component | License | Notes |
|---|---|---|
| [Iceman proxmark3](https://github.com/RfidResearchGroup/proxmark3) | GPL-3.0 | client and firmware; not vendored here, fetched at build time |
| [TrimUI SDK and toolchain](https://github.com/trimui/toolchain_sdk_smartpro) | TrimUI's terms | **not redistributed** — downloaded from TrimUI's own GitHub releases |
| [SDL2](https://libsdl.org/) | zlib | supplied by the SDK sysroot and by the device firmware |
| [lz4](https://github.com/lz4/lz4) | BSD-2-Clause | built statically from source |
| [DejaVu fonts](https://dejavu-fonts.github.io/) | Bitstream Vera / DejaVu | UI font; `deploy-app.sh` copies it from your system |

Not affiliated with or endorsed by TrimUI or the Proxmark3 projects.

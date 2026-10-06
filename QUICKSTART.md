# QUICKSTART — put PM3 tools on a TrimUI handheld

For someone starting from a fresh clone with a handheld in hand. Verified on a
**TrimUI Brick Pro (TG4040)** running stock firmware 1.1.2.

---

## 0. What you need

| | |
|---|---|
| Handheld | TrimUI running the **stock TrimUI OS** (the app relies on its `/Apps` menu, `MainUI` and `/usr/trimui/lib` SDL2) |
| Proxmark3 | PM3 Easy / generic clone or RDV4, **flashed with firmware from tag `v4.23346`** — see step 4 |
| Computer | Linux or macOS on the same network, with `git`, `bash`, `python3`, `tar` |
| Network | The handheld and the computer on the same Wi-Fi |

Plug the Proxmark3 into the **TOP** USB-C port (that is the USB host port; the
bottom one is charge/OTG).

---

## 1. Get the handheld ready

1. **Turn on Wi-Fi** and note the address under **Settings → Device Info**.
2. **SSH is built into the stock firmware.** The account is `root`, and the stock
   password is `tina` (that is the vendor default, documented in the community
   paks — change it if you like).
3. Check it works:

   ```sh
   ssh root@<handheld-ip> 'uname -a; ls /mnt/SDCARD/Apps'
   ```

   If you get `Connection refused`, the device is asleep — wake it. If you get
   `No route to host`, Wi-Fi is off.

---

## 2. Get the project

```sh
git clone <this-repo> trimui-headless
cd trimui-headless
```

---

## 3. Install

### Fastest: someone already built it

If you were handed (or built earlier) these files, installation needs **no
download and no compiler**:

```
client/out/proxmark3-v4.23346-aarch64
client/out/pm3-resources-v4.23346.tar.gz
app/out/pm3scan
```

then:

```sh
./install.sh --host <handheld-ip> --restart-ui
```

### No SSH at all: copy the files onto the card

If you would rather not enable SSH, the whole thing can be installed with a card
reader:

```sh
./make-sdcard.sh          # on a machine that has the binaries
```

That writes `dist/sdcard/Apps/Proxmark3Tools/`, containing the app **and** the
Iceman client with all its dictionaries and scripts. Copy the `Apps` folder onto
the microSD card, merging it with the one already there, and put the card back in
the handheld. `dist/sdcard/HOW-TO-INSTALL.txt` repeats this for the end user.

The app looks for its client in this order, so this layout works with no internal
storage involved:

1. `$PM3_BIN` (or `--pm3`)
2. `<app dir>/pm3/proxmark3` — the copy on the card
3. `/mnt/UDISK/pm3-v423346/proxmark3` — where `install.sh` puts it

If `PM3 tools` does not appear in the Apps menu, add
`{"label":"PM3 tools","show":1}` to the `Apps/show.json` array on the card.

Packaging details for this route — what the tree contains, why the vfat card
needs no `chmod`, and how the app finds the client on the card — are in
[docs/SDCARD-DEPLOY.md](docs/SDCARD-DEPLOY.md).

### From source

One command — it downloads the TrimUI SDK and toolchain, builds the client and
the GUI app, then installs everything:

```sh
./install.sh --host <handheld-ip> --restart-ui --build
```

Roughly 600 MB of downloads and 5–10 minutes the first time. If GitHub is slow,
set a proxy first (measured here: 27 KB/s direct vs 2.25 MB/s through one):

```sh
https_proxy=http://127.0.0.1:3128 ./install.sh --host <ip> --restart-ui --build
```

### What it does

```
/mnt/UDISK/pm3-v423346/            aarch64 proxmark3 client + dictionaries/lua/scripts
/mnt/SDCARD/Apps/Proxmark3Tools/   the GUI app
```

and registers `PM3 tools` in `Apps/show.json` so the stock launcher lists it.
`--restart-ui` restarts `MainUI` so the entry appears immediately; without it,
reboot the handheld. The script is idempotent — re-run it to update.

Useful flags: `--pass <pw>`, `--skip-client`, `--skip-app`, `--force`, `--help`.

---

## 4. Match the Proxmark3 firmware (the usual gotcha)

The client and the firmware shake hands on a *capabilities version*. A mismatch
looks like this and **is not a bug**:

```
[!!] Capabilities structure version sent by Proxmark3 is not the one expected
     by this client! (v6 != v11)
```

| tag | date | capabilities |
|---|---|---|
| v4.17768 | 2024-01-03 | 6 |
| v4.21611 | 2026-04-14 | 7 |
| **v4.23346** ← what this project uses | 2026-09-17 | **11** |

Flash matching firmware with **[docs/FIRMWARE.md](docs/FIRMWARE.md)**. Both the client and
the firmware must come from the same tag, otherwise the client refuses to talk.

---

## 5. Use it

On the handheld: **Apps → PM3 tools**.

| Key | Action |
|---|---|
| A | scan the highlighted mode |
| B | cancel a scan, or leave the app |
| Left/Right | switch HF (13.56 MHz) / LF (125 kHz) |
| X | rescan · Y | clear |

Or from a terminal:

```sh
ssh root@<handheld-ip>
cd /mnt/UDISK/pm3-v423346
./proxmark3 /dev/ttyACM0 -c "hf search"
./proxmark3 /dev/ttyACM0                 # interactive CLI
```

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `install.sh: cannot run commands on root@…` | Device asleep, Wi-Fi off, wrong address, or SSH disabled. Check step 1. |
| Capabilities mismatch `(v6 != v11)` | Firmware is a different tag — step 4. |
| `no Proxmark3 on /dev/ttyACM0` (shown in the app's status line) | PM3 not plugged in, or plugged into the bottom (charge) port. It must be the **top** port. |
| App not in the Apps menu | Restart the handheld, or re-run with `--restart-ui`. |
| Screen goes black / app vanishes | The device slept. Any long session should keep `/tmp/stay_awake` set — `launch.sh` already does this. |
| Wi-Fi drops after a while | The device suspends when idle. Wake it, or keep a session running. |
| `Text file busy` when re-pushing | An old copy of the app is still running: `ssh root@<ip> 'kill -9 $(pgrep -x pm3scan)'`. |

---

## 7. What you do *not* need

- **No custom firmware, no NextUI.** Everything runs on the stock TrimUI OS.
- **No kernel work.** The stock kernel already has `CONFIG_USB_ACM=y`, which is
  what makes the direct USB connection possible (see [docs/DEVICE-NOTES.md](docs/DEVICE-NOTES.md)).
- **No Bluetooth or TCP bridge.** Route A works; those are fallbacks only.

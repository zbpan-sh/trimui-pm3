# TrimUI Brick Pro (TG4040) — Device Notes

What the stock TrimUI Brick Pro firmware runs, which kernel interfaces it exposes, and the
evidence that a Proxmark3 can be driven directly over USB from the handheld. Everything below
was collected **on the device itself** over SSH as `root` with `device/collect.sh` on 2026-10-05;
the full raw output is archived at `docs/evidence/device-report-2026-10-05.txt`, and each claim
is backed by the pasted evidence in the section that makes it.

**Summary**: the stock OS on the Brick Pro exposes a working USB 2.0 host port, and the stock
kernel has `CONFIG_USB_ACM=y` built in (there is no module support to fall back on). A Proxmark3
attached to the top Type-C port therefore enumerates as `/dev/ttyACM0`, and the standard
`proxmark3` client can talk to it once the client and the PM3 firmware come from the same
release tag. No custom firmware, Bluetooth bridge or TCP bridge is required for this.

## Device

| Item | Value |
|---|---|
| Model | TrimUI Brick Pro, `TG4040` |
| Address used for collection | `<device-ip>` |
| SoC / device tree | `/proc/device-tree/compatible` = `allwinner,a133 arm,sun50iw10p1`; `/proc/device-tree/model` = `sun50iw10` |
| Kernel | `TinaLinux 4.9.191`, build `#921 SMP PREEMPT Fri Aug 28 02:11:09 UTC 2026`, `aarch64` |
| OS | Stock TrimUI OS, version `1.1.2` (`/etc/version` = `1.1.2`) |
| Firmware source | `github.com/trimui/firmware_brickpro` |
| C library | glibc 2.33 (`/lib/ld-2.33.so`, `/lib/libc.so.6 -> libc-2.33.so`); not musl, not uClibc |
| Remote access | OpenSSH 8.0, default credentials `root:tina` |
| SD card | mounted `rw` at `/mnt/SDCARD`, 6.0 GB free of 59.5 GB |
| Client install path used in testing | `/mnt/UDISK/pm3-v423346/` |
| On-device tools | `curl`, `wget`, `nc`, `tar`, `gzip` (busybox-based); **no** `scp`, `sftp`, `rsync`, `python`, `stty`, `socat`, and **no** compiler |

The same SSH setup is what the community packages document for related devices — see the
[nextui native-ssh submission](https://github.com/LoveRetro/nextui-pak-store/issues/61) and
[minui-dropbear-server-pak](https://github.com/josegonzalez/minui-dropbear-server-pak). The
Brick Pro release notes do not mention adding SSH, so support appears inherited and undocumented
rather than advertised.

### Common assumptions

| Common assumption | What this device shows |
|---|---|
| The model is a "Brick", "Smart Pro" or "Smart Pro S" | It is a **TrimUI Brick Pro (`TG4040`)**; its firmware lives at `github.com/trimui/firmware_brickpro`, not `firmware_brick` |
| The SoC is an "Allwinner A133P" | Device tree reports `allwinner,a133 arm,sun50iw10p1`, model `sun50iw10` |
| It runs NextUI or another custom firmware | It runs per **stock TrimUI OS 1.1.2**: no `.system`, no `.userdata`, no `Tools`, no `/Roms`-based NextUI layout. Because the stock OS already auto-discovers SD-card apps, no custom firmware or third-party app-store packaging is involved |
| SSH arrived only with the Brick's v1.1.1 | OpenSSH 8.0 with `root:tina` works on this Brick Pro 1.1.2 |
| The target is musl or uClibc | aarch64 with **glibc 2.33** — a comfortable target for prebuilt binaries |
| An ACM driver would have to be loaded as a module | `CONFIG_USB_ACM=y`, built into the running kernel image (see below) |

## Kernel and USB

### USB-serial (ACM) support

The stock kernel is monolithic: there is **no `/lib/modules`** at all, so a driver built as a
module could never be inserted. `CONFIG_USB_ACM` is built in:

| # | Check | Result |
|---|---|---|
| 1 | `/proc/tty/drivers` | `acm  /dev/ttyACM  166 0-255 serial` — driver registered |
| 2 | `/sys/bus/usb/drivers/cdc_acm` | **exists** (`bind`, `new_id`, `unbind`, …) |
| 3 | `/proc/config.gz` | **`CONFIG_USB_ACM=y`** — in the kernel image, not a module |

Additional USB-serial drivers are built in too, which is useful for other hardware and for cheap
"does the host port work" tests: `usbserial`, `ch341`, `cp210x`, `ftdi_sio`, `pl2303`,
`ti_usb_3410_5052`.

### USB host controllers

```
CONFIG_USB_EHCI_HCD=y        CONFIG_USB_SUNXI_EHCI0=y   CONFIG_USB_SUNXI_EHCI1=y
CONFIG_USB_OHCI_HCD=y        CONFIG_USB_SUNXI_OHCI0=y   CONFIG_USB_SUNXI_OHCI1=y
CONFIG_USB_SUNXI_HCD=y
```

```
/sys/bus/usb/devices : usb1  usb2          ← both root hubs present and powered
usb1: EHCI 480 Mbps (product "SW USB2.0 'Enhanced' Host Controller (EHCI) Driver")
usb2: OHCI  12 Mbps (product "SW USB2.0 'Open' Host Controller (OHCI) Driver")
usb1-vbus: state=enabled  microvolts=5000000  num_users=1
```

A full-speed USB 2.0 host root hub is enumerated before anything is even plugged in, so
`proxmark3 /dev/ttyACM0` works as soon as the hardware is attached. Bluetooth bridging and a TCP
bridge over Wi-Fi remain possible fallbacks, but neither is needed for the primary plan.

### Rehearsing the host port without a Proxmark3

Plug **any** USB device into the top Type-C port and watch enumeration:

```sh
# on the handheld, while the device is plugged in
dmesg | tail -30
ls /sys/bus/usb/devices/          # expect a new 1-1 / 2-1 entry
ls /dev/ttyUSB* /dev/ttyACM*      # a CH340/CP2102/FTDI dongle lands here
```

The kernel has `ch341`, `cp210x`, `ftdi_sio` and `pl2303` built in, so a cheap USB-serial dongle
is a **direct rehearsal** for the Proxmark3: if the dongle produces `/dev/ttyUSB0`, the whole
"host port + power + enumeration + tty node" chain is proven end to end, and `cdc_acm` behaves
the same way for the PM3. A USB flash drive (`usb-storage` is built in → `/dev/sda`) is an even
more common object to have on hand and proves power and enumeration, though not the tty path.

## Proxmark3 enumeration

A real Proxmark3 attached to the top Type-C port enumerates as a USB CDC-ACM device. Raw kernel
output:

```
usb 2-1: new full-speed USB device number 2 using sunxi-ohci
cdc_acm 2-1:1.0: ttyACM0: USB ACM device
2-1: proxmark3 | proxmark.org | idVendor=9ac4 idProduct=4b8f speed=12
2-1:1.0 -> cdc_acm     2-1:1.1 -> cdc_acm
/dev/ttyACM0  crw------- 1 root root 166,0
```

The device identifies itself as `idVendor=9ac4 idProduct=4b8f`, both interfaces (`2-1:1.0` and
`2-1:1.1`) bind to `cdc_acm`, and `/dev/ttyACM0` is created. No Y-cable is needed for this.

The kernel also logs a power-supply note alongside the attach:

```
axp2202_usb_power: current limit not set: usb adapter type
```

That is worth remembering if HF operations turn out flaky (see [Open questions](#open-questions)).

Port roles: the **top Type-C is a working host port** (that is where the PM3 enumerates). The
**bottom port is the charge/OTG device-mode port** — it is wired for USB gadget mode
(`CONFIG_USB_SUNXI_USB_ADB=y`, `adb on /dev/usb-ffs/adb type functionfs`).

## Version matching

The client and the PM3 firmware handshake on a capabilities-structure version:

| tag | date | `CAPABILITIES_VERSION` |
|---|---|---|
| v4.17768 — *the version originally on the test unit* | 2024-01-03 | 6 |
| v4.19552 | 2024-11-22 | 6 |
| v4.21611 | 2026-04-14 | 7 |
| **v4.23346 — latest release, used for this build** | **2026-09-17** | **11** |
| master `dd8bf6c` | 2026-10-04 | 13 |

v4.17768 is not the latest release. The client talks to the hardware, reads the firmware's
capabilities version, and refuses to continue when the two do not match:

```
[+] Using UART port /dev/ttyACM0
[!!] Capabilities structure version sent by Proxmark3 is not the one expected by this client! (v6 != v11)
```

**The client and the firmware must come from the same tag**, otherwise the client will refuse to
communicate — this is a protection mechanism, not a bug. Flashing instructions are in
[FIRMWARE.md](FIRMWARE.md).

### Verified end to end

After flashing v4.23346, the chain works. `hw version` from the handheld:

```
Platform.................. Linux / aarch64
Firmware.................. PM3 GENERIC
Bootrom.... Iceman/master/v4.23346-suspect 2026-09-18 00:22:18 9ce8a4b6c
OS......... Iceman/master/v4.23346-suspect 2026-09-18 00:22:18 9ce8a4b6c
uC: AT91SAM7S512 Rev A     Embedded flash memory 512K bytes ( 82% used )
```

`hw tune` from the handheld, which also shows that the VBUS budget is sufficient for normal
operation (no brown-out at these loads):

```
LF antenna ... 121.21 kHz optimal  22.22 V   ( ok )
HF Antenna ... 13.56 MHz           20.38 V   ( ok )
Transfer Speed PM3 -> Client ... 827424 bytes/s      ← full-speed link, no brown-out
Frame rate ... 1326 frames/s
```

A real card read closes the whole loop — handheld → USB-CDC → Proxmark3 → RF → card:

```
./proxmark3 /dev/ttyACM0 -c "hf search"
[+] iCLASS / Picopass CSN: 11 22 33 44 55 66 77 88
[+] Valid iCLASS tag / PicoPass tag found

./proxmark3 /dev/ttyACM0 -c "hf iclass info"
[+]     Card type.... PicoPass 2K
[+]     AA1 Key...... 0011223344556677
[+]     AA2 Key...... 8899AABBCCDDEEFF
[+] [H10301  ] HID H10301 26-bit    FC: 1    CN: 12345   parity ( ok )
```

**Note**: the card identifiers shown in the sample output above are synthetic/redacted.

### Client running on the handheld

```
Client: Iceman/master/v4.23346-suspect 2026-09-18 00:22:18 9ce8a4b6c compiler: GCC 7.5.0 OS:Linux ARCH:aarch64
```

Offline mode and resource discovery both work from `/mnt/UDISK/pm3-v423346/` (`script list`
enumerates the transferred `luascripts/`).

The cross-toolchain fit is established: Linaro GCC 7.5.0 builds the Iceman client for aarch64.
It needs three accommodations (all in `client/`): `NOHARDENING=1`, a bundled-linenoise build instead
of the device's incomplete `libreadline.so.6.3`, and a patch for `static const` scalars used as
case labels / static initializers (GCC folds those only from GCC 8 on). The resulting binary
requires just `GLIBC_2.17` against the device's 2.33.

## How the stock OS runs apps

Stock TrimUI OS auto-discovers user apps on the SD card:

```
/mnt/SDCARD/Apps/<Name>/  config.json  launch.sh  icon.png   ← third-party apps, already used by
                                                               EmuDrop (added 2026-09-30)
/mnt/SDCARD/Apps/show.json                                   ← visibility registry
```

A stock app's `launch.sh` (verbatim from `/usr/trimui/apps/bookreader/launch.sh`):

```sh
#!/bin/sh
echo $0 $*
progdir=`dirname "$0"`
cd $progdir
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$progdir
echo 1 > /tmp/stay_awake      # ← stock OS's "don't sleep" flag
./bookreader
rm /tmp/stay_awake
```

Two useful facts fall out of this layout:

1. **`echo 1 > /tmp/stay_awake` is the stock anti-suspend mechanism.** dmesg shows the sunxi host
   controllers doing `super suspend` / `super resume` and `usb usb1: root hub lost power or was
   reset`. A sleeping host port is a real failure mode for a plugged PM3, so any run script must
   set this flag.
2. Apps are plain directories with a shell entrypoint — no CFW, no NextUI, no compilation needed
   to ship.

The Proxmark3 client is an interactive CLI, but that is a non-issue for a **headless**
deployment: SSH in (`root:tina`) and run `proxmark3` with the PM3 on `/dev/ttyACM0`. The handheld
is a network-attached PM3 endpoint; no on-device terminal UI is required for the first working
milestone. A gamepad-driven on-device UI is a later, optional layer — the display and input side
of that layer (`MainUI` display ownership, the `runtrimui.sh` / `/tmp/cmd_to_run.sh` handoff, and
the measured gamepad mapping) is documented in [GUI-APP.md](GUI-APP.md).

### Channels available, in order of usefulness

| Channel | Status |
|---|---|
| SSH over WiFi | **working** (`root:tina`, OpenSSH 8.0) |
| ADB over the bottom Type-C | **enabled in kernel** (`CONFIG_USB_SUNXI_USB_ADB=y`, `adb on /dev/usb-ffs/adb type functionfs`) — unused so far, a good rescue channel |
| SD card | mounted `rw` at `/mnt/SDCARD`, 6.0 GB free of 59.5 GB |
| curl / wget / nc / tar / gzip on device | present (busybox-based); **no** `scp`, `sftp`, `rsync`, `python`, `stty`, `socat`, **no** compiler |

File transfer to the device is by `nc`, by device-side `curl`/`wget` from a host HTTP server, or
via the SD card.

## Open questions

- **Sustained worst-case HF current draw is untested.** Enumeration is a light-load event and
  `hw tune` is a moderate one; neither exercises the PM3's HF antenna at full current.
- **The port's current headroom is not exposed.** `usb1-vbus` reads `max_microamps` as empty,
  so the VBUS budget cannot be read from the kernel. `state=enabled`, 5 V, 1 user. The
  `axp2202_usb_power: current limit not set: usb adapter type` message is consistent with this.
- **Suspend behaviour.** Root hubs demonstrably lose power across suspend/resume cycles, so any
  long run needs `/tmp/stay_awake` set.

## Reproducing this

```sh
cd p0
TRIMUI_PASS=tina ./rsh.sh 'uname -a'          # one-shot remote command
TRIMUI_PASS=tina ./rsh.sh 'sh -s' < collect.sh > report.txt   # full device report
```

`device/rsh.sh` does password SSH without `sshpass` (via `SSH_ASKPASS` + `setsid`), so no root and no
extra packages are needed on the workstation. Credentials come from `TRIMUI_PASS` / `TRIMUI_USER`
/ `TRIMUI_HOST` env vars, or `~/.trimui-env`. The archived output of this run is
`docs/evidence/device-report-2026-10-05.txt`.

# Flashing matching Proxmark3 firmware

**Goal**: put firmware on the Proxmark3 that comes from **exactly the same source
tag** as the client running on the handheld.

**Why this is required**: the client and the firmware handshake on a
*capabilities structure version*. If they disagree, the client refuses to
communicate:

```
[!!] Capabilities structure version sent by Proxmark3 is not the one expected
     by this client! (v6 != v11)
```

That is a compatibility guard, not a bug.

| Iceman tag | Date | `CAPABILITIES_VERSION` |
|---|---|---|
| v4.17768 | 2024-01-03 | 6 |
| v4.19552 | 2024-11-22 | 6 |
| v4.21611 | 2026-04-14 | 7 |
| **v4.23346** ← used by this project | 2026-09-17 | **11** |
| master `dd8bf6c` | 2026-10-04 | 13 |

So either flash the Proxmark3 with v4.23346 firmware (this document), or rebuild
the handheld client from whatever tag your Proxmark3 already runs
(`PROXMARK3_SRC=... client/build-client.sh` accepts any checkout).

---

## 1. Get the source

```sh
git clone --branch v4.23346 --depth 1 https://github.com/RfidResearchGroup/proxmark3.git
cd proxmark3
```

Exact commit used here: `dc0110c29d320e04b37ea436ee2924901407ae72`
("Release v4.23346 - Frosty Lemon", 2026-09-17).

---

## 2. Install dependencies (Debian/Ubuntu, upstream's recommended set)

```sh
sudo apt-get update
sudo apt-get install --no-install-recommends git ca-certificates build-essential pkg-config \
  libreadline-dev gcc-arm-none-eabi libnewlib-dev qt6-base-dev \
  libbz2-dev liblz4-dev zlib1g-dev libbluetooth-dev libpython3-dev libssl-dev libgd-dev
```

`qt6-base-dev` is only needed for the Qt GUI and can be dropped for a
command-line build. On newer distributions (such as Debian Forky), if
`gcc-arm-none-eabi` conflicts with `libnewlib-dev`, use
`picolibc-arm-none-eabi` instead.

This is separate from the handheld build: the handheld client and the GUI app
are cross-compiled with the TrimUI SDK (see [../README.md](../README.md)),
whereas firmware needs the bare-metal `arm-none-eabi` toolchain.

---

## 3. Build (firmware + host client)

```sh
make clean
make -j$(nproc) PLATFORM=PM3GENERIC
```

**512 KB note**: `PLATFORM_SIZE` defaults to **512**, so a 512 KB unit needs
nothing extra; only 256 KB units pass `PLATFORM_SIZE=256`. The build confirms it:

```
Platform name:     Proxmark3 generic target
PLATFORM_SIZE:     512
```

Artifacts:

| File | Size (measured) | Purpose |
|---|---|---|
| `bootrom/obj/bootrom.elf` | 11,840 B | bootloader |
| `armsrc/obj/fullimage.elf` | 424,332 B | main firmware |

`PLATFORM=PM3GENERIC` covers the PM3 Easy and the various clone boards; only the
RDV4 uses `PLATFORM=PM3RDV4`.

---

## 4. Flashing

Plug the Proxmark3 into the computer. On Linux, make sure ModemManager will not
grab `ttyACM*` first — see upstream's
`doc/md/Installation_Instructions/ModemManager-Must-Be-Discarded.md`. This matters
most while flashing the bootloader, which is the step that is hard to recover.

**Recommended (auto-detects the port and selects the images)**:

```sh
sudo ./pm3-flash-all
```

**Equivalent manual form**:

```sh
./client/proxmark3 /dev/ttyACM0 --flash --unlock-bootloader \
    --image bootrom/obj/bootrom.elf \
    --image armsrc/obj/fullimage.elf
```

- Flash **bootrom** first, then **fullimage**; the order must not be reversed.
- `--unlock-bootloader` is for locked or old bootroms — common on clone boards,
  and usually required the first time.
- If the flasher cannot find the device, **hold the button on the Proxmark3 while
  plugging in USB** and release it once it enters bootloader mode; both LEDs
  normally stay lit (the "button trick").

**If it fails or is interrupted**: leave the cable plugged in and run
`pm3-flash-all` again. If that does not work, use the button trick to re-enter the
bootloader and flash again. It only counts as done when both bootrom and
fullimage flashed successfully.

---

## 5. Verify

On the computer:

```sh
./client/proxmark3 /dev/ttyACM0 -c "hw version"
```

It should report v4.23346 and no longer complain about capabilities.

Then on the handheld:

```sh
cd /mnt/UDISK/pm3-v423346
./proxmark3 /dev/ttyACM0 -c "hw version; hw status"
```

Expected: hardware version, firmware version and `capabilities ... 11`, with no
`vN != vM` line.

---

## 6. Alternative: flash prebuilt images

If the firmware was already built from the same tag, the two images can be
flashed directly instead of rebuilding:

```
client/out/bootrom-v4.23346-PM3GENERIC-512k.elf
client/out/fullimage-v4.23346-PM3GENERIC-512k.elf
```

```sh
./client/proxmark3 /dev/ttyACM0 --flash --unlock-bootloader \
    --image /path/to/bootrom-v4.23346-PM3GENERIC-512k.elf \
    --image /path/to/fullimage-v4.23346-PM3GENERIC-512k.elf
```

These live in `client/out/`, which is not committed; they are produced by the bundle
(`make-bundle.sh`) or by building the firmware with the command in section 3.
Only successful compilation has been verified in this repository — the flashing
step itself is performed by the user on real hardware.

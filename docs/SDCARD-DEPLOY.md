# Packaging and deploying onto the microSD card

The **card route**: build one self-contained `Apps/Proxmark3Tools/` folder on a
workstation, copy it onto the handheld's microSD card with a card reader, and
launch the app from the stock Apps menu.

It exists so that installing needs **no SSH, no network, no compiler and no
account on the handheld** — and so that the finished tree can be moved to another
handheld by moving the card. This document is the packaging/deployment reference;
`QUICKSTART.md` is the end-user walkthrough and `HOW-TO-INSTALL.txt` (generated
into the tree) is the note that travels with the card.

Everything here was exercised on this checkout: `make-sdcard.sh`,
`make-bundle.sh` and `make-release.sh` were re-run and their output inspected —
sizes, directory layout, file modes, the resources tarball's entry types and
filenames — and the resulting release zip was deployed to a real TrimUI microSD
card over USB mass storage and verified file by file. Device-side facts come from
`docs/evidence/device-report-2026-10-05.txt`.

---

## 1. When to use this route

| | SSH route (`install.sh`) | **Card route (`make-sdcard.sh`)** |
|---|---|---|
| Needs SSH on the handheld | yes | **no** |
| Needs Wi-Fi / a network | yes | **no** |
| Needs a build on any machine | optional (`--build`) | yes, once, on a machine that can build |
| Client location | `/mnt/UDISK/pm3-v423346/` (internal) | **inside the app folder on the card** |
| Installation act | script pushes over the network | copy a folder in a card reader |
| Survives moving the card | no | **yes** |
| Update path | re-run `install.sh` | re-run `make-sdcard.sh`, copy again |

Both routes install the same GUI app to `/mnt/SDCARD/Apps/Proxmark3Tools/`. The
only difference is where the Iceman client lives, and the app resolves that at
runtime (section 6).

---

## 2. Inputs

`make-sdcard.sh` needs three build products plus a font. Nothing is downloaded.

| Input | Produced by | Typical size |
|---|---|---|
| `client/out/proxmark3-<PM3_TAG>-aarch64` | `client/build-client.sh` (after `client/fetch-sources.sh`) | 5.6 MB |
| `client/out/pm3-resources-<PM3_TAG>.tar.gz` | `client/build-client.sh` | 8.5 MB |
| `app/out/pm3scan` | `app/build-app.sh` | 44 KB |
| `DejaVuSans.ttf` | the host, `/usr/share/fonts/truetype/dejavu/` | 760 KB |

`PM3_TAG` defaults to `v4.23346` and can be overridden
(`PM3_TAG=v4.xxxxx ./make-sdcard.sh`), matching whatever `build-client.sh` was
run with. The font path can be overridden with `FONT=/path/to.ttf`.

If any input is missing the script prints which ones and exits non-zero, with the
commands that produce them:

```
== MISSING /.../client/out/proxmark3-v4.23346-aarch64

Build them first:
    client/fetch-sources.sh
    PROXMARK3_SRC=$PWD/client/src/proxmark3-v4.23346 client/build-client.sh
    app/build-app.sh
```

A release bundle (`trimui-pm3-<version>.tar.gz`) already contains all four, so
someone who was handed a bundle can build the card tree without a toolchain.

---

## 3. Building the card tree

```sh
./make-sdcard.sh                    # -> dist/sdcard/
```

The script starts by reporting every input it found, so a stale or absent binary
is visible before anything is written:

```
== have    proxmark3-v4.23346-aarch64                 5.6M
== have    pm3-resources-v4.23346.tar.gz              8.5M
== have    pm3scan                                    44K
== assembling /.../dist/sdcard
```

It then **deletes and recreates `dist/sdcard/`** (it is generated output, and
`dist/` is git-ignored), so the result never contains files from an older tag.
`dist/sdcard/` is the only thing it touches — the repository, `client/out/` and
`app/out/` are left alone.

Expected result:

```
== ready: /.../dist/sdcard
   size: 47M
   /Apps
   /Apps/Proxmark3Tools
   /Apps/Proxmark3Tools/pm3

Copy the 'Apps' folder onto the microSD card, merging with the existing one.
```

47 MB is the on-disk size on the host; the zip is **12.4 MB** (section 9). On the
vfat card itself it occupies **56 MB**, not 47: with 32 KB clusters, the many
small dictionary/lua files each round up. Budget ~60 MB of card space, and note
that this is the app folder alone — the SSH route spends the same bytes in
`/mnt/UDISK/` instead.

---

## 4. What is in the tree

```
dist/sdcard/
├── HOW-TO-INSTALL.txt              end-user instructions (generated)
└── Apps/                           copy this folder onto the card
    └── Proxmark3Tools/
        ├── pm3scan                 44 KB   aarch64 GUI binary
        ├── DejaVuSans.ttf         760 KB   UI font
        ├── config.json            165 B    package/label/icon/launch/description
        ├── launch.sh              515 B    MainUI entry point
        ├── icon.png               5.2 KB   300x300 RGBA launcher icon
        └── pm3/                            the Iceman client, self-contained
            ├── proxmark3          5.6 MB   aarch64 client
            ├── dictionaries/              card-database lookups
            ├── lualibs/                   Lua libraries
            ├── luascripts/                Lua scripts
            ├── cmdscripts/                command scripts
            └── resources/                 duox/picc trust material, etc.
```

The resources come out of `pm3-resources-<tag>.tar.gz` and extract **beside** the
client binary, which is where the Iceman client looks for them.

Counting the whole tree: `dist/sdcard/` is **568 files in 17 directories**, of
which `Apps/Proxmark3Tools/` is 567 files in 15 directories (the extra file is
`HOW-TO-INSTALL.txt` at the tree root). The resources tarball alone is 574 entries
(561 regular files, 13 directories).

Two properties make this tree safe to drop on the handheld's card:

- **No symlinks and no hard links.** The microSD card is mounted `vfat`, which
  cannot represent them. Every entry in the resources tarball is a regular file or
  a directory: `tar tvzf ... | awk '{print substr($1,1,1)}' | sort -u` prints only
  `-` and `d`.
- **No vfat-hostile filenames.** No `:` `*` `?` `"` `<` `>` `|` `\` anywhere in
  the tree; the longest name is 69 characters, well inside the 255-byte limit.
  Nesting depth and long names are fine (`shortname=mixed`).

### Executable bits on vfat

`make-sdcard.sh` runs `chmod +x` on `pm3scan`, `launch.sh` and `pm3/proxmark3` in
`dist/sdcard/`. **Those bits are not what makes the app run on the device**, and
they cannot be stored on a vfat card at all. The device mount is:

```
/dev/mmcblk1p1 on /mnt/SDCARD type vfat
    (rw,sync,relatime,fmask=0000,dmask=0000,allow_utime=0022,
     codepage=437,iocharset=utf8,shortname=mixed,errors=continue)
```

`fmask=0000,dmask=0000` means the kernel presents every file and directory as
0777 regardless of what the card's FAT entries say. So `./launch.sh` and the
binaries are executable on the device by construction, and a plain copy — with no
`chmod`, no `tar`-as-root, and no permission-preserving tool — is enough. The
`chmod` calls matter only for the host-side `dist/sdcard/` tree itself.

---

## 5. Copying it onto the card

This is what `HOW-TO-INSTALL.txt` tells the end user:

1. Power the handheld off and remove the microSD card.
2. Insert it into the computer.
3. Copy the whole `Apps` folder from `dist/sdcard/` onto the card, **merging it
   with the `Apps` folder already there**. Do not replace that folder: it holds
   the stock launcher's own entries. The result should contain
   `<card>/Apps/Proxmark3Tools/pm3scan` and `<card>/Apps/Proxmark3Tools/pm3/proxmark3`.
4. Eject (unmount), reinsert, power on.
5. Launch `PM3 tools` from the Apps menu.

**Eject properly before unplugging** — step 4 is not optional, and skipping it can
destroy the tree you just copied. Section 13 is the incident report.

The Proxmark3 itself goes into the **top** USB-C port (the host port) before
scanning.

If the card has no `Apps` folder yet, create it by copying the one from the tree.

### Merging from a shell: mind `cp`'s nesting rule

A file manager merges directories when you drop one onto another. `cp -r` does
not always, and the difference decides whether the app appears in the menu:

```sh
# correct -- contents merge into the card's existing Apps
cp -r  dist/sdcard/Apps/.      /media/<user>/<card>/Apps/
cp -r  dist/sdcard/Apps        /media/<user>/<card>/        # dest is the card root
rsync -a dist/sdcard/Apps/     /media/<user>/<card>/Apps/

# WRONG -- the destination *names* an existing directory, so cp copies into it
cp -r  dist/sdcard/Apps        /media/<user>/<card>/Apps
# -> <card>/Apps/Apps/Proxmark3Tools/   ... MainUI scans Apps/*/ and shows nothing
```

Verified on the real card: the two correct forms produce `Apps/Proxmark3Tools/`;
the wrong form produces `Apps/Apps/Proxmark3Tools/`. Re-running the correct form
over an existing install is idempotent — same 567 files, no duplicates, no stale
files, and the other apps in `Apps/` are untouched. If you do end up with an
`Apps/Apps/`, delete it and re-copy.

---

## 6. Why it works with no internal storage

`pm3scan` resolves the client on startup, in this order
(`app/src/pm3scan.c`, `main()`):

1. `$PM3_BIN`, or the `--pm3 PATH` argument;
2. `<app dir>/pm3/proxmark3` — **the copy on the card**;
3. `/mnt/UDISK/pm3-v423346/proxmark3` — where `install.sh` puts it.

`<app dir>` is derived from `/proc/self/exe`, i.e. the directory holding the
running `pm3scan` binary, so it follows the card. The lookup is implemented in the
GUI binary, not in `launch.sh`, which is why the app is testable from a shell
(`--pm3`, `PM3_BIN`) as well.

Consequences worth knowing:

- The card copy **shadows internal storage**. If a device has both an
  `install.sh`-installed client and a card copy, the card copy wins after the
  first `make-sdcard.sh` deployment. To go back to the internal copy, delete
  `<card>/Apps/Proxmark3Tools/pm3/` (or point `PM3_BIN` at it).
- Updating over SSH (`install.sh`) will **not** change what a card-deployed app
  runs; the card tree must be rebuilt and re-copied.
- The PM3 serial port defaults to `/dev/ttyACM0`, overridable with `$PM3_PORT`
  or `--port`.

---

## 7. Menu registration (`Apps/show.json`)

The stock launcher scans `Apps/*/` for `config.json` itself, so no registration
file has to be written by hand for the card route. `Apps/show.json` is only the
launcher's **visibility list**, and MainUI rewrites it during its own scan.

If `PM3 tools` does not appear, add this object to the array in
`<card>/Apps/show.json` (keeping the file valid JSON, separating it from the
previous entry with a comma) and reboot:

```json
{
 "label": "PM3 tools",
 "show": 1
}
```

The label comes from `config.json` (`"label":"PM3 tools"`); the directory name
`Proxmark3Tools` is what `install.sh`/`deploy-app.sh` use, and `config.json` is
what MainUI shows. The SSH route performs this edit automatically and verifies it
by re-parsing the file — see `app/deploy-app.sh`. There is no automated
equivalent on the card route, by design: a card reader has no shell on the device.

---

## 8. Verifying on the device

The GUI binary has non-interactive modes, so a card install can be checked
without trusting the menu:

```sh
# from a shell on the handheld (needs SSH) ...
cd /mnt/SDCARD/Apps/Proxmark3Tools
./pm3scan --help                       # binary runs at all (loader/SDL present)
./pm3scan --probe                      # SDL video driver, resolution, gamepad
./pm3scan --scan-once hf               # one HF scan, no UI, prints the result
./pm3scan --pm3 ./pm3/proxmark3 --scan-once lf     # force the card copy
```

To prove the card copy is really the one in use, the definitive signal is the
first line of the app's log — see below.

### No-SSH verification: read the log off the card

`pm3scan` appends every session to `<app dir>/pm3scan.log`, and that file lives on
the card. So a card install can be verified end to end with only the card reader:

1. Launch `PM3 tools` on the handheld and press **A** (one HF scan is enough).
2. Leave the app, power the handheld off, take the card out.
3. On the workstation:

   ```sh
   head -1 /media/<user>/<card>/Apps/Proxmark3Tools/pm3scan.log
   ```

The first line names the client that was actually used:

```
=== pm3scan start (pid ...) pm3=/mnt/SDCARD/Apps/Proxmark3Tools/pm3/proxmark3 port=/dev/ttyACM0
```

- `pm3=/mnt/SDCARD/Apps/Proxmark3Tools/pm3/proxmark3` — **the card copy is in use**;
  this deployment is self-contained.
- `pm3=/mnt/UDISK/pm3-v423346/proxmark3` — the card copy was not found, so the app
  fell through to internal storage. Re-copy the tree (check for an `Apps/Apps/`
  nesting, section 5).

The same log records the display driver, the gamepad, and each scan's outcome, so
it also answers "did it actually read a tag" without a shell:

```
display 1024x768 driver=mali
joystick: Xbox 360 Controller
scan start: HF 13.56MHz -> hf search
scan done: exit=0 findings=6
```

This is the loop the card route was verified with, on the real handheld. The log
of that session reads:

```
[14:09:43] === pm3scan start (pid 14889) pm3=/mnt/SDCARD/Apps/Proxmark3Tools/pm3/proxmark3 port=/dev/ttyACM0
[14:09:44] display 1024x768 driver=mali
[14:09:44] joystick: Xbox 360 Controller
[14:09:44] start refused: no Proxmark3 on /dev/ttyACM0        <- PM3 not plugged in yet
[14:11:25] pm3 status: PM3 GENERIC  fw v4.23346-suspect
[14:11:27] scan start: HF 13.56MHz -> hf search
[14:11:37] scan done: exit=0 findings=7                       <- a real tag was read
```

`pm3=` names the card copy, so the deployment is genuinely self-contained — the
first time this route was exercised on this hardware it resolved to
`/mnt/UDISK/...` instead (section 12). `fw v4.23346-suspect` is upstream's way of
saying the firmware was built from a source tree with local modifications; it is
the same tag and the client accepted it, so capabilities matched.

If the Proxmark3 was missing it says `start refused: no Proxmark3 on
/dev/ttyACM0`, which is the same diagnostic the app shows on screen.

Because the log is on the card and not in internal storage, this check works on a
handheld with SSH disabled, and it survives the card being moved. It is the only
way to confirm the resolution order of section 6 without a shell on the device.

---

## 9. Release packaging

`make-release.sh` produces the two assets that match the two install routes:

```sh
./make-release.sh                  # -> dist/release/
```

| Asset | Route |
|---|---|
| `trimui-pm3-<version>.tar.gz` | sources + prebuilt binaries; unpack and run `install.sh` over SSH |
| `trimui-pm3-sdcard-<version>.zip` | **the card tree**; extract and copy `Apps/` — no SSH |

The zip is built by walking `dist/sdcard/` with Python's `zipfile` (deflate,
`compresslevel=9`), which puts `Apps/` and `HOW-TO-INSTALL.txt` at the zip root.
Zip rather than tar.gz so a Windows user can extract it with Explorer — and the
card route is precisely the one that should not require a Unix toolchain.

`<version>` comes from `git describe --tags --exact-match`, falling back to
`git describe --tags --always`, then `dev`. So the current release is
`v0.0.1`, but a build from a commit *after* that tag is named e.g.
`v0.0.1-2-g2fd7eb5`. Both scripts accept `VERSION=...` to override.

Two constraints that follow from the implementation:

- `make-bundle.sh` lays out the bundle with `git archive HEAD`, so **only
  committed content is packaged**. Commit before building a bundle, or the
  binaries will ship against a tree that does not exist upstream.
- `make-release.sh` calls both `make-bundle.sh` and `make-sdcard.sh`, so it needs
  the Python 3 interpreter on the host (the device has none, which is why the
  show.json edit in `deploy-app.sh` is done host-side).

Both release bundles carry the Iceman client built from tag **v4.23346** with its
dictionaries, lua scripts and command scripts, so neither needs a cross-compiler.

---

## 10. Updating and removing

| Task | Card route |
|---|---|
| Update the app | rebuild, copy `Apps/Proxmark3Tools/` over the old one, reboot |
| Update the client | same — the client travels in `pm3/` inside the app folder |
| Remove | delete `<card>/Apps/Proxmark3Tools/` and, if present, its entry in `Apps/show.json` |

Nothing is installed outside `<card>/Apps/Proxmark3Tools/`, so removal is a single
directory delete. (Compare the SSH route, which also writes
`/mnt/UDISK/pm3-v423346/` and keeps a `show.json.bak`.)

Overwriting a binary that is currently running fails with `Text file busy` on
Linux. The card route avoids it because the device is powered off while the card
is out; if the app is ever updated in place over SSH instead, kill it first.

---

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `make-sdcard.sh` reports `== MISSING` | Build `client/out/` and `app/out/` first (section 2), or unpack a release bundle |
| `PM3 tools` not in the Apps menu | MainUI only re-reads the list at startup: reboot. Still missing → add the `show.json` entry (section 7) |
| App starts, status says the client is missing | `pm3/proxmark3` did not survive the copy, or was copied without `pm3/` — re-copy the whole `Proxmark3Tools` folder |
| `no Proxmark3 on /dev/ttyACM0` | PM3 not plugged in, or in the bottom (charge) port instead of the **top** host port |
| `Capabilities structure version ... (vN != vM)` | PM3 firmware is from a different Iceman tag than the client — see `docs/FIRMWARE.md` |
| Client runs but cannot find dictionaries | `pm3-resources-*.tar.gz` was not extracted into `pm3/`; rebuild the tree |
| `Text file busy` when re-pushing over SSH | An old copy is running: `kill -9 $(pgrep -x pm3scan)` |
| Screen goes black mid-session | The device slept; `launch.sh` sets `/tmp/stay_awake`, so this means the app was not started through the menu |

---

## 12. Notes from reviewing this path

Behaviour confirmed by re-running the scripts on this checkout and by deploying to
a real TrimUI card over USB mass storage, plus points a reader of the older docs
should know:

- **End-to-end on hardware.** The release zip was extracted and its `Apps/` copied
  onto a real card: 567 files landed byte-identical to the built tree, no
  symlinks, `Apps/show.json` untouched and still valid, and the card's other apps
  unaffected. Re-running the copy (the update path) was idempotent — no
  `Apps/Apps/` nesting, no stale files. The first attempt was then destroyed by
  pulling the cable before ejecting; the card was repaired with `fsck.vfat` and
  the tree re-copied and re-verified — that incident is section 13, and it is the
  most important operational lesson in this document. The device-side launch check
  is section 8's log method. Closing the loop: after the repair, an ejected
  re-deploy, a reboot, and an HF scan on the handheld, `pm3scan.log` showed the
  card copy in use and `findings=7`; reading the card back afterwards showed all
  567 files still byte-identical, so the eject procedure and the deployment
  survive a real device session.
- **The card copy had never actually been exercised on the device.** The app log
  left by the previous install showed `pm3=/mnt/UDISK/pm3-v423346/proxmark3`, and
  that card's `Proxmark3Tools/` had no `pm3/` subdirectory at all — so the runs
  that were claimed as "client on the card" were resolving to internal storage.
  This is precisely the failure the log's first line is meant to catch; check it
  after every card deployment.
- **`make-sdcard.sh` rebuilds `dist/sdcard/` cleanly** (47 MB, no stale files),
  `make-bundle.sh` names its output from `git describe`
  (`trimui-pm3-v0.0.1-2-g2fd7eb5.tar.gz` on the current HEAD), and the tree
  contains no symlinks, no vfat-hostile names and no files over the path limits.
- **`make-bundle.sh` + `make-release.sh` round-trip exactly:** unzipping the
  release zip reproduces all 568 files byte-identically, and the zip preserves the
  executable bit (which the vfat card ignores anyway).
- **`make-release.sh` does not clear `dist/release/` first.** Assets from previous
  versions stay there, and its own suggested `gh release create ... $OUT/*` would
  attach them to the new release. Delete stale files before uploading, or read the
  script's output listing rather than trusting the glob.
- **Executable bits are not a concern** on the device (section 4): `chmod +x` on
  the host tree has no effect on a vfat card, and none is needed, because the
  device mount's `fmask`/`dmask` present everything as 0777. The host-side mount
  (`fmask=0022`) shows those same files as `-rw-r--r--`, which is expected and
  harmless — it is not the permission set the handheld sees.
- **Copying 56 MB to the card takes about a minute** over USB mass storage with
  `sync`; the packaging scripts themselves are instant. A card with little free
  space, or an interrupted copy, is the most likely source of a half-deployed
  tree — re-copy rather than patching it up.
- **Precedence is a footgun, not a bug:** the card copy shadows the internal one
  (section 6). Document it wherever a user might mix the two routes.
- **The Iceman tag is repeated in five places:** the pin in
  `client/fetch-sources.sh`, the hardcoded `PM3_TAG` in `install.sh`, the
  `${PM3_TAG:-...}` defaults in `make-sdcard.sh`/`make-bundle.sh`, the tag
  `build-client.sh` derives from the checked-out source, and the prose in
  `docs/FIRMWARE.md`. The packaging scripts can be retargeted with `PM3_TAG=...`,
  but `install.sh` cannot — a tag bump must touch all five consistently.
- **`README.md`'s bundle example still used the old `trimui-pm3-v4.23346.tar.gz`
  naming**, which predates `make-bundle.sh` versioning bundles by release tag.
  Corrected to `<version>` alongside this document.

---

## 13. Ejecting properly: a real incident

This happened while writing this document, on the verified Brick Pro and a real
card. It is recorded here because the failure mode is invisible until the device
reboots, and because "I ran `sync`" does **not** prevent it.

### What was done

The 56 MB tree was copied to the card while the TrimUI was in USB mass-storage
mode. The copy was verified file by file, `sync` was run, and the card was then
unplugged — **while the volume was still mounted** (an attempted unmount had
failed with `target is busy` and the cable was pulled anyway).

### What the kernel said

```
FAT-fs (sda1): Volume was not properly unmounted. Some data may be corrupt. Please run fsck.
sd 0:0:0:0: [sda] Synchronize Cache(10) failed: Result: hostbyte=DID_NO_CONNECT driverbyte=DRIVER_OK
FAT-fs (sda1): error, fat_get_cluster: invalid cluster chain (i_pos 0)
FAT-fs (sda1): Filesystem has been set read-only
```

The device enumerates as a USB mass-storage gadget that advertises
`Write cache: enabled`. Pulling the cable aborts the `SYNCHRONIZE CACHE` the
kernel would have issued on the last close, so the *tail* of the FAT metadata
never reaches the medium. The host's `sync` only guarantees the host page cache
was written to the gadget — not that the gadget wrote it to the card.

### What the user sees on the handheld

`PM3 tools` disappears from the Apps menu while every other app still works. The
device mounts `/mnt/SDCARD` with `errors=continue`, so the kernel logs the bad
directory and skips it instead of going read-only — which is exactly why the rest
of the menu looks fine. The host mounts the same card with `errors=remount-ro`
instead, so any `ls` of `Apps/` there flips the filesystem read-only until it is
remounted.

`show.json` is **not** rewritten and still lists `PM3 tools`; the label is there,
but there is no discoverable app behind it.

### Diagnosis

```sh
ls -la /media/<user>/<card>/Apps/
# d?????????  ? ?  ?  ?  ?  Proxmark3Tools
# ls: cannot access '.../Proxmark3Tools': Input/output error
```

The whole deployed tree was orphaned: 582 lost FAT chains for a tree of 567 files
+ 15 directories.

### Repair

```sh
udisksctl unmount -b /dev/sda1       # never run fsck on a mounted volume
sudo fsck.vfat -n /dev/sda1          # read-only: look before you touch
sudo fsck.vfat -a /dev/sda1          # repair
```

Two passes were needed, and the difference between them is instructive:

1. First pass — `Contains a free cluster (1747733). Assuming EOF.` It truncated
   the broken directory chain, which orphaned everything after the break, and
   then **wrote each lost chain to a file**: `Reclaimed 1776 unused clusters
   (58195968 bytes) in 582 chains.` dosfstools keeps lost data rather than freeing
   it, as `FSCK0000.REC` … `FSCK0581.REC` in the card root. Check the arithmetic
   before deleting them: 582 = 567 files + 15 directories, 15 of the `.REC` files
   begin with the `.`/`..` entries of a directory cluster, and the recovered sizes
   match the tree (including a 300x300 PNG and LZ4-compressed resources) — so they
   are the deployed tree's remains, not user data.
2. Second pass — `Start does point to root directory. Deleting dir.` The
   truncation had left the directory entry with start cluster **0**, which is how
   a FAT entry points at the root directory and is invalid for a subdirectory.
   That is what the kernel had been reporting as `corrupted directory (invalid
   entries)`. fsck deleted the entry, which is the desired outcome: the content is
   reproducible from `make-sdcard.sh`.

Then re-mount, re-copy, and re-verify all 567 checksums — do not try to repair the
half-deployed tree in place.

fsck also made three unrelated changes, all pre-existing rather than caused by
this deployment, and all harmless: it cleared an invalid volume-label field,
renamed two files whose 8.3 short names were garbled
(`Apps/PixelReader/Books/…`, `RetroArch/…/CHEATS/…`; their long names are kept),
and it left a harmless one-byte boot-sector/backup difference alone.

### Fallback if `Deleting dir.` is not offered

The launcher matches menu entries by the **`label` in `config.json`**, not by
directory name — `EmuDrop`, `WiliWili` and `SDRRadio` are all named differently
from what they display. So an undeletable broken entry can be side-stepped by
deploying to a fresh directory (`Apps/PM3Tools/`): the menu still shows
`PM3 tools`. Treat that as a workaround, not a fix — the broken entry keeps
logging errors on every scan on a device that mounts with `errors=continue`, and
keeps flipping a host mount read-only.

### The rule

1. Unmount (or power off) the card **and confirm it** before touching the cable:
   `findmnt /dev/sda1` must print nothing.
2. Prefer a card reader over the handheld's mass-storage gadget; it removes the
   gadget's write cache from the path entirely.
3. After re-plugging, verify rather than assume: compare checksums of the whole
   tree again (section 8's log check covers the runtime side).

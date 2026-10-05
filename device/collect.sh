#!/bin/sh
# TrimUI (TG4040 verified) — device and kernel diagnostic script.
#
# Answers the single question the whole project hinges on: does this kernel
# provide a host-side CDC-ACM (cdc_acm) driver, i.e. will a Proxmark3 plugged
# into the top USB-C port show up as /dev/ttyACM0 ?
#
# Runs on the device with busybox sh. Writes a report to stdout; if $1 is given,
# also writes it to that path (use an SD-card path when running without SSH).
#
# Three independent checks are used because any one of them can be missing:
#   1. /proc/tty/drivers     - "acm" line exists only if the driver is built in/loaded
#   2. /sys/bus/usb/drivers  - cdc_acm dir exists only if the driver is registered
#   3. config/module files   - CONFIG_USB_ACM=y|m, or a cdc_acm.ko file on disk

OUT="${1:-}"

emit() {
    if [ -n "$OUT" ]; then
        tee -a "$OUT"
    else
        cat
    fi
}

{
    echo "==================================================================="
    echo " TrimUI device report — $(date 2>/dev/null)"
    echo "==================================================================="

    echo
    echo "### 0. Device identity"
    echo "--- uname -a"
    uname -a
    echo "--- /proc/device-tree/model"
    tr -d '\0' < /proc/device-tree/model 2>/dev/null; echo
    echo "--- /proc/device-tree/compatible"
    tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null; echo
    echo "--- /etc/os-release / version files"
    cat /etc/os-release 2>/dev/null
    cat /etc/version /etc/trimui_version 2>/dev/null
    echo "--- uptime"
    cat /proc/uptime 2>/dev/null

    echo
    echo "### 1. VERDICT CHECK — /proc/tty/drivers (look for an 'acm' line)"
    echo "--- raw"
    cat /proc/tty/drivers 2>/dev/null
    echo "--- grep acm/usb"
    grep -iE 'acm|usb' /proc/tty/drivers 2>/dev/null || echo "(no acm/usb line)"

    echo
    echo "### 2. VERDICT CHECK — /sys/bus/usb/drivers (look for 'cdc_acm')"
    ls -1 /sys/bus/usb/drivers 2>/dev/null | tr '\n' ' '; echo
    echo "--- cdc_acm registered?"
    if [ -d /sys/bus/usb/drivers/cdc_acm ]; then
        echo "YES: /sys/bus/usb/drivers/cdc_acm exists"
        ls -l /sys/bus/usb/drivers/cdc_acm 2>/dev/null
    else
        echo "NO: no cdc_acm in /sys/bus/usb/drivers"
    fi
    echo "--- related usb-serial drivers present"
    for d in cdc_acm usbserial option ch341 ftdi_sio pl2303 cp210x; do
        [ -d "/sys/bus/usb/drivers/$d" ] && echo "  present: $d"
    done

    echo
    echo "### 3. VERDICT CHECK — kernel config / modules"
    for f in /proc/config.gz /boot/config-$(uname -r) /lib/modules/$(uname -r)/config; do
        echo "--- $f"
        if [ -f "$f" ]; then
            case "$f" in
                *.gz) zcat "$f" 2>/dev/null | grep -iE 'USB_ACM|USB_CDC|ACM|USB_SERIAL|USB_GADGET|USB_HOST|USB_EHCI|USB_OHCI|USB_MUSB|SUNXI' ;;
                *)    grep -iE 'USB_ACM|USB_CDC|ACM|USB_SERIAL|USB_GADGET|USB_HOST|USB_EHCI|USB_OHCI|USB_MUSB|SUNXI' "$f" ;;
            esac
        else
            echo "(absent)"
        fi
    done
    echo "--- cdc_acm module file on disk?"
    find /lib/modules -name 'cdc_acm*' -o -name 'usbserial*' 2>/dev/null | head -20
    echo "--- is cdc_acm loaded right now?"
    ls -d /sys/module/cdc_acm 2>/dev/null && echo "loaded" || echo "not loaded (expected: no hardware attached)"
    echo "--- modules.dep / modules.builtin hints"
    for m in /lib/modules/$(uname -r)/modules.builtin /lib/modules/$(uname -r)/modules.dep; do
        [ -f "$m" ] && { echo "-- $m"; grep -iE 'cdc_acm|usbserial' "$m" 2>/dev/null || echo "  (no cdc_acm/usbserial entry)"; }
    done

    echo
    echo "### 4. USB host controller stack"
    echo "--- USB host controller drivers registered"
    ls -1 /sys/bus/platform/drivers 2>/dev/null | grep -iE 'usb|ehci|ohci|musb|dwc|sunxi' | tr '\n' ' '; echo
    echo "--- /sys/bus/usb/devices"
    ls -1 /sys/bus/usb/devices 2>/dev/null | tr '\n' ' '; echo
    echo "--- lsusb"
    lsusb 2>/dev/null || echo "(no lsusb)"
    echo "--- usbcore version / usbfs"
    cat /sys/module/usbcore/version 2>/dev/null || echo "(usbcore not built as module)"
    grep -i usbfs /proc/filesystems 2>/dev/null

    echo
    echo "### 5. Character devices / tty nodes"
    echo "--- /proc/tty/driver (per-driver detail)"
    ls -1 /proc/tty/driver 2>/dev/null | tr '\n' ' '; echo
    echo "--- /dev/tty[A-Z]* /dev/ttyUSB* /dev/ttyS0-4"
    ls -la /dev/tty[A-Z]* /dev/ttyUSB* 2>/dev/null || echo "(none)"
    ls -la /dev/ttyS0 /dev/ttyS1 /dev/ttyS2 /dev/ttyS3 /dev/ttyS4 2>/dev/null
    echo "--- /sys/class/tty listing"
    ls -1 /sys/class/tty 2>/dev/null | tr '\n' ' '; echo

    echo
    echo "### 6. USB power / regulator hints (100mA OTG problem)"
    for d in /sys/class/regulator/*; do
        [ -e "$d/name" ] || continue
        n=$(cat "$d/name" 2>/dev/null)
        case "$n" in
            *usb*|*USB*|*vbus*|*VBUS*|*otg*|*OTG*)
                echo "  $n: $(cat "$d/state" 2>/dev/null) microvolts=$(cat "$d/microvolts" 2>/dev/null) max=$(cat "$d/max_microamps" 2>/dev/null)" ;;
        esac
    done
    echo "--- extcon / otg mode"
    find /sys/class/extcon -maxdepth 3 -name name -exec sh -c 'echo "  $(dirname {}): $(cat {})"' \; 2>/dev/null | head

    echo
    echo "### 7. dmesg — USB related"
    dmesg 2>/dev/null | grep -iE 'usb|cdc_acm|acm|tty|ehci|ohci|musb' | tail -60 || echo "(dmesg not readable)"

    echo
    echo "### 8. userspace tooling available on device"
    for b in sh bash gcc clang make readline python3 curl wget socat stty lsusb; do
        printf '  %-10s ' "$b"; command -v "$b" 2>/dev/null || echo "-"
    done
    echo "--- libc"
    ls -l /lib/libc.so* /lib/ld-* /lib/ld-linux* 2>/dev/null
    echo "--- writable SD mount points"
    mount 2>/dev/null | grep -iE 'mmcblk|sd|vfat|exfat' 

    echo
    echo "==================================================================="
    echo " INTERPRETATION"
    echo "==================================================================="
    if grep -qiE '(^| )acm( |$)' /proc/tty/drivers 2>/dev/null || [ -d /sys/bus/usb/drivers/cdc_acm ]; then
        echo " RESULT: cdc_acm IS available -> route A (USB direct) is ALIVE."
        echo " Next: attach the Proxmark3 to the TOP USB-C port and re-run with PM3_ATTACHED=1."
    else
        echo " RESULT: no cdc_acm found by the static checks."
        echo " Still confirm by attaching the PM3: a missing driver + attached device shows"
        echo " up in dmesg as 'new full-speed USB device' with no /dev/ttyACM0."
        echo " If dmesg shows nothing at all -> USB host port/power problem, try a Y-cable."
    fi
} 2>&1 | emit

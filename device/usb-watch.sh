#!/bin/sh
# Run ON the handheld. Watches for a USB device being plugged into the host port
# and dumps everything needed to judge whether the port + driver path works.
#
#   sh usb-watch.sh [seconds]        # default 90
#
# Keeps the SoC awake (the sunxi host controllers lose VBUS across suspend),
# snapshots before/after, and reports the new device with its bound driver.
# Works for any USB device; a CDC-ACM device (Proxmark3) shows up as ttyACM*.

DUR="${1:-90}"
echo 1 > /tmp/stay_awake 2>/dev/null

snap_usb() {
    ls -1 /sys/bus/usb/devices 2>/dev/null | sort
}

snap_tty() {
    ls -1 /dev/ttyACM* /dev/ttyUSB* /dev/sd* 2>/dev/null | sort
}

dump_dev() {
    d="/sys/bus/usb/devices/$1"
    [ -d "$d" ] || return
    echo "    product      : $(cat $d/product 2>/dev/null)"
    echo "    manufacturer : $(cat $d/manufacturer 2>/dev/null)"
    echo "    idVendor     : $(cat $d/idVendor 2>/dev/null)"
    echo "    idProduct    : $(cat $d/idProduct 2>/dev/null)"
    echo "    bcdDevice    : $(cat $d/bcdDevice 2>/dev/null)"
    echo "    speed        : $(cat $d/speed 2>/dev/null) Mbps"
    echo "    bDeviceClass : $(cat $d/bDeviceClass 2>/dev/null)"
    echo "    interfaces   : $(ls -d $d/*:* 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"
    # which driver claimed each interface
    for i in $d/*:*; do
        [ -e "$i/driver" ] || continue
        echo "      $(basename $i) -> $(basename $(readlink $i/driver))"
    done
}

BEFORE_USB=$(snap_usb)
BEFORE_TTY=$(snap_tty)

echo "=== BEFORE ==="
echo "usb devices: $(echo $BEFORE_USB | tr '\n' ' ')"
echo "tty nodes  : $(echo $BEFORE_TTY | tr '\n' ' ')"
echo
echo "*** Plug the device into the TOP USB-C port now (${DUR}s window) ***"
echo

FOUND=""
i=0
while [ $i -lt "$DUR" ]; do
    sleep 1
    i=$((i + 1))
    NOW=$(snap_usb)
    NEW=$(printf '%s\n' "$BEFORE_USB" | grep -vxF "$NOW" ; printf '%s\n' "$NOW" | grep -vxF "$BEFORE_USB")
    # only care about genuinely NEW entries
    for n in $NOW; do
        case "$(printf '%s\n' "$BEFORE_USB" | grep -x "$n")" in
            "") ;;
            *) continue ;;
        esac
        # skip the interface nodes of the root hubs we already had
        case "$n" in usb1|usb2) continue;; esac
        FOUND="$FOUND $n"
    done
    [ -n "$FOUND" ] && break
done

echo "=== AFTER ${i}s ==="
AFTER_USB=$(snap_usb)
AFTER_TTY=$(snap_tty)
echo "usb devices: $(echo $AFTER_USB | tr '\n' ' ')"
echo "tty nodes  : $(echo $AFTER_TTY | tr '\n' ' ')"

if [ -z "$FOUND" ]; then
    echo
    echo "RESULT: NO USB device enumerated within ${DUR}s."
    echo "  - if nothing was plugged, re-run and plug it"
    echo "  - if something was plugged: the top port is not a working host port,"
    echo "    or VBUS is off / current-limited. Check 'dmesg | tail' and try a Y-cable."
else
    echo
    echo "RESULT: NEW USB device (s) detected:$FOUND"
    for n in $FOUND; do
        echo "  -- $n"
        dump_dev "$n"
    done
    echo
    echo "--- driver bind check ---"
    if [ -d /sys/bus/usb/drivers/cdc_acm ]; then
        echo "  cdc_acm bound interfaces: $(ls -1 /sys/bus/usb/drivers/cdc_acm 2>/dev/null | grep -v '^bind$\|^unbind$\|^new_id$\|^remove_id$\|^uevent$\|^module$' | tr '\n' ' ')"
    fi
    if [ -d /sys/bus/usb/drivers/usb-storage ]; then
        echo "  usb-storage bound       : $(ls -1 /sys/bus/usb/drivers/usb-storage 2>/dev/null | grep -v '^bind$\|^unbind$\|^new_id$\|^remove_id$\|^uevent$\|^module$' | tr '\n' ' ')"
    fi
    echo
    echo "--- new tty nodes ---"
    for t in $AFTER_TTY; do
        case "$(printf '%s\n' "$BEFORE_TTY" | grep -x "$t")" in
            "") echo "  NEW: $t" ;;
        esac
    done
    echo
    echo "--- dmesg tail ---"
    dmesg 2>/dev/null | tail -25
fi

rm -f /tmp/stay_awake 2>/dev/null
echo
echo "=== VERDICT ==="
if printf '%s\n' "$AFTER_TTY" | grep -q 'ttyACM'; then
    echo " ttyACM node present -> CDC-ACM path CONFIRMED end to end."
elif printf '%s\n' "$AFTER_TTY" | grep -q 'ttyUSB'; then
    echo " ttyUSB node present -> USB-serial path CONFIRMED (host port, power, enumeration, tty all work)."
    echo " A Proxmark3 (CDC-ACM) will produce ttyACM0 through the same path."
elif [ -n "$FOUND" ]; then
    echo " Device enumerated but produced no tty node (expected for a keyboard/flash drive)."
    echo " Host port + VBUS + enumeration CONFIRMED; only the CDC-ACM bind is still unproven."
else
    echo " No enumeration - host port or VBUS problem. Try a Y-cable with external power."
fi

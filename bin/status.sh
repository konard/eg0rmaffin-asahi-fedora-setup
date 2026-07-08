#!/bin/bash
# swaybar status_command — printed once per loop, consumed by swaybar.
# Extracted from sway/config: an inline while-loop is fragile to quote inside
# the sway config and produced no output on the target machine.
#
# Right-side layout: layout │ date/time │ battery, e.g.
#   EN  │  Wed 08 Jul 04:52  │  bat 90%
# Refresh is 5s so the layout indicator flips promptly after Cmd+Shift;
# battery/clock don't mind the faster cycle.
while true; do
    # Active keyboard layout -> EN / RU. `first` guards against multiple
    # keyboards (built-in + external) each reporting a layout.
    layout=$(swaymsg -t get_inputs 2>/dev/null \
        | jq -r '[.[] | select(.type=="keyboard") | .xkb_active_layout_name] | first' 2>/dev/null)
    case "$layout" in
        English*) kb=EN ;;
        Russian*) kb=RU ;;
        "" | null) kb="??" ;;
        *) kb=EN ;;
    esac

    # English month name regardless of system locale (LC_TIME=C).
    now=$(LC_TIME=C date '+%a %d %b %H:%M')

    bat=$(cat /sys/class/power_supply/macsmc-battery/capacity 2>/dev/null || echo '?')

    echo "${kb}  │  ${now}  │  bat ${bat}%"
    sleep 5
done

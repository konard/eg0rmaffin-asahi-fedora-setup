#!/bin/bash
# swaybar status_command — printed once per loop, consumed by swaybar.
# Extracted from sway/config: an inline while-loop is fragile to quote inside
# the sway config and produced no output on the target machine.
while true; do
    bat=$(cat /sys/class/power_supply/macsmc-battery/capacity 2>/dev/null || echo '?')
    echo "$(date '+%d.%m %H:%M') | bat ${bat}%"
    sleep 30
done

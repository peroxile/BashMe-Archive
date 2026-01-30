#!/usr/bin/env bash 

set -euo pipefail
# set -x

TRASH="$HOME/.local/share/Trash"
SCRIPT_PATH="$(readlink -f "$0" )"

usage() {
    echo "Usage:"
    echo " $0 <time>            # run cleanup now (e.g 1h, 7d)"
    echo " $0 --cron <time>     # install cron job"
    echo " $0 --systemd <time>  # install systemd timer"
    exit 1
}

[[ $# -lt 1 ]] && usage

MODE="run"

if [[ "$1" == "--cron" || "$1" == "--systemd" ]]; then
    MODE="$1"
    shift
fi 


INPUT="${1:-}"

# Validate input 
if [[ ! "$INPUT" =~ ^([0-9]+)([mhd])$ ]]; then
    echo "Invalid format. Use: <number>[m|h|d]" >&2
    exit 1
fi

VALUE="${BASH_REMATCH[1]}"
UNIT="${BASH_REMATCH[2]}"

# Convert to minutes
case "$UNIT" in
    m) MINUTES="$VALUE" ;;
    h) MINUTES=$(( VALUE * 60 )) ;;
    d) MINUTES=$(( VALUE * 1440 )) ;;
esac


# Delete files 

cleanup() {
    find "$TRASH/files" -mindepth 1 -mmin +"$MINUTES" -exec rm -rf {} +
    find "$TRASH/info" -mindepth  1 -mmin +"$MINUTES" -exec rm -f {} +

}


install_cron() {
    ( crontab -l 2>/dev/null; echo "0 * * * * $SCRIPT_PATH $INPUT") | crontab -
}

install_systemd() {
    mkdir -p ~/.config/systemd/user

    cat > ~/.config/systemd/user/empty-trash.service <<EOF
[Unit]
Description=Empty trash

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH $INPUT
EOF

    cat > ~/.config/systemd/user/empty-trash.timer <<EOF
[Unit]
Description=Empty trash timer

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now empty-trash.timer
}


case "$MODE" in 
    run) 
        cleanup
        ;;
    --cron)
        install_cron
        ;;
    --systemd) 
        install_systemd
        ;;
    esac
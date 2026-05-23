#!/bin/sh
# tynet-rpi-eeprom-update — fetch the newest pieeprom-*.bin from upstream
# raspberrypi/rpi-eeprom on GitHub and stage it via `rpi-eeprom-update -d -f`,
# preserving the currently-running EEPROM's config (BOOT_ORDER etc.).
#
# Rationale: the rpi-eeprom Debian package on Ubuntu lags upstream by months.
# This avoids adding a foreign apt source by reading the raspberrypi/rpi-eeprom
# repo directly. It will not modify the EEPROM image itself — staged updates
# only take effect after a reboot, so this is reversible up until that point
# with `sudo rpi-eeprom-update -r`.

set -eu

REPO="raspberrypi/rpi-eeprom"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/master"
API_BASE="https://api.github.com/repos/${REPO}/contents"

channel=default
dry_run=0
cron_mode=0
platform=""

usage() {
    cat <<EOF
Usage: tynet-rpi-eeprom-update [--channel default|latest|beta]
                               [--platform 2711|2712]
                               [--dry-run] [--cron]

Fetches the newest pieeprom-*.bin for this Pi's SoC from upstream
raspberrypi/rpi-eeprom on GitHub. Preserves the currently-running EEPROM
config (BOOT_ORDER etc.) via 'rpi-eeprom-config --config'. Stages the
update; user must reboot to apply.

Options:
  --channel <name>   default (stable, recommended), latest, or beta
  --platform <soc>   2711 (Pi 4/400/CM4) or 2712 (Pi 5). Auto-detected if omitted.
  --dry-run          Show what would happen; don't download or stage.
  --cron             Quiet mode for cron: no output unless action taken or error.
EOF
}

log() { if [ "$cron_mode" -eq 0 ]; then printf '%s\n' "$*"; fi; }
warn() { printf '%s\n' "$*" >&2; }
die() { warn "error: $*"; exit 1; }

while [ $# -gt 0 ]; do
    case $1 in
        --channel) channel=$2; shift 2 ;;
        --platform) platform=$2; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        --cron) cron_mode=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

case "$channel" in
    default|latest|beta) ;;
    *) die "invalid channel: $channel (want default|latest|beta)" ;;
esac

if [ -z "$platform" ]; then
    compat=$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null || true)
    case "$compat" in
        *bcm2712*) platform=2712 ;;
        *bcm2711*) platform=2711 ;;
        *) die "could not detect Pi platform from /proc/device-tree/compatible (got: $compat); pass --platform explicitly" ;;
    esac
fi

case "$platform" in
    2711|2712) ;;
    *) die "invalid platform: $platform (want 2711 or 2712)" ;;
esac

for cmd in curl rpi-eeprom-update rpi-eeprom-config; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done

dir="firmware-${platform}/${channel}"

# Upstream sometimes makes a channel a symlink (e.g. firmware-2711/beta -> latest/).
# The GitHub contents API returns a single object with "type": "symlink" in
# that case rather than the linked dir's listing, so resolve one hop and
# re-query if needed.
fetch_listing() {
    target_dir=$1
    response=$(curl -fsSL "${API_BASE}/${target_dir}")
    case "$response" in
        \[*) printf '%s' "$response"; return ;;
    esac
    type=$(printf '%s' "$response" | awk -F'"' '/"type"[[:space:]]*:/{print $4; exit}')
    [ "$type" = "symlink" ] || die "unexpected API response shape for ${target_dir} (type=${type:-unknown})"
    target=$(printf '%s' "$response" | awk -F'"' '/"target"[[:space:]]*:/{print $4; exit}')
    target=${target%/}
    parent=$(dirname "$target_dir")
    if [ "$parent" = "." ]; then
        resolved=$target
    else
        resolved="$parent/$target"
    fi
    # Goes to stderr because fetch_listing's stdout is captured by $().
    if [ "$cron_mode" -eq 0 ]; then
        printf '  (%s is a symlink to %s)\n' "$target_dir" "$resolved" >&2
    fi
    curl -fsSL "${API_BASE}/${resolved}"
}

# Newest pieeprom-YYYY-MM-DD.bin in the channel directory. Names sort
# lexically by date because they're zero-padded ISO-8601.
latest_file=$(fetch_listing "$dir" \
    | awk -F'"' '/"name":/ {print $4}' \
    | grep -E '^pieeprom-[0-9]{4}-[0-9]{2}-[0-9]{2}\.bin$' \
    | sort -r \
    | head -n1)

[ -n "$latest_file" ] || die "no pieeprom-*.bin found in ${dir} (network issue or upstream layout change?)"

latest_date=$(printf '%s' "$latest_file" | sed -E 's/^pieeprom-([0-9-]+)\.bin$/\1/')

# Current EEPROM timestamp comes out of rpi-eeprom-update as a unix epoch
# on the CURRENT line, e.g.: "   CURRENT: Mon Feb 23 14:56:33 UTC 2026 (1771858593)"
current_epoch=$(rpi-eeprom-update | awk '/^[[:space:]]*CURRENT:/ {gsub(/[()]/, "", $NF); print $NF; exit}')
[ -n "$current_epoch" ] || die "could not parse CURRENT epoch from rpi-eeprom-update"
latest_epoch=$(date -u -d "${latest_date}" +%s 2>/dev/null) || die "could not parse upstream date ${latest_date}"

log "channel:   ${channel}"
log "platform:  bcm${platform}"
log "current:   $(date -u -d "@${current_epoch}" '+%Y-%m-%d') (epoch ${current_epoch})"
log "available: ${latest_date} (epoch ${latest_epoch})"

if [ "$latest_epoch" -le "$current_epoch" ]; then
    log "no newer EEPROM available — nothing to do."
    exit 0
fi

if [ "$dry_run" -eq 1 ]; then
    log "(dry-run) would download ${RAW_BASE}/${dir}/${latest_file} and stage it"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "must run as root (need to write /boot/firmware and reflash SPI on reboot)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

[ "$cron_mode" -eq 0 ] && printf 'downloading %s ...\n' "$latest_file"
curl -fsSL "${RAW_BASE}/${dir}/${latest_file}" -o "${tmp}/${latest_file}"

# 524288 bytes is the canonical Pi EEPROM image size; sanity check.
got=$(wc -c < "${tmp}/${latest_file}")
[ "$got" -eq 524288 ] || die "downloaded image is ${got} bytes; expected 524288 — refusing to flash"

# Preserve current config (BOOT_ORDER, BOOT_UART, WAKE_ON_GPIO, ...).
rpi-eeprom-config > "${tmp}/current.conf"

# Build a new image: upstream binary + our preserved config.
rpi-eeprom-config \
    --config "${tmp}/current.conf" \
    --out "${tmp}/staged.bin" \
    "${tmp}/${latest_file}" >/dev/null

rpi-eeprom-update -d -f "${tmp}/staged.bin" >/dev/null

# rpi-eeprom-update places pieeprom.upd + recovery.bin into /boot/firmware.
[ -f /boot/firmware/pieeprom.upd ] || die "rpi-eeprom-update did not stage /boot/firmware/pieeprom.upd"

printf 'staged %s (channel=%s, platform=bcm%s). reboot to apply.\n' \
    "$latest_file" "$channel" "$platform"
printf 'cancel with: sudo rpi-eeprom-update -r\n'

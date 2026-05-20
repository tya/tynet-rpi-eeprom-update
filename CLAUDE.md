# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single POSIX shell script (`packaging/tynet-rpi-eeprom-update.sh`) that
fetches the newest `pieeprom-*.bin` for this Pi's SoC from upstream
`raspberrypi/rpi-eeprom` on GitHub and stages it via `rpi-eeprom-update
-d -f`. Preserves the currently-running EEPROM config (BOOT_ORDER,
WAKE_ON_GPIO, ...) via `rpi-eeprom-config --config`.

It exists because Ubuntu's `rpi-eeprom` package lags upstream by months
and `rpi-update` is too blunt (no rollback, no version pinning).

## Common commands

```sh
make lint     # shellcheck packaging/tynet-rpi-eeprom-update.sh
make test     # lint + sh -n + --help smoke
make deb      # build arm64 .deb into dist/ (requires nfpm)
make clean
```

`make deb` derives `VERSION` from `git describe` (falling back to
`0.0.0~dev`); override for ad-hoc: `make deb VERSION=0.0.1`. Releases
happen via tag push: `git tag v0.1.0 && git push origin v0.1.0` triggers
`.github/workflows/release.yml`, which builds the `.deb`, publishes a
GitHub Release, and dispatches into `tya/tynet-apt`.

## Architecture and the broader system

One of the `tynet-*` apt packages. **Don't make changes here in isolation
when behavior is shared across them:**

- **tynet-rpi-eeprom-update** (this repo) — script-only Debian package.
- **`tya/tynet-apt`** — GH-Pages-served apt repo at
  `https://tya.github.io/tynet-apt`. Its `ingest.yml` runs on
  `repository_dispatch` (fired here on tag push), drops the `.deb` into
  the pool, regenerates signed apt indexes, pushes `gh-pages`.
- **`tya/tynet-cloud-init`** — sibling package, same release pattern; the
  Makefile / workflows / packaging layout here are derived from it.
- **`tya/tynet-infra`** — Ansible. Configures the apt source on managed
  nodes (`origin=tynet`, scoped `unattended-upgrades`).

**Release flow:** `git push origin v0.X.Y` → release workflow publishes
`.deb` and dispatches into `tya/tynet-apt` → ingest regenerates the
GH-Pages apt repo (~30s) → on managed nodes, `apt-daily-upgrade.timer`
fires within ≤1h and picks up the new candidate. End-to-end ≤1 hour.

## Things worth knowing

- **POSIX `sh` only.** No bashisms. CI runs `shellcheck` and `sh -n`.
- **`rpi-eeprom` is a hard dep** — the script invokes `rpi-eeprom-update`
  and `rpi-eeprom-config` from that package. Declared in `nfpm.yaml`.
- **No automatic timer / cron unit shipped.** EEPROM flashing is too
  consequential for unattended schedules; the user (or Ansible) invokes
  the script when they're prepared to reboot. `--cron` is a quiet-mode
  flag for users who do want to wire it into their own cron, not a
  built-in trigger.
- **Reversible until reboot.** `rpi-eeprom-update -d -f` only writes the
  pending image to `/boot/firmware/pieeprom.upd` + `recovery.bin`. The
  EEPROM SPI flash is rewritten on next boot by `recovery.bin`. To cancel
  before that: `sudo rpi-eeprom-update -r`.
- **Image size sanity check.** The script refuses to flash any download
  that isn't exactly 524288 bytes (canonical Pi EEPROM size). If upstream
  ever changes that size this check needs updating.
- **Channel directory layout** is hardcoded to upstream's current shape
  (`firmware-{2711,2712}/{default,latest,beta}/`). If upstream
  reorganizes, the script's `dir=` and the file-name regex are the two
  places to update.
- **Date parsing** assumes ISO-8601 (`pieeprom-YYYY-MM-DD.bin`) which has
  held for years; lexical sort doubles as date sort.

## Packaging layout

`packaging/`:

- `nfpm.yaml` — package definition (arm64, contents, depends). `${VERSION}`
  is interpolated by nfpm from the env var the Makefile sets.
- `tynet-rpi-eeprom-update.sh` — the actual script. Ships at
  `/usr/bin/tynet-rpi-eeprom-update`.
- `copyright` — Debian copyright file.

No `postinst` / `prerm` / `postrm` — there's no service, user, or state
to manage. The package is a single executable + docs.

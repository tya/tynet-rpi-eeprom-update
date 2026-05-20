# tynet-rpi-eeprom-update

Tiny POSIX shell tool that fetches the newest `pieeprom-*.bin` from upstream
[`raspberrypi/rpi-eeprom`](https://github.com/raspberrypi/rpi-eeprom) on
GitHub and stages it via `rpi-eeprom-update -d -f`, preserving the
currently-running EEPROM's config (`BOOT_ORDER`, `WAKE_ON_GPIO`, etc.).

## Why

The `rpi-eeprom` package in Ubuntu lags upstream by months — the bundled
firmware in `/usr/lib/firmware/raspberrypi/bootloader-*/` is whatever
Canonical packaged at release time. Bypassing apt entirely with `rpi-update`
is risky (no rollback, no version pinning). This sits in between: pull only
the EEPROM `.bin` from upstream, leave kernel / firmware / userland alone.

## Usage

```sh
sudo tynet-rpi-eeprom-update                         # check + stage newest stable
sudo tynet-rpi-eeprom-update --dry-run               # show what would happen
sudo tynet-rpi-eeprom-update --channel latest        # use the "latest" upstream channel
sudo tynet-rpi-eeprom-update --cron                  # quiet; no output unless action/error
sudo tynet-rpi-eeprom-update --platform 2711         # override SoC detection
```

Reboot to apply the staged update. Cancel with `sudo rpi-eeprom-update -r`
before rebooting if you change your mind.

Auto-detects platform from `/proc/device-tree/compatible`:

| SoC      | Pi models                | Channel directory   |
|----------|--------------------------|---------------------|
| bcm2711  | Pi 4 / 400 / CM4         | `firmware-2711/...` |
| bcm2712  | Pi 5                     | `firmware-2712/...` |

## Build & test

```sh
make lint    # shellcheck the script
make test    # lint + POSIX syntax check + --help smoke
make deb     # build arm64 .deb into dist/ (requires nfpm)
make clean
```

`nfpm` is the only extra build dep:

```sh
brew install goreleaser/tap/nfpm
```

`make deb` derives `VERSION` from `git describe`; override for ad-hoc builds:
`make deb VERSION=0.0.1`.

## Releasing

Tag with semver and push:

```sh
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yml` runs on tag push, builds the arm64 `.deb`,
publishes it to a GitHub Release, and dispatches `new-release` into
[`tya/tynet-apt`](https://github.com/tya/tynet-apt). That repo's ingest
workflow drops the deb into its pool, regenerates the signed apt indexes,
and pushes `gh-pages` — served at `https://tya.github.io/tynet-apt`.

On a node with the tynet apt source configured, `apt update && apt install
tynet-rpi-eeprom-update` picks it up.

## Required secrets

- `APT_DISPATCH_TOKEN` — fine-grained PAT with `contents: write` on
  `tya/tynet-apt`, used by `release.yml` to fire the ingest dispatch.

## Related

- [`raspberrypi/rpi-eeprom`](https://github.com/raspberrypi/rpi-eeprom) — upstream EEPROM image source
- [`tya/tynet-apt`](https://github.com/tya/tynet-apt) — apt repo this package publishes into
- [`tya/tynet-cloud-init`](https://github.com/tya/tynet-cloud-init) — sibling package, same release pattern

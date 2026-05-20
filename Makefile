BINARY = tynet-rpi-eeprom-update
GIT_VERSION := $(shell git describe --tags --dirty 2>/dev/null | sed -e 's/^v//' -e 's/-/~/g')
VERSION ?= $(if $(GIT_VERSION),$(GIT_VERSION),0.0.0~dev)

.PHONY: help deb lint test clean

.DEFAULT_GOAL := help

help:
	@echo "Targets:"
	@echo "  deb     build arm64 .deb into dist/ (requires nfpm)"
	@echo "  lint    shellcheck the script"
	@echo "  test    lint + dry-run smoke (POSIX sh syntax check)"
	@echo "  clean   remove dist/"

deb:
	@command -v nfpm >/dev/null || { echo "install nfpm: https://nfpm.goreleaser.com/install/"; exit 1; }
	mkdir -p dist
	{ \
	  echo "$(BINARY) ($(VERSION)) stable; urgency=low"; \
	  echo ""; \
	  echo "  * See https://github.com/tya/tynet-rpi-eeprom-update/releases/tag/v$(VERSION) for details."; \
	  echo ""; \
	  echo " -- Ty Alexander <ty.alexander@gmail.com>  $$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"; \
	} | gzip -9 -n > dist/changelog.gz
	VERSION=$(VERSION) nfpm package -f packaging/nfpm.yaml -p deb -t dist/

lint:
	shellcheck packaging/tynet-rpi-eeprom-update.sh

test: lint
	sh -n packaging/tynet-rpi-eeprom-update.sh
	packaging/tynet-rpi-eeprom-update.sh --help >/dev/null

clean:
	rm -rf dist

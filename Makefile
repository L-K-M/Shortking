# Shortking
#
# `swift build` produces bare executables, but TCC identity is bundle- and
# signature-based: launched from .build/, AXIsProcessTrusted() reports on whatever
# launched the process rather than on Shortking. So the real target here is `app`,
# which assembles a genuine .app bundle with the probe helper inside it.

SHELL := /bin/bash

APP_NAME    := Shortking
HELPER_NAME := shortking-probe
BUNDLE_ID   := com.shortking.app
CONFIG      ?= release
BUILD_DIR   := .build/$(CONFIG)
APP_BUNDLE  := build/$(APP_NAME).app
CONTENTS    := $(APP_BUNDLE)/Contents

# Set these to sign and notarize. Without them, `make app` still produces a
# runnable (ad-hoc signed) bundle for local use.
SIGN_IDENTITY ?=
TEAM_ID       ?=
KEYCHAIN_PROFILE ?= shortking-notary

.PHONY: all build app run test lint clean sign notarize dmg help

all: app

help:
	@echo "make build     — compile with SwiftPM"
	@echo "make app       — assemble $(APP_BUNDLE) (this is what you want)"
	@echo "make run       — assemble and launch the app bundle"
	@echo "make test      — run the unit tests"
	@echo "make sign      — codesign with hardened runtime (needs SIGN_IDENTITY)"
	@echo "make notarize  — submit and staple (needs KEYCHAIN_PROFILE)"
	@echo "make dmg       — build a distributable disk image"
	@echo "make clean     — remove build products"

build:
	swift build -c $(CONFIG)

test:
	swift test

# The app bundle. The probe helper goes in Contents/MacOS alongside the app binary
# so Bundle.main.url(forAuxiliaryExecutable:) finds it.
# SwiftPM has named executables after the product in some toolchain versions and
# after the target in others, so both are accepted rather than pinning a guess.
app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@if [ -f "$(BUILD_DIR)/$(APP_NAME)" ]; then \
		cp "$(BUILD_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"; \
	elif [ -f "$(BUILD_DIR)/ShortkingApp" ]; then \
		cp "$(BUILD_DIR)/ShortkingApp" "$(CONTENTS)/MacOS/$(APP_NAME)"; \
	else \
		echo "error: could not find the app binary in $(BUILD_DIR)"; exit 1; \
	fi
	@if [ -f "$(BUILD_DIR)/$(HELPER_NAME)" ]; then \
		cp "$(BUILD_DIR)/$(HELPER_NAME)" "$(CONTENTS)/MacOS/$(HELPER_NAME)"; \
	elif [ -f "$(BUILD_DIR)/ShortkingProbe" ]; then \
		cp "$(BUILD_DIR)/ShortkingProbe" "$(CONTENTS)/MacOS/$(HELPER_NAME)"; \
	else \
		echo "error: could not find the probe helper in $(BUILD_DIR)"; exit 1; \
	fi
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	@if [ -d "$(BUILD_DIR)/$(APP_NAME)_$(APP_NAME).bundle" ]; then \
		cp -R "$(BUILD_DIR)/$(APP_NAME)_$(APP_NAME).bundle" "$(CONTENTS)/Resources/"; \
	fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@$(MAKE) --no-print-directory sign
	@echo "Built $(APP_BUNDLE)"

run: app
	@open "$(APP_BUNDLE)"

# Signing. With no SIGN_IDENTITY we ad-hoc sign, which is enough to run locally but
# NOT enough to trust a permission check: an ad-hoc signature's cdhash changes on
# every build, so TCC grants lapse each time. Use a real identity before running the
# verification experiments.
sign:
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		echo "Signing with $(SIGN_IDENTITY)"; \
		codesign --force --options runtime --timestamp \
			--entitlements Resources/Shortking.entitlements \
			--sign "$(SIGN_IDENTITY)" "$(CONTENTS)/MacOS/$(HELPER_NAME)"; \
		codesign --force --options runtime --timestamp \
			--entitlements Resources/Shortking.entitlements \
			--sign "$(SIGN_IDENTITY)" "$(APP_BUNDLE)"; \
		codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"; \
	else \
		echo "No SIGN_IDENTITY set — ad-hoc signing (permission grants will lapse on rebuild)"; \
		codesign --force --sign - "$(CONTENTS)/MacOS/$(HELPER_NAME)"; \
		codesign --force --sign - "$(APP_BUNDLE)"; \
	fi

notarize: dmg
	@if [ -z "$(KEYCHAIN_PROFILE)" ]; then \
		echo "Set KEYCHAIN_PROFILE (see: xcrun notarytool store-credentials)"; exit 1; \
	fi
	xcrun notarytool submit "build/$(APP_NAME).dmg" \
		--keychain-profile "$(KEYCHAIN_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUNDLE)"
	xcrun stapler staple "build/$(APP_NAME).dmg"

dmg: app
	@rm -f "build/$(APP_NAME).dmg"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(APP_BUNDLE)" \
		-ov -format UDZO "build/$(APP_NAME).dmg"

clean:
	swift package clean
	rm -rf build

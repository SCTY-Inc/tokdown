# Agent-friendly Makefile for TokDown iOS
# Wraps XcodeGen + xcodebuild + devicectl with pipefail + xcbeautify.
#
# THE LOAD-BEARING LINE: `set -o pipefail; xcodebuild ... | xcbeautify`
# Without pipefail, xcodebuild can fail and the pipe still returns 0 —
# that's how agents end up "saying everything is green when it's broken."
#
# Usage (from repo root): make -f scripts/Makefile <target>
# Or: cd scripts && make <target>

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# ─── CONFIGURE ────────────────────────────────────────────────────────────────

PROJECT     := TokDown.xcodeproj
SCHEME      := TokDown
BUNDLE_ID   := com.amadad.tokdown
CONFIG      := Debug
DERIVED     := .build/DerivedData

# Simulator name for `make test`. Override on command line:
#   make -f scripts/Makefile test SIMULATOR="iPhone 17 Pro"
SIMULATOR   ?= iPhone 17

# Physical device UDID for devicectl install/launch. Override on command line:
#   make -f scripts/Makefile install DEVICE_UDID=00008120-000XXXXXXXXXXXX
DEVICE_UDID ?=

# Signing team is externalized in project.yml. Pass it when building for a device:
#   make -f scripts/Makefile build DEVELOPMENT_TEAM=683DJ66L4U
DEVELOPMENT_TEAM ?=

# Resolve repo root (parent of this Makefile's directory)
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

# Built .app path after a successful `make build`
APP_PATH = $(REPO_ROOT)/$(DERIVED)/Build/Products/$(CONFIG)-iphoneos/$(SCHEME).app

# xcbeautify if available, cat as graceful fallback — pipefail still catches failures
XCB := $(shell command -v xcbeautify >/dev/null 2>&1 && echo "xcbeautify --disable-logging" || echo "cat")
XCODEBUILD_OVERRIDES := $(if $(strip $(DEVELOPMENT_TEAM)),DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM),)

# ─── TARGETS ──────────────────────────────────────────────────────────────────

.PHONY: all doctor generate build test clean install launch logs

all: build

## doctor — verify toolchain is ready
doctor:
	@command -v xcbeautify >/dev/null || { echo "brew install xcbeautify"; exit 1; }
	@command -v xcodegen   >/dev/null || { echo "brew install xcodegen"; exit 1; }
	@command -v xcodebuild >/dev/null || { echo "install Xcode command line tools"; exit 1; }
	@test -f $(REPO_ROOT)/project.yml || { echo "project.yml not found at $(REPO_ROOT)"; exit 1; }
	@echo "OK — SCHEME=$(SCHEME) BUNDLE_ID=$(BUNDLE_ID)"

## generate — regenerate TokDown.xcodeproj from project.yml (required after adding files)
generate:
	@cd $(REPO_ROOT) && xcodegen generate

## build — compile for generic iOS device (matches CLAUDE.md build command)
build:
	@cd $(REPO_ROOT) && set -o pipefail; xcodebuild \
	  -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -destination 'generic/platform=iOS' \
	  -derivedDataPath $(DERIVED) \
	  -configuration $(CONFIG) \
	  $(XCODEBUILD_OVERRIDES) \
	  build | $(XCB)

## test — run unit tests on simulator (override with SIMULATOR="iPhone 17 Pro")
test:
	@cd $(REPO_ROOT) && set -o pipefail; xcodebuild \
	  -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
	  CODE_SIGNING_ALLOWED=NO \
	  test | $(XCB)

## clean — nuke derived data and clean build outputs
clean:
	@cd $(REPO_ROOT) && rm -rf $(DERIVED)
	@cd $(REPO_ROOT) && set -o pipefail; xcodebuild \
	  -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  clean | $(XCB)

## install — devicectl install the built .app (requires DEVICE_UDID=...)
install:
	@test -n "$(DEVICE_UDID)" || { echo "DEVICE_UDID is required — pass DEVICE_UDID=<udid>"; exit 1; }
	@test -d "$(APP_PATH)" || { echo "App not built at $(APP_PATH) — run 'make build' first"; exit 1; }
	@xcrun devicectl device install app --device $(DEVICE_UDID) "$(APP_PATH)"

## launch — devicectl launch the installed app (requires DEVICE_UDID=...)
launch:
	@test -n "$(DEVICE_UDID)" || { echo "DEVICE_UDID is required — pass DEVICE_UDID=<udid>"; exit 1; }
	@xcrun devicectl device process launch --device $(DEVICE_UDID) $(BUNDLE_ID)

## logs — stream device console for this bundle (requires DEVICE_UDID=...)
logs:
	@test -n "$(DEVICE_UDID)" || { echo "DEVICE_UDID is required — pass DEVICE_UDID=<udid>"; exit 1; }
	@xcrun devicectl device process launch --console --device $(DEVICE_UDID) $(BUNDLE_ID)

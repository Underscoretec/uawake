PACKAGES := Packages/UAwakeCore Packages/UAwakeSystem Packages/UAwakeIPC
BUILD := build.noindex
DERIVED := $(BUILD)/DerivedData
XCODEBUILD := xcodebuild -project uawake.xcodeproj -scheme uawake -destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath $(DERIVED) -quiet

.PHONY: generate build probe test uitest screenshots strings release lint format clean clean-apps

generate:
	xcodegen generate --quiet

build: generate
	$(XCODEBUILD) build

# Sandbox spike tool (docs/SANDBOX-SPIKE.md). Not shipped.
probe: generate
	xcodebuild -project uawake.xcodeproj -scheme SandboxProbe -configuration Release -destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath $(DERIVED) -quiet build

test: generate
	@for p in $(PACKAGES); do (cd $$p && swift test -Xswiftc -warnings-as-errors) || exit 1; done
	$(XCODEBUILD) test

uitest: generate
	xcodebuild -project uawake.xcodeproj -scheme uawakeUITests -destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath $(DERIVED) -quiet test -skip-testing:uawakeUITests/ScreenshotTests; s=$$?; scripts/clean-apps.sh --unregister; exit $$s

# Design screenshots, light and dark, into docs/design/screenshots/.
screenshots: generate
	rm -rf $(BUILD)/screenshots.xcresult
	xcodebuild -project uawake.xcodeproj -scheme uawakeUITests -destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath $(DERIVED) -resultBundlePath $(BUILD)/screenshots.xcresult -quiet test -only-testing:uawakeUITests/ScreenshotTests; s=$$?; scripts/clean-apps.sh --unregister; exit $$s
	python3 -I scripts/export-screenshots.py $(BUILD)/screenshots.xcresult docs/design/screenshots

# Adds every string the compiler extracted from the app to Localizable.xcstrings
# (Xcode does this when building in the IDE; this does it for command-line builds).
strings: build
	python3 -I scripts/sync-strings.py $(DERIVED) App/Resources/Localizable.xcstrings

# Archive, export, DMG and zip in build.noindex/release/. Signing and notarization run only when a
# Developer ID identity, TEAM_ID and NOTARY_PROFILE exist; otherwise an unsigned stub (docs/RELEASING.md).
release: generate
	scripts/release.sh

lint:
	xcrun swift-format lint --strict --recursive --parallel App AppTests AppUITests Tools Packages/*/Sources Packages/*/Tests

format:
	xcrun swift-format format --in-place --recursive --parallel App AppTests AppUITests Tools Packages/*/Sources Packages/*/Tests

# Finds every uawake.app outside /Applications, unregisters it from Launch Services and deletes it
# (including build.noindex products), so uawake:// reaches only the installed copy.
clean-apps:
	scripts/clean-apps.sh

clean:
	scripts/clean-apps.sh
	rm -rf $(BUILD) build uawake.xcodeproj $(addsuffix /.build,$(PACKAGES))

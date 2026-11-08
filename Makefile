PACKAGES := Packages/UAwakeCore Packages/UAwakeSystem Packages/UAwakeIPC
DERIVED := build/DerivedData
XCODEBUILD := xcodebuild -project uawake.xcodeproj -scheme uawake -destination 'platform=macOS,arch=$(shell uname -m)' -derivedDataPath $(DERIVED) -quiet

.PHONY: generate build probe test lint format clean

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

lint:
	xcrun swift-format lint --strict --recursive --parallel App AppTests Tools Packages/*/Sources Packages/*/Tests

format:
	xcrun swift-format format --in-place --recursive --parallel App AppTests Tools Packages/*/Sources Packages/*/Tests

clean:
	rm -rf build uawake.xcodeproj $(addsuffix /.build,$(PACKAGES))

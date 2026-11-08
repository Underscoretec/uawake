# uawake

uawake — keep your Mac awake.

A free, open-source macOS menu bar app by Underscore Technology that keeps your Mac
awake on demand or automatically. MIT licensed.

**Status: pre-alpha.** Nothing is released yet. See [docs/SPEC.md](docs/SPEC.md) for the plan.

## Build

Requirements: macOS 14 or later, Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
make generate   # create uawake.xcodeproj from project.yml
make build      # build the app
make test       # package tests, then app tests
make lint       # swift-format
```

The built app is in `build/DerivedData/Build/Products/Debug/uawake.app`.

## Licence

MIT. See [LICENSE](LICENSE).

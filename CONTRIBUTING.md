# Contributing to uawake

Thanks for your interest. uawake is in its first alpha; contributions open with the public release.

## Before you start
- Read [CLAUDE.md](CLAUDE.md) (project guide), [docs/SPEC.md](docs/SPEC.md) and
  [docs/CONTRACTS.md](docs/CONTRACTS.md).
- uawake is a clean implementation. Do not copy code or assets from KeepingYouAwake or any other
  keep-awake app.
- Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md) (Contributor Covenant 2.1).

## AI-assisted contributions
AI-assisted contributions are welcome when:
- the pull request says which parts were AI-assisted and with which tool, and
- a human contributor has reviewed and understands every change, and answers review questions about it.

## Workflow
1. Open an issue for anything beyond a small fix, so the approach can be agreed first.
2. Branch from `main`, keep changes focused, and add or update tests.
3. Run `make test`, `make uitest` and `make lint` before opening a pull request.
4. Every user-facing string goes through `App/Resources/Localizable.xcstrings` (`make strings`).

## Translations
Translations open after 1.0, through Weblate. Until then, please don't open translation pull requests.

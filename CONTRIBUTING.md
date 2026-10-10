# Contributing to Snapmark

Thanks for helping. Snapmark stays small on purpose: fast capture, the annotations people actually
use, and nothing that phones home.

## Before you start

- **Bugs:** open an issue with your macOS version, what you did, what you expected and what happened.
- **Features:** open an issue first for anything bigger than a fix, so we can agree on the shape
  before you spend time on it.

## Working on the code

```sh
make test       # unit tests (no window needed)
make install    # build, sign and run your copy from ~/Applications
make selftest   # render every annotation onto Tests/Fixtures/sample.png
```

- Drawing, geometry and file handling belong in `Sources/SnapmarkCore`, covered by tests in
  `Tests/SnapmarkCoreTests`. The AppKit layer in `Sources/Snapmark` should stay thin.
- A bug fix comes with a test that fails without it.
- Match the surrounding style: short functions, comments that say why, no new dependencies.
- No network code, analytics or telemetry, ever.

## Pull requests

Keep each PR to one change, describe how you tested it, and make sure `swift test` and CI pass.

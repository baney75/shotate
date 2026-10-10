# Contributing to Snapmark

Thanks for helping. Snapmark stays small on purpose: fast capture, the annotations people actually
use, and nothing that phones home.

## Before you start

- **Bugs:** open an issue with your macOS version, what you did, what you expected and what happened.
- **Features:** open an issue first for anything bigger than a fix, so we can agree on the shape
  before you spend time on it.

## Working on the code

```sh
cd macos && make test   # macOS unit tests (no window needed)
make install            # build, sign and run your macOS copy
make selftest           # render every annotation onto a sample image
cd ../desktop && npm ci && npm test   # Windows/Linux editor tests
cargo test --manifest-path src-tauri/Cargo.toml
```

- On macOS, drawing, geometry and file handling belong in `macos/Sources/SnapmarkCore`, covered by
  tests in `macos/Tests/SnapmarkCoreTests`; the AppKit layer stays thin. On Windows and Linux the
  same model lives in `desktop/src/core`, with tests beside it, and Rust (`desktop/src-tauri`) owns
  capture, files, the clipboard, shortcuts and the config file.
- A behavior change lands on both apps, or the PR says why it is platform-specific.
- A bug fix comes with a test that fails without it.
- Match the surrounding style: short functions, comments that say why, no new dependencies.
- No network code, analytics or telemetry, ever.

## Pull requests

Keep each PR to one change, describe how you tested it, and make sure `swift test` and CI pass.

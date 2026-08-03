# Contributing

Thanks for helping improve Headphone EQ.

## Development setup

You need:

- macOS 14.2 or newer
- Swift 6 / Xcode 16 or newer for source builds
- A recent Xcode with Icon Composer support for a complete `.app` build
- a stereo output device to exercise the live audio path

Build and test the source:

```sh
swift test
swift build -c release
```

Build the complete application bundle:

```sh
make app
```

## Pull requests

Keep changes focused and explain how you tested them. For audio-path changes,
include the output device, sample rate, and macOS version used for testing.
Never commit credentials, signing certificates, provisioning profiles, imported
third-party profiles, or captured audio.

By contributing, you agree that your contribution is licensed under the
project's MIT License.

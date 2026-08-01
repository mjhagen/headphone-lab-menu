# Headphone Lab Menu

A tiny, native macOS menu-bar host for beyerdynamic's Headphone Lab Audio Unit.
It routes system playback through the plug-in without requiring BlackHole,
Audio Hijack, a DAW, or a permanent virtual audio driver.

> [!IMPORTANT]
> This is an unofficial, independent project. It is not affiliated with,
> endorsed by, or distributed by beyerdynamic. Headphone Lab is proprietary
> software and is not included.

## How it works

The app creates a private Core Audio process tap for the current output device,
mutes the original stream while the tap is being read, moves stereo samples
through a small lock-free ring buffer, processes them with the Headphone Lab
Audio Unit, and plays the result through the selected output.

Everything happens locally. The app has no networking, analytics, or telemetry.

## Download

Download the latest pre-built app from
[GitHub Releases](https://github.com/mjhagen/headphone-lab-menu/releases/latest),
unzip it, and move **Headphone Lab Menu.app** to `/Applications`.

Release builds are signed with a Developer ID and notarized by Apple. Headphone
Lab itself is proprietary and must be installed separately.

## Requirements

- macOS 14.2 or newer
- [beyerdynamic Headphone Lab](https://beyerdynamic.com/headphone-lab-software-bddownload)
  with its Audio Unit installed at:
  `/Library/Audio/Plug-Ins/Components/Headphone Lab.component`

The first launch requests **System Audio Recording** permission. This permission
allows the Core Audio tap to receive playback; it does not use the microphone.

## Build

Install Xcode, then run:

```sh
make app
```

The built application is written to:

```text
build/Headphone Lab Menu.app
```

Launch it directly with `make run`, or install it in `/Applications` with:

```sh
make install
```

Local builds are ad-hoc signed. Maintainers can create a hardened-runtime,
Developer ID-signed and notarized archive using a `notarytool` Keychain
profile:

```sh
xcrun notarytool store-credentials "headphone-lab-menu"
make notarize VERSION=1.0.0 \
  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

The notarized ZIP and SHA-256 checksum are written to `build/`.

The full app build uses Xcode's asset compiler for
`Resources/AppIcon.icon`. A source-only build can be performed with
`swift build`.

## Usage

Use the headphones icon in the menu bar to:

- enable or disable Headphone Lab processing;
- open Headphone Lab's native configuration editor; or
- quit the app.

Closing the configuration editor releases its graphics resources while leaving
processing active. Headphone Lab settings are restored when the editor or app
is opened again.

## Known limitations

- Only stereo system playback is supported.
- After changing the macOS output device, disable and re-enable processing so
  the route follows the new device.
- The app hosts the Audio Unit v2 format. The VST3 installation is not used.
- Live audio integration cannot run without the separately installed plug-in.

## Troubleshooting

If playback is silent:

1. Confirm Headphone Lab is installed and validates in Audio MIDI Setup or
   another Audio Unit host.
2. In **System Settings → Privacy & Security → Screen & System Audio Recording**,
   enable access for Headphone Lab Menu.
3. Select the intended output device in macOS.
4. Disable and re-enable processing from the menu-bar icon.

## Development

```sh
swift test
swift build -c release
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines and
[SECURITY.md](SECURITY.md) for private vulnerability reporting.

## License and trademarks

The source code and original project artwork are available under the
[MIT License](LICENSE).

“beyerdynamic” and “Headphone Lab” are trademarks or product names of their
respective owner. Their use here is solely to identify compatibility.

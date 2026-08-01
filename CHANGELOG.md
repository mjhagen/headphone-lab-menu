# Changelog

All notable changes to this project will be documented here.

## 1.0.1 - 2026-08-01

- Release the Headphone Lab editor when it closes so its hidden Metal render
  loop cannot continue consuming GPU resources.

## 1.0.0 - 2026-07-30

- Initial open-source release.
- Route stereo system playback through the Headphone Lab Audio Unit.
- Add a menu-bar enable/disable control and embedded plug-in editor.
- Persist Audio Unit state between launches.
- Avoid permanent virtual audio drivers by using Core Audio process taps.
- Add an Icon Composer app icon.
- Sign and notarize the downloadable app with an Apple Developer ID.

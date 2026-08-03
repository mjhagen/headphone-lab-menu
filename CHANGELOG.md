# Changelog

All notable changes to this project will be documented here.

## 2.0.1 - 2026-08-03

- Tighten the output-trim label and value around the visible knob while keeping
  its larger interaction area.
- Add a prominent Settings screenshot to the README.

## 2.0.0 - 2026-08-03

- Replace the proprietary beyerdynamic Headphone Lab host with a native,
  system-wide parametric equalizer.
- Import common Equalizer APO and AutoEq text profiles.
- Search AutoEq's public headphone catalog and download a selected parametric
  profile from a compact native window, with a one-week local index cache.
- Preview catalog profiles live on row selection; committing keeps the profile,
  while cancelling restores the previously active EQ without restarting audio.
- Overlay each selected response on a 16,384-sample post-EQ spectrum, with
  display-native path interpolation up to 120 Hz, clipping warnings, and a
  persistent 0 to -24 dB output-trim knob. All animation stops when Settings
  closes.
- Identify and highlight the saved profile as soon as Settings opens.
- Reset output trim to 0 dB by double-clicking its knob.
- Add an optional Peak Limiter using Apple's native limiter with its minimum
  1 ms look-ahead and a -0.3 dB sample-peak safety margin. Enabling it resets
  output trim to 0 dB and locks the trim control.
- Consolidate enablement, limiting, local profile files, and AutoEq selection in
  one Settings window. Simplify the menu bar to current status, Settings, and
  Quit.
- Remove the third-party plug-in and editor, its runaway hidden Metal renderer,
  and the library-validation exception.
- Rename the user-facing application to Headphone EQ.

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

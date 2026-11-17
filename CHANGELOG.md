# Changelog

All notable changes to this project will be documented here.

## 3.0.0 - 2026-11-17

- Refine the native macOS menu with clear headphone-processing status, consistent
  audio labels and SF Symbols, profile and device subtitles, direct processing and
  limiter toggles, an Audio Output shortcut, and contextual DAC identification.

- Detect the selected headphone output and automatically stop EQ and soundstage on
  other outputs, resuming when headphones return without changing the saved enable
  preference. Follow output and source changes, pin playback to the captured device,
  show the waiting state, and remember manual headphone identification for USB DACs.

- Make cabinet directivity visible in the moving wavefronts. Full view separates
  faint thin bass wrap from brighter forward mid/treble arcs; energy-based angular
  contrast hides weak rear treble, and each layer follows its own room decay.
  Band views retain the existing source filter and physical travel radius.

- Keep Optimal Placement enabled as a persistent illuminated toggle. Room changes
  recalculate speaker positions automatically; manual angle/distance edits turn
  it off. Preserve older saved rooms and the mode through room resets.

- Add an Optimal Placement button below the speaker controls. It sets a symmetric
  equilateral stereo triangle using room width/depth, fits both rotated cabinets
  with 0.5 m wall clearance, and updates the persisted angle/distance live.

- Add generic enclosed-speaker directivity to the soundstage audio and display.
  Toed-in cabinet glyphs show the front baffle; bass wraps broadly while off-axis
  mids and treble are attenuated in each early-reflection filter. The late field
  uses a diffuse source-power approximation. Direct on-axis HRTFs stay unchanged.

- Clarify live soundstage propagation with fewer wavefronts, direct-arrival
  retirement, dimmer reflections and spectrum-weighted fading from the audio
  renderer’s shared room-decay model. Show band-specific RT60 and identify
  the propagation model in the display legend.

- Drive the room visualization from live stereo energy and frequency content,
  with actual processed ear waveforms and output-level history. First-order
  propagation includes floor and ceiling timing; display controls, freeze,
  silence handling, and Reduce Motion leave playback unchanged. Monitoring uses
  an independent bounded queue and is disabled when the display is closed.

- Add a skeuomorphic studio interface with generated brushed-metal panels and
  machined knobs, illuminated room and value displays, tactile active/bypass
  controls, and accessible mouse, scroll, and keyboard operation. The equalizer
  window shares the panel material and output-trim dial.

- Add an optional custom binaural soundstage with two virtual loudspeakers,
  three licensed SADIE II HRTFs, directional early reflections, and subtle late
  reverberation. Room dimensions, treatment, presence, and speaker placement
  persist and crossfade live before headphone EQ and the limiter.
- Add a soundstage configuration window with a live room diagram, accessible
  from the menu bar and equalizer window.
- Fix local ad-hoc builds failing to load Sparkle under hardened-runtime library
  validation; Developer ID builds retain hardened runtime.

## 2.1.1 - 2026-08-12

- Rename **Settings…** to **Configure Equalizer…** to better describe the
  window's operational controls.

## 2.1.0 - 2026-08-12

- Add automatic signed updates and a **Check for Updates…** menu item using
  Sparkle 2.

## 2.0.2 - 2026-08-12

- Add a checked **Run at Startup** menu item backed by macOS Login Items.
- Keep the menu state synchronized with changes made in System Settings and
  guide the user there when macOS requires manual approval.

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

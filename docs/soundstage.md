# Soundstage renderer

Soundstage presents stereo system audio as two virtual loudspeakers over
headphones. Open **Soundstage…** from the menu bar or the equalizer configuration
window. It is off by default. Settings are saved independently of the headphone
EQ profile and apply live without restarting the Core Audio route.

Choose one of three measured SADIE II HRTFs (KU100, KEMAR, or listener H10).
Choose by listening: no generic profile is universally correct for every ear.
The app loads all spatial data locally and does not upload audio or measurements.
Head tracking and personal SOFA import are not part of this implementation.

## Interface

The rack-style soundstage panel uses generated brushed-metal and machined-knob
artwork. The room screen, ticks, pointers, labels, and numeric readouts are drawn
at the current display resolution. Knobs retain native slider accessibility
semantics and support vertical dragging, horizontal fine movement, scrolling,
arrow keys, Shift for fine adjustment, and double-click to reset an individual
parameter. **Reset Room** restores the room defaults while preserving the
current enabled state and automatic-placement mode. The active/bypass button controls the existing renderer.

The equalizer window shares the rack surface and output-trim dial. UI rendering
runs on the main thread; audio rendering remains on the audio callback with
room-filter preparation on the control queue. Asset files and exact generation prompts are under
`Sources/HeadphoneLabMenu/Resources/StudioSkin/`; `generation.json` records the
built-in image-generation workflow. Assets are bundled locally with the app.

## Live acoustic visualization

The room display reacts to the actual stereo stream consumed by the soundstage
renderer. It samples source-channel RMS and bandpass energy centered at 125 Hz,
1 kHz, and 4 kHz. The default **Full** view follows broadband RMS; band selection
isolates that analysis band. L / L+R / R selects displayed source channels and
does not mute audio. Opposite-polarity stereo retains its independent channel
energy; the display never folds the source to mono.

Measured activity emits bounded visual energy packets; transient rises can emit
additional packets, with at least 200 ms between packets per channel (400 ms
for steady activity). Silence below the fixed −72 dBFS display threshold creates
none. Source markers follow live energy, and the listener marker follows actual
processed output. The packets travel through the existing first-order image
sources at 1/40 of sound speed so propagation remains visible. Floor and ceiling
fronts use spherical cross-sections at ear height, including vertical travel.
Distance, room dimensions, presence, and the renderer's reflection filter set
path geometry and gain. Full view uses separate bass, midrange, and treble layers weighted by
measured source-band RMS share. Opacity uses perceptual contrast for visibility; this is an
energy-flow illustration, not a sample-accurate pressure/interference simulation.

Solid direct fronts fade out smoothly over 5 ms of acoustic time after reaching
the listener, keeping attention on fresh arrivals. Dashed wall returns and dotted
floor/ceiling returns are dimmer and fade with the low/mid/high RT60 values shared
with the audio renderer. Higher treatment increases absorption; room dimensions
set decay through the volume-to-surface ratio. Each layer in Full view uses its own band decay, so a longer bass tail
does not prolong the forward treble arcs. The RT60 fade illustrates
energy dissipation; it is not an additional filter on the first-order audio paths
or a rendering of the late FDN as individual rays. Direct-front retirement is
a display aid, not physical absorption at the listener.

L/R cabinet glyphs show generic enclosed monitors aimed at the listener. Their
front baffles pass through the source positions; the boxes extend behind them.
Glyphs have a minimum display size for legibility and are not to scale in large
rooms. Wavefront opacity varies with outgoing angle and frequency using the
same source filter as the audio. Bass remains broad; midrange and treble favor
the front. The Full view draws bass wrap as faint thin fronts, with stronger and
thicker forward mid/treble arcs at the same travel radius. Per-band RMS shares
come from actual input; zero-energy bands produce no layer. This contrast makes
cabinet radiation visible without inventing different propagation speeds or
hard rear occlusion. The per-band views use a single, equally emphasized layer.
Opacity follows squared source-filter magnitude (energy), with a soft angular
display floor at 0.05 relative to on-axis power (about −13 dB). This display floor
hides weak rearward treble instead of outlining an almost complete circle;
it does not mute audio. Surface attenuation remains separate, and reflections
keep their dashed/dotted style. Image sources mirror the emission axes as well as positions, so each
reflected arc uses the correct source departure angle. The HRTFs independently
model reception at the listener.

The lower traces show the last 80 ms of the actual left and right soundstage
output **before headphone EQ**, including the active HRTF, early convolution,
and late FDN. Display-scale level is indicated, with a −34 dBFS minimum range to
avoid amplifying near-silence into a large waveform. The right-hand graph shows
three seconds of actual output RMS levels, with a fixed −72 to 0 dBFS axis.
The RT60 readout follows the selected bass/midrange/treble band (midrange for
Full); live music levels are not interpreted as a measured room decay. No synthetic test pulse is used
by the interface and no test sound is played.

A dedicated C monitor collects 10 ms packets of channel energy and 32 min/max
scope bins per ear. Its independent SPSC queue is bounded and drops display
packets on overflow rather than blocking audio. The UI discards packets more
than 200 ms behind the render clock and clears histories on route/generation
changes. Audio processing and monitoring use bounded stack/preallocated storage;
no allocation or locking is introduced in the source callback. Monitoring goes
through the original renderer directly when the display is closed or frozen.
No audio or display packets are saved or transmitted.

The display polls at 30 Hz while open, supports freeze/resume, and respects
Reduce Motion by retaining live meters and waveforms while suppressing moving
fronts. Closing or freezing disables the monitor; resume flushes stale data.
The separate equalizer spectrum has its own consumer and is unaffected.

## Controls

- **Optimal Placement:** a persistent on/off toggle. When lit, it maintains a
  symmetric 60° stereo triangle (±30°), with both cabinets aimed at the fixed listener. Listening distance starts from the smaller
  of 55% of room width and 40% of room depth, then fits inside the room with at
  least 0.5 m clearance around each rotated cabinet and the 3.5 m renderer limit.
  This is a geometric starting point, not a room-mode measurement or global
  acoustic optimum. Width/depth determine horizontal placement; height continues
  to affect reflections and decay. Only speaker angle/distance are calculated.
  Placement updates automatically as room dimensions change, and the mode persists across closing the window and
  restarting the app. Click to turn it off while keeping the current positions.
  Adjusting angle or distance switches to manual mode; other controls leave it on.
  The equilateral layout follows [standard stereo monitor guidance](https://www.genelec.com/monitor-placement);
  the room-scaling and clearance rules are choices for this renderer.
- **Speaker angle:** angle per speaker from straight ahead (15–60 degrees).
- **Listening distance:** 0.6–3.5 m, bounded to keep both speakers inside the room.
- **Width / depth / height:** 3–12 m / 3–16 m / 2.2–5 m.
- **Treatment:** moves a three-band surface model from relatively reflective to
  broadly absorptive. Low-frequency absorption remains lower than treble
  absorption; this is a perceptual room model, not a treatment-design calculator.
- **Room presence:** controls early reflection and late reverberation levels.
  Zero retains the binaural direct speakers; it does not bypass HRTF rendering.

The listener sits at the width center, 38% of the depth from the rear wall, at
an ear height of 1.2 m. Virtual speakers are at the same height. The diagram is a
top view; floor and ceiling reflections are also rendered.

## Signal path

`stereo tap → custom soundstage → headphone EQ / trim → peak limiter → safety trim → output`

Each input channel feeds two ear filters, giving a four-path convolution matrix.
The early field contains direct sound and the six first-order image sources
(walls, floor, ceiling) per speaker. Each image has its own direction, propagation
delay, distance attenuation, cabinet radiation filter, and frequency-dependent
reflection filter. Direct
level is held constant as distance changes, to allow comparison at a stable
listening level; the direct-to-reflected relationship still changes with distance.

The original 48 kHz, diffuse-field-equalized SADIE II filters are directionally
subsampled and zero-padded. Per-ear peaks are aligned before interpolation and
restored when constructing the room response, retaining measured interaural
arrival times. Four nearest measured directions are interpolated. Filter
resampling uses a windowed sinc with anti-alias filtering and gain correction.
No second HRTF is applied to an already binaural filter.

Surface energy absorption at low / middle / high frequencies is:

- Low: `0.10 + 0.30 × treatment`
- Mid: `0.15 + 0.65 × treatment`
- High: `0.22 + 0.65 × treatment`

Reflections use square roots of the unabsorbed energy as amplitude gains, with
complementary low/mid/high filter bands. The late field uses an eight-line,
normalized Hadamard feedback delay network with three allpass input diffusers
per channel. Odd, unequal delay lengths scale with room volume. Three-band loop
gains follow an Eyring decay estimate, bounded to keep the room effect subtle.
Separate orthogonal stereo excitation and output vectors retain side-only
content instead of losing it through a mono send. The late field is a diffuse
stereo approximation, not a full directional HRTF sound field or a wave solver.

Room size, treatment, and presence are independent. The model does not calculate
low-frequency room modes, detailed edge diffraction, arbitrary geometry, material-specific
resonances, or higher-order specular paths. It does not infer instrument positions
or height metadata from a stereo mix. Use ordinary stereo input and disable it
for already binaural recordings or when another spatializer is active.

## Generic speaker cabinet model

Each source represents a 0.22 m wide, 0.28 m deep enclosed monitor, with its front
axis aimed at the listener. This is our own smooth approximation of baffle
shadowing and driver beaming, not a measured loudspeaker, a branded waveguide,
or a solution of scattering from a rigid cuboid. In real enclosed speakers,
long-wavelength bass wraps around the box; shorter wavelengths become more
forward-directed. Background: [Linkwitz on baffle diffraction and the transition
from broad to forward radiation](https://www.linkwitzlab.com/diffraction.htm).

For source departure angle theta, let `u = (1 + cos(theta)) / 2`. Low/mid/high
asymptotic amplitude gains are `1`, `0.15 + 0.85u`, and `0.03 + 0.97u²`.
Complementary one-pole bands use a baffle transition `343 / (pi × width)`
(about 496 Hz) and a driver-beaming transition at 2.5 kHz. These are deliberate
generic model choices, not specifications or measurements of a real cabinet.
The transfer is unity on-axis and tends to unity at DC in every direction;
there is no hard rear mute. Off-axis filtering adds phase as well as attenuation.
The UI evaluates the magnitude response of those same causal filters at its
analysis frequencies, weighting full-band opacity by measured input-band energy.

For first-order paths, the source axis is mirrored about the relevant wall,
floor, or ceiling. It is compared with the ray leaving the image source toward
the listener, rather than incorrectly using the HRTF arrival angle as a speaker
angle. Filtering is baked into the four FIR paths on the control queue; the
additional filter tail is included in the convolution allocation. On-axis direct
filters and their measured HRTF delays are unchanged.

Late reverberation remains diffuse. Its stereo input passes through an independent
complementary-band filter with gains `1`, `sqrt(mean(g_mid²))`, and
`sqrt(mean(g_high²))`, averaged over the sphere. This reduces high-frequency
room excitation while preserving side-only input. It approximates radiated power
by band; it does not trace directional late paths or alter the room's decay times.
The filter uses two preallocated states per channel and no callback allocation.

## Real-time behavior

`HLMSpatialAudio.c` uses 128-sample partitions with preallocated complex vDSP FFTs
and overlap-add. The fixed buffering latency is 128 frames (2.67 ms at 48 kHz),
including soundstage bypass. Enabled rendering also includes modeled acoustic
flight time and the measured HRIR delay. Core Audio buffering and the optional
limiter contribute their existing latency separately.

Asset loading, interpolation, room-filter construction, resampling, allocation,
and FFT preparation occur before startup or on a serial control queue. The
callback only processes preallocated C state. An atomic mailbox publishes new
states; a 50 ms linear crossfade follows a one-block warmup. Old states are
reclaimed on the control queue or after rendering has stopped. Rapid control
changes are debounced by 120 ms. No locks, file access, Swift arrays, or memory
allocation/deallocation occur in the spatial audio callback.

The direct speaker matrix has a fixed 0.5 gain (6 dB headroom). This is not a
peak guarantee: HRTFs, summation, EQ boosts, and reflections may still produce
peaks above full scale. The existing peak limiter remains downstream.

## Data provenance and rebuilding

The modified measurement subsets retain University of York copyright and are
redistributed under Apache-2.0. The source project's code remains MIT-licensed.
The packaged HRTF directory includes the Apache license, attribution NOTICE,
source URLs, and SHA-256 digests. Original SOFA inputs are not committed.

To reproduce the bundled assets in a Python environment with numpy and h5py:

```sh
python3 Scripts/prepare_hrtf.py --cache /tmp/headphone-spatial-sadie
```

The script downloads only absent originals and rejects any input whose embedded
license does not identify Apache licensing. It uses D1, D2, and H10; older mirror
files for some other subjects still carry non-commercial terms.

## Verification

The spatial tests compare partitioned processing against direct convolution,
including cross-channel filters, long partitions, and irregular callback sizes.
They check bypass latency, measured lateral ear ordering, geometry, HRTF assets,
sample-rate gain and anti-alias behavior, stereo late excitation, decay,
parameter crossfades, non-finite input rejection, and rendering at 44.1, 48, 96,
and 192 kHz. Live-display tests check sample transparency in both buffer layouts,
frequency sensitivity, independent stereo energy, concurrent queue access,
stale-data rejection, silence, freeze/resume, and bounded histories. Subjective externalization still requires listening on headphones;
these tests do not establish perceptual transparency for every listener.

For a UI-only preview without starting another system audio tap:

```sh
open -n "build/Headphone EQ.app" --args --browse-soundstage
```

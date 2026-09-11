# audiodrift

**Windows tells you your audio device runs at 48000 Hz. It does not.**

That number is the *format* the audio engine is configured for. The hardware is
clocked by a quartz crystal, and crystals are not exact. Your speakers might
really run at 48000.123 Hz and your microphone at 48000.119 Hz. Nothing in
Windows will ever show you that.

It matters the moment you record two devices at once. If your capture card and
your microphone sit on different crystals, they drift apart for the entire
length of the recording, and you spend the edit nudging one track sideways
wondering why the sync keeps going. `audiodrift` measures the real rate of
every endpoint and tells you which ones share a clock.

```
audiodrift 1.0.0  -  the sample rate your hardware actually runs at

  [1] Speakers (2- Realtek High Definition Audio(SST))
      render, default   nominal 48000 Hz, 2 ch, 32-bit IEEE float
      measured 48000.1234 Hz   +2.572 ppm  +/- 0.048 ppm
      that is 9.3 ms of drift per hour against the system clock
      via packet timestamps, 5997 packets over 60.0 s
      cross-check: IAudioClock polling gives 2.639 +/- 0.346 ppm, a difference of 0.067 ppm
      uncertainty: regression 0.006 ppm, batch scatter 0.048 ppm; the larger is reported

  [2] Microphone Array (2- Realtek High Definition Audio(SST))
      capture, default   nominal 48000 Hz, 2 ch, 32-bit IEEE float
      measured 48000.1239 Hz   +2.581 ppm  +/- 0.049 ppm
      that is 9.3 ms of drift per hour against the system clock
      via packet timestamps, 5996 packets over 60.0 s
      cross-check: IAudioClock polling gives 6.202 +/- 21.142 ppm, a difference of 3.622 ppm
      uncertainty: regression 0.005 ppm, batch scatter 0.049 ppm; the larger is reported

  CLOCK DOMAINS
    endpoints whose measured rates agree within 2.000 ppm share a crystal
    domain 1: [1] Speakers (2- Realtek ...)  +  [2] Microphone Array (2- Realtek ...)

  WILL THESE TWO DRIFT APART?

    pair         relative      apart per hour   verdict
    [1] vs [2]   -0.009 ppm    0.0 ms           same clock, locked
        at 24 fps, one frame out of sync after 53.7 days
        at 30 fps, one frame out of sync after 43.0 days
        at 60 fps, one frame out of sync after 21.5 days
```

That is a real run on the author's machine. Both endpoints sit on one Realtek
codec, so they share a crystal and will never drift apart - which is the
answer you want before you hit record. The `+/-` symbol is printed as a proper
glyph in the terminal; it is written out here so it survives every viewer.

---

## Why you would run this

- **Before a long stream or recording.** Two endpoints in the same clock
  domain will stay in sync forever. Two in different domains will not, and
  the tool tells you how long you have before it costs you a frame.
- **When your audio slowly slides out of sync** and you have already checked
  everything else. A 10 ppm mismatch is 36 ms per hour. That is a frame at
  30 fps every ten minutes, accumulating.
- **When choosing which mic to pair with which interface.** Devices on one
  physical codec share a crystal. Devices on separate boxes almost never do.
- **Because it is a number Windows measures and refuses to show you.** The
  audio engine knows the real position of every stream to the byte, and
  timestamps it against the performance counter. The information is right
  there. No UI surfaces it.

## Install

There is nothing to install. One file, no dependencies, no modules, no
downloads.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File audiodrift.ps1
```

Run it exactly like that. Most Windows machines block `.ps1` files by
default, and `-ExecutionPolicy Bypass` on the command line applies to that
one process only - **it changes no setting on your computer.** You do not
need to run `Set-ExecutionPolicy`, and you should not.

Windows PowerShell 5.1, which ships with Windows 10 and 11. No admin rights
needed.

## Usage

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File audiodrift.ps1 [options]

  -Seconds <n>     measurement duration, default 60 (see "Why 60 seconds")
  -Fps <list>      frame rates for the slip table, default 24,30,60
  -NoMic           do not open capture endpoints (no microphone indicator)
  -SkipMeasure     list endpoints and formats without measuring
  -Json            machine-readable output, nothing else on stdout
  -Quiet           one line per endpoint
  -Info            version and environment
  -FromJson <f>    re-render a saved -Json file as a human report
```

```powershell
# the normal run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File audiodrift.ps1

# quick look at what is connected, no measuring, no mic light
powershell.exe -NoProfile -ExecutionPolicy Bypass -File audiodrift.ps1 -SkipMeasure -NoMic

# five minutes for the tightest possible numbers, film frame rates
powershell.exe -NoProfile -ExecutionPolicy Bypass -File audiodrift.ps1 -Seconds 300 -Fps 23.976,29.97

# save and re-read later
powershell.exe -NoProfile -ExecutionPolicy Bypass -File audiodrift.ps1 -Json > drift.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File audiodrift.ps1 -FromJson drift.json
```

**About the microphone indicator.** To time a capture device the tool has to
open a capture stream, so Windows lights the microphone indicator - exactly
as it should. Nothing is recorded, decoded or written; the audio samples are
discarded and only the timestamps are kept. Use `-NoMic` to skip capture
endpoints entirely.

`-SkipMeasure` opens nothing at all. It reads each endpoint's format through
`GetMixFormat`, which never creates a stream, so the indicator stays dark
whether or not you also pass `-NoMic`. The suite asserts this against live
hardware rather than taking it on trust.

## How it works

Two clocks, one comparison.

The system performance counter (`QueryPerformanceCounter`) is the reference.
The audio device's own clock is the thing being measured. WASAPI hands you
both at once: every captured packet carries the device position **and** the
performance-counter instant it corresponds to.

Collect a few thousand of those pairs, fit a straight line through them, and
the slope is the ratio of the two clocks. A slope of 1.0000026 means the
audio hardware runs 2.6 parts per million fast.

Two independent techniques are used on every endpoint:

| technique | what it reads |
|---|---|
| packet timestamps | the device position stamped on each buffer by the driver |
| `IAudioClock` polling | the stream position queried directly, with its own QPC stamp |

**Neither one wins everywhere, so the tool does not assume.** It runs both and
reports whichever *demonstrates* the lower uncertainty on that run, showing
the other as a cross-check. On this machine's capture endpoint the packet
timestamps are around 100x tighter; on the render endpoint they are not.
Picking a favourite from theory would have printed a confidently wrong number
on half the hardware.

Render endpoints are measured through a loopback capture stream, with a
silent-but-real feed so the engine keeps the clock running.

### Why 60 seconds

Because a shorter run cannot measure a render endpoint honestly, and this was
not obvious until it was measured.

Windows' shared-mode **render** position oscillates by about +/- 9 ppm with a
period of roughly 30 to 40 seconds. Capture on the *same physical codec* is
steady to 0.2 ppm over the same interval. Eight consecutive sub-window rates
from one 60-second render run:

```
render   8.92  9.13  8.50  2.28  -7.61  -7.40  0.10  2.62   ppm
capture  2.34  2.53  2.48  2.49   2.76   2.81  2.60  2.77   ppm
```

Over a full period the render figure converges on capture's. Over 20 seconds
it lands wherever the oscillation happened to be, and reports a tight,
confident, wrong answer. So the default is 60 seconds, and the uncertainty is
estimated in a way that notices when this is happening (below).

Whether this oscillation is specific to this codec or general to the Windows
shared-mode render path is not something one machine can establish. If you run
this on other hardware, the sub-window rates are in the `-Json` output as
`WindowPpms`.

### The error bar is measured, not assumed

A regression's standard error assumes the residuals are independent. Audio
timestamps are not - the engine's scheduling wanders over seconds. On the run
above the regression error read 0.486 ppm while the true run-to-run scatter
was around 6 ppm.

So the series is split into 8 sub-windows, each fitted separately, and the
scatter of those rates gives a second, empirical error. **The larger of the two
is reported.** This is self-calibrating: when the wander is absent the two
agree, and when it appears the error bar grows on its own.

### What it will not do

The tool refuses to report a number it cannot stand behind, rather than
printing one anyway:

- format fields that disagree with each other
- an audio clock frequency that matches neither the byte rate nor the sample rate
- a reading beyond +/- 1000 ppm, which is not a crystal tolerance at all but a
  resampled or virtual endpoint
- an uncertainty above 5 ppm, which cannot decide the question the tool exists
  to answer

Each refusal says which one it was.

## Read-only

`audiodrift` opens its own audio streams and reads clocks. That is all.

It writes no registry value, changes no device setting, creates no file,
starts and stops no service, and ends no process. This is not a promise in a
README - it is checked on every test run, two ways:

1. **Structurally.** The source is scanned for every registry and
   state-changing call pattern - 15 of them, from `Set-ItemProperty` and
   `New-Item` through `RegSetValueEx`, `RegCreateKeyEx` and
   `Microsoft.Win32.Registry`. **0 hits across 1,525 lines of code.** The tool
   contains no registry API at all, not even a read. A registry change
   therefore *cannot* originate in it, whatever a before/after diff happens to
   show.
2. **Empirically.** All **972** values under `HKLM\...\MMDevices\Audio` are
   snapshotted before and after a full measurement and compared byte for byte.

Both checks carry a negative control proving they can actually fail: 15
registry APIs are planted into a copy of the source and all 15 must be found,
and a planted change must be caught in every key the comparison covers.

> The empirical half needed one honest correction. A machine is not quiet
> while you measure it. On this hardware, one value moved -
> `{5510c7ab-...},4` on a connected Bluetooth headset, a `VT_I4` that went from
> `-69` to `-85`: signal strength in dBm, rewritten by the Bluetooth radio.
>
> Waving that through with a hardcoded exception would make the check
> worthless. So the suite decides it with evidence instead. After the
> measurement it takes six more snapshots with **nothing running**, and any key
> that moves on its own is classified volatile - by observation, not by name.
> Anything that differs across the measurement but was *not* already classified
> gets a second chance: twelve more samples, tool stopped, watching only that
> key. Move on your own and you are volatile and get named and decoded in the
> output; hold still and you are a failure.
>
> The result on this machine: **971 of 972 values compared exactly, 0
> mismatches**, 1 excluded with its reason printed. The exclusion is narrow by
> assertion - the suite requires that at least all-but-ten values stay in the
> exact comparison, so the classifier cannot quietly excuse its way to a pass -
> and a planted change in **every one** of the 971 static keys must still be
> caught.

> One subtlety the source scan had to learn: `IPropertyStore::SetValue` appears
> in the source as a COM interface signature. It is never called - but a COM
> interface must declare every method in order, because declaration order *is*
> the vtable layout, and omitting it would silently move `GetValue` into the
> wrong slot. A naive grep flags it. The scan separates declarations from call
> sites and proves the identifier is never invoked.

## How it was verified

Three suites. Every one runs on demand from the repo.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File selftest.ps1    # arithmetic, synthetic
powershell.exe -NoProfile -ExecutionPolicy Bypass -File realcheck.ps1   # real system data
powershell.exe -NoProfile -ExecutionPolicy Bypass -File mutate.ps1      # can the tests fail?
```

### selftest.ps1 - 254 assertions, 0 failures

Ground truth planted in synthetic series: seven different drift rates
recovered exactly, a deliberate +/-20 ppm oscillation the batch means must
expose and the whole-series fit must hide, every refusal path, a full report
built with **a different distinctive value in every field** so a tool that
transposes two fields cannot pass, and a JSON round trip.

### realcheck.ps1 - 97-98 assertions, 0 failures

The tool's COM view of the machine, checked against independent references
written with a completely different technique.

The assertion count is not fixed on purpose. Two checks compare the *two
measurement techniques* against each other, and on a run where one of them
happens to be too imprecise to decide anything, the suite prints `[skip]`
with the tolerance it would have needed instead of asserting it. A claim that
cannot be decided on this run is not a claim. Skips are reported in the
summary line so they can never be mistaken for passes.

| the tool reads | checked against |
|---|---|
| COM `IPropertyStore` / `GetMixFormat` | raw registry `REG_BINARY`, decoded by hand with offset arithmetic |
| COM `IMMDeviceEnumerator` | `Get-PnpDevice -Class AudioEndpoint` |
| `QueryPerformanceFrequency` | `[Diagnostics.Stopwatch]::Frequency` |
| "these share a crystal" | the device instance path Windows records for each endpoint |
| measured drift | drift planted *inside the real captured series* |
| the `-SkipMeasure` code path | the measure code path, field for field |

Real numbers from that run:

- **62 genuine `WAVEFORMATEX` blobs** parsed straight out of the live registry
  (supported formats, preferred formats, per-mode formats - far more than the
  two the tool uses), **434 real format fields** decoded by offset arithmetic,
  **0 inconsistencies**. Each blob's own length is predicted by its own
  `cbSize` field, which is what proves the offsets are right rather than
  lucky.
- **26 name fields** cross-checked against the registry, **0 mismatches**.
- **10 planted-drift recoveries across 5,996 genuine hardware timestamps**,
  recovered to within 0.0001 ppm while surrounded by real samples that must
  not leak into the answer. With both endpoints usable that is **20
  recoveries across ~11,990 real timestamps**.
- **24 static fields** compared between the enumerate and measure code paths,
  **0 mismatches**.
- **971 of 972 registry values** byte-identical before and after, the one
  exclusion classified volatile by observation and printed with its decoded
  value.

The strongest single check: Windows records the same device instance path
(`{1}.INTELAUDIO\FUNC_01&VEN_10EC&DEV_0274&...`) for both the speakers and the
microphone array. One physical codec means one crystal, which is an
independent confirmation of the tool's verdict from the hardware topology
rather than from another measurement.

### Negative controls on everything

A comparison that tolerates anything proves nothing, so every check above is
replayed against deliberately corrupted values and **every one must be
rejected**:

| control | score |
|---|---|
| corrupted real format blobs (block align off by one, byte rate off by one, rate doubled, channels doubled, bits halved, channels/bits transposed, byte rate read as block align, rate read as byte rate) | **496 / 496 killed** |
| length-corrupted blobs | **186 / 186 killed** |
| corrupted endpoint names (single character, reversed, another endpoint's) | **157 / 157 killed** |
| fabricated endpoint names, including a case-only mutation | **8 / 8 killed** |
| corrupted cross-path fields (suffix, upper case, lower case) | **32 / 32 killed** |
| planted registry APIs in a copy of the source | **15 / 15 found** |
| planted changes in every static registry value | **971 / 971 caught** |
| plausible wrong answers to the planted-drift check (planted value alone, real value alone, sign flipped, applied twice, zero) | **all killed** |

Five name mutations are reported as **UNDETECTABLE** and excluded from the
score rather than counted as passes: this machine has four endpoints described
"Headphones" and two "Microphone", and "Microphone" is a substring of
"Microphone Array". Substituting one for another produces a string that is
still legitimately present, so no containment test can tell them apart. Saying
"157 of 157" while quietly counting those as wins would be a lie.

Forty cross-path case mutations are excluded the same way and for the same
reason: a field like `48000` or `{0.0.0.00000000}.{...}` contains no cased
letters, so upper-casing it is a no-op and the control decides nothing. That
is settled *before* looking at the outcome, never after.

### mutate.ps1 - 41 of 41 mutations killed

Proving the tool is right is only half of it. These suites also have to be
capable of being *wrong*. `mutate.ps1` injects 43 specific bugs into a copy of
the tool - inverted comparisons, wrong divisors, dropped bounds, a slope that
divides the wrong way, an error bar that reports the smaller of two estimates -
and requires `selftest.ps1` to fail on every one.

```
mutation score      41 / 41
survivors           0
invalid controls    1 (dead anchors, counted separately)
equivalent mutants  1 (excluded from the score, proven)
```

Three things make that number honest:

- **Anchors are validated.** A mutation whose anchor text is not in the source
  changes nothing and would be silently reported as a kill. Every anchor must
  appear exactly once. One mutation is deliberately anchored on text that does
  not exist, and the harness must report it as an **invalid control** - which
  it does.
- **An assertion's anchor needs the same scrutiny.** A mutation that renamed
  the shared emitter to `EmitEndpointsRenamed` *survived*, because the guard
  asserting "exactly one emitter exists" searched for `static void
  EmitEndpoints` as a substring - which the renamed function still contains.
  A prefix match is not an identity check. The anchor now requires the opening
  parenthesis, and a second assertion rejects any near-miss name outright.
- **Equivalent mutants are proven, not assumed.** Removing the explicit
  `IsNaN` and `IsInfinity` guards from the plausibility check survives, because
  `[math]::Abs(NaN) -le 1000` is already false. The harness supports paired
  edits, removes both guards together, *demonstrates* the equivalence
  arithmetically, and excludes it from the score. The guards stay - they state
  the intent at the call site.
- **The first run found four real gaps.** The sub-window slicing was reachable
  but unasserted: rounding the window size up, dropping the last window's tail,
  relaxing the minimum sample count and using the population standard deviation
  all survived. Nine assertions were added pinning the partition exactly
  (101 samples across 4 windows must be 25/25/25/26) and the batch-means
  standard error against arithmetic done by hand. All four now die.

## Things this cost real time to learn

Kept here because every one of them is a plausible-looking bug that produces a
number rather than an error.

- **`AUDCLNT_BUFFERFLAGS_SILENT` corrupts loopback timing.** A render feeder
  that releases buffers with the silent flag lets the engine treat the endpoint
  as idle, and the loopback tap then emits filler packets whose timestamps
  wander. Writing zero-filled *real* samples instead cut the error by 3x and
  the sub-window spread by 5x.
- **A render stream's clock stops when its buffer drains**, producing a device
  elapsed time of exactly zero and a perfectly plausible **-1,000,000 ppm**.
  The feeder tops up every iteration.
- **The first `IAudioClock::GetPosition` after `Start()` returns position 0 and
  QPC 0.** Using it anchors the whole regression to the origin.
- **`WAVE_FORMAT_EXTENSIBLE` hides integer-vs-float in a GUID, not in
  `wFormatTag`.** The tag reads `0xFFFE` and the SubFormat GUID's first DWORD
  is 1 for PCM or 3 for float. Assuming float and writing float bit patterns
  into an integer stream is full-scale noise through the user's speakers.
- **The registry and COM disagree about the format, and both are right.**
  `PKEY_AudioEngine_DeviceFormat` is the *device* format - 16-bit PCM,
  192000 bytes/sec, what the Sound control panel shows. `GetMixFormat` is the
  *engine mix* format - 32-bit float, 384000 bytes/sec. Sample rate and channel
  count must match; bit depth, block align and byte rate legitimately differ.
  Cross-checking them as if they were the same field is a cry-wolf bug.
- **`blockAlign` and `nAvgBytesPerSec` depend only on the *product* of channels
  and bits**, so the classic WAVEFORMATEX redundancy check cannot detect a
  channels/bits transposition: 2ch/32-bit and 32ch/2-bit both give block align
  8 and 384000 bytes/sec. Each field needs an independent bound.
- **A 32-bit audio field must be carried as `[long]`.** A real format blob on
  this machine holds `4294967032` in the sample-rate slot, and `[int]` *throws*
  on any UInt32 above `Int32.MaxValue` - crashing the parser before the bounds
  check could reject the value.
- **A second code path that emits its own schema will rot silently.** The
  `-SkipMeasure` path used to emit `all.N.*` records while everything
  downstream parsed `ep.N.*`, so the mode printed a header and *zero
  endpoints* - a clean exit code, no error, no stack trace, and a documented
  flag that did nothing. Neither the synthetic suite nor the mutation harness
  could see it, because both exercised the measure path. It was caught by
  running every invocation the README literally shows against a fresh clone.
  The fix is structural, not a patch: one emitter, called by both paths, with
  an assertion that there is exactly one of it.
- **Activating an audio client on an inactive endpoint has a cost you pay
  later.** The verification suite briefly probed the format of all 13
  endpoints - including nine unplugged ones and a disconnected Bluetooth
  headset - immediately before measuring. Nothing failed at the time. What
  failed, intermittently and a minute later, was the *microphone opening for
  the measurement*: a run that should have seen two endpoints saw one, and
  three assertions that depend on having two went red. The tool now probes
  only `DEVICE_STATE_ACTIVE` endpoints and reports the rest by name and state
  without touching them. A test that perturbs the thing it is about to
  measure is not a test.
- **A registry value can move without anything writing it.** A read-only proof
  built on "nothing changed" failed, once, on a value that turned out to be
  `-69 -> -85` on a Bluetooth headset: signal strength in dBm, rewritten by the
  radio when the audio engine wakes. It is not free-running either - it sat
  still through 183 seconds of idle sampling while the headset was
  disconnected, so a quick volatility scan would have called it static and
  then failed anyway. Two things fixed it. The decisive claim is *structural*:
  the tool contains no registry API at all, so nothing it does can write one.
  The empirical claim is *earned*: any key that differs is re-watched with the
  tool stopped, and only a key that moves on its own is excused - named,
  decoded and printed, never silently tolerated.
- **In PowerShell, `,` binds tighter than `+`.** `@('p', 'q', 'r' + '!!')` is
  **four** elements - `('p','q','r') + '!!'` - not three. In a mutation harness
  this silently invented a control that tested nothing.
- **PowerShell's `-eq` on strings is case-insensitive**, so an upper-cased name
  compares *equal* to the original and a case mutation is an equivalent mutant
  by construction. Identity comparisons use
  `[String]::Equals(..., [StringComparison]::Ordinal)`.
- **Bluetooth renames its own interfaces.** The registry adapter name is
  `iClever-BTH12 Hands-Free` while the COM friendly name is
  `Headset (iClever-BTH12)`, because one headset exposes A2DP and Hands-Free as
  separate interfaces of the same device. Demanding verbatim containment
  reports a fault that does not exist.
- **`IAudioClock2` is not available on all hardware.** `GetService` fails on
  this Realtek codec. It can never be a required cross-check.
- **`IAudioClock`'s QPC out-parameter is in 100 ns units, not QPC ticks.** On a
  machine whose performance counter runs at exactly 10 MHz - as this one does -
  confusing the two divisors is a perfect no-op and completely invisible.

## Output

`-Json` emits a single object and nothing else, including on error paths.
Per endpoint: `NominalRate`, `TrueRate`, `Ppm`, `SePpm`, `SeOlsPpm`,
`SeEmpiricalPpm`, `Method`, `Samples`, `SpanSec`, `WindowPpms`, `MsPerHour`,
`ClockDomain`, plus both techniques' individual results and every gate's
verdict. Per pair: `RelativePpm`, `SameClock`, `Tolerance` and the frame-slip
table.

`-FromJson` re-renders a saved file, so you can measure on one machine and
read the report on another.

## Limitations

- It measures against the system performance counter, so it reports each
  endpoint's rate *relative to that*. The comparison between two endpoints is
  the reliable part; the absolute figure inherits the reference's own error.
- Bluetooth and virtual endpoints are usually resampled by software. Their
  "rate" is a driver's reconstruction, not a crystal, and the tool classifies
  readings beyond 1000 ppm as exactly that rather than reporting them.
- Endpoints that are not active cannot be measured. Plug it in and enable it
  first.
- The render oscillation described above is real on this hardware. Whether it
  generalises is unknown, and the README does not claim it does.

## See also

- [obs-4k60-recorder](https://github.com/appsmypass/obs-4k60-recorder) - OBS settings for 4K60 capture
- [miccheck](https://github.com/appsmypass/miccheck) - microphone level, noise floor and clipping
- [framecheck](https://github.com/appsmypass/framecheck) - dropped and duplicated frames in a recording

## License

MIT. See [LICENSE](LICENSE).

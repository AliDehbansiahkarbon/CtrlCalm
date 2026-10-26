# Audio engine

## Backend: XAudio2 2.9

Ctrl+Calm mixes with **XAudio2 2.9** (`xaudio2_9.dll`), a system component of Windows 10
and 11. Delphi ships no XAudio2 declarations, so `CtrlCalm.Audio.XAudio2` binds the
minimal subset, translated from the Windows SDK header `um\xaudio2.h` (10.0.26100.0):

- every structure is `packed` because the header uses `#pragma pack(push, 1)`
  (for example `XAUDIO2_BUFFER.pContext` sits at offset 36 on Win64, not 40);
- `IXAudio2` derives from `IUnknown` and is a Delphi interface;
- the voice interfaces and both callback interfaces do *not* derive from `IUnknown`, so they
  are bound as explicit vtable records with every method in header order and the object
  pointer as the first argument (`STDMETHOD` = `__stdcall`; on Win64 the single x64
  convention applies);
- the DLL is loaded with `LOAD_LIBRARY_SEARCH_SYSTEM32` and `XAudio2CreateWithVersionInfo`
  is preferred over `XAudio2Create`, exactly like the SDK's inline helper. The module is
  never unloaded (the SDK helper does the same).

XAudio2 was chosen over WASAPI because it provides a real multi-voice mixer, per-voice
gain ramps that are interpolated inside its processing pass (no zipper noise),
sample-rate conversion per voice, and automatic default-device following through the
virtual audio client.

## Signal flow and gain

```
source voice (per sound, native format) --> mastering voice --> default output device
gain = taper(volume) * envelope^2 * pause^2         master = taper(master) * mute * duck * headroom
```

- `taper(v) = v^1.6` (about -9.6 dB at 50 %), used for track and master sliders.
- `envelope` ramps 0..1 for fades (default 1.5 s in, 1 s out, 2 s preset crossfade); it is
  squared so fades follow perceived loudness.
- `pause` is the global play/pause fade; when it reaches 0 the voices are stopped (`Stop`
  keeps their queued buffers, so resuming continues seamlessly).
- `mute` and `duck` (optional mute when RAD Studio loses focus) ramp in 250 / 600 ms.
- **Headroom:** uncorrelated ambient tracks add in power. When `sqrt(sum(gain^2))` exceeds
  1.5 the master is reduced by `1.5 / sqrt(sum(gain^2))`, smoothly, so enabling all 16
  sounds at full volume cannot drive the output into clipping.
- All volume changes are ramps (120 ms for slider moves); nothing jumps.
- Default master volume is 30 %. Nothing plays until the user starts playback.

## Input formats

`CtrlCalm.Audio.Wav` walks every RIFF chunk (it never assumes a 44-byte header) and
accepts:

- `WAVE_FORMAT_PCM` or `WAVE_FORMAT_EXTENSIBLE` with the PCM sub-format;
- 16-bit samples, mono or stereo, 8–192 kHz (XAudio2 resamples to the device rate).

It rejects, with a reason, anything else: other bit depths, float or compressed data,
more than two channels, missing or duplicate `fmt `/`data` chunks, chunks running past
the end of the file, inconsistent block alignment, empty data. A `data` chunk whose size
overruns the file is clamped to the whole frames that exist. Odd-sized chunks are padded
as the RIFF specification requires. Bundled files are 48 kHz stereo (Fan: 44.1 kHz mono).

## Buffering and streaming

Recorded sounds are streamed from disk, never loaded whole:

- each track has a fixed ring of **4 buffers × 400 ms** allocated once (≈ 300 KB per
  48 kHz stereo track; 5.4 MB with all 16 sounds playing);
- the worker refills from `GetState(XAUDIO2_VOICE_NOSAMPLESPLAYED).BuffersQueued`; because
  XAudio2 consumes buffers in FIFO order, the next ring slot is free whenever fewer than
  4 are queued, so a buffer is never rewritten while XAudio2 can still read it;
- `OnBufferEnd` (XAudio2 audio thread) only calls `SetEvent` on the worker's wake event;
- 1.6 s of audio is queued ahead, enough to ride out long IDE stalls during compiles;
- the real-time path allocates nothing.

## Looping

`TLoopingWavSource` produces an endless stream with an **equal-power crossfade** at the
seam: with file length `L` and crossfade `X` (1.5 s, at most `L/4`), frames `[L-X, L)` are
blended with the first `X` frames (cached in memory), after which playback continues at
frame `X`. The steady-state loop is `[X, L)` and contains no hard edit. The automated test
`Audio.Loop.SeamIsEqualPowerCrossfade` checks every frame of the seam.

## Procedural noise

Stereo float32 at 48 kHz, independent generators per channel (decorrelated), seeded per
process and sound (deterministic for a seed):

| Noise | Method | Measured slope 250 Hz–8 kHz |
|---|---|---|
| White | xoshiro128** uniform | +0.05 dB/oct (ideal 0) |
| Pink | Paul Kellet's refined 7-pole filter | -2.98 dB/oct (ideal -3.01) |
| Brown | leaky integrator, pole 0.998 | -5.97 dB/oct (ideal -6.02) |

A one-pole DC blocker removes any offset; levels are calibrated to -20 dBFS RMS, the same
target as the recorded loops (peaks 0.18–0.45, no clipping). Two minutes of brown noise
show no drift (`Audio.Noise.BrownNoiseHasNoLongTermDrift`).

## Asset preparation (build time only)

`scripts/package/prepare_sounds.py` (Python standard library) converts the original
recordings to the bundled loops: 60 s segment starting 8 % into the recording, gain toward
-20 dBFS RMS, a 5 ms look-ahead peak limiter at -1 dBFS (at most 12 dB, 16 dB for Water and
20 dB for Fireplace, which are sparse and impulsive), TPDF dither to 16 bit. Details and
checksums per file are in `assets/sounds/manifest.json`. End users never need Python.

## Failure handling

- **Missing or damaged file:** detected at startup by validating each header; the tile shows
  "Unavailable" with the reason in its tooltip and cannot be activated. Other sounds work.
- **Read error while streaming:** silence is written and the track reports the error.
- **No audio device / XAudio2 failure:** status "No audio output device"; the engine retries
  with back-off (1, 2, 4, 5 s ...) while sounds are wanted.
- **Device unplugged / invalidated:** `OnCriticalError` sets an atomic flag and wakes the
  worker, which tears down all voices and the engine, reports "Audio device lost -
  reconnecting", retries, and on success recreates the voices and fades the active sounds
  back in from where they were.
- **Default device changed:** handled by XAudio2's virtual audio client (the engine is
  created without `XAUDIO2_NO_VIRTUAL_AUDIO_CLIENT`).
- **Idle:** when nothing has played for 3 s the XAudio2 engine is stopped
  (`StopEngine`), so an idle IDE pays no audio processing cost.

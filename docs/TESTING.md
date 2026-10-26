# Testing

## Automated tests

`tests\CtrlCalmTests.dpr` is a console program with a tiny built-in test harness (no
DUnit/DUnitX needed). Run it via the build script or directly:

```powershell
.\scripts\build\Build.ps1 -Test            # build and run for Win32 and Win64
build\RAD13\Win64\Debug\bin\CtrlCalmTests.exe [filter] [/nodevice]
```

Exit code = number of failures. `/nodevice` skips the tests that open the real audio
output (they play quietly, at 5-8 % master volume).

| Suite | What it covers |
|---|---|
| Core | catalog (16 unique stable ids), key round trip, volume taper, mix comparison, built-in presets, safe defaults, normalization |
| Audio.Wav | canonical header, extra/odd-sized chunks, extensible PCM, truncated data, 15 malformed/unsupported cases |
| Audio.Loop | frame-exact equal-power seam, buffer-boundary independence, missing/short files |
| Audio.Noise | level/DC/clipping, spectral slope (white 0, pink -3, brown -6 dB/oct), determinism, continuity, stereo decorrelation, no drift |
| Audio.Engine | ramps, track state transitions, headroom limiter (without a device) |
| Audio.Device | 10x engine init/shutdown on the real device |
| Assets | manifest covers all 16 sounds with provenance; every bundled file parses and matches its SHA-256 |
| Timer | start/pause/resume/expiry, zero and out-of-range durations, no drift over long runs, reset/cancel, sleep policy, Pomodoro cycle and auto-start |
| Persistence | full round trip, backward compatibility, invalid JSON, corrupt-file recovery, favorites CRUD, 4 concurrent writers x 25 updates, read-only file |
| Threading | 25x start/stop, queue order, coalescing of 40 000 volume commands, shutdown under 18 000 pending commands, partial initialization, timer completion inside the worker |
| Service | click/reconcile, favorites across instances, two independent instances |
| Device | all 16 sounds at once (glitches, CPU, memory, output level), rapid toggle/slider stress, two separate processes playing independently |

### IDE smoke test

`tests\IntegrationTests\IdeProbe\IdeProbe.dpr` starts a real RAD Studio with the
installed package (`bds.exe -pDelphi -ns -np`, with `CTRLCALM_AUTOMATION=1`), then
checks: the package is loaded, the Tools > Ctrl+Calm submenu has its five actions, the
mixer opens with 16 tiles, clicking tiles makes the IDE process's own audio session
produce sound, audio continues while the panel is hidden, the timer opens, pause
silences the output, and the IDE exits with code 0.

```powershell
build\RAD13\Win64\Debug\bin\IdeProbe.exe "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin64\bds.exe" build\ide-shots
```

The automation endpoint it uses exists only when the IDE is started with
`CTRLCALM_AUTOMATION=1`; it executes the same actions as the menu items.

## Manual smoke-test checklist

Items marked (A) are also covered automatically; the rest need a person.

1. IDE starts with the package installed; no error dialog. (A)
2. Tools > Ctrl+Calm > Show/Hide Mixer opens the panel. (A)
3. Close the panel while audio plays: audio continues. (A)
4. Reopen the panel: state (active tiles, levels, timer) is unchanged.
5. Five sounds at once; then all 16 at once: no distortion, no stutter. (A, at engine level)
6. Click tiles rapidly on and off; drag sliders quickly. (A, at service level)
7. Save a mix (+ Save mix), rename, update, duplicate and delete it via right-click; restart the IDE; favorites remain. (A, persistence)
8. Start a 1-minute timer, hide the panel, wait: notification appears and sounds stop. (A, worker)
9. Pause and resume the timer; the remaining time does not drift.
10. Play during a long build (e.g. a large project group): no audible stutter.
11. Play while debugging an application, including stopping at breakpoints.
12. Switch IDE theme (Tools > Options > User Interface > Theme Manager): the panel follows without restart.
13. Resize the docked panel from very narrow to wide: compact, comfort and expanded layouts switch cleanly.
14. Dock the panel left, right and in a tab group; float it; restart the IDE: layout is restored.
15. Unplug the headphones / disable the output device while playing: status shows "reconnecting"; reconnect: sound fades back in.
16. Change the Windows default output device while playing: audio moves to the new device.
17. Sleep and resume Windows while playing and with a timer running.
18. Run two RAD Studio instances with different mixes and timers; close one; the other continues. (A, two processes)
19. Exit the IDE while playing and while a timer runs: clean exit. (A)
20. Kill the IDE from Task Manager while playing; start it again: Ctrl+Calm starts normally.
21. Replace `%APPDATA%\CtrlCalm\settings.json` with garbage; start the IDE: defaults, damaged file kept. (A)
22. Delete one WAV from the sounds folder; restart: that tile shows "Unavailable", others work. (A)
23. Open/close the panel 20 times; leave sounds playing for several hours; memory stays flat.
24. Windows display scaling 100/125/150/175/200 %, and moving the floating panel between monitors with different scaling.
25. Windows high-contrast theme.
26. Keyboard only: Tab through controls, Space toggles a tile, arrows change its level.

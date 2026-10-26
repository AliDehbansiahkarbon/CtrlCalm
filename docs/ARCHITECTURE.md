# Ctrl+Calm architecture

Ctrl+Calm is a single design-time package (`CtrlCalm370.bpl`) written in Delphi with VCL,
the Open Tools API and Windows system APIs only. It has no runtime dependencies beyond
RAD Studio's own packages and Windows (XAudio2 2.9 is loaded from System32 at runtime).

## Layers

| Layer | Units | Responsibility |
|---|---|---|
| Core | `CtrlCalm.Core.Types`, `CtrlCalm.Core.Settings` | Sound catalog, mix/preset/settings value types, validation |
| Audio | `CtrlCalm.Audio.XAudio2`, `.Wav`, `.Sources`, `.Engine` | XAudio2 bindings, RIFF parser, streaming/looping and noise sources, the mixer |
| Timer | `CtrlCalm.Timer` | Countdown and Pomodoro state machine (pure logic, injectable clock) |
| Persistence | `CtrlCalm.Persistence` | JSON settings, atomic multi-process-safe storage |
| Threading | `CtrlCalm.Threading.Worker`, `CtrlCalm.Service` | The worker thread, command queue, snapshots, main-thread service |
| UI | `CtrlCalm.UI.*` | Palette/theming, vector icons, custom controls, mixer view, timer panel, settings dialog |
| IDE | `CtrlCalm.IDE.Register`, `CtrlCalm.IDE.HostFrame` | Wizard, menu actions, dockable window, theme notifier, lifecycle |

Dependencies point downwards only: the IDE layer uses UI and Service; UI uses Service and
Core; Service uses Worker and Persistence; Worker uses Engine and Timer; Engine uses the
Audio units and Core. Core depends on nothing but the RTL. The standalone harness
(`demos/StandaloneMixerHarness`) and the test runner (`tests/CtrlCalmTests.dpr`) use the
same units as the package.

```
 IDE (ToolsAPI)        Harness / Tests
      \                     /
       TCalmMixerView  (UI, main thread)
              |
         TCalmService  (main thread)  --- TSettingsStore (JSON, %APPDATA%\CtrlCalm)
              |  commands (queue)  ^  snapshots + 1 posted message
              v                    |
         TCalmWorker  (one thread per IDE process)
          |               |
     TAudioEngine     TFocusTimer
          |
   XAudio2 2.9 (system)  -- its own audio thread calls back only to signal an event
```

## Object ownership

- `CtrlCalm.IDE.Register` owns, per IDE process: the wizard (owned by the IDE after
  `RegisterPackageWizard`), the `TCalmIdeController` (actions, menu, timers), the
  `INTACustomDockableForm` implementation and the single `TCalmService`.
- `TCalmService` owns the `TCalmWorker`, the `TSettingsStore` and a hidden message window.
- `TCalmWorker` creates and owns the `TAudioEngine` and the `TFocusTimer` *on the worker
  thread*; no other thread touches them.
- `TAudioEngine` owns one `TEngineTrack` per sound; each track owns its source (file
  stream or noise generator), its XAudio2 source voice and a fixed ring of 4 buffers.
- The dockable form is created by the IDE; Ctrl+Calm tracks it with `FreeNotification`
  and only frees it when the package unloads.

## UI interaction flow

1. A click on a tile calls `TCalmService.ToggleSound`.
2. The service updates its optimistic model immediately (so the UI responds in the same
   message), posts a command to the worker queue and notifies listeners.
3. The worker drains the queue, applies the commands to the engine and timer, then
   publishes an immutable `TCalmSnapshot` and calls the service's notifier.
4. The notifier (worker thread) posts at most one `WM_CALM_CHANGED` message to the
   service's hidden window (coalesced with an atomic flag).
5. On the main thread the service copies the snapshot, adopts the worker's logical state
   once the worker has processed every command sent so far (`ProcessedSeq`), handles
   timer events (balloon notification, taskbar flash) and notifies listeners, which
   repaint only what changed.

## Lifecycle

**Startup.** `Register` creates the controller and menu, registers the dockable form and
theme notifier. No audio thread exists yet. Two seconds later a one-shot timer reads the
settings file (without starting audio) to apply shortcuts and, if enabled, open the panel
or auto-resume. The service and worker are created on first use. On creation the last
mix is *armed* (sources validated and prepared) while paused; nothing is heard until the
user presses Play or clicks a sound, unless auto-resume was deliberately enabled.

**Shutdown / package unload** (unit finalization, in this order):

1. Stop the startup timer; free the menu items; detach actions from the IDE action list.
2. Free the dockable form (frees the frame and mixer view, which unregister from the service).
3. Unregister the dockable form and the theme notifier; clear UI hooks.
4. Free the service, which: saves pending settings, tells the worker to stop accepting
   commands, queues `ckShutdown`, and waits for the thread. The worker cancels the timer,
   stops and destroys every source voice (XAudio2 `DestroyVoice` blocks until the audio
   thread no longer uses the voice and its buffers), destroys the mastering voice,
   unregisters the engine callback, releases the XAudio2 engine, uninitializes COM and
   exits. Only then is the hidden window destroyed, so no posted message can reach freed
   code.

Every step is guarded so that a failure in one does not skip the rest. See
[THREADING.md](THREADING.md) for the details of thread safety and
[AUDIO_ENGINE.md](AUDIO_ENGINE.md) for the audio pipeline.

## Settings file

`%APPDATA%\CtrlCalm\settings.json` (UTF-8). Sections: `audio`, `timer` (with
`pomodoro`), `appearance`, `general`, `shortcuts`, `favorites`. Unknown keys are ignored,
missing keys take defaults and out-of-range values are clamped, so older and newer files
load safely. A damaged file is kept as `settings.corrupt-<timestamp>.json` and defaults
are used. Timer state is never persisted, so two IDE instances cannot overwrite each
other's running timers.

## Supported versions

The code uses only APIs present in RAD Studio 11 Alexandria and later
(`INTAServices270` docking, `IOTAIDEThemingServices250`, `{$LIBSUFFIX AUTO}`), but it has
been built and tested only with RAD Studio 13 Florence (BDS 37.0). See
[INSTALLATION.md](INSTALLATION.md).

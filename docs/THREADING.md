# Threading

## One worker per IDE process

Each RAD Studio process that loads Ctrl+Calm has exactly one `TCalmService` (a unit-level
variable of the package, created lazily) and therefore exactly one `TCalmWorker` thread.
Nothing is shared between processes except the settings file: there is no global mutex
around audio, no service, no helper executable. Two IDEs play, pause and time
independently (`Device.TwoProcessesPlayIndependently` starts two real processes).

Showing, hiding, docking or re-creating the panel never creates a thread; the worker lives
as long as the service, which lives until the package unloads. XAudio2 runs its own
internal audio thread(s), which call back into Ctrl+Calm only to signal an event.

## Ownership

| Object | Thread |
|---|---|
| `TCalmService`, views, settings store, hidden window | main (IDE) thread |
| `TAudioEngine`, `TEngineTrack`, sources, `TFocusTimer` | worker thread only |
| XAudio2 voice/engine callbacks | XAudio2 audio thread; touch only an atomic flag and `SetEvent` |
| Command queue | shared, guarded by a critical section |
| Published snapshot | shared, guarded by a critical section; copied by value |

## Command queue

`TCalmWorker.Post` appends a `TCalmCommand` record (value type: sound, value, mix, timer
options ...) under a lock, assigns it a sequence number and signals the wake event.
Commands: ActivateSound, DeactivateSound, SetSoundVolume, SetMasterVolume, SetMuted,
SetDucked, PlayAll, PauseAll, ResumeAll, StopAll, ApplyPreset, SetFades, StartTimer,
StartPomodoro, PauseTimer, ResumeTimer, CancelTimer, ResetTimer, StartNextPhase,
PlayChime, Shutdown.

**Coalescing:** a `SetSoundVolume` for a sound (or a `SetMasterVolume`) that is still
queued is updated in place instead of appending a new command, so dragging a slider can
never flood the worker. In the test `Threading.RapidVolumeCommandsCoalesce`, 40 002 posted
volume commands resulted in 3 executed commands with the correct final values.

Order is otherwise preserved (`Threading.CommandQueueKeepsOrder`).

## Worker loop

```
repeat
  drain queue -> execute each command (exceptions are contained per command)
  wait := engine.Process          // ramps, refills, device recovery
  timer.Poll -> completion actions // stop/fade sounds, chime, Pomodoro mix switch
  wait := min(wait, timer.MsUntilDue)
  if anything changed: publish snapshot, notify main thread
  WaitFor(wake event, wait)
until terminated
```

The wait is `INFINITE` when idle (0.0 ms of worker CPU over 5 s idle in the device test),
15 ms only while a fade or ramp is running, otherwise until the next buffer completes or
the timer is due. There is no polling and no busy-waiting.

## Main-thread notifications

The worker never touches VCL objects and never uses `TThread.Synchronize` or
`TThread.Queue`. After publishing a snapshot it calls the service's notifier, which does
`PostMessage(WM_CALM_CHANGED)` to the service's hidden window, guarded by an atomic flag
so that at most one message is pending. The message handler copies the snapshot and
notifies the registered views. Because the window belongs to the service and is destroyed
only after the worker has been joined, a posted message can never run code in a freed
object or an unloaded package.

## Race-condition prevention

- **Stale snapshots:** commands carry increasing sequence numbers and the snapshot records
  the highest one processed. The service adopts the worker's logical state (active sounds,
  volumes, play state) only when `ProcessedSeq` has caught up with the last command it sent;
  until then it keeps its optimistic state, so a click is never visually undone.
- **Buffers:** a streaming buffer is only rewritten when XAudio2 reports fewer queued
  buffers than the ring size; voices are destroyed (which waits for the audio thread)
  before their buffers are released.
- **Device loss:** the audio thread only sets an atomic flag; all teardown and recovery run
  on the worker.
- **Listeners:** the service iterates over a copy of the listener list, so a view can
  unregister while being notified.

## Shutdown and package-unload safety

`TCalmWorker.Shutdown` (called from the service destructor):

1. stops accepting commands (`Post` returns -1 afterwards);
2. queues `ckShutdown` behind any pending commands and signals the worker;
3. waits for the thread to finish.

On the worker, `ckShutdown` terminates the loop; the `finally` block cancels the timer,
shuts the engine down in order (source voices, mastering voice, callback registration,
engine), publishes a final snapshot, frees the engine and timer and uninitializes COM.
All steps tolerate partial initialization (`Threading.PartialInitializationCleansUp`) and
pending work (`Threading.ShutdownUnderLoad`: 18 000 queued commands, shutdown in 10 ms).

Because the service is freed in the IDE unit's `finalization`, which runs during
`UnloadPackage` before the module is unmapped, the worker thread has fully exited before
any package code disappears.

# Contributing to Ctrl+Calm

Thanks for helping. A few rules keep Ctrl+Calm safe to run inside everyone's IDE.

## Ground rules

- Delphi, VCL, the Open Tools API, the RTL and Windows system APIs only. No third-party
  components, libraries, runtime packages, DLLs or online services.
- IDE stability first: no blocking work on the main thread, no `TThread.Synchronize`,
  no VCL access from the worker, and every lifecycle path must tolerate partial
  initialization. Read [docs/THREADING.md](docs/THREADING.md) before touching the worker.
- Do not invent API declarations. New Windows bindings must be translated from the SDK
  headers and cite them; new ToolsAPI use must exist in every supported IDE version.
- Sounds must be CC0 or properly attributed CC BY with verifiable provenance. Add them via
  `scripts/package/prepare_sounds.py` so `manifest.json`, `ATTRIBUTION.md` and
  `LICENSES.md` stay accurate. Never add audio from a source with unclear rights.

## Workflow

```powershell
.\scripts\build\Build.ps1 -Test -Harness   # package, tests, harness for Win32 + Win64
build\RAD13\Win64\Debug\bin\CtrlCalmHarness.exe   # iterate on the UI without the IDE
```

Add or update tests in `tests\` for any behavior change; all tests must pass on both
platforms. Run the manual checklist in [docs/TESTING.md](docs/TESTING.md) for UI or IDE
integration changes. Keep source files ASCII (the compiler reads BOM-less files with the
system code page).

## Style

Match the surrounding code: `T`/`F`/`A` prefixes, two-space indentation, XML doc comments
only where they add information, comments that explain *why*.

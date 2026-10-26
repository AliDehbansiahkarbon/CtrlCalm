# Troubleshooting

**The Ctrl+Calm menu does not appear.**
Check Component > Install Packages: "Ctrl+Calm - ambient sounds and focus timer" must be
listed and checked. The 32-bit IDE needs the Win32 package and the 64-bit IDE the Win64
package (`.\scripts\package\Install.ps1` installs both). If RAD Studio disabled the package
after an error, it is listed under `Disabled Packages` / `Disabled Packages x64` in
`HKCU\Software\Embarcadero\BDS\37.0`; reinstalling removes that entry.

**All recorded sounds show "Unavailable".**
The package cannot find its `sounds` folder. It looks in `CTRLCALM_SOUNDS`, then next to the
BPL and one level above it, then (for development builds) in `assets\sounds` up the folder
tree. Hover a tile to see the exact reason.

**No sound, status says "No audio output device" or "reconnecting".**
Ctrl+Calm retries automatically. Check that a playback device is enabled and not used
exclusively by another application. Settings > About > Copy diagnostics copies the
engine status, buffer and glitch counters for a bug report.

**Sound is too quiet / too loud.**
The master starts at 30 % on purpose. Each sound has its own level; when many sounds are
loud at once the engine lowers the master automatically to prevent clipping. Fireplace and
Water are recordings of sparse sounds and are naturally quieter; raise their level.

**My settings were reset.**
If the settings file could not be parsed it is kept next to the new one as
`settings.corrupt-<date>.json` in `%APPDATA%\CtrlCalm`. A read-only file or folder shows
"settings not saved" in the status footer; changes then last until the IDE closes.

**Shortcuts.**
No shortcut is assigned by default to avoid clashing with editor commands. Set them in
Settings > General. They are IDE action shortcuts and also appear in the IDE's own action
customization.

**Uninstalling.** See [INSTALLATION.md](INSTALLATION.md#uninstall).

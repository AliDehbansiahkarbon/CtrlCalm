# Installation

## Requirements

- Windows 10 or 11, which provide XAudio2 2.9 as a system component.
- RAD Studio 13 Florence, 64-bit and/or 32-bit IDE. This is the version tested; see
  "Other versions" below.
- No other software is needed.

## Install (recommended: script)

Close RAD Studio, then run from the repository root in PowerShell:

```powershell
.\scripts\package\Install.ps1
```

The script:

1. builds the Release package `CtrlCalm370.bpl` for the Win32 and Win64 IDEs with the
   installed command-line compiler;
2. copies the packages to `%LOCALAPPDATA%\CtrlCalm\RAD13\Win32` and `...\Win64`, and the
   sounds and license files to `%LOCALAPPDATA%\CtrlCalm\RAD13\sounds`;
3. registers each package for the current user under
   `HKCU\Software\Embarcadero\BDS\37.0\Known Packages` (32-bit IDE) and
   `Known Packages x64` (64-bit IDE).

Nothing is written to the RAD Studio folder and no administrator rights are needed.
Options: `-Platform Win32|Win64|Both`, `-InstallDir <folder>`, `-SkipBuild`, and
`-RegistryProfile <name>` to install into an isolated IDE profile started with
`bds.exe -r<name>`.

Start RAD Studio and choose **Tools > Ctrl+Calm > Show/Hide Mixer**.

## Install manually from the IDE

1. Open `packages\RADStudio13\CtrlCalm.dproj`.
2. Choose the platform matching the IDE you are running: **Windows 32-bit** for
   `bds.exe` in `bin`, **Windows 64-bit** for the 64-bit IDE in `bin64`. A 32-bit IDE
   cannot load a 64-bit package or vice versa.
3. Select the **Release** configuration, then right-click the project and choose **Install**.
4. The package finds its sounds automatically when it is built inside the repository
   (`build\RAD13\<platform>\Release\bin` walks up to `assets\sounds`). If you move the
   BPL, put the `sounds` folder next to it or one level above it, or set the environment
   variable `CTRLCALM_SOUNDS` to the folder.

## Build only

```powershell
.\scripts\build\Build.ps1                # Release package, Win32 + Win64
.\scripts\build\Build.ps1 -Test          # plus the automated tests
.\scripts\build\Build.ps1 -Test -NoDevice  # tests without audio output
```

Outputs go to `build\RAD13\<Win32|Win64>\<Config>\bin`. MSBuild works too:

```bat
call "%ProgramFiles(x86)%\Embarcadero\Studio\37.0\bin\rsvars.bat"
msbuild packages\RADStudio13\CtrlCalm.dproj /t:Build /p:Config=Release /p:Platform=Win64
```

## Uninstall

Close RAD Studio, then:

```powershell
.\scripts\package\Uninstall.ps1                  # keeps settings and favorites
.\scripts\package\Uninstall.ps1 -RemoveSettings  # also deletes %APPDATA%\CtrlCalm
```

Manual alternative: **Component > Install Packages**, select "Ctrl+Calm - ambient sounds
and focus timer", **Remove**, restart the IDE, and delete
`%LOCALAPPDATA%\CtrlCalm` and optionally `%APPDATA%\CtrlCalm`.

## Other versions

The sources use only Open Tools API interfaces available since RAD Studio 11 Alexandria
(`INTAServices270` docking, `IOTAIDEThemingServices250`) and `{$LIBSUFFIX AUTO}`, so the
same `CtrlCalm.dpk` should compile on RAD Studio 11.x and 12.x (it produces
`CtrlCalm280.bpl` / `CtrlCalm290.bpl`). **These versions have not been tested yet.** To try one:

```powershell
.\scripts\build\Compile.ps1 -Project packages\RADStudio13\CtrlCalm.dpk -Platform Win32 -Config Release -BdsVersion 23.0
.\scripts\package\Install.ps1 -BdsVersion 23.0 -InstallDir $env:LOCALAPPDATA\CtrlCalm\RAD12
```

then run the tests with the same `-BdsVersion` and the manual checklist in
[TESTING.md](TESTING.md). The 64-bit IDE exists only in RAD Studio 12.3 and later.

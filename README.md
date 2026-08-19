# Open Couch

[![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPL%20v3+-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/GustavoBelo/OpenCouch)](https://github.com/GustavoBelo/OpenCouch/releases)

Open Couch switches your KDE Plasma display setup between your desk and the living room TV. It can launch Steam Big Picture and restore your normal layout when you finish playing.

## ✨ What it does

| | |
|---|---|
| **One-click display switch** | Switch between your desk and living room TV layouts instantly. |
| **Steam Big Picture integration** | Launch Big Picture, monitor it, and restore your desktop layout when you finish playing. |
| **Detailed display settings** | Configure resolution, refresh rate, scale, position, priority, and enabled state for each display. |
| **Flexible TV setup** | Keep the desk display enabled or mirror it while playing on the TV. |
| **System tray** | Keep Open Couch out of the way and start it automatically with your desktop session. |
| **Logs and history** | Export logs and review history when troubleshooting display or Steam issues. |
| **Guided setup** | Choose your desk display and TV through a simple first-run setup. |

## 📦 Installation

The **AppImage is the recommended way to install Open Couch**.

1. Download `OpenCouch-x86_64.AppImage` from the [latest GitHub Release](https://github.com/GustavoBelo/OpenCouch/releases/latest).
2. Make it executable and run it:

   ```sh
   chmod +x OpenCouch-x86_64.AppImage
   ./OpenCouch-x86_64.AppImage
   ```

The AppImage includes the display and Steam engine. On first launch, it automatically installs or updates the engine in `~/.local/bin` when needed. You do not need to update the engine separately.

## 🚀 First run

1. Open Open Couch from the AppImage.
2. Follow the setup and select your desk monitor and TV.
3. Use **Go to TV** to switch layouts and launch Steam Big Picture.
4. Close Steam or use **Restore desktop** to return to your normal layout.

Open Couch is designed for KDE Plasma and requires Steam for the Big Picture integration.

## 🧹 Remove

Delete the AppImage to remove the application. To remove the engine that it installed:

```sh
rm -f ~/.local/bin/open-couch-engine ~/.local/bin/open-couch-log-viewer
```

## 📄 License

Open Couch is licensed under [GPL-3.0-or-later](LICENSE).
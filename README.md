# Open Couch

[![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPL%20v3+-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/GustavoBelo/OpenCouch)](https://github.com/GustavoBelo/OpenCouch/releases)

Open Couch hands your whole machine to Steam's gamescope session on the television, and
gives it back cleanly when you leave.

It is not a launcher that opens Big Picture in a window. Big Picture only offers per-game
HDR, FSR, tearing and the frame limiter when the session it runs in declares them, and only
a real gamescope session does. So this runs one: your desktop session ends, gamescope takes
the television, and Steam's own **Switch to Desktop** brings your desktop back.

Works on KDE Plasma, Hyprland and GNOME. It does not replace your distribution and does not
need you to reinstall anything.

## ✨ What it does

| | |
|---|---|
| **A real console session** | Your distribution's own `gamescope-session`, with everything Big Picture needs declared. |
| **Switching without a greeter** | A login session hosts both your desktop and the console, so switching never drops you at a password prompt. |
| **Picks the television** | Points gamescope at the display you chose, and waits for it when it is still switched off. |
| **Moves the sound** | Follows the display to its HDMI output and puts the sound back on the way home. |
| **Comes back clean** | Sanitises the systemd user manager on the way out, which is what lets the next compositor start at all. |
| **Announces itself** | A countdown you can cancel, because entering ends the desktop session and everything open in it. |

Resolution, refresh rate, HDR and VRR are deliberately not settings here: gamescope reads the
display's preferred mode and Steam changes it per game.

## 📦 Install

You need a `gamescope-session` package from your distribution — Open Couch runs it, it does
not ship it. `open-couch-engine doctor` tells you if it is missing.

### The engine

The engine is the whole product: a static binary with no runtime dependencies that does
everything from the command line. The graphical application is optional.

```sh
curl -fsSL https://raw.githubusercontent.com/GustavoBelo/OpenCouch/main/packaging/host/install.sh | bash
```

Or, with a Go toolchain:

```sh
go install github.com/GustavoBelo/OpenCouch/engine/cmd/open-couch-engine@latest
```

Or take the binary straight from the [latest release](https://github.com/GustavoBelo/OpenCouch/releases/latest)
— `open-couch-engine-linux-amd64` or `-arm64`, checksums in `SHA256SUMS`.

### From a package

Two packages, the same split as above: `open-couch-engine`, and `open-couch` for the graphical
application, which pulls in Qt and needs the engine.

For Fedora, Nobara and Bazzite (`.rpm`) or Debian and Ubuntu (`.deb`), take the files from the
[latest release](https://github.com/GustavoBelo/OpenCouch/releases/latest):

```sh
sudo dnf install ./open-couch-engine-*.rpm ./open-couch-*.rpm
sudo apt install ./open-couch-engine_*.deb ./open-couch_*.deb
```

## 🚀 First run

```sh
open-couch-engine doctor              # what is still missing
open-couch-engine outputs             # the connectors on this machine
open-couch-engine tv HDMI-A-1         # choose the one on the television
open-couch-engine setup               # writes the hosting session entry, tells you where to put it
```

`setup` prints the last step, which depends on your login screen. If it offers a
session picker, choose **Open Couch (console switch)** there. Plenty of themes
have no picker -- they choose a session for you and show no way to change it --
in which case `setup` gives you an autologin snippet instead. Autologin is read
when the display manager starts, so that route needs a reboot; logging out only
returns you to the greeter, which never re-reads it.

Then:

```sh
open-couch-engine enter
```

Steam → Power → **Switch to Desktop** brings you home. So does `open-couch-engine leave`
over ssh.

To start there every time: `open-couch-engine boot console`.

If a switch does not do what you expected, `~/.cache/open-couch/console.log` says
what the wrapper did. It survives between sessions, which the display manager's
own session log does not, and the login before this one is filed under
`~/.cache/open-couch/logs/` -- which is usually the one worth reading, because
the switch that failed is what ended it. The application shows both;
`open-couch-engine log`, `log --list` and `log --session <ID>` are the same thing
from a terminal.

## 🎮 Entering with a controller

`open-couch-engine controller on` -- or the switch in the application -- offers
the console when a gamepad is switched on. It announces itself first and waits
twenty seconds, with a Cancel button in the notification and the same countdown
in the application if it is open: switching a pad on by accident should not close
your desktop.

## 🆘 If you cannot log in

The hosting session is what your machine logs into, so anything that breaks the
engine breaks your login. Two things keep that from trapping you:

- The entry declares `TryExec`, so a **missing** binary just hides the session.
- After three logins that end within seconds, the engine stops offering the
  console on its own: it starts your plain desktop, ignores the boot setting and
  any pending switch, and says why in the application. One normal login brings
  the console back. From that desktop, `open-couch-engine disable` makes the
  pause permanent -- no root, the session entry stays installed, and
  `open-couch-engine enable` undoes it.

If a login still will not take -- a binary that is present but failing, an
autologin pointed straight at a broken session -- switch to a text console with
**Ctrl+Alt+F2**, log in there, and remove the entry:

```sh
sudo rm -f /usr/local/share/wayland-sessions/open-couch-session.desktop
sudo rm -f /usr/share/wayland-sessions/open-couch-session.desktop
rm -f ~/.local/share/wayland-sessions/open-couch-session.desktop
```

If you set up autologin, also undo that:

```sh
sudo rm -f /etc/sddm.conf.d/zzz-open-couch.conf
```

Then reboot. `~/.cache/open-couch/console.log` will still be there afterwards and
is the first thing to read.

## 🧹 Remove

To pause it without root: `open-couch-engine disable`. The next login goes
straight to the desktop, and the session entry stays installed.

To take it out for good, remove the session entry **first**. A machine that
still offers a session whose engine you have deleted is a machine you may not be
able to log into.

```sh
sudo rm -f /usr/local/share/wayland-sessions/open-couch-session.desktop
sudo rm -f /usr/share/wayland-sessions/open-couch-session.desktop
sudo rm -f /etc/sddm.conf.d/zzz-open-couch.conf     # only if you set up autologin
rm -f ~/.local/bin/open-couch-engine
rm -rf ~/.config/open-couch ~/.cache/open-couch
```

## 📄 License

Open Couch is licensed under [GPL-3.0-or-later](LICENSE).

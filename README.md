# MicKeeper

**The right mic, at the right level, and AirPods that never sound like a phone call.**

<p align="center">
  <img src="docs/screenshot.png" width="572" alt="The MicKeeper settings window">
</p>

When AirPods or other Bluetooth headphones connect to a Mac, macOS makes them the microphone too. As soon as an app
uses that microphone (a call, a Meet tab, dictation), the headphones switch to call mode and everything you hear
turns mono and muffled. With an iPhone nearby, macOS may switch to its microphone instead. And apps like Zoom, Teams
and Chrome change your microphone level on their own. MicKeeper switches the microphone back and, if you want,
puts the level back too.

## What it does

- When macOS switches the input to AirPods or other Bluetooth headphones (when they connect, or go back in your
  ears), MicKeeper switches back to the microphone you were using, or the built-in one. Your headphones stay high
  quality, and their battery lasts longer.
- Same for an iPhone: if macOS picks a nearby or plugged-in iPhone's microphone, MicKeeper switches back. You can
  still use the iPhone as a camera.
- You can also pick one microphone in the list, and MicKeeper uses it whenever it is connected. That is also how to
  use AirPods or an iPhone as the microphone on purpose.
- Optionally puts the microphone level back when an app changes it.
- The window shows the current microphone, its level, and how often MicKeeper stepped in.

## Resource use

The agent uses about 3 MB of memory. It has no timers and doesn't poll; it sleeps until macOS reports a microphone
or level change. Over 60 seconds idle, the kernel's own counters showed it ran no instructions at all.

Measured on macOS 26.7.1: memory with `footprint`, CPU and wakeups with the kernel's `proc_pid_rusage` counters.

There is no menu bar icon, and the settings window only runs while it's open. MicKeeper needs no permissions
because it never listens to the microphone. It only changes which one is selected, and its level.

## Good to know

- Apps that let you pick a microphone themselves (Zoom, Teams, and so on) follow MicKeeper when they are set to the
  system default ("Same as System"). If AirPods are picked inside the app, the app uses them anyway.
- macOS reports your own switch to AirPods in Sound settings exactly like its automatic one, so MicKeeper switches
  back. To use AirPods or an iPhone as the microphone, pick it in MicKeeper.
- To switch between other microphones quickly, hold Option and click the sound icon in the menu bar.

## Requirements

- A Mac with Apple silicon
- macOS 13 Ventura or later

Tested on a 14-inch MacBook Pro (Apple silicon) with macOS 26.7.1 Tahoe, with AirPods Pro and an iPhone.

## Install

### Homebrew

```sh
brew install --cask fratayaydn/tap/mickeeper
```

### Download

Download `MicKeeper-<version>.dmg` from the [latest release](https://github.com/fratayaydn/mickeeper/releases/latest),
open it and drag **MicKeeper** to **Applications**. The app is signed with a Developer ID and notarized by Apple.

### First run

Open **MicKeeper** and turn on **Enable MicKeeper**. It needs no permissions. Close the window when you're done
and MicKeeper keeps working in the background.

## How it works

- `MicKeeper.app/Contents/MacOS/mickeeperd` is a small background agent, registered as a login item through
  `SMAppService`. It asks CoreAudio to report changes to the default input, the list of devices and the input level,
  and otherwise sleeps.
- When the default input becomes a Bluetooth or Continuity (iPhone) device, it sets it back to the last real
  microphone in use, else the built-in one, else any other real microphone. If there is none, it leaves it alone.
- With a microphone picked in the list, it keeps that one as the default input while it is connected.
- With the level locked, it puts the input level back to the locked value when it changes.
- Only the agent changes the input and its level; the window only saves settings, so the two never race.
- It watches its app bundle through the kernel's event queue (no polling): when the app is replaced by an update it
  restarts with the new version, and when the app is moved to the Trash it removes its login item and quits.
- `MicKeeper.app/Contents/MacOS/MicKeeper` is the SwiftUI settings window. It runs only while open.

MicKeeper uses only public macOS APIs.

## Building from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/fratayaydn/mickeeper.git
cd mickeeper
make install
```

This builds `MicKeeper.app`, copies it to `/Applications` and opens it. To update, pull and run `make install`
again.

Local builds are signed with a self-signed certificate that `scripts/create-signing-identity.sh` creates on the
first build, so the login item keeps working across rebuilds; `scripts/install.sh` re-registers it after each
update. To sign with your own Apple Developer ID instead:
`make install SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"`.

## Uninstall

Move **MicKeeper** from Applications to the Trash (or `brew uninstall --cask mickeeper`). The background agent
notices, removes its login item and quits. Your settings are kept in case you install it again.

To remove the settings too, use `brew uninstall --zap --cask mickeeper` instead, or run
`defaults delete io.github.fratayaydn.mickeeper` after moving the app to the Trash. If you built it from source,
`make uninstall` in the cloned folder removes both the app and the settings.

## Command line

```sh
/Applications/MicKeeper.app/Contents/MacOS/mickeeperd --status   # prints the current microphone and its level
```

## More small Mac apps

- [NightKeys](https://github.com/fratayaydn/nightkeys): keyboard backlight that only comes on when you type on the
  built-in keyboard
- [BalanceKeeper](https://github.com/fratayaydn/balancekeeper): puts the left/right audio balance back when macOS
  shifts it
- [CapsNow](https://github.com/fratayaydn/capsnow): turns off the Caps Lock delay, so quick taps register

## License

MIT license, see [LICENSE](LICENSE).

<div align="center">

# capybar

**A capybara and her retinue in the macOS menu bar: CPU and memory, network throughput, ping and Wi-Fi, and the microphone.**

[![CI](https://github.com/illinifellow/capybar/actions/workflows/ci.yml/badge.svg)](https://github.com/illinifellow/capybar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-ff905c.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-88bd66.svg)](https://www.apple.com/macos/)
[![Buy me a coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-ffdd04?logo=buymeacoffee&logoColor=000)](https://buymeacoffee.com/illinifellow)

*Being a Brief and Respectful Account of a Small Rodent of Quality, Lately Elevated to the macOS Menu Bar, Together with Such Instruments of Measurement as Befit Her Retinue.*

</div>

## Contents

- [I. Of the Establishment, and Why It Exists at All](#i-of-the-establishment-and-why-it-exists-at-all)
- [II. Of Installation, Which Requires No Great Talent](#ii-of-installation-which-requires-no-great-talent)
- [III. Of Certain Services Rendered Without Ceremony](#iii-of-certain-services-rendered-without-ceremony)
- [IV. Of Instructions Given from the Command Line](#iv-of-instructions-given-from-the-command-line)
- [V. Of the Arrangement of the Sources](#v-of-the-arrangement-of-the-sources)
- [VI. Of Improvements, and the Proper Manner of Proposing Them](#vi-of-improvements-and-the-proper-manner-of-proposing-them)
- [VII. Of Licence](#vii-of-licence)

## I. Of the Establishment, and Why It Exists at All

One had long observed that the menu bar of a Mac, that narrow and much-coveted strip of ground at the summit of the screen, was given over almost entirely to persons of no particular breeding: a clock, a battery, an assortment of icons whose owners one could not, upon interrogation, recall having admitted. Into this unpromising company there is now introduced a capybara. She is accompanied by three attendants of strictly practical disposition, and the whole household lives in a single process, as a respectable household ought.

From left to right, the capybara keeping the place of honour at the far end:

1. **The Constitution**: CPU load above, memory in use below (reckoned as Activity Monitor reckons *Memory Used*), refreshed each second. CPU at 85% or more, or memory at 90% or more, appears in red. A click upon it produces a list of the principal offenders, the five processes consuming the most CPU and the five holding the most memory, each grouped by name, with the lesser culprits folded into a *More* submenu where they may be consulted without being encouraged.
2. **The Network**: upload above, download below, each preceded by its arrow, refreshed every 500 ms. Only physical interfaces (`en*`) are counted, so that a VPN tunnel is not permitted to claim the same traffic twice. A click measures every process for one second through `nettop` and names the five most garrulous, the remainder folded likewise.
3. **The Ping**: the round-trip time to `8.8.8.8` above, the quality of the Wi-Fi signal in percent below (−100 dBm counting as 0%, −50 dBm and better as 100%), both taken once a second. Should Google decline to reply, or reply with a tardiness exceeding 150 ms, the upper figure is rendered in red, as one might raise an eyebrow at a footman who arrives late with the tea; the lower turns red when the quality sinks beneath 50% or the Wi-Fi has absented itself altogether.
4. **The Capybara**, who no longer queues among the others but sits in a borderless panel laid over the menu bar's Control Center icon, which she conceals and whose movements she follows; she walks, chews grass, reclines with her head raised to survey her estate with a red apple balanced upon it, sleeps while releasing a modest procession of *z*s, stands with dignity in the rain, and swims, the apple still in place. Eight frames a second; she is not to be hurried. She is, moreover, a creature of service: a left click upon her summons the iTerm2 session in which Claude Code is already at work, or, finding none so engaged, opens a fresh window and issues the command `cc` on your behalf; a right click offers the *Quit* entry. The first such summons obliges macOS to ask whether `capybar` may direct iTerm2, a question one answers *Allow*, unless one prefers the life of a lighthouse keeper, whose only correspondent is the sea.
5. **The Microphone**: a microphone, crossed out and red when the default input device is muted. Only the keyboard's own microphone key changes that state; capybar remaps the key to F5 with `hidutil` (so macOS no longer pesters one about Dictation), catches it, and puts the device back at once should any application or system whim presume to alter the state the key last chose. At every start, wake and unlock the microphone is muted; only the key may unmute it. Each press of the key toggles the microphone, on or off.

## II. Of Installation, Which Requires No Great Talent

You shall require macOS and the Swift compiler that arrives with the Xcode Command Line Tools. Those who possess neither are respectfully advised to take up the restoration of antique barometers, a pursuit that likewise concerns itself with pressure, though at a far more forgiving pace.

```bash
git clone https://github.com/illinifellow/capybar.git
cd capybar
./install.sh
```

`install.sh` compiles every file in `Sources/` into `~/.local/bin/capybar` and registers the launchd agent `com.illinifellow.capybar`, which starts at login and returns of its own accord should it ever leave without permission (a crash, that is; a deliberate *Quit* is respected). To apply a change, run it again; it rebuilds and restarts without further ceremony.

To dismiss the household entirely:

```bash
./uninstall.sh
```

The *Quit* entry in the menu of any item (on the capybara, the right-click menu) closes all four together, as befits a household that dines as one. They return at the next login.

## III. Of Certain Services Rendered Without Ceremony

- **Cmd+\\** summons the macOS screenshot toolbar, poised upon a selected area, and commits the result to the clipboard; **Cmd+Shift+\\** does likewise but delivers the result to Preview. capybar requires the Screen Recording permission for it; without that permission macOS hands back captures holding nothing but the wallpaper. The system's own screenshot shortcuts must be left on their defaults, lest they claim the backslash first.
- The moon key (Do Not Disturb) is remapped to F6 and toggles Do Not Disturb by running the Shortcuts shortcut «Toggle Do Not Disturb», which must first be imported once from `extras/Toggle Do Not Disturb.shortcut` (open it and press *Add Shortcut*); macOS offers no public means of switching Focus otherwise.
- `install.sh` signs the binary with a code-signing identity named `capybar local signing` when the keychain holds one, so that macOS remembers the permissions above across rebuilds.

## IV. Of Instructions Given from the Command Line

The binary answers a few orders directly, for those who prefer a keyboard to a key:

| Command                       | Effect                                                    |
| ----------------------------- | --------------------------------------------------------- |
| `capybar`                     | Runs the household (what the launchd agent does at login) |
| `capybar --focus-claude-code` | Does what a left click on the capybara does               |

## V. Of the Arrangement of the Sources

| File                       | Responsibility                                                                           |
| -------------------------- | ---------------------------------------------------------------------------------------- |
| `Sources/main.swift`       | Starts the application and admits the four items, the first admitted standing rightmost  |
| `Sources/shared.swift`     | The Quit menu, the menu bar's label colour, and the two-line inscription the items share |
| `Sources/ping.swift`       | The ping and Wi-Fi signal item                                                           |
| `Sources/capybara.swift`   | The capybara, her activities, her apple and her weather                                  |
| `Sources/network.swift`    | Interface counters and the upload and download item                                      |
| `Sources/system.swift`     | CPU ticks, memory statistics, and the item that reports them                             |
| `Sources/hotkeys.swift`    | Screenshot hotkeys and the responsibility-disclaimed `screencapture` spawn               |
| `Sources/microphone.swift` | The microphone item, the key remap and the guard on the mute state                       |
| `Sources/processes.swift`  | Per-process CPU, memory and traffic, and the folded top-five menu section                |

Thresholds, refresh intervals and the host to be pinged are declared as constants at the head of each file. One alters them there, and nowhere else, then runs `./install.sh`.

## VI. Of Improvements, and the Proper Manner of Proposing Them

Every change begins as an issue, a [bug report](https://github.com/illinifellow/capybar/issues/new?template=bug_report.yml) or a [feature request](https://github.com/illinifellow/capybar/issues/new?template=feature_request.yml). The work for an issue proceeds upon its own branch, taken from `develop`, and arrives by a pull request into `develop` that closes it; the branch is removed upon merging, as a guest's coat is returned at the door. Releases gather `develop` into `master` under a tag bearing the version, without the vulgar «v».

To build without installing, as the continuous integration does:

```bash
swiftc -O Sources/*.swift -o .build/capybar
```

## VII. Of Licence

MIT. You may do with it very nearly as you please, provided you do not mistake the capybara for a hippopotamus in polite company.

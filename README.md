# capybar

<!-- cover: docs/cpu.png -->
<!-- date: 2026-10-06T02:00:00Z -->

**A capybara and her retinue in the macOS menu bar: CPU and memory, network throughput, ping and Wi-Fi, and the microphone.**

[![CI](https://img.shields.io/github/actions/workflow/status/illinifellow/capybar/ci.yml?label=CI)](https://github.com/illinifellow/capybar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-ff905c)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-88bd66)](https://www.apple.com/macos/)
[![Buy me a coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-ffdd04?logo=buymeacoffee&logoColor=000)](https://buymeacoffee.com/illinifellow)

![capybar in the macOS menu bar, enlarged three times: CPU and memory, upload and download, ping and Wi-Fi quality, the muted microphone among the system icons, and the capybara beside the clock](docs/menubar.png)

It had long been remarked, in households of the better sort, that the menu bar of a Mac is the one strip of ground that is never out of sight, and that it is squandered almost entirely upon matters one consults twice a day. A gentleman at his work wishes to know rather different things, and to know them at a glance: whether the machine is labouring, and at whose expense; whether the network is moving or merely pretending to; whether a sluggish connection is the fault of the Wi-Fi or of some distant party; and, before every call, whether the microphone is at last silent. Each answer was to be had, but only by opening a window, which is precisely the exertion a glance exists to spare. Such utilities as already offered themselves arrived in the manner of a dashboard, with dozens of graphs, a preferences window and a subscription, as though one had asked for the time and been sold a clock tower.

The ambition, therefore, was modest and severe: four readings, always legible, which colour themselves red only when something genuinely requires attention; a click upon any of them that names the culprit without ceremony; a microphone that answers to its own key and to no one else; and nothing whatever to configure. The first attempts wrote their figures as plain text, and the bar fidgeted every second as the numbers changed their width, which no respectable household tolerates; drawing each reading as an image of fixed width, in the menu bar's own colour, restored its composure. The microphone proved the most wilful member of the establishment, for applications and macOS alike kept altering its state without leave, and so capybar now holds the key itself and restores the device the instant anyone else presumes to touch it. The capybara arrived last and declined to leave, it having been observed that a menu bar of gauges resembles a cockpit, whereas one calm rodent in the corner makes of it a place where somebody lives.

![The Constitution opened: the five processes using the most CPU and the five holding the most memory, each with a cross that ends it at once, the rest folded under More](docs/cpu.png)

## Of How the Thing Is Built

It is one native Swift program keeping five status items, admitted at each login by a launch agent of unimpeachable punctuality. Its intelligence is taken directly from the system, without intermediaries: the kernel's own tally of the processor, memory reckoned as Activity Monitor reckons it, traffic counted on the physical interfaces alone, a ping sent through its own ICMP socket and the strength of the Wi-Fi once every second, and nothing redrawn that has not changed; the capybara occupies a small animated panel laid over the Control Center icon, and the microphone key is remapped with `hidutil` so that its decisions may be enforced.

*Being a Brief and Respectful Account of a Small Rodent of Quality, Lately Elevated to the macOS Menu Bar, Together with Such Instruments of Measurement as Befit Her Retinue.*

## I. Of the Establishment, and Why It Exists at All

One had long observed that the menu bar of a Mac, that narrow and much-coveted strip of ground at the summit of the screen, was given over almost entirely to persons of no particular breeding: a clock, a battery, an assortment of icons whose owners one could not, upon interrogation, recall having admitted. Into this unpromising company there is now introduced a capybara. She is accompanied by three attendants of strictly practical disposition, and the whole household lives in a single process, as a respectable household ought.

From left to right, the capybara keeping the place of honour at the far end:

1. **The Constitution**: CPU load above, memory in use below (reckoned as Activity Monitor reckons *Memory Used*), refreshed each second. CPU at 85% or more, or memory at 90% or more, appears in red. A click upon it produces a list of the principal offenders, the five processes consuming the most CPU and the five holding the most memory, each grouped by name, with the lesser culprits folded into a *More* submenu. Beside every one of them stands a small cross: a press upon it ends that process forthwith, as Activity Monitor's *Force Quit* would, though without the interview; a process belonging to another user wears its cross greyed, being beyond one's jurisdiction. The list keeps itself current every second for as long as it is open.
2. **The Network**: upload above, download below, each preceded by its arrow, refreshed every 500 ms. Only physical interfaces (`en*`) are counted, so that a VPN tunnel is not permitted to claim the same traffic twice. A click opens a register of every process presently making use of the line, with what each is receiving and sending at this moment and what it has received and sent in total, the most garrulous first and the remainder folded under *More*. The register is kept, through `nettop`, only while it is open, and refreshed every second.

   ![The Network opened: per process, the download and upload rates now and the totals, the busiest first](docs/network.png)

3. **The Ping**: the round-trip time to `8.8.8.8` above, the quality of the Wi-Fi signal in percent below (−100 dBm counting as 0%, −50 dBm and better as 100%), both taken once a second, the ping through capybar's own ICMP socket rather than by summoning `/sbin/ping` afresh each time. Should Google decline to reply, or reply with a tardiness exceeding 150 ms, the upper figure is rendered in red, as one might raise an eyebrow at a footman who arrives late with the tea; the lower turns red when the quality sinks beneath 50% or the Wi-Fi has absented itself altogether. A click lays out the whole connection: the Wi-Fi network, its channel and band, PHY mode, signal, noise and their ratio, transmit rate, security and country code; the interface, local IPv4 and IPv6, router, DNS servers, VPN and public address; and the pings of the last minute, with their minimum, average, maximum and losses. Any address or figure there is copied upon a click, and acknowledges it with a brief *Copied*. macOS withholds the BSSID from a program without a bundle, and says so; the public address is asked of `api.ipify.org` and remembered for five minutes.

   ![The Ping opened: the Wi-Fi network, channel, signal and noise, the local and public addresses, router, DNS and VPN, and the pings of the last minute](docs/ping.png)

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

When a newer release has been published, every menu shows an *Update to X.Y.Z* entry beside *Quit*. A click upon it fetches that release, compiles it exactly as `install.sh` would, and only then replaces the binary and restarts the household through its launch agent; should any step fail, the old capybar stays where it was and a notice says which step declined. The household looks for such releases at start and every six hours.

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

| File                       | Responsibility                                                                                   |
| -------------------------- | ------------------------------------------------------------------------------------------------ |
| `Sources/main.swift`       | Starts the application and admits the four items, the first admitted standing rightmost          |
| `Sources/shared.swift`     | The menu bar's label colour and the two-line inscription the items share                         |
| `Sources/menu.swift`       | The rows, sections and Quit entry the menus share, and the timer that keeps an open menu current |
| `Sources/update.swift`     | The search for a newer release and the rebuilding of capybar in its place                        |
| `Sources/ping.swift`       | The ping and Wi-Fi signal item                                                                   |
| `Sources/capybara.swift`   | The capybara, her activities, her apple and her weather                                          |
| `Sources/network.swift`    | Interface counters and the upload and download item                                              |
| `Sources/system.swift`     | CPU ticks, memory statistics, and the item that reports them                                     |
| `Sources/hotkeys.swift`    | Screenshot hotkeys and the responsibility-disclaimed `screencapture` spawn                       |
| `Sources/microphone.swift` | The microphone item, the key remap and the guard on the mute state                               |
| `Sources/processes.swift`  | The sampling of processes through `ps` and `nettop`, and the force quit                          |

Thresholds, refresh intervals and the host to be pinged are declared as constants at the head of each file. One alters them there, and nowhere else, then runs `./install.sh`.

## VI. Of Improvements, and the Proper Manner of Proposing Them

Every change begins as an issue, a [bug report](https://github.com/illinifellow/capybar/issues/new?template=bug_report.yml) or a [feature request](https://github.com/illinifellow/capybar/issues/new?template=feature_request.yml). The work for an issue proceeds upon its own branch, taken from `develop`, and arrives by a pull request into `develop` that closes it; the branch is removed upon merging, as a guest's coat is returned at the door. Releases gather `develop` into `master` under a tag bearing the version, without the vulgar «v».

To build without installing, as the continuous integration does:

```bash
swiftc -O Sources/*.swift -o .build/capybar
```

## VII. Of Licence

MIT. You may do with it very nearly as you please, provided you do not mistake the capybara for a hippopotamus in polite company.

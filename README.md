# Dice

A die that lives in your Mac's Dock. Drag it off the Dock and it becomes a 3D die you can
throw and roll around your screen. Drop it back on the Dock, or right-click it, to put it away.

The screen is treated as a tabletop seen from above: the die lifts when you grab it, rolls
across your windows, bounces off the screen edges, and settles with one face toward you. The
Dock icon then shows the face you rolled.

## Using it

| Do this | And this happens |
|---|---|
| Drag the Dock icon off the Dock | The die comes out under your cursor |
| Click the Dock icon | The die pops out with a small toss |
| Grab the die and let go while moving | It is thrown and rolls |
| Hold the die and wiggle it | It rattles in your hand |
| Right-click the die | It shoots back to the Dock |
| Drop the die on the Dock | It docks (works with a hidden Dock too) |
| Right-click the Dock icon | Recall Die, and Sound on/off |
| Right-click the Dock icon → Dice Style | Pick Classic, Ancient, Glowing or Void; it changes at once and is remembered |

There are a few easter eggs. Finding them is more fun than reading about them, but they are
listed in [SPEC.md](SPEC.md) if you want spoilers.

## Requirements

- macOS 14 or later
- A Swift 6 toolchain. The Xcode Command Line Tools are enough; Xcode itself is not needed.

## Build and run

```bash
scripts/build-app.sh
open build/Dice.app
```

To keep the die in your Dock, right-click its Dock icon and choose Options → Keep in Dock.

### Accessibility permission

macOS tells an app nothing when its Dock icon is dragged, so Dice watches mouse events with an
event tap, and that needs the Accessibility permission. On first launch macOS will prompt you;
switch Dice on under System Settings → Privacy & Security → Accessibility. Dice notices within
a couple of seconds, with no relaunch.

Without the permission Dice still runs in a reduced mode: clicking the Dock icon pops the die
out and recalls it, but you cannot drag it off the Dock or grab it on screen.

Dice is not sandboxed and reads only mouse position and button events. It never looks at the
keyboard.

### Keeping the permission across rebuilds

By default the build is ad hoc signed, which makes every rebuild look like a new app to macOS.
The old Accessibility switch then stays on but is silently ignored. Two ways out:

- **Sign with a stable identity.** In Keychain Access choose Certificate Assistant → Create a
  Certificate, name it `Dice Signing`, and set Certificate Type to **Code Signing**. The build
  script uses it automatically. Any other identity works via `DICE_SIGN_IDENTITY="Name"`.
- **Reset the stale entry** after a rebuild, then relaunch and switch Dice on again:

  ```bash
  tccutil reset Accessibility local.mac-apps.dice
  ```

## How it works

- **One event tap** (`InputTap.swift`) handles every gesture. It swallows the mouse-down on the
  Dice tile before the Dock sees it, so the Dock never starts its own drag.
- **The Dock is located through the Accessibility API** (`DockLocator.swift`): which element is
  under the cursor, where the Dice tile and the Trash are, and whether the Dock is hidden.
- **A transparent, click-through window** covers the screen that holds the Dock
  (`OverlayWindow.swift`). It is only shown while the die is out.
- **SceneKit** does the rendering and rigid-body physics (`DiceScene.swift`). Rendering pauses
  whenever the die is at rest, so an idle die costs nothing.
- **Throws** use the strongest stretch of cursor motion in the last 0.3 s before release
  (`ThrowController.swift`), because people slow down just before they let go.
- **Sounds** are synthesised in code at launch (`Sound.swift`); there are no audio files.

[SPEC.md](SPEC.md) is the original build brief plus notes on everything added since. It
explains the decisions and the dead ends.

## Debug switches

Set these in the environment, for example
`open --stderr /tmp/dice.log --env DICE_DEBUG=1 build/Dice.app`.

| Variable | Effect |
|---|---|
| `DICE_DEBUG=1` | Log every state change, tap decision and roll to stderr |
| `DICE_DEMO=1` | Walk through every feature automatically; needs no permission |
| `DICE_DEMO_STEPS=a,b` | Run only the named demo steps |
| `DICE_MUTE=1` | Silence all sound and log what would have played |
| `DICE_REVEAL_DOCK=0` | Do not try to reveal a hidden Dock while the die is held near it |
| `DICE_STYLE=<name>` | Start in a dice style (`classic`, `ancient`, `glowing`, `void`) without changing the saved choice |
| `DICE_FRIDAY13=1` / `0` | Force one of the easter eggs on or off |
| `DICE_BORED_AFTER=<seconds>` | Shorten the idle timer behind another easter egg |
| `DICE_SHADOW=shadowonly` | Use SceneKit's shadow-only floor instead of the blob shadow |
| `DICE_SNAPSHOT_DIR=<dir>` | Save PNG snapshots of the scene (slow; debugging only) |

## Limitations

- The die stays on the screen that holds the Dock.
- One die at a time in normal use.
- Not notarised and not suitable for the Mac App Store, because of the event tap.

## Licence

MIT. See [LICENSE](LICENSE).

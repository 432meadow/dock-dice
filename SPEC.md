# Dice — build spec

A macOS toy. A die sits in the Dock. Drag it off the Dock and it becomes a 3D die you can
throw and roll around the screen. Drop it back on the Dock to put it away.

## Decisions already made (do not reopen)

- **Physics model:** the screen is a tabletop seen from above. Gravity points into the screen.
  The die lifts toward the viewer when grabbed, rolls across the screen, bounces off the screen
  edges, and comes to rest with one face toward the viewer.
- **Accessibility permission is required** for the real gesture. Without it the app still works
  in a fallback mode (click the Dock icon to pop the die out).
- **One screen for v1:** the die is confined to the screen that holds the Dock.
- **Look:** classic white die, black pips, opposite faces sum to 7.
- **Renderer:** SceneKit (soft-deprecated, but transparent windows and rigid-body physics work
  out of the box).
- **Not sandboxed, not for the App Store.**

## Machine constraints

- macOS 26, Apple silicon, Swift 6.2, **Command Line Tools only — no Xcode**. No `xcodebuild`,
  no asset catalogs, no XCTest. Build with SwiftPM and assemble the `.app` by script.
- No code-signing identities. Sign ad-hoc unless `DICE_SIGN_IDENTITY` is set.
- Do not: use sudo, install Xcode, create certificates or keychain items, run `tccutil`, or try
  to grant the Accessibility permission by any means. The user grants it by hand.
- Do not `git init` or commit.

## Layout

```
Dice/
  Package.swift              executable target "Dice", macOS 14+, Swift 5 language mode
  Sources/Dice/
    main.swift               NSApplication bootstrap, activation policy .regular
    AppDelegate.swift        state machine, wiring, Dock menu, reopen handler
    InputTap.swift           the one CGEventTap
    DockLocator.swift        Accessibility queries against the Dock
    OverlayWindow.swift      transparent click-through window + SCNView
    DiceScene.swift          scene, die, floor, walls, camera, lights, rest/face detection
    ThrowController.swift    held-follow behaviour and release velocity
    DockTileRenderer.swift   swaps the Dock tile image
    DieArt.swift             Core Graphics pip-face drawing (shared by textures, tile, icon)
  Resources/Info.plist
  scripts/build-app.sh       swift build -c release → build/Dice.app → codesign
  scripts/make-icon.swift    renders the iconset with DieArt-style drawing → iconutil → AppIcon.icns
```

Use Swift 5 language mode (`swiftLanguageModes: [.v5]`): the C event-tap callback and the
SceneKit render-thread delegate are painful under Swift 6 strict concurrency.

Bundle id: `local.mac-apps.dice`. Bundle name: `Dice`. No `LSUIElement` (the app needs its Dock
icon). No main window. Never activate or steal focus.

## State machine (AppDelegate owns it)

```
docked ──pull / click──▶ held ──release──▶ rolling ──settles──▶ resting
   ▲                       ▲                  │                    │
   │                       └──────grab────────┴────────────────────┘
   └── release over Dock tile / Recall / click on empty tile ──────┘
```

- `docked`: overlay window ordered out, nothing rendering, Dock tile shows the die.
- `held`: die follows the cursor, lifted off the table.
- `rolling`: physics running.
- `resting`: physics settled, rendering paused, overlay still up showing the die.

## The gesture (highest risk — build and log this path first)

macOS sends an app nothing when its Dock icon is dragged, and the Dock runs its own drag. So we
swallow the mouse-down before the Dock sees it.

**InputTap**
- `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap)`
  for `leftMouseDown`, `leftMouseDragged`, `leftMouseUp`. Source on the main run loop, common modes.
- Returning `nil` swallows an event. Once a mouse-down is swallowed, swallow every drag and the
  mouse-up of that same gesture. Pass everything else through untouched, including right-clicks
  (the Dock menu must keep working).
- The callback must return fast. Re-enable the tap on `.tapDisabledByTimeout` and
  `.tapDisabledByUserInput`.
- Needs Accessibility trust. On launch call `AXIsProcessTrustedWithOptions` with the prompt
  option. If untrusted or tap creation fails, run in fallback mode and retry every ~2 s so the
  gesture comes alive once the user grants it, without a relaunch.

**On `leftMouseDown`, in this order**
1. If state is `rolling` or `resting` and the point is inside the die's projected screen circle
   → swallow, enter `held`. Pure math, no IPC.
2. Else if the point is inside the cached Dock strip rect → ask `DockLocator` whether the element
   under the cursor is our tile. If yes → swallow and remember the start point.
   - Dragged more than ~6 pt → enter `held`: show overlay, spawn the die under the cursor, tile
     becomes the empty slot.
   - Released without dragging, die docked → pop out: spawn at the tile and toss it a short
     distance toward screen centre with random spin.
   - Released without dragging, die out → recall.
3. Else pass through.

**DockLocator**
- Dock pid from `NSRunningApplication` with bundle id `com.apple.dock`; `AXUIElementCreateApplication`.
  Set `AXUIElementSetMessagingTimeout` to ~0.2 s so a slow Dock cannot stall the tap.
- Dock strip rect: frame of the Dock's `AXList` child. Cache it; refresh on a ~2 s timer and on
  `NSApplication.didChangeScreenParametersNotification`. Inflate it to allow for magnification.
- Is-it-our-tile test: `AXUIElementCopyElementAtPosition`, then match the element's `AXURL`
  against our bundle URL (fall back to `AXTitle == "Dice"`).
- Tile frame (for returning the die): `AXPosition` + `AXSize` of that same item. Re-query while
  the die is held, since magnification moves it.
- Event and AX coordinates are global, top-left origin. AppKit is bottom-left. Convert in one place.

**Fallback mode (no permission)**: `applicationShouldHandleReopen` (a Dock icon click) pops the
die out or recalls it. Grabbing the die on screen is unavailable without the tap; that is
acceptable.

**Unverified assumption:** that swallowing the mouse-down at the session tap fully prevents the
Dock's own drag on macOS 26. If it does not, report exactly what was observed rather than
papering over it.

## Overlay window

- Borderless `NSWindow`, `isOpaque = false`, clear background, no shadow,
  `ignoresMouseEvents = true` always (all input comes through the tap), cannot become key or main.
- Level above the Dock and menu bar. Collection behaviour: all Spaces, stationary, full-screen
  auxiliary, ignores cycle. Show with `orderFrontRegardless()`.
- Frame = full `frame` of the screen containing the Dock tile (not `visibleFrame`), so the die can
  pass over the Dock and menu bar.
- `SCNView` with clear background, non-opaque layer, 4x multisampling, `rendersContinuously = false`.
  `isPlaying` is true only in `held` and `rolling`.
- On screen-parameter change: recall the die and refit.

## Scene

- **Scale:** die edge = 1.0 scene unit, so the physics solver works at a sane scale. One scene
  unit = `edgePoints` screen points; make `edgePoints` about 0.8 × the Dock tile size, clamped
  to 44…72.
- **Axes:** x and y are the screen axes, +z points at the viewer. `physicsWorld.gravity = (0, 0, -g)`
  with g well above 9.8 (start near 40) so the die feels snappy rather than floaty.
- **Camera:** perspective, narrow field of view (~25°), looking straight down −z from a height
  chosen so the visible area at z = 0 is exactly the window. The die then grows slightly when
  lifted and shows a hint of its side faces as it tumbles. When held, unproject the cursor onto
  the plane at lift height so the die stays under the cursor.
- **Die:** `SCNBox` with a chamfer of about 12% of the edge, six materials textured by `DieArt`
  (ivory-white, black pips, 1/6, 2/5, 3/4 on opposite faces), modest specular highlight.
  Dynamic body with a box shape. Starting values to tune: restitution 0.45, friction 0.6,
  angular damping 0.2, linear damping 0.1. A firm throw should roll for 1–2.5 s.
- **Floor:** static plane at z = 0 that shows only the die's shadow. Try
  `SCNMaterial.lightingModel = .shadowOnly` under a shadow-casting directional light. If that does
  not render correctly in a transparent window, use a blob shadow instead: a soft radial-gradient
  quad under the die whose size and opacity follow the die's height.
- **Walls:** four thick invisible static boxes just outside the screen edges and a ceiling above
  lift height. Enable continuous collision detection on the die. Safety net: if the die is ever
  out of bounds, put it back at the nearest in-bounds point.
- **Rest:** linear and angular speed under small thresholds for ~0.3 s → `resting`. The face up
  is the local axis whose world direction has the largest +z component.
- Mutate physics only from the `SCNSceneRendererDelegate` callbacks. The cursor target reaches
  the render thread through a lock-protected value.

## Holding and throwing (ThrowController)

- **Held:** the body stays dynamic. Each step, set its linear velocity toward the cursor target
  at lift height (about 1.2 units above the table) with a stiff, clamped follow so it tracks the
  cursor closely. Add spin about the axis ẑ × v so it tumbles in the direction it is being
  dragged, with extra angular damping so it calms down when the cursor stops.
- **Release:** linear velocity = cursor velocity averaged over the last ~100 ms, converted to
  scene units and clamped. Angular velocity = rolling-direction spin proportional to speed plus
  a random component. Every release is a roll: a slow or stationary release still gets a small
  hop and random spin.
- **Release over the Dock tile** (tile frame inflated ~12 pt): shrink the die into the tile over
  ~0.15 s, order the overlay out, enter `docked`.
- **Recall:** same animation from wherever the die is.

## Dock tile and icon

- `NSApp.dockTile.contentView` holds an image view; call `display()` after each change.
- Docked: a 2D die face — rounded ivory square, black pips, soft shadow — showing the last
  rolled value (5 before the first roll).
- Die out: an empty slot — dashed rounded-square outline at low opacity.
- `AppIcon.icns` (shown when the app is not running) is the same face drawing showing 5, rendered
  by `scripts/make-icon.swift` and packed with `iconutil`.
- `applicationDockMenu` adds "Recall Die", enabled only while the die is out.

## Build and debug

- `scripts/build-app.sh`: `swift build -c release`, assemble `build/Dice.app` (binary,
  `Info.plist`, `AppIcon.icns`), then
  `codesign --force --sign "${DICE_SIGN_IDENTITY:--}" build/Dice.app`.
- `DICE_DEBUG=1`: log every state transition, tap decision (swallowed or passed, and why),
  DockLocator result, and rolled face to stderr.
- `DICE_DEMO=1`: needs no permission. On launch, pop the die out and throw it automatically
  every few seconds, so rendering and physics can be checked without the gesture.

## Done means

1. `scripts/build-app.sh` succeeds from a clean checkout with no warnings that matter.
2. `build/Dice.app` launches, stays up, shows the die tile in the Dock, and opens no window.
3. In `DICE_DEMO=1` mode the die appears, rolls, bounces off the screen edges, settles on a
   face, and the debug log reports that face.
4. Fallback mode works with Accessibility ungranted.
5. The gesture code path is complete and logged. Whether it works end to end can only be
   confirmed by the user after granting the permission — say so plainly in the report.

## Added after v1

What the app does now beyond the sections above. Where this section and the sections above disagree, this one is current.

### Batch 1: gestures and fairness
- **Right-click the die to send it home.** The event tap also watches right mouse down/up. A right-down inside the die's circle while `rolling`/`resting` is swallowed, together with its matching right-up, and shoots the die home. Every other right-click passes through, including the Dock menu.
- **Return styles.** `shot`: a fast, accelerating flight (0.25–0.35 s), tumbling, with a little hop, shrinking on arrival. Used for right-click, Dock-menu Recall, and a tile click while the die is out. `drop`: the original short shrink, used for a hand drop. `trash`: a twisting crumple (see the Trash egg).
- **Drop zone (`DropZone` in DockLocator.swift).** Releasing the held die docks it when the cursor is (a) over the Dock strip while the Dock is showing, or (b), shown or hidden, inside a 40 pt band along the Dock's screen edge spanning the strip's extent plus one tile on each side. Left and right Docks are handled the same way. Anywhere on the Dock counts. The die still flies to our tile's position (off the edge if the Dock is hidden). The geometry is self-checked at launch.
- **Drop-zone cue.** While held in the zone the die shrinks to 0.8 (0.72 over the Trash). Only a child "visual" node is ever scaled. Scaling the physics-body node made SceneKit reset the body to a stale transform and teleported the die.
- **Dock reveal (switchable).** While the held die is in the drop zone, drags are passed on as `mouseMoved` instead of being swallowed, so an autohidden Dock sees ordinary cursor motion and slides in. On by default; `DICE_REVEAL_DOCK=0` turns it off.
- **Holding stays calm.** The held target is kept 0.8 units from the edges. Contacts while held are neither logged nor heard. Shakes are not detected within ~150 pt of the Dock edge.
- **Release velocity.** The release velocity is the strongest 50–100 ms stretch of motion within the last 0.3 s, scaled from 1.0 (at release) down to 0.4 (0.3 s before). A throw that ends in a brief pause still flies; a die held still just hops. `releaseMaxSpeed` is unchanged.
- **Fair spawns.** Pop-out and pull use a uniformly random starting orientation. Tallies across 129 natural rolls showed no bias.
- **Prewarmed overlay.** The overlay, scene and textures are built at launch, so the first pull does no heavy work inside the tap callback.
- **Signing.** `scripts/build-app.sh` signs with the "Dice Signing" identity when present (ad hoc otherwise; `DICE_SIGN_IDENTITY` overrides), so the Accessibility grant survives rebuilds.

### Batch 2: sound, shake, easter eggs
- **Sound (Sound.swift).** Everything is synthesised at launch into PCM buffers; no audio files. AVAudioEngine plays them through 8 player nodes. Palette: "wooden die on felt, heard across a quiet room". Low tones with 3–6 ms fade-ins, everything 4th-order low-passed (no meaningful energy above 2 kHz), master level 0.3, small dynamic range.
  - `tokWall` / `tokFloor`: 160–345 Hz damped tones. Hit strength comes from the velocity change beyond gravity (SceneKit's contact impulse reads 0). Threshold dv > 2, at most one every 45 ms.
  - `rattle`: muffled, for shakes.
  - `thunk` / `bigThunk`: Dock landing and the shot landing.
  - `crumple`: the Trash.
  - `pop`: back from the Trash.
  - `blip`: the wink.
  - `chime`: kalimba-like E5–B5, for the hot streak.
  - The engine starts when the die comes out and stops 3 s after it rests, or 1.5 s after it docks.
  - The Dock menu has a "Sound" checkmark item (UserDefaults `soundEnabled`, on by default). `DICE_MUTE=1` silences everything and logs each sound that would have played.
- **Shake to rattle (ThrowController).** A reversal is a direction change (dot product < −0.3) above 450 pt/s. From the 2nd reversal within 0.6 s, each reversal tumbles the held die and plays a rattle. A release within 0.35 s of a shake uses only the final stroke: if that stroke lasted under 120 ms its velocity is ×0.25, and the roll gets extra random spin and a hop.
- **Friday the 13th.** On a local Friday the 13th the die and the Dock tile (not the bundle icon) are black with red pips. Re-checked every 2 s and on `NSCalendarDayChanged`. `DICE_FRIDAY13=1` forces it on, `=0` off.
- **The Trash eats it.** Releasing over the Trash (subrole `AXTrashDockItem`), or in the edge band within the Trash's span when the Dock is hidden, crumples the die into the Trash. The Trash takes priority over the general drop zone. State `trashed`: the tile shows an empty slot for 5 s, then the die pops back. A tile click, Dock click or Recall restores it at once. The real Trash is never touched.
- **Loaded die.** Option held at mouse-up (from the event flags) loads the roll. If it settles on anything but 6, the die does a hop-and-flip onto 6. Then the 6 winks: its pips vanish for 150 ms, with a blip.
- **Hot streak.** Three natural sixes in a row turn the die and the tile gold for the next roll, with a chime. Another natural six keeps it gold; anything else reverts it when that roll settles. Loaded rolls reset the streak and end gold.
- **Bored die.** After 3 min resting untouched, the die wobbles; again 20 s later; 60 s after that it rolls home in quarter-turn hops and docks itself. Any interaction resets this. Rendering wakes only for these animations. `DICE_BORED_AFTER=<s>` shortens the first delay and scales the others (minimum 1.5 s).
- **Demo mode** walks every path through `handleTapEvent` with synthetic events: throw, pause-throw, shake, Option release, right-click, hand drop, Trash, three forced sixes, natural rolls, Friday off/on, boredom. `DICE_DEMO_STEPS=a,b,...` picks steps. In demo mode without Accessibility, a hidden Dock shaped like the user's is simulated.

### Batch 3: Hot Hand (hidden five-dice game)

An original push-your-luck game in the folk "bank it or risk it" family. It is an easter egg:
nothing in the menus mentions it, and the name never appears in the app.

- **Getting in.** Hold Option while dragging the Dice tile off the Dock: a handful of five dice comes out. A plain drag or click still gives the single die, unchanged.
- **The dice.** Five standard dice, values 1–6, opposite faces summing to 7. Four use the current palette; one is the special die, always gold. Game dice use a constellation pip style (the standard pip positions as dots joined by hairlines). The special die's 1 face is the wild, drawn as an open ring. The single die and the Dock tile keep plain pips.
- **Scoring (Scoring.swift, pure functions).** Only the dice thrown this time count together. Each 1 scores 100, each 5 scores 50. Three or more of a face score face × 100 (1s: 1000), doubled for each die beyond three. The wild takes whichever value scores most: it joins a pair or extends a set, otherwise it is a 1. A throw with nothing scoring is a bust and the turn's points are lost. When all five dice have been kept they all come back and the turn carries on; banking is still allowed. No minimum to bank, no end goal, solo.
- **A turn.** Grab any live die and the live dice gather under the cursor as a loose handful; shake-to-rattle works; release throws them all. When they settle, scoring dice glow and slide into a row by the Dock edge above the Dice tile. Clicking a kept loose 1 or 5 hands it back (never the last die kept from a throw). Right-click any die, or drop the handful on the Dock, to bank. On a bust the dice dim and shuffle home.
- **Score display (Hud.swift).** A small pill beside the kept row shows the turn total. The banked total is the Dock tile's badge, stored in UserDefaults; the Dock menu shows "Reset Score" while it is above zero.
- **Existing extras in game mode.** Loaded die and hot-streak gold are off. The bored timer banks the turn and goes home. Dropping the handful on the Trash forfeits the turn.
- **Dice collide with each other, everywhere.**
  - Rolling dice are dynamic bodies in one category and collide normally.
  - Kept dice in the row carry a static, die-sized body, so thrown dice knock against the row instead of rolling through it. `.place` and `.hold` replace any non-dynamic body with a dynamic one when a die comes back into play.
  - Held dice are driven by setting their velocity each step, which cancels the physics solver's own separation, so a handful used to sink into itself. Held neighbours closer than 1.3 units are now pushed apart, and the handful ring is sized so neighbours rest about 1.35 apart.
  - Scripted animations (keep slide, shuffle home, the return into the Dock tile) have no physics body, so dice converging on the tile still pass through each other. That is deliberate: five dice are entering one tile.
  - With `DICE_DEBUG`, any pair of dice whose bodies intersect is logged as `SCENE OVERLAP`.
- **Engineering.** Per-die state lives in a `Die` object (node, visual child, mode, rest tracking); the scene holds an array, and commands, settle callbacks and hit tests carry a die index. `HandGame.swift` owns the turn; `Scoring.swift` has a launch self-check table in place of unit tests. The demo walkthrough has a `game` step that plays a full sequence with forced faces (marked DEMO-ONLY in the log).

### Dice styles

- **Choosing.** The Dock menu has a "Dice Style" submenu: Classic, Ancient, Glowing, Void, with a checkmark on the current one. The choice is stored in UserDefaults (`diceStyle`; demo mode uses `diceStyle.demo`) and applies at once: to a die already on screen, to all five game dice, and to the Dock tile. `DICE_STYLE=classic|ancient|glowing|void` overrides the stored choice at launch without changing it. The bundle icon stays classic.
- **The looks.** Classic is the original ivory die, unchanged.
  - *Ancient:* old bone. Warm off-white to tan with seeded mottling, speckle, pits and hairline scratches, darker worn edges, a larger chamfer (0.2 against 0.12), matte (lambert, no specular). Ring-and-dot pips (a drilled dot inside a scribed circle) in dark brown, each pip a little off in place and size, the same on every launch.
  - *Glowing:* dark, glassy resin body (depth gradient, tight highlight, a teal fresnel rim) with phosphor aqua-green pips drawn into an emission map, plus a faint glow along the face edges. On the table, a teal halo with a small contact shadow replaces the offset shadow. The halo is a drawn, normally blended radial image, deep enough in colour to read on a white desktop; no HDR, bloom or additive blending, nothing animated.
  - *Void:* flat black (lambert, no specular), small cold-white point pips and a faint cold rim at every face edge, both in the emission map, plus a weak fresnel tint so the side faces read while it tumbles. Shadow at about a fifth of normal.
- **Mechanism.** `DiePalette` (DieArt.swift) is now a whole look: colours plus surface kind, pip kind, emission colours, chamfer, tile corner radius, material finish (lighting model, specular, shininess, reflection) and floor (shadow strength, halo colour and size). `DieStyle` maps the menu choice to a look. `DiceScene.applySkin` applies every part of a look per die; textures, emission maps and floor images are cached. The Dock tile draws the same surface and pips on the rounded tile.
- **Combining.** Friday the 13th replaces Classic only; a chosen style wins over it. Hot-streak gold replaces any style while it lasts, then the style returns. The game's special die stays gold. The wink also removes a style's pip light (a Void rim stays). Looks with an emission map get the scoring glow as a warm-washed copy of their emission map (switched, not faded); dimming on a bust works through `multiply` as before.
- **Constellation pips (game).** Drawn in each style's pip colour. Ring-and-dot: the hairlines stop at the scribed circles instead of running through them, since a line through a ring reads as a crossed-out pip. Glowing and Void: the lines are lit as well, a little dimmer than the pips.
- **Debug.** The `SKIN` log line names the style; `STYLE` lines log each change and its cost. With `DICE_SNAPSHOT_DIR` the Dock tile image is also saved (`tile-face<N>-<look>.png`) each time it changes. The demo step `styles` (in the default walkthrough, after `friday-on`) picks each style through the Dock menu's own items, logs the checkmarks, saves `style-<name>-rest` and two mid-tumble snapshots (`style-<name>-tumble-a/b`) with a throw in each, then restores the launch style.

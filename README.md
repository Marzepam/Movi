<img width="974" height="423" alt="Screenshot 2026-10-23 at 11 33 08" src="https://github.com/user-attachments/assets/adc3eca8-5cab-4002-8a8d-a1b88adad36e" />
# Movi

A minimal, native macOS video editor in the style of the classic **Shave
Video** (something like VirtualDub on Windows). Written in Swift/SwiftUI +
AVFoundation, with no external dependencies.

The project (folders, the `project.yml` file, the Xcode target, the
entitlements, the Swift entry point `MoviApp`) is entirely named **Movi** —
not just the app's displayed name, but also the whole repo structure and
the bundle identifier (`com.movi.Movi`).

Version **2.0**. The "About Movi" window (menu Movi → About Movi) is
entirely custom (`AboutPanel.show()` in `MoviApp.swift`, called from
`EditorCommands`, replaces the default `CommandGroup(replacing: .appInfo)`)
— it shows only the version number and "Made by Marcin Lipiński", through
the same standard panel AppKit itself uses
(`NSApplication.orderFrontStandardAboutPanel(options:)`), just fed
different options instead of whatever it would default to from Info.plist.
It no longer includes the GNU GPL v3 license text — removed on request.

A large, full-app-window video view + a floating bar at the bottom with a
progress bar and buttons. Cutting is lossless wherever possible (re-mux via
`AVAssetExportSession` with the `Passthrough` preset, with no re-encoding
of the image).

The window is locked to the aspect ratio of the opened video, so the image
fills it completely, edge to edge, including the area under the (hidden)
title bar — with no black bars. This requires a two-part mechanism in
`ContentView`: `window.contentAspectRatio`/`window.minSize` (native AppKit
properties, set in `configureWindow`) **and** a custom `NSWindowDelegate` —
`WindowSizingDelegate` — whose `windowWillResize(_:to:)` recomputes and
clamps the target size (aspect ratio + minimum) on *every* resize,
regardless of whether it's a corner drag, the zoom button, or our own
`setFrame` call. Two mechanisms instead of one, because
`contentAspectRatio`/`minSize` alone correctly drive an interactive drag
(that part was never broken), but turned out not to be enough on their own
to keep a size set *programmatically* in place — see below. `install(on:)`
on the delegate doesn't replace the window's whole delegate, only attaches
itself to the existing one (forwarding on anything it doesn't itself
handle) — so it doesn't break anything SwiftUI already set on that
window's delegate.

This also applies to opening **another** video with a different
resolution/aspect ratio while one is already open (⌘O / the folder button
— not "append at end"): the window always re-fits itself fresh to the
material that was just opened, even if the previous video had a different
shape and the window already had a size set for it. This is distinguished
from edits to material already on the timeline (append/split/trim/undo),
which never yank a window the user has positioned themselves —
`EditorViewModel` itself tells the two cases apart via the
`openGeneration` counter, which only increments on an actual new file
open.

**Undo (⌘Z) also correctly re-fits the window** when the restored video
has a different shape than the one on screen before the undo — `undo()`
doesn't bump `openGeneration` (that's reserved exclusively for a fresh
file open, so an ordinary undo never yanks a window the user has
positioned themselves), so `openGeneration` alone wouldn't catch this.
`ContentView` therefore also keeps `lastAppliedAspectRatio` — the aspect
ratio the window was last actually resized for — and compares it against
the current video's aspect ratio on every `configureWindow` call (i.e.
also after `undo()`, since that changes the `videoSize` published by
`EditorViewModel`); a difference larger than a tenth of a percent forces a
fresh resize, exactly the same as on a new file open.

**Fullscreen mode** is handled separately: while the window is in native
fullscreen (`window.styleMask.contains(.fullScreen)`), `ContentView`
doesn't touch its geometry at all — neither `contentAspectRatio` nor its
size. Doing that to a fullscreen window doesn't scale its content the way
it does in a normal window — it instead shrinks the whole window down to a
small rectangle pinned to a corner, leaving the rest of the screen black —
which is exactly what made opening a new video in fullscreen show the
image (and the floating bar along with it) shrunk into a corner instead of
maximized. In fullscreen the window is therefore left untouched (it
already has the size of the whole screen), and `.resizeAspect` on
`VideoPlayerView` fits the video into the full screen on its own, aspect
ratio preserved (with bars if the aspect ratios don't match — natural in
fullscreen, since the screen itself can't be reshaped). The bar positions
itself against the same single, shared `GeometryReader` as the video, so
it always comes out centered and exactly 10% of the height up from the
bottom — the same in a normal window and in fullscreen. On exiting
fullscreen, the window gets a fresh fit to the current video (listening
for `NSWindow.didExitFullScreenNotification`), in case a differently
shaped video was opened in the meantime while in fullscreen.

Pinning down the actual cause of the black bars took a few attempts, but
in the end one specific observation cracked it: the window opened too
large (with black bars), but grabbing a corner with the mouse and dragging
it even a little made it immediately "snap" to the correct, video-fitting
size — and every subsequent resize already worked correctly. That means
interactive resizing (dragging a corner) always computed the size
correctly — the problem was strictly in our own **programmatic** call
(`window.setContentSize`, used previously). The most likely explanation:
SwiftUI's `WindowGroup` manages the window's size itself (fitting it to
the content by its own logic), and that management could simply overwrite
our `setContentSize` a moment later — something it doesn't do to
interactive resizing, since that goes through a different AppKit path.
Two changes close that gap:

1. `MoviApp` got `.windowResizability(.contentSize)` on the `WindowGroup`
   — this tells SwiftUI to hand control of the content's window size back
   (i.e. to our own properties/delegate on `NSWindow`), instead of
   continually recomputing the "right" size itself.
2. `applyWindowSize` computes the target size **directly from the opened
   video's own size** (`videoSize`, in pixels, scaled by a fixed factor of
   **1/2** — e.g. 1920×1080 opens as 960×540 — and clamped to a max of 90%
   of the screen / the minimum size), and applies it via
   `window.setFrame(_:display:animate:)` — the same primitive the native,
   correctly working interactive resize uses — instead of
   `setContentSize`.

The window's minimum size is computed directly from the floating bar's own
size (`FloatingControlBar.footprintSize` — 466×90pt): height = the bar's
height plus 10% of the window's height that the bar sits on
(`padding(.bottom, geo.size.height * 0.1)` in `body`) — i.e.
`barHeight / 0.9`. The width is **not** simply the bar's own width, but
`FloatingControlBar.minWindowWidth` = `barWidth * 1.2` — 20% wider, i.e.
10% of the bar's width as margin on each side. Without this, a narrow
(e.g. portrait) video could squeeze the window down to exactly the bar's
width, making the bar touch both window edges instead of "floating" above
the video with margin on each side. It's set both as `window.minSize`
(the native hint) and as `WindowSizingDelegate.minContentSize` — the
delegate is what actually and reliably enforces it, on every resize
attempt below that threshold, whether by mouse or programmatically.

On exiting fullscreen, where AppKit additionally still animates its own
return to the previous window frame for a moment (which could overwrite
our own computation shortly after), `applyWindowSize` is called a second
time, 0.35s later — it's idempotent (recomputing from an already-correct
size gives the same result), so the repeat doesn't break anything, it just
makes sure our computation is the one left standing.

Every fresh video open (a new file, not an edit to material already on the
timeline) also centers the window on whichever screen it's currently on,
after setting its size — by hand, against `screen.visibleFrame`, not via
`NSWindow.center()`: that method deliberately places a window a bit
*above* the screen's true center (Apple's own convention for dialog
windows), which read as "too high, not vertically centered". Computing the
center by hand gives exact centering in both dimensions.

**The green zoom button / "Fill & Arrange" menu** (holding down the green
button shows macOS's window-tiling menu — "Fill", "Center", moving to half
the screen, etc.) now works correctly with every option, on exactly the
same, simple aspect-ratio-enforcement mechanism that was there from the
start: `WindowSizingDelegate.windowWillResize(_:to:)` unconditionally
forces the video's exact aspect ratio onto *every* proposed size, and the
native `window.contentAspectRatio` property is kept continuously updated
to the video's real aspect ratio in `configureWindow`. Along the way there
was a stage where both of these mechanisms were deliberately relaxed (only
for zoom/tiling), on the theory that this was the only way to unlock the
rest of that menu's options — but using them in that version could hand
the window back a degenerate frame through AppKit's own internal tiling
machinery, which **crashed the app outright** (`CGRectContainsRect`
assertion, uncaught `NSException`). After reverting that change, back to
this simple, unconditional enforcement, the Fill & Arrange menu on its own
started correctly offering and honoring every option, with no crash — so
apparently it was *not* the hard aspect-ratio lock itself that was
limiting that menu before; relaxing it turned out to be both unnecessary
and unsafe.

**Auto-hiding the bar and window buttons on inactivity.** After 3 seconds
with no mouse movement inside the window, or immediately once the mouse
leaves the window, both fade out together (500ms): the floating control
bar and the window's own buttons (close/minimize/zoom) in the top-left
corner — leaving just the window with the video. Any mouse movement inside
the window (or simply hovering over it) brings both back with the same
500ms fade, and resets the 3-second inactivity timer. Implemented via
`.onContinuousHover` on the whole `ZStack` in `ContentView` — `.active`
(the mouse is moving in the window) shows both and resets the timer,
`.ended` (the mouse has left the window) hides them immediately, without
waiting out those 3 seconds, since that's a stronger signal than mere
inactivity. The bar itself hides via `.opacity` +
`.animation(.easeInOut(duration: 0.5))` on a SwiftUI `VStack` (with
`allowsHitTesting(false)` while hidden, so an invisible bar can't catch
clicks). The window's own buttons are native `NSButton`s
(`window.standardWindowButton(_:)`), which can only animate `alphaValue`
(not `isHidden`), so a separate function hides them via
`NSAnimationContext.runAnimationGroup` with the same duration — both
appear/disappear together.

**In fullscreen the bar hides/shows the same way, but the window's own
buttons — deliberately — don't.** With a hidden title bar
(`.hiddenTitleBar`), the close/minimize/zoom buttons in fullscreen aren't
an ordinary window element that can simply be shown by changing
`alphaValue` — macOS tucks them into its own, auto-revealing strip at the
very top of the screen (alongside the menu bar), governed by the cursor's
proximity to that edge, not by activity anywhere in the window. Trying to
take this over with our own logic doesn't make the buttons appear on an
ordinary mouse move — it only conflicts with the system's own handling of
that strip. `setWindowButtonsHidden` is therefore now a no-op in
fullscreen (`window.styleMask.contains(.fullScreen)`) — the floating bar,
which is a plain SwiftUI layer unrelated to window chrome, still
hides/shows exactly as in a normal window. To exit fullscreen, use Esc or
hold down the green button after hovering the top edge of the screen (the
Fill & Arrange menu works the same there as in a normal window — see
above).

**Exception: the bar doesn't hide while the mouse is resting on it.** The
3-second inactivity timer above still works the same way in the rest of
the window, but if, at the moment it fires, the cursor happens to be
resting directly on the floating bar itself, hiding is skipped and the
timer restarts — instead of the bar vanishing out from under the cursor
mid-click. Tracked via a plain `.onHover` directly on `FloatingControlBar`
(the `isHoveringFloatingBar` flag) — unlike `.onContinuousHover`, used for
the rest of the auto-hide logic (which only fires on actual mouse
movement), `.onHover` reliably signals entering/leaving the bar's bounds
even while the cursor sits perfectly still on it — which is exactly the
case (the mouse resting on the bar, unmoving, until the 3-second timer
fires) that needed catching. `scheduleAutoHide()` checks this flag right
before hiding; if the mouse is still on the bar, hiding is skipped and the
timer restarts, so the bar stays visible for as long as the cursor rests
on it. Leaving the bar (even to somewhere else in the window) is mouse
movement, so it immediately resets the normal 3-second timer via
`.onContinuousHover`/`showControls()` — after those 3 seconds of
inactivity away from the bar, it hides as usual. The window's own buttons
still hide together with the bar (unchanged), so in this one case they
also stay visible. The mouse leaving the window itself still hides both
immediately, with no wait — that rule is unchanged.

**Exiting fullscreen restores exactly the window position and size it had
before entering** — not a fresh, centered fit to the video, as before.
Previously, `configureWindow`/`applyWindowSize` ran unconditionally after
every fullscreen exit, so a window that had been manually moved and
resized snapped back every time to the default, screen-centered size —
exactly as if the video had just been opened. `ContentView` now remembers
the window's frame (`preFullScreenFrame`) at the moment fullscreen is
*entered* (`NSWindow.willEnterFullScreenNotification` — at that point
`window.frame` is still the ordinary windowed one, before the transition
animation), along with the video's aspect ratio at that moment
(`preFullScreenAspectRatio`). On exit
(`didExitFullScreenNotification`), it compares the current video's aspect
ratio against the remembered one: if they match (still the same-shaped
video — the common case), the window goes back exactly to the remembered
frame via `setFrame`, instead of a fresh fit. If they differ (a
differently shaped video was opened in the meantime, in fullscreen — see
the section on a different video in fullscreen above), the remembered
frame wouldn't match the new aspect ratio anyway, so in that one case the
app still does a fresh fit and centering, as before. Either way, the
second application of the same frame/size, delayed by 0.35s, remains as
the same insurance against a race with AppKit's own animation as before.

**Closing the window** (⌘W / the red button) doesn't quit the app — it
stays in the Dock/menu bar, same as most macOS apps, with no menu item or
Dock icon click to reopen a video window. Without extra handling,
`AVPlayer` would therefore just keep playing in the background, unseen and
unheard until the audio gave it away. `ContentView` listens for
`NSWindow.willCloseNotification` and pauses playback the moment the window
closes.

**Playback starts immediately when a video is opened.** `AVPlayer.rate` is
preserved across `replaceCurrentItem` calls — which is why opening another
video while the previous one was playing kept playing on its own (the
rate stayed at 1), but the very first video in a given session (rate
still at its initial 0) just sat there waiting for a manual press of
play. `open(url:)` in `EditorViewModel` now calls `player.play()`
explicitly, so every fresh open — first one included — behaves the same
way.

## Unsaved changes when opening a new video

Clicking the folder icon or ⌘O (opening a **new** video — not "append at
end", and not dragging a file onto an already-open video, since both of
those call `append(url:)`, not `open(url:)`, and never ask about saving)
first checks whether the current video has unsaved changes
(`EditorViewModel.hasUnsavedChanges`). If not — because it was just opened
and nothing has been edited yet, or because it's already been exported and
nothing has changed since — the new file opens immediately, with no
prompt. If so, `requestOpen(url:)` stashes the chosen file in
`pendingOpenURL` instead of opening it right away, which makes
`ContentView` show a system alert with three buttons:

- **Save** — opens the save panel (the same one ⌘E/the export button use)
  for the current video; the newly chosen file is dropped in the process —
  after saving (or after cancelling the save panel itself) the user stays
  on the same video, exactly as it was.
- **Discard** — discards the unsaved changes and opens the chosen file.
  `open(url:)` clears the undo stack in the process, so "Undo Edit" is
  immediately unavailable for the freshly loaded video — the previous
  file's edit history doesn't belong to it.
- **Cancel** — nothing happens: we stay on the current video exactly as it
  was, and the chosen file is never opened at all.

`hasUnsavedChanges` gets set to `true` on every editing action
(append/split/delete/trim/undo — all right after `pushUndoSnapshot()`/a
restore from the stack) and back to `false` after `open(url:)` (a freshly
opened file has no changes yet) and after a successful export in
`export(to:)`. It's a plain "something changed since the last open/save"
flag, not a deep comparison against the original timeline — undoing back
to exactly the same state still counts as "changed", which is what most
people intuitively expect from an "unsaved changes" flag anyway.

## Unsaved changes when closing the window

The same prompt (Save / Discard / Cancel) now also appears when closing
the window — the red button, ⌘W, or File ▸ Close Window — if the current
video has unsaved changes. All three ways of closing in AppKit ultimately
go through the same window-delegate method, `windowShouldClose(_:)`, so
one hook in `WindowSizingDelegate` (`shouldCloseHandler`) is enough for
all of them at once. When there's nothing to lose, the window closes
immediately with no prompt — as before.

- **Save** — opens the export panel; once saving finishes, the window
  closes itself (export is asynchronous, so it's `onChange(of:
  viewModel.hasUnsavedChanges)` that actually closes the window once it
  flips back to `false`). Cancelling the save panel itself leaves the
  window open.
- **Discard** — closes the window immediately, discarding the unsaved
  changes.
- **Cancel** — nothing happens, the window stays open.

## Export: default folder and filename

The save panel (⌘E, the export button, or "Save" from either prompt
above) now defaults to the folder the current video was loaded from, and
the source filename with a `_movi` suffix (e.g. `clip.mov` →
`clip_movi.mov`), instead of a fixed `export.mov` in whatever folder the
system last remembered. That source video is always the one opened via
⌘O/the folder button/a drop onto an empty window (`open(url:)`) — not
whatever file happens to be under the playhead — since that's what
establishes the project's identity; appending more clips at the end
doesn't change that.

## Startup window after relaunching the app

Previously, if the video window had been moved/resized and the app was
then fully quit and relaunched, macOS's own window-state restoration
mechanism ("Resume") remembered exactly that position/shape, and the
empty startup window ("Open Video…") would open right there, instead of
in its default shape centered on screen. `window.isRestorable = false`
turns that remembering off, and the first time the window is resolved
(`WindowAccessor`) it explicitly centers the empty startup window — so
every fresh launch of the app starts the same way, regardless of where
and how large the last opened video's window was.

## Independent video per tab

macOS counts this app toward the standard window-tabbing system, hence the
"Show Tab Bar"/"Add Tab" options in the View menu — that's system
behavior, not something this app deliberately adds or can turn off.
Previously, every tab edited exactly the same, single, shared video,
because `EditorViewModel` was a single instance owned by the whole app
(`MoviApp`).

For each tab to be able to hold an independent video, `EditorViewModel` is
now a `@StateObject` owned by `ContentView` — every window/tab (SwiftUI
creates a separate `ContentView` instance under the hood for a new tab)
gets its own instance. Menu commands (Open/Append/Export/Undo), which
previously called straight into one shared `viewModel`, now read the
currently focused/active window's `EditorViewModel` through SwiftUI's
`@FocusedValue` mechanism (`EditorCommands` in `MoviApp.swift`, fed by
`.focusedSceneValue(\.editorViewModel, viewModel)` in `ContentView`).
Keyboard shortcuts with no modifier (space, arrows, S, [, ]) are handled
by a separate, local event monitor in each window — a check for
`NSApp.keyWindow === hostWindow` was added there, so a shortcut always
reaches whichever window is actually active, rather than whichever
monitor happens to catch the event first.

Confirmed working on a live macOS system — every tab now holds its own,
independent video.

### Tab label = the name of the file being edited

Every tab/window shows the name of the video currently being edited (with
no extension) in the tab bar, and an empty tab (with no file loaded yet)
shows "No File". Even though the window has no visible title bar
(`.windowStyle(.hiddenTitleBar)`), `window.title` is still exactly what
macOS uses as each tab's own label in the tab bar — so setting it is
enough, even though it's never drawn anywhere in the window itself.

`updateWindowTitle()` in `ContentView` reads `segments.first?.sourceURL`
— the same source file whose name drives the default export filename (see
above) — so appending more clips at the end doesn't change the tab's
name; only a fresh open of a new video, or going back to an empty
timeline, changes it. Called the first time the window is resolved, on
every change to `videoSize` (covering, among other things, the
empty↔non-empty transition), and separately on every change to
`openGeneration` (covering a fresh open of a video with the same pixel
dimensions as the previous one — `videoSize` itself wouldn't change in
that case).

Independent video per tab has already been confirmed working; it's still
worth double-checking in Xcode that a new, empty tab's name actually shows
"No File" right away, and that it updates the instant a video is loaded
into it.

## Frame-step buttons

Directly on either side of the Play/Pause button on the floating bar are
two extra icons ("backward.frame.fill"/"forward.frame.fill") for moving
the playhead exactly one frame back/forward — the same ±1/30s step as the
left/right arrow keys (`ContentView.installKeyMonitor()`), just also
reachable with the mouse, for precisely finding a cut point.

**While playing, the first press only stops the video — it doesn't step a
frame yet.** A single frame's step is practically unnoticeable against a
video that's actually still in motion, so
`viewModel.stepOrPauseFromButton(seconds:)` checks `isPlaying`: if `true`,
it calls `togglePlayPause()` (just stopping, no step); only the next
press — now with the video actually paused — actually steps a frame
(`step(seconds:)`). The keyboard shortcuts (left/right arrows) aren't
affected by this and always step directly, without this intermediate
step — this behavior is specific to these two icons on the bar.

To fit the two extra icons without changing the bar's overall size
(`FloatingControlBar.barWidth`/`footprintSize` unchanged), row 1's (icons)
layout was rearranged: the "open video" icon (folder) — previously first
in the central icon group — moved out to its own slot at the bar's outer
left edge, directly above the current-time label in row 2 (where there
used to be just empty space reserved for its width). That freed up both
width and one icon from the central group, so the spacing between the
remaining icons (`controlIconSpacing`) could go back to the full 14pt
(even a bit more than before, given the group now has one fewer icon)
instead of the temporarily squeezed 6pt. The volume slider stays at the
bar's outer right edge (row 1's right margin is just the same
`rowSpacing`, 8pt, instead of the former `edgeWidth + rowSpacing`, 51pt) —
that remains a deliberate departure from the earlier alignment of its
right edge exactly under the duration label in row 2.

## Features

| Feature | How |
|---|---|
| Open video | ⌘O, the folder button, or drag a file onto the empty window |
| Append (add another video at the end) | ⌘⇧A, the button, or drag a file onto a window with a video already open |
| Split (at the playhead) | the **S** key, or the scissors button |
| Delete (remove a segment) | Backspace / Delete, or the trash button — deletes **only** the explicitly selected (yellow) segment; does nothing without a selection |
| Trim start (cut everything before the playhead) | the **[** key (no button on the bar) |
| Trim end (cut everything after the playhead) | the **]** key (no button on the bar) |
| Play / Pause | Space, or the play button |
| Step one frame back / forward | ← / → |
| Volume / mute | the volume slider on the bar (top, right side), or the speaker icon |
| Scrub | click or drag on the progress bar (bottom) — always moves playback, never selects |
| Select a fragment | click the thick mark under the progress bar (see below) |
| Undo last edit | ⌘Z |
| Export | ⌘E, the button — tries lossless (passthrough) mode first, falls back automatically to highest-quality re-encoding if sources aren't compatible; cancellable mid-export |

The bar is compact — a fixed width of 432pt (it doesn't stretch to the
full window width), centered, with its bottom edge 10% of the window's
height up from the bottom (not flush against the edge itself). The layout
and look follow QuickTime Player's style: the controls (volume and
progress) are a thin horizontal *line* — a `Capsule` with rounded ends, so
it reads as a line rather than a rectangular "bar" — with a round "ball"
knob (12pt) riding on it as a handle. The time (current/total) is set in
the plain system font, not a monospaced one. All of this sits on a
genuinely transparent background, though 10 percentage points less
transparent than before. The background is a plain alpha-blended fill
(`Color.black.opacity(0.4)`), not a system material/blur
(`NSVisualEffectView` / `.ultraThinMaterial`) — those sample whatever is
drawn behind them in the window, and the video layer from `AVPlayerView`
can composite in a way a live blur doesn't correctly pick up, which made
the bar look like a solid gray box instead of transparent regardless of
the material chosen. A plain opacity fill has no such problem — it's
ordinary alpha blending over whatever's underneath, video included, so
the video always actually shows through (dimmed) through the bar.

The top row groups the icons together (folder, append, scissors, trash,
play/pause, export) in the center, with the volume slider on the right —
its right end is aligned exactly with the right end of the progress bar in
the row below it (not with the duration label after it). The middle row
is time + the thin progress bar. Both sliders (volume and progress) share
the same minimalist look (a thin line + a white knob). The old trim
buttons (arrows) have been removed from the bar — trim now only works
from the keyboard ( **[** / **]** ).

Selecting fragments has been completely separated from the progress bar:
beneath it is a separate, third row with thick marks — one per fragment —
that only appears once there's more than one segment (i.e. after the
first cut, or after a second video is appended; a single piece spanning
the whole bar has nothing to show). A mark is white when its fragment
isn't selected, yellow when it is. **Clicking only works on these thick
marks, and only ever changes the color to yellow — nothing else.** The
marks are laid out in a plain `HStack` (one next to the other, in segment
order), not a `ZStack` with manual `.offset()` positions — that earlier
version could misattribute a click to the wrong segment, since a visible
area shifted via offset doesn't always line up with what's actually
clickable. With a plain horizontal layout, each mark's clickable area
always exactly matches what's drawn on screen, so a click always lands on
the right segment. The progress bar itself (the middle row) is now purely
for scrubbing: a click or drag anywhere on it always moves playback and
never selects a fragment — the two functions are physically split into
separate rows, so they can never be confused with each other. The trash
button acts **only** on the explicitly selected (yellow) segment: with
nothing selected, the trash button (and the Delete key) does nothing — it
doesn't delete the segment under the playhead or any other, so a fragment
can't accidentally be deleted without having been chosen. The scissors
(split) always act at the playhead — that's the natural cut point, and
selection plays no role here.

## Requirements

- macOS 14 (Sonoma) or newer — both for building and running
- Xcode 15 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional, see below)

## Building

### Option A — via XcodeGen (recommended)

```bash
brew install xcodegen   # if you don't have it
cd Movi
xcodegen generate
open Movi.xcodeproj
```

In Xcode, press **⌘R**.

### Option B — without XcodeGen

1. In Xcode: *File → New → Project… → macOS → App*, name it `Movi`,
   interface *SwiftUI*, language *Swift*.
2. Delete the generated default files (`ContentView.swift`, the `@main`
   file) and drag the whole `Sources` folder from this repo into the
   project (check "Create groups" and "Copy items if needed").
3. In the target's settings (*Signing & Capabilities*), enable *App
   Sandbox* and check *User Selected File → Read/Write* — or just add the
   `Movi.entitlements` file from this repo as the *Code Signing
   Entitlements*.
4. Set the *Deployment Target* to macOS 14.0.
5. ⌘R.

## Project structure

```
Movi/
├── README.md
├── project.yml                    ← project definition for XcodeGen
├── Info.plist                     ← explicit Info.plist (CFBundleDocumentTypes and other keys)
├── Movi.entitlements              ← App Sandbox + user-selected file access
└── Sources/
    ├── App/
    │   └── MoviApp.swift          ← entry point, menus (File/Edit) with shortcuts
    ├── Assets.xcassets/
    │   └── AppIcon.appiconset/    ← app icon (film reel + scissors)
    ├── Models/
    │   └── TimelineSegment.swift  ← a single timeline segment (a range within a source file)
    ├── ViewModels/
    │   └── EditorViewModel.swift  ← all editing state: segment list, AVPlayer, actions
    ├── Views/
    │   ├── ContentView.swift      ← main window: drag & drop, panels, keyboard shortcuts
    │   ├── VideoPlayerView.swift  ← NSViewRepresentable wrapping AVPlayerView
    │   └── FloatingControlBar.swift ← the floating bar: transport + scrubber with segment marks
    ├── Support/
    │   ├── VideoExporter.swift    ← building the AVMutableComposition + export (passthrough/re-encode)
    │   ├── CMTime+Format.swift    ← mm:ss time formatting
    │   └── Array+Safe.swift       ← safe subscript
    └── Resources/
        └── Localizable.xcstrings  ← String Catalog with translations for every interface string (pl → en/fr/de/es)
```

## "Open With" in Finder

Movi registers itself as an available app in Finder's "Open With" menu for
the same video file types its own Open panel already accepts
(`EditorViewModel.configureVideoPanel`: `.movie`/`.video`/`.mpeg4Movie`/
`.quickTimeMovie` — in practice covering `.mov`, `.mp4`, `.m4v`, and most
other QuickTime-readable containers). Done via `CFBundleDocumentTypes` in
the explicit, now checked-in `Info.plist` (the project had to move away
from Xcode's auto-generated Info.plist — `GENERATE_INFOPLIST_FILE: YES`
in `project.yml` — since that mode only supports flat string values via
`INFOPLIST_KEY_*`, and `CFBundleDocumentTypes` is a nested array/dict that
can't be expressed that way). `LSHandlerRank` is set to `Alternate` — Movi
shows up as an option in "Open With", but doesn't become the default app
for these file types; a plain, unopinionated "I can also open this"
registration, not a takeover of file associations.

Picking Movi this way (or double-clicking a file, if the user ever set
Movi as the default app) reaches `MoviApp`'s `.onOpenURL` — SwiftUI routes
the standard "open document" event there as a URL, for every type
declared in `Info.plist`, with no need to write a custom
`NSApplicationDelegate`. From there it goes straight to
`EditorViewModel.requestOpen(url:)` — exactly the same entry point as the
folder icon/⌘O — so if the app is already running and has unsaved changes
on the timeline, the same Save/Discard/Cancel prompt appears instead of
silently discarding the edits (see the section on unsaved changes above).

## How it works (architecture)

The timeline is just an array of `[TimelineSegment]` — each segment is
`(source file URL, time range within that file)`. No video data is copied
during editing:

- **Split** divides one segment into two, with the same `sourceURL` but
  different time ranges.
- **Delete** simply removes a segment from the array.
- **Trim** clips the first/last segment's range (or removes whole segments
  lying entirely before/after the playhead).
- **Append** adds a new segment (the whole newly opened file) at the end
  of the array.

After every change, the segment array is turned into a composition
(`VideoExporter.buildComposition`), which stitches the relevant ranges
from the source files into a single timeline — with no transcoding. The
same composition is used both for preview (`AVPlayer`) and for export.

### Mixed sources (different frame rate / frame size)

If every segment shares the same (orientation-corrected) frame size and
the same frame rate, `buildComposition` doesn't build any extra video
composition, and export tries `AVAssetExportPresetPassthrough` first
(a pure re-mux, zero quality loss, very fast) — exactly as before.

If instead **you combine sources with different resolutions and/or frame
rates**, the app **takes the first clip's size and frame rate as the
canonical ones** and builds an `AVMutableVideoComposition` that fits
(`fitTransform`) every following segment into that frame — aspect ratio
preserved, centered, with black bars (letterbox/pillarbox) wherever the
aspect ratios don't match, with no cropping — the bar color is set
explicitly (`instruction.backgroundColor = CGColor(gray: 0, alpha: 1)`),
so they're always black, regardless of AVFoundation's own default
behavior. This same effect already shows up in the preview
(`AVPlayerItem.videoComposition`), not only in the exported file.
Attaching a custom video composition forces re-encoding — passthrough is
skipped in this situation, since it can't apply per-segment transforms;
export then uses `AVAssetExportPresetHighestQuality`.

Since the fit is computed per segment (each clip's own
`preferredTransform`, rather than one transform for the whole track), this
also removes the former limitation with mixed-orientation clips — each
segment is now displayed with its own, correct orientation, as long as its
size differs enough from the first clip's to trigger this path (which in
practice covers nearly every case of differing orientation).

## Fixed bug: export hanging the app

An earlier version could "hang" during export. The cause was that the app
(running in the App Sandbox) never called
`startAccessingSecurityScopedResource()` on files added via drag & drop —
after some time the system would revoke access to such a file, and
`AVAssetExportSession`, instead of returning an error, would simply hang
indefinitely trying to read it. `EditorViewModel` now holds access open to
every source file for as long as some segment on the timeline still
references it. The export mechanism itself was also rewritten: the
progress poller now stops deterministically (rather than a loop waiting
on a status that, in rare cases, might never arrive), and export can now
be cancelled at any time with the "Cancel" button under the progress bar.

## App icon

The icon (a colorful film reel + blue scissors) lives in
`Sources/Assets.xcassets/AppIcon.appiconset`, generated from the supplied
image and saved at every size macOS requires (16–1024px, with @2x
variants). `project.yml` sets
`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`, so after `xcodegen
generate` Xcode wires it up automatically — nothing else to do.

## Fixed compiler warnings

Two Swift Concurrency warnings ("Main actor-isolated property … can not
be referenced/mutated from a Sendable closure") in `EditorViewModel` came
from the closure passed to `addPeriodicTimeObserver` — `AVPlayer` types
that handler as `@Sendable` regardless of the queue given, so even though
it actually always runs on `queue: .main`, the compiler couldn't infer
that. Fixed with an explicit `MainActor.assumeIsolated { … }` inside the
closure (with no extra `Task`, so no delay in updating playback time).

## About the console logs in Xcode while debugging

Xcode can print a whole page of logs while playing video from the App
Sandbox, in the style of: `Unable to get synchronousRemoteObjectProxy…
com.apple.linkd.autoShortcut`, `Error registering app with intents
framework`, `checkRichAnalysisAvailability XPC failed… Sandbox
restriction`, `Visual isTranslatable: NO`, `<<<< FigFilePlayer >>>>
signalled err=-12864`, `SetLoudnessFromLM: can't get audio mode from
session`, `cannot open file… DetachedSignatures`,
`(+[PPSClientDonation isRegisteredSubsystem:category:]) Permission
denied`, and similar. This is standard, harmless system/debugger noise —
it concerns services the sandbox (deliberately) doesn't grant access to:
Shortcuts/Intents registration (`linkd`), CoreMedia telemetry
(`PPSClientDonation`), image analysis/Live Text over the rendered video
(`checkRichAnalysisAvailability`) — plus internal, "handled" AVFoundation/
CoreAudio logs (`FigFilePlayer`, `AudioQueueObject`). It shows up in
practically every sandboxed AVFoundation app run from Xcode and has
nothing to do with Movi's own code, nor does it affect how the app
behaves — there's nothing to "fix" about it in the app's code, and no need
to. If it clutters the console, it's easiest to just filter it in Xcode
(the search field above the console).

## Known limitations

- Passthrough requires mutually compatible source formats; with mixed
  sources (see the section on mixed sources above) the app switches to
  re-encoding — export then isn't lossless anymore, but still works
  correctly and still fits the frame correctly.
- No project (session) saving/loading — this is a simple "open, cut,
  export" editor, not an NLE with projects.

## License

Code free to use and modify in any way — no further restrictions.

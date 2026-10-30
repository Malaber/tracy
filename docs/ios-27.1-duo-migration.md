# Moving a SwiftUI app to iPhone Duo

## Development baseline

Use **Xcode 27.1 and the iOS 27.1 SDK for all new iOS development**. Tracy pins
Xcode build `27A9275` in screenshot automation. This is a tooling baseline, not a
requirement to raise the deployment target: Tracy still supports iOS 17, with
availability checks for newer controls.

Select the installation once:

```sh
sudo xcode-select --switch /Applications/Xcode_27.1.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcodebuild -version
xcodebuild -checkFirstLaunchStatus
```

For a single shell or CI job, set
`DEVELOPER_DIR=/Applications/Xcode_27.1.app/Contents/Developer` instead.
Do not silently fall back to an older Xcode on CI.

### Keep the runtimes you actually need

SDK version and simulator runtime version are different. The installed iOS 27.1
runtime supports Duo only. Ordinary iPhone and iPad device types still need the
27.0 runtime when testing with Xcode 27.1:

| Capture profile | Runtime build | Native screenshot pixels |
| --- | --- | --- |
| iPhone 18 Pro | iOS 27.0, `24A434` | 1206 × 2622 |
| iPad Pro 13-inch (M5) | iOS 27.0, `24A434` | 2064 × 2752 |
| Duo closed, outer screen | iOS 27.1, `24A94232` | 1398 × 2034 |
| Duo open, inner screen, landscape | iOS 27.1, `24A94232` | 2853 × 2007 |

Install the exact runtime builds, then inspect `xcrun simctl list runtimes --json`
and each runtime's supported device types before deleting older runtimes.

```sh
xcodebuild -downloadPlatform iOS -buildVersion 24A434 -architectureVariant arm64
xcodebuild -downloadPlatform iOS -buildVersion 24A94232 -architectureVariant arm64
```

Delete obsolete archives, downloaded installers and disposable DerivedData only
after the new installation builds successfully. Preserve signing credentials,
release archives needed for symbols, and simulator data you still use. Removing
27.0 just because 27.1 is installed currently breaks iPhone/iPad test coverage.

## Migrate the interface

1. Use native `TabView`, `NavigationStack`, `NavigationSplitView`, `List`, `Form`,
   sheets and toolbars. The system adapts navigation to the active display.
   Give toolbar actions both a title and SF Symbol; use semantic placements.
2. Design from available space and size classes, not device names, idiom checks,
   fixed screen dimensions or an assumption that all phones are narrow.
   Tracy uses a split Today layout at regular width and a single scrolling list
   at compact width or accessibility text sizes. Explicitly use a title-and-icon
   label style for content: a sidebar can otherwise change inherited label presentation.
3. Keep shared app state and sheet presentation above layout branches. Opening
   the device must not discard an entry, selection or pending offline mutation.
4. Keep content cards opaque with semantic backgrounds. Reserve Liquid Glass
   for navigation and controls. Let system containers handle safe areas and
   fold-related layout; do not paint a custom tab bar over content.
5. Use adaptive stacks for competing headline/status content. Switch controls
   to vertical layouts at accessibility text sizes; do not compress button labels.
   Supply both title and SF Symbol for toolbar buttons. On Duo's vertical bar,
   text-only Save/Cancel actions can move into overflow or disappear from direct
   automation queries. Use `cancellationAction` for Cancel and, on iOS 27+,
   `topBarPinnedTrailing` for Save. Retain `confirmationAction` on older systems.
   Verify these controls after scrolling a sheet and with the keyboard visible.
6. Scale typography and avoid fixed-height text rows. Give icon-only controls
   VoiceOver labels. Pair status colors with text and symbols; verify light,
   dark, Increase Contrast, Reduce Transparency and accessibility text sizes.
7. Consider `ArrangementView` on iOS 27.1 only if your content needs independent
   fold-aware split/overlay regions. Do not nest it casually inside another
   scroll or navigation layout. A native split view is sufficient for Tracy.

Apple references: [Prepare for Duo](https://developer.apple.com/iphone-duo/prepare/),
[Duo Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo),
[Technology overview](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo),
[Apple's Duo talk](https://developer.apple.com/videos/play/tech-talks/111461/),
[Raise the bar with Duo](https://developer.apple.com/videos/play/tech-talks/111462/).

## Automate real screenshots

Use a fresh simulator for each device/display profile, stable fixture data,
fixed locale, appearance and status-bar time. Build with the same Xcode used for
release. Capture the actual application, not a resized screenshot or mockup.
Run Xcode build/test jobs sequentially when they share a local Swift package.
Keep DerivedData outside the Swift package directory; generated files under the
package root can trigger repeated resolution. Tracy puts build outputs under
`e2e-artifacts/`, and native jobs run sequentially.

Tracy's entrypoint:

```sh
.codex/setup.sh --ios
.venv/bin/inv capture-ios-screenshots
# Focused iteration, same capture pipeline:
.venv/bin/python scripts/capture_ios_screenshots.py --version 0.2.8 --device iphone-duo-inner
```

The GitHub screenshot workflow includes both Duo displays plus iPhone and iPad.
Ten scenes cover Today, editing, Recent Days, pending sync, dark mode,
Statistics, Settings, an empty day, a completed day and the month forecast. Packaging rejects missing,
duplicate, failed, black or incorrectly sized images and produces opaque PNGs
with a manifest and hashes.

Duo has two displays. Powering the inner screen via `simctl io screenConfig`
alone does **not** open the hinge; it can produce a black frame. Our simulator-only
`scripts/duo_hinge.m` sends the hinge input event used by
[Appium's Duo support](https://appium.github.io/appium-xcuitest-driver/latest/guides/duo/).
The capture script compiles and runs it inside the simulator: 0° for closed,
180° for open. This helper uses simulator-specific interfaces and must never be
linked into or shipped with an App Store app. Its failure should fail capture,
not silently substitute an outer-screen image. XCTest's image API rounds the inner panel's odd dimensions down by one pixel.
For inner captures, a temporary localhost server runs `simctl io screenshot
--display=primary-1` exactly when the UI test requests each scene. The test waits
for that PNG and attaches its original bytes. The ephemeral port is injected
into the test bundle only; neither server nor capture code ships in the app.
The screenshot packager still requires full native dimensions.

## Review before release

Inspect screenshots at readable size, not just dimensions. Check billable total,
status, break deduction, goal and primary action first. Check scrollable content
is not hidden under navigation; forms, lists and secondary screens must follow
the same spacing and typography. Look for truncated statuses and oversized empty
space on the inner display.

Exercise closed → open → partially folded → closed while editing and while a
session is running. Check selection, draft, focus, sheets and scroll position.
Tracy's inner-display capture test also opens an editor during an active session,
types an unsaved note, and changes the hinge through 0°, 180°, 90°, 180°, and 0°.
It waits for the real display-size transition, verifies the draft and Save action,
then saves and checks that the session remains active. Pose evidence is packaged
under `review/duo-transitions`, separately from the forty App Store scenes.
The hinge bridge runs only on localhost inside the test setup; it is absent from
the production app. Static screenshots alone do not establish that transitions
preserve state. The native contrast
service can report text partially hidden by floating system bars. Recheck such rows
fully onscreen; never discard a visible contrast failure. Tracy uses a fresh app launch
per audited viewport, with deterministic scrolling, and a deliberately low-contrast
control to ensure real failures remain detectable. Account for top-aligned iPad tabs,
vertical Duo tabs, and navigation bars belonging to separate columns; one column's
bar must not mark the other column's content as obscured. Audit findings can identify
buttons as well as text, so preserve the reported element's identity when rechecking.
Add UI
assertions for important transitions and run VoiceOver/accessibility audits with
large text separately from normal-size marketing screenshots.

Run local tests and fix failures before archiving. Upload the exact reviewed
source revision to TestFlight. Keep CI screenshot artifacts for review; do not
claim a GitHub run or Apple processing completed merely because a push/upload
was accepted.

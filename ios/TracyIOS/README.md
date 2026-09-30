# Tracy Time Tracking for iOS

A native SwiftUI iPhone/iPad client focused on recording time and reviewing recent days.

- **App name:** Tracy Time Tracking
- **Bundle ID / App Store Connect SKU:** `de.malaber.tracy`
- **Deployment target:** iOS 17; native Liquid Glass controls on iOS 26 and newer
- **Signing team:** `VWKG94374J`, matching Planini and Hiinterval (override for your own builds)
- **Default server:** `https://tracy.malaber.de`; another HTTPS origin can be selected at sign-in

## Build and test

From the repository root, run `.codex/setup.sh` first. Install Xcode 26 or newer and XcodeGen, then:

```sh
.venv/bin/inv check-ios-package
.venv/bin/inv generate-ios-project
.venv/bin/inv build-ios-simulator
.venv/bin/inv check-ios-ui --destination='platform=iOS Simulator,name=iPhone 17 Pro'
```

Open `ios/TracyIOS/TracyApp.xcodeproj` and select the **Tracy** scheme. The project is generated
from `project.yml`. UI tests use an isolated local fixture, never a production account.
The Swift package covers validation, date handling, journal persistence, lost-response retries,
ordered updates, conflict resolution, and recovery after restarting.

## Daily use

**Today** provides check-in/check-out and an editable native form. **Recent Days** shows two weeks,
with a needs-attention filter for missing, unfinished, and below-target days, and can open any earlier date. Calendar classifications come from
the server: weekends, German holidays, and personal days off do not become false missing-entry
warnings. Completed means an entry is present; it does not assert that its hours are correct.
**Statistics** shows server-calculated exact/billable time and full-period targets.

Forms support time pickers, overnight checkout, multiple duration/range breaks, and notes.
When first completing a span longer than 4½ hours with no breaks, the same 30-minute default break
as the web app is added. It remains visible and editable, including while offline.

System, light, and dark appearance are available in Settings. The app uses semantic colors,
Dynamic Type, standard navigation/forms/sheets, labeled controls, and text plus symbols for status.
Liquid Glass is used for navigation and primary actions through native system components; iOS 17–25
uses standard bordered buttons. There are no custom looping animations. System accessibility
settings control motion, contrast, and transparency.

## Offline entry and sync

Sign in once while online. The app stores its server timezone, downloaded entries/calendar, and a
persistent mutation journal in Application Support, separately for each server/account. Credentials
are in Keychain. Journal writes are atomic and protected with iOS file protection; disk failures are
reported instead of claiming an entry was saved. A damaged journal is not silently overwritten.

- Check-in, check-out, corrections, breaks, and notes can be saved without connectivity.
- Pending entries remain editable and survive closing or restarting the app.
- Mutations are sent in order. They use original entry revisions and stable idempotency IDs.
- A lost response is retried with the same ID. Later edits cannot overtake an uncertain save.
- New server changes produce a conflict rather than being overwritten. Review both versions and
  explicitly keep the offline entry or the server entry. Other days continue syncing.
- Entries with server validation errors stay on the device and can be corrected.
- An expired session preserves the journal and asks for sign-in to the same account.
- Signing out or switching accounts is blocked while entries remain unsynced.
- Uncached days can be entered offline; if they already exist on the server, syncing asks you to
  resolve the conflict. Calendar information not downloaded yet is labeled as unavailable.

Sync retries on network restoration while the app is running, on foregrounding, every minute while
active, and through pull-to-refresh or Sync now. iOS does not guarantee execution while an app is
suspended or terminated: reopen Tracy to finish sync. Statistics require connectivity and explicitly
exclude pending edits; totals are calculated by the server after syncing. Offline times use the
configured server timezone and the device clock, so correct device date/time matters.

## Server deployment and authentication

Deploy the backend changes in this branch before using the app. Startup applies migrations
`0004_mobile_authorization` and `0005_entry_sync_revisions`. Older mobile clients and the web app can
still use existing entry routes without conditional headers.

Sign-in uses `ASWebAuthenticationSession` with the existing web passkey registration/login pages,
so self-hosted HTTPS origins do not need app-specific associated-domain entitlements. The fixed
callback is `de.malaber.tracy://auth`. It carries only a short-lived single-use code and random state.
An S256 PKCE verifier is required to exchange the code. Codes are stored hashed, consumed atomically,
and expire after two minutes. Tokens never appear in callback URLs. Native bearer tokens have a
server session and are revoked by the app's logout endpoint. Normal server token/session expiry
and inactive-account checks still apply.

The existing `APP_BASE_URL`, `WEBAUTHN_RP_ID`, `SECRET_KEY`, and `SECURE_COOKIES` configuration must
match the public HTTPS deployment. Production web passkey sign-in must work before mobile sign-in
can work. Verify actual passkey registration/login on a signed physical device before distribution.

## App Store delivery

The source includes a layered light/dark app icon derived from Tracy's existing vector mark and a
privacy manifest for local appearance preferences and account/work data used by the server. No App Store record has been created or uploaded
by this implementation. Create an iOS record named **Tracy Time Tracking**, using **de.malaber.tracy**
for both SKU and bundle ID. Confirm signing, complete privacy disclosures for account identifiers
and user-entered work data stored on the chosen server, provide a privacy policy/support URL,
capture iPhone/iPad screenshots, and archive in Xcode for TestFlight. Set release versions through
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.

The native controls follow [Apple’s Liquid Glass guidance](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass). Authentication uses [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession).

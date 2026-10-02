# Review accounts and manual passkey recovery

Tracy uses real accounts and passkeys for review, not a password or simulated native demo.
The administrator can create an account and issue a one-time **additional passkey** link,
following Planini's workflow. Existing keys and work data are preserved. Email delivery is
not implemented.

## Enable administration

Register your own account normally. On the server, grant that exact existing account access:

```sh
docker compose exec app python -m app.services.admin_access you@example.com
```

For a source checkout, use `.venv/bin/inv set-admin --email=you@example.com`.
Append `--revoke` to remove administrator access. New accounts are never administrators.
Sign in normally, then select **Admin** or open `/admin`. Each request checks the current
account's administrator status; issuing links requires a session-bound form token.

## Prepare Apple's review account

1. In `/admin`, create a dedicated non-admin account, with an email you control.
2. Generate a passkey link for that account. The default expiry is 24 hours; choose up to
   720 hours (30 days) if needed for review scheduling. The full URL is displayed only once.
3. Open this first link in a separate browser profile and register your preparation passkey.
   Populate the account normally with useful recent entries, breaks, notes, and days off.
4. Back in your administrator profile, generate a **new** link for Apple. Do not redeem it
   yourself. Merely opening the page does not consume it; successful passkey creation does.
5. Put that link and instructions below in Beta App Review Information/review notes. Provide
   a separate fresh link if another reviewer needs to enroll a key or the original expires.

Suggested review notes (replace placeholders):

> Tracy uses passkeys; it has no username/password sign-in. Open [ENROLLMENT LINK] on your
> review device in Safari and select “Create passkey”. Save the passkey to access our
> prepared review account. Then open Tracy Time Tracking, keep the server set to
> https://tracy.malaber.de, and select “Sign in with passkey” using the saved key. This is a
> normal account with all time-entry, recent-day, statistics, and offline-sync features.
> The enrollment link is single-use and expires [UTC DATE/TIME]. After enrollment, use the
> saved passkey for subsequent sign-ins. Contact tracy@schaedler.rocks if another enrollment
> link is needed.

Account deletion also works for the review account. If the reviewer deletes it, create and
prepare a replacement account and provide a fresh link. This implementation does not submit
review notes or change App Store Connect configuration automatically.

## Manual recovery

After verifying the user's identity outside Tracy, generate an additional-key link for the
existing account and deliver it manually through a trusted channel. After enrollment, the
user can remove lost keys through **Passkeys**, with confirmation using their new key.
Issuing a link does not delete existing keys, revoke sessions, or send email.

Treat enrollment URLs like credentials: anyone holding a valid link can access that account.
The database stores only a SHA-256 hash of a random 256-bit token. Consumption and key creation
are one database transaction. Expired, revoked, used, or inactive-account links cannot enroll.
Use **Revoke** in `/admin` to cancel a pending link. Issuer, creation time, expiry, and final
state remain visible; raw URLs cannot be retrieved again. Avoid storing enrollment paths in
reverse-proxy/access logs. Enrollment/admin pages disable caching and referrer forwarding.

## Release version

`RELEASE_MINIMUM` sets this feature release to **0.2.0**. CI and untagged native builds use
that floor alongside existing Git tags. Once v0.2.0 exists, the usual patch sequence resumes
at 0.2.1; native builds on a release tag always use that tag's version.

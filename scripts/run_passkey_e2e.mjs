import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import fsSync from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import { createVirtualAuthenticator } from "@malaber/fastpasskey/playwright";
import { chromium } from "playwright";

const baseUrl = process.env.PREVIEW_BASE_URL ?? "http://localhost:8000";
const artifactDir = process.env.PREVIEW_ARTIFACT_DIR ?? "e2e-artifacts/passkey";
const browserChannel = process.env.E2E_BROWSER_CHANNEL?.trim() || undefined;
const flowLog = path.join(artifactDir, "flow.log");

function log(message) {
  console.log(`[passkey-e2e] ${message}`);
  fsSync.appendFileSync(flowLog, `${new Date().toISOString()} ${message}\n`);
}

function waitForPost(page, pattern) {
  return page.waitForResponse((response) => {
    const request = response.request();
    return request.method() === "POST" && pattern.test(new URL(response.url()).pathname);
  });
}

async function assertRegistrationOptions(response, excludedCredentials = 0) {
  assert(response.ok(), `Registration options failed with ${response.status()}`);
  const options = await response.json();
  assert.equal(options.authenticatorSelection?.residentKey, "required");
  assert.equal(options.authenticatorSelection?.userVerification, "required");
  assert.equal(options.excludeCredentials?.length ?? 0, excludedCredentials);
}

async function assertAuthenticationOptions(response, allowedCredentials) {
  assert(response.ok(), `Authentication options failed with ${response.status()}`);
  const options = await response.json();
  assert.equal(options.userVerification, "required");
  if (allowedCredentials === undefined) {
    assert.equal(options.allowCredentials?.length ?? 0, 0);
  } else {
    assert.equal(options.allowCredentials?.length, allowedCredentials);
  }
}

async function main() {
  await fs.mkdir(artifactDir, { recursive: true });
  const browser = await chromium.launch(browserChannel ? { channel: browserChannel } : {});
  const context = await browser.newContext({ viewport: { width: 1280, height: 960 } });
  const page = await context.newPage();
  page.setDefaultTimeout(15_000);
  page.setDefaultNavigationTimeout(15_000);
  const authenticator = await createVirtualAuthenticator(context, page, {
    ctap2Version: "ctap2_1",
    transport: "usb",
  });

  try {
    log("Registering account with real WebAuthn ceremony");
    await page.goto(new URL("/", baseUrl).toString(), { waitUntil: "networkidle" });
    await page.waitForURL(/\/login(?:\?|$)/);
    await page.locator('[data-auth-tab-trigger="signup"]').click();
    await page.locator('[data-passkey-register] input[name="display_name"]').fill("E2E Worker");
    await page.locator('[data-passkey-register] input[name="email"]').fill("e2e@example.com");
    const registerOptions = waitForPost(
      page,
      /\/api\/v1\/auth\/register\/options$/,
    ).then((response) => assert(response.ok(), "Registration options request should pass"));
    const initialEntry = page.waitForResponse((response) =>
      response.request().method() === "GET" && /\/api\/v1\/entries\/\d{4}-\d{2}-\d{2}$/.test(response.url())
    ).then((response) => assert(response.ok(), "Initial protected entry request should pass"));
    await Promise.all([
      page.waitForURL(new URL("/", baseUrl).toString()),
      registerOptions,
      initialEntry,
      page.locator('[data-passkey-register] button[type="submit"]').click(),
    ]);
    await page.getByRole("heading", { name: "Track your working day" }).waitFor();

    log("Saving protected tracker data");
    await page.locator("#checkIn").fill("08:00");
    await page.locator("#checkOut").fill("09:00");
    await page.locator("#notes").fill("Passkey e2e entry");
    const saveResponse = page.waitForResponse((response) =>
      response.request().method() === "PUT" && /\/api\/v1\/entries\//.test(response.url())
    );
    await page.locator("#saveEntry").click();
    const saved = await saveResponse;
    assert(saved.ok(), `Protected tracker save failed: ${saved.status()} ${await saved.text()}`);

    log("Marking and removing a vacation date range");
    const trackedDate = await page.locator("#workDate").inputValue();
    const followingDate = new Date(`${trackedDate}T00:00:00Z`);
    followingDate.setUTCDate(followingDate.getUTCDate() + 1);
    const followingDateISO = followingDate.toISOString().slice(0, 10);
    await page.locator("#vacationAction").click();
    await page.locator("#vacationDialog").waitFor({ state: "visible" });
    assert.equal(await page.locator("#vacationStart").inputValue(), trackedDate);
    assert.equal(await page.locator("#vacationEnd").inputValue(), trackedDate);
    await page.locator("#vacationEnd").fill(followingDateISO);
    await page.screenshot({
      path: path.join(artifactDir, "vacation-range-dialog.png"),
      fullPage: true,
    });
    const markVacationResponse = page.waitForResponse((response) =>
      response.request().method() === "PUT"
      && new URL(response.url()).pathname === "/api/v1/days-off"
    );
    await page.locator("#confirmVacation").click();
    const markedVacation = await markVacationResponse;
    assert(
      markedVacation.ok(),
      `Vacation range save failed with ${markedVacation.status()}`,
    );
    assert.deepEqual((await markedVacation.json()).days_off, [trackedDate, followingDateISO]);
    await page.waitForFunction(
      () => document.querySelector("#dayStatus")?.textContent?.includes("Vacation"),
    );

    const followingEntryResponse = page.waitForResponse((response) =>
      response.request().method() === "GET"
      && new URL(response.url()).pathname === `/api/v1/entries/${followingDateISO}`
    );
    await page.locator("#nextDay").click();
    assert((await followingEntryResponse).ok(), "Vacation range should include the following date");
    await page.waitForFunction(
      (expectedDate) =>
        document.querySelector("#workDate")?.value === expectedDate
        && document.querySelector("#dayStatus")?.textContent?.includes("Vacation"),
      followingDateISO,
    );

    await page.locator("#vacationAction").click();
    await page.locator("#vacationStart").fill(trackedDate);
    const removeVacationResponse = page.waitForResponse((response) =>
      response.request().method() === "DELETE"
      && new URL(response.url()).pathname === "/api/v1/days-off"
    );
    await page.locator("#removeVacation").click();
    await page.getByRole("button", { name: "Confirm remove 2 dates" }).click();
    const removedVacation = await removeVacationResponse;
    assert(
      removedVacation.ok(),
      `Vacation range removal failed with ${removedVacation.status()}`,
    );
    await page.waitForFunction(
      () => !document.querySelector("#dayStatus")?.textContent?.includes("Vacation"),
    );

    log("Adding and renaming passkey on second authenticator");
    await page.goto(new URL("/security", baseUrl).toString(), { waitUntil: "networkidle" });
    assert.equal(await page.locator(".passkey-row").count(), 1);
    await authenticator.replace();
    await page.getByRole("button", { name: "Add another" }).click();
    await page.locator("[data-passkey-name-input]").fill("Work laptop");
    const addOptions = waitForPost(page, /\/api\/v1\/auth\/passkeys\/register\/options$/);
    await page.getByRole("button", { name: "Continue", exact: true }).click();
    await assertRegistrationOptions(await addOptions, 1);
    await page.locator(".passkey-row").nth(1).waitFor();

    let managedRow = page.locator(".passkey-row", { hasText: "Work laptop" });
    await managedRow.getByRole("button", { name: "Rename" }).click();
    await page.locator("[data-passkey-name-input]").fill("Phone");
    const renameOptions = waitForPost(page, /\/rename\/options$/);
    await page.getByRole("button", { name: "Save and verify" }).click();
    await assertAuthenticationOptions(await renameOptions, 1);
    managedRow = page.locator(".passkey-row", { hasText: "Phone" });
    await managedRow.waitFor();

    log("Logging out and signing back in with discoverable credential");
    await Promise.all([
      page.waitForURL(/\/login(?:\?|$)/),
      page.getByRole("button", { name: "Sign out" }).click(),
    ]);
    const protectedStatus = await page.evaluate(async () =>
      (await fetch("/api/v1/preferences")).status,
    );
    assert.equal(protectedStatus, 401);
    const loginOptions = waitForPost(
      page,
      /\/api\/v1\/auth\/login\/options$/,
    ).then((response) => assert(response.ok(), "Login options request should pass"));
    await Promise.all([
      page.waitForURL(new URL("/", baseUrl).toString()),
      loginOptions,
      page.getByRole("button", { name: "Sign in with passkey" }).click(),
    ]);
    await page.locator("#notes").waitFor();
    await page.waitForFunction(
      () => document.querySelector("#notes")?.value === "Passkey e2e entry",
    );

    log("Deleting original passkey after confirmation with second passkey");
    await page.goto(new URL("/security", baseUrl).toString(), { waitUntil: "networkidle" });
    const originalRow = page.locator(".passkey-row").filter({ hasNotText: "Phone" });
    await originalRow.getByRole("button", { name: "Delete" }).click();
    const deleteOptions = waitForPost(page, /\/delete\/options$/);
    await page.getByRole("button", { name: "Continue to verification" }).click();
    await assertAuthenticationOptions(await deleteOptions, 1);
    await page.waitForFunction(() => document.querySelectorAll(".passkey-row").length === 1);
    const remainingRow = page.locator(".passkey-row", { hasText: "Phone" });
    await remainingRow.waitFor();
    assert(!(await remainingRow.innerText()).includes("{date}"));
    assert(!(await page.locator("[data-passkey-name-form]").isVisible()));
    await page.screenshot({ path: path.join(artifactDir, "passkey-flow.png"), fullPage: true });
    log("Admin creates review account and one-time passkey links");
    // Server operator bootstrap, against this task's disposable database only.
    execFileSync(process.env.E2E_PYTHON, ["-m", "app.services.admin_access", "e2e@example.com"], { env: process.env });
    await page.goto(new URL("/admin/user/list", baseUrl).toString());
    await page.getByRole("link", { name: /New Account/ }).click();
    await page.getByLabel("Email", { exact: true }).fill("apple-review@example.com");
    await page.getByLabel("Display Name", { exact: true }).fill("Apple Review");
    await Promise.all([
      page.waitForURL(new URL("/admin/user/list", baseUrl).toString()),
      page.getByRole("button", { name: "Create account", exact: true }).click(),
    ]);
    const reviewRow = page.locator("tbody tr", { hasText: "apple-review@example.com" });
    await reviewRow.waitFor();
    const detailsURL = await reviewRow.locator('a[href*="/details/"]').getAttribute("href");
    await page.goto(new URL(detailsURL, baseUrl).toString());
    await page.getByRole("button", { name: "Create passkey link", exact: true }).click();
    const firstLink = await page.locator("#generated-link").inputValue();
    const reviewerContext = await browser.newContext();
    const reviewerPage = await reviewerContext.newPage();
    const reviewerKey = await createVirtualAuthenticator(reviewerContext, reviewerPage, {
      ctap2Version: "ctap2_1", transport: "usb",
    });
    await reviewerPage.goto(firstLink);
    await Promise.all([
      reviewerPage.waitForURL(new URL("/", baseUrl).toString()),
      reviewerPage.getByRole("button", { name: "Create passkey", exact: true }).click(),
    ]);
    assert.equal((await reviewerContext.request.get(new URL("/admin/user/list", baseUrl).toString())).status(), 403);
    const preparedEntry = new URL("/api/v1/entries/2026-01-06", baseUrl).toString();
    assert.equal((await reviewerContext.request.put(preparedEntry, {
      data: { check_in: "08:00", check_out: "17:00", notes: "Prepared review data" },
    })).status(), 200);
    await reviewerContext.request.post(new URL("/logout", baseUrl).toString());
    assert.equal((await reviewerContext.request.get(firstLink)).status(), 404);
    await page.goto(new URL(detailsURL, baseUrl).toString());
    await page.getByRole("button", { name: "Create passkey link", exact: true }).click();
    const appleLink = await page.locator("#generated-link").inputValue();
    await reviewerKey.replace();
    await reviewerPage.goto(appleLink);
    await Promise.all([
      reviewerPage.waitForURL(new URL("/", baseUrl).toString()),
      reviewerPage.getByRole("button", { name: "Create passkey", exact: true }).click(),
    ]);
    assert.equal((await (await reviewerContext.request.get(preparedEntry)).json()).notes, "Prepared review data");
    await reviewerPage.goto(new URL("/security", baseUrl).toString());
    await reviewerPage.locator(".passkey-row").nth(1).waitFor();
    assert.equal(await reviewerPage.locator(".passkey-row").count(), 2);
    await reviewerContext.request.post(new URL("/logout", baseUrl).toString());
    await reviewerPage.goto(new URL("/login", baseUrl).toString());
    await Promise.all([
      reviewerPage.waitForURL(new URL("/", baseUrl).toString()),
      reviewerPage.getByRole("button", { name: "Sign in with passkey", exact: true }).click(),
    ]);
    const reviewVerifier = randomBytes(32).toString("base64url");
    const reviewAuthorization = await reviewerContext.request.get(new URL("/api/v1/auth/mobile/authorize", baseUrl).toString(), {
      params: { state: randomBytes(32).toString("base64url"), code_challenge: createHash("sha256").update(reviewVerifier).digest("base64url") }, maxRedirects: 0,
    });
    assert.equal(reviewAuthorization.status(), 303);
    const reviewCode = new URL(reviewAuthorization.headers().location).searchParams.get("code");
    const reviewExchange = await reviewerContext.request.post(new URL("/api/v1/auth/mobile/token", baseUrl).toString(), {
      data: { code: reviewCode, code_verifier: reviewVerifier },
    });
    assert.equal(reviewExchange.status(), 200);
    const reviewNativeEntry = await reviewerContext.request.get(preparedEntry, {
      headers: { Authorization: `Bearer ${(await reviewExchange.json()).access_token}` },
    });
    assert.equal((await reviewNativeEntry.json()).notes, "Prepared review data");
    await page.goto(new URL(detailsURL, baseUrl).toString());
    await page.getByRole("button", { name: "Create passkey link", exact: true }).click();
    const revokedLink = await page.locator("#generated-link").inputValue();
    const linkID = new URLSearchParams(new URL(revokedLink).hash.slice(1)).get("identifier");
    assert.match(linkID, /^[0-9a-f-]{36}$/);
    await page.goto(new URL(`/admin/passkey-add-link/list?search=${linkID}`, baseUrl).toString());
    assert.equal(await page.locator("tbody tr").count(), 1);
    await page.locator('tbody a[href*="/details/"]').click();
    await page.getByRole("button", { name: "Revoke link", exact: true }).click();
    assert.equal((await reviewerContext.request.get(revokedLink)).status(), 404);
    await page.goto(new URL("/admin/user/list?search=apple-review", baseUrl).toString());
    await page.screenshot({ path: path.join(artifactDir, "admin-review-account.png"), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), "Admin must fit mobile viewport");
    await page.screenshot({ path: path.join(artifactDir, "admin-mobile.png"), fullPage: true });
    await page.setViewportSize({ width: 1280, height: 960 });
    await reviewerKey.dispose();
    await reviewerContext.close();

    log("Checking public App Store pages without a session");
    const publicContext = await browser.newContext();
    const publicPage = await publicContext.newPage();
    for (const route of ["app", "support", "privacy"]) {
      await publicPage.goto(new URL(`/${route}`, baseUrl).toString());
      await publicPage.getByRole("heading", { level: 1 }).waitFor();
      assert(await publicPage.locator('a[href="mailto:tracy@schaedler.rocks"]').count());
      await publicPage.screenshot({ path: path.join(artifactDir, `${route}.png`), fullPage: true });
    }
    await publicContext.close();

    log("Exchanging passkey session for native PKCE token");
    const verifier = randomBytes(32).toString("base64url");
    const state = randomBytes(32).toString("base64url");
    const challenge = createHash("sha256").update(verifier).digest("base64url");
    const authorization = await context.request.get(new URL("/api/v1/auth/mobile/authorize", baseUrl).toString(), {
      params: { state, code_challenge: challenge }, maxRedirects: 0,
    });
    assert.equal(authorization.status(), 303);
    const callback = new URL(authorization.headers().location);
    assert.equal(callback.protocol, "de.malaber.tracy:");
    assert.equal(callback.searchParams.get("state"), state);
    const exchange = await context.request.post(new URL("/api/v1/auth/mobile/token", baseUrl).toString(), {
      data: { code: callback.searchParams.get("code"), code_verifier: verifier },
    });
    assert.equal(exchange.status(), 200);
    const { access_token: nativeToken } = await exchange.json();
    const native = await browser.newContext({ extraHTTPHeaders: { Authorization: `Bearer ${nativeToken}` } });
    const entryURL = new URL("/api/v1/entries/2026-01-07", baseUrl).toString();
    const mutationHeaders = { "If-Match": "missing", "Idempotency-Key": randomUUID() };
    const payload = { check_in: "08:00", check_out: "17:00", notes: "Queued native edit" };
    const first = await native.request.put(entryURL, { headers: mutationHeaders, data: payload });
    assert.equal(first.status(), 200);
    const firstEntry = await first.json();
    const retry = await native.request.put(entryURL, { headers: mutationHeaders, data: payload });
    assert.deepEqual(await retry.json(), firstEntry, "Lost-response retry must be idempotent");
    const webEdit = await context.request.put(entryURL, { data: { ...payload, notes: "Newer web edit" } });
    assert.equal(webEdit.status(), 200);
    const conflict = await native.request.put(entryURL, {
      headers: { "If-Match": firstEntry.revision }, data: payload,
    });
    assert.equal(conflict.status(), 409);
    assert.equal((await (await native.request.get(entryURL)).json()).notes, "Newer web edit");
    log("Deleting account and verifying native session revocation");
    const deletion = await native.request.delete(new URL("/api/v1/account", baseUrl).toString());
    assert.equal(deletion.status(), 204);
    assert.equal((await native.request.get(entryURL)).status(), 401);
    await native.close();
    await fs.writeFile(
      path.join(artifactDir, "summary.md"),
      "Admin-created review account, one-use enrollment, revocation, prepared data, passkey registration, login, data persistence, public store pages, native PKCE, idempotent retry, conflict protection, and account deletion passed.\n",
    );
    log("Passkey flow passed");
  } finally {
    await authenticator.dispose();
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

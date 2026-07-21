import assert from "node:assert/strict";
import fsSync from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
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

async function createVirtualAuthenticator(page) {
  const client = await page.context().newCDPSession(page);
  await client.send("WebAuthn.enable", { enableUI: false });
  const { authenticatorId } = await client.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      ctap2Version: "ctap2_1",
      transport: "usb",
      hasResidentKey: true,
      hasUserVerification: true,
      automaticPresenceSimulation: true,
      isUserVerified: true,
    },
  });
  return { client, authenticatorId };
}

async function credentialCount(authenticator) {
  return (await authenticatorCredentials(authenticator)).length;
}

async function authenticatorCredentials(authenticator) {
  const { credentials } = await authenticator.client.send("WebAuthn.getCredentials", {
    authenticatorId: authenticator.authenticatorId,
  });
  return credentials;
}

async function main() {
  await fs.mkdir(artifactDir, { recursive: true });
  const browser = await chromium.launch(browserChannel ? { channel: browserChannel } : {});
  const context = await browser.newContext({ viewport: { width: 1280, height: 960 } });
  const page = await context.newPage();
  page.setDefaultTimeout(15_000);
  page.setDefaultNavigationTimeout(15_000);
  const authenticators = [];
  let authenticator = await createVirtualAuthenticator(page);
  authenticators.push(authenticator);

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
    assert.equal(await credentialCount(authenticator), 1);
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

    log("Adding and renaming passkey on second authenticator");
    await page.goto(new URL("/security", baseUrl).toString(), { waitUntil: "networkidle" });
    assert.equal(await page.locator(".passkey-row").count(), 1);
    await authenticator.client.send("WebAuthn.removeVirtualAuthenticator", {
      authenticatorId: authenticator.authenticatorId,
    });
    authenticator = await createVirtualAuthenticator(page);
    authenticators.push(authenticator);
    await page.getByRole("button", { name: "Add another" }).click();
    await page.locator("[data-passkey-name-input]").fill("Work laptop");
    const addOptions = waitForPost(page, /\/api\/v1\/auth\/passkeys\/register\/options$/);
    await page.getByRole("button", { name: "Continue", exact: true }).click();
    await assertRegistrationOptions(await addOptions, 1);
    await page.locator(".passkey-row").nth(1).waitFor();
    assert.equal(await credentialCount(authenticator), 1);

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
    assert.equal(await credentialCount(authenticator), 1);
    await page.screenshot({ path: path.join(artifactDir, "passkey-flow.png"), fullPage: true });
    await fs.writeFile(
      path.join(artifactDir, "summary.md"),
      "Passkey registration, protected write, management, logout, login, and data persistence passed.\n",
    );
    log("Passkey flow passed");
  } finally {
    for (const item of authenticators) {
      await item.client.send("WebAuthn.removeVirtualAuthenticator", {
        authenticatorId: item.authenticatorId,
      }).catch(() => {});
    }
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

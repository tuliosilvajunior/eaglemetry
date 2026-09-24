import { assertEquals, assertMatch, assertNotEquals } from "jsr:@std/assert";
import { getClientIp, handleClaim, handleRegister, handleStart } from "./index.ts";
import {
  CLAIM_RATE_LIMIT_THRESHOLD,
  CLAIM_RATE_LIMIT_WINDOW_MS,
  START_RATE_LIMIT_MAX_PENDING_PER_VEHICLE,
  claimErrorReason,
  classifyOwnershipClaim,
  formatUserCode,
  generateCarToken,
  generateDeviceCode,
  generateUserCode,
  hashToken,
  isClaimRateLimited,
  isExpired,
  isRegisterIpRateLimited,
  isRegisterVehicleRateLimited,
  isStartRateLimited,
  isValidDeviceCode,
  isValidUserCodeFormat,
  isValidVehicleId,
  normalizeAndFormatUserCode,
  normalizeUserCode,
  resolvePollStatus,
} from "./pairing.ts";

// ---------------------------------------------------------------------------
// user_code
// ---------------------------------------------------------------------------

Deno.test("formatUserCode formats 6 digits as XXX-XXX", () => {
  assertEquals(formatUserCode("482910"), "482-910");
  assertEquals(formatUserCode("000001"), "000-001");
});

Deno.test("normalizeUserCode strips non-digits and validates length", () => {
  assertEquals(normalizeUserCode("482-910"), "482910");
  assertEquals(normalizeUserCode("482910"), "482910");
  assertEquals(normalizeUserCode(" 482 910 "), "482910");
  assertEquals(normalizeUserCode("48-29-10"), "482910");
  assertEquals(normalizeUserCode("48291"), null);
  assertEquals(normalizeUserCode("4829100"), null);
  assertEquals(normalizeUserCode("abc"), null);
});

Deno.test("normalizeAndFormatUserCode round-trips", () => {
  assertEquals(normalizeAndFormatUserCode("482910"), "482-910");
  assertEquals(normalizeAndFormatUserCode("482-910"), "482-910");
  assertEquals(normalizeAndFormatUserCode("482 910"), "482-910");
  assertEquals(normalizeAndFormatUserCode("bad"), null);
});

Deno.test("isValidUserCodeFormat accepts 6 digits with or without dash", () => {
  assertEquals(isValidUserCodeFormat("482-910"), true);
  assertEquals(isValidUserCodeFormat("482910"), true);
  assertEquals(isValidUserCodeFormat("482 910"), true);
  assertEquals(isValidUserCodeFormat("48291"), false);
  assertEquals(isValidUserCodeFormat("4829100"), false);
  assertEquals(isValidUserCodeFormat(""), false);
});

Deno.test("generateUserCode produces 6-digit XXX-XXX", () => {
  for (let i = 0; i < 20; i++) {
    const code = generateUserCode();
    assertMatch(code, /^\d{3}-\d{3}$/);
    assertEquals(isValidUserCodeFormat(code), true);
  }
});

Deno.test("generateUserCode varies across calls", () => {
  const set = new Set<string>();
  for (let i = 0; i < 10; i++) set.add(generateUserCode());
  // Very likely to have at least 2 distinct values in 10 draws
  // If this flakes, it indicates RNG breakage
  assertEquals(set.size > 1, true);
});

// ---------------------------------------------------------------------------
// device_code & car_token
// ---------------------------------------------------------------------------

Deno.test("generateDeviceCode produces UUID v4", () => {
  const code = generateDeviceCode();
  assertEquals(isValidDeviceCode(code), true);
  assertNotEquals(generateDeviceCode(), code);
});

Deno.test("isValidDeviceCode rejects bad values", () => {
  assertEquals(isValidDeviceCode("not-a-uuid"), false);
  assertEquals(isValidDeviceCode(""), false);
  assertEquals(isValidDeviceCode(null), false);
  assertEquals(isValidDeviceCode(123 as unknown as string), false);
});

Deno.test("generateCarToken is base64url, 43+ chars, distinct", () => {
  const t1 = generateCarToken();
  const t2 = generateCarToken();
  assertMatch(t1, /^[A-Za-z0-9_-]+$/);
  // 32 bytes => 43 base64url chars (without padding)
  assertEquals(t1.length >= 43, true);
  assertNotEquals(t1, t2);
});

Deno.test("hashToken is deterministic SHA-256 hex and not raw token", async () => {
  const token = "hello-car-token";
  const h1 = await hashToken(token);
  const h2 = await hashToken(token);
  assertEquals(h1, h2);
  assertMatch(h1, /^[0-9a-f]{64}$/);
  assertEquals(h1.includes(token), false);
  const h3 = await hashToken(token + "x");
  assertNotEquals(h1, h3);
});

// ---------------------------------------------------------------------------
// expiry
// ---------------------------------------------------------------------------

Deno.test("isExpired distinguishes future vs past", () => {
  const future = new Date(Date.now() + 60_000).toISOString();
  const past = new Date(Date.now() - 60_000).toISOString();
  assertEquals(isExpired(future), false);
  assertEquals(isExpired(past), true);
  assertEquals(isExpired(new Date(Date.now() + 10 * 60 * 1000).toISOString()), false);
  assertEquals(isExpired("invalid-date"), true);
});

Deno.test("resolvePollStatus returns expired when expires_at in past", () => {
  const past = new Date(Date.now() - 1000).toISOString();
  const future = new Date(Date.now() + 600_000).toISOString();
  assertEquals(resolvePollStatus({ status: "pending", expires_at: past }).status, "expired");
  assertEquals(resolvePollStatus({ status: "pending", expires_at: future }).status, "pending");
  assertEquals(resolvePollStatus({ status: "expired", expires_at: future }).status, "expired");
  assertEquals(resolvePollStatus({ status: "approved", expires_at: future }).status, "approved");
  assertEquals(resolvePollStatus({ status: "approved", expires_at: past }).status, "expired");
});

// ---------------------------------------------------------------------------
// claimErrorReason: distinguish invalid vs expired vs already_claimed
// ---------------------------------------------------------------------------

Deno.test("claimErrorReason distinguishes invalid_code vs expired vs already_claimed", () => {
  assertEquals(claimErrorReason(null), "invalid_code");
  const future = new Date(Date.now() + 600_000).toISOString();
  const past = new Date(Date.now() - 1000).toISOString();
  assertEquals(claimErrorReason({ status: "pending", expires_at: future }), null);
  assertEquals(claimErrorReason({ status: "pending", expires_at: past }), "expired");
  assertEquals(claimErrorReason({ status: "expired", expires_at: future }), "expired");
  assertEquals(claimErrorReason({ status: "approved", expires_at: future }), "already_claimed");
  assertEquals(claimErrorReason({ status: "rejected", expires_at: future }), "already_claimed");
  // Expired takes precedence over already_claimed: an approved session that is also past expiry should report expired
  assertEquals(claimErrorReason({ status: "approved", expires_at: past }), "expired");
});

// ---------------------------------------------------------------------------
// classifyOwnershipClaim: idempotency and vehicle_already_claimed
// ---------------------------------------------------------------------------

Deno.test("classifyOwnershipClaim: no existing ownership => ok", () => {
  assertEquals(classifyOwnershipClaim([], "acct-1"), "ok");
});

Deno.test("classifyOwnershipClaim: same account re-claim => already_owned_by_self (idempotent)", () => {
  assertEquals(
    classifyOwnershipClaim([{ account_id: "acct-1", revoked_at: null }], "acct-1"),
    "already_owned_by_self",
  );
});

Deno.test("classifyOwnershipClaim: different account => already_owned_by_other", () => {
  assertEquals(
    classifyOwnershipClaim([{ account_id: "acct-1", revoked_at: null }], "acct-2"),
    "already_owned_by_other",
  );
});

Deno.test("classifyOwnershipClaim: revoked ownership ignored", () => {
  assertEquals(
    classifyOwnershipClaim([{ account_id: "acct-1", revoked_at: "2026-08-01T00:00:00Z" }], "acct-2"),
    "ok",
  );
  assertEquals(
    classifyOwnershipClaim([{ account_id: "acct-1", revoked_at: "2026-08-01T00:00:00Z" }], "acct-1"),
    "ok",
  );
});

Deno.test("classifyOwnershipClaim: mixed — other account present => already_owned_by_other even if self also present", () => {
  assertEquals(
    classifyOwnershipClaim(
      [
        { account_id: "acct-1", revoked_at: null },
        { account_id: "acct-2", revoked_at: null },
      ],
      "acct-1",
    ),
    "already_owned_by_other",
  );
});

Deno.test("classifyOwnershipClaim: revoked other but active self => already_owned_by_self", () => {
  assertEquals(
    classifyOwnershipClaim(
      [
        { account_id: "acct-1", revoked_at: null },
        { account_id: "acct-2", revoked_at: "2026-08-01T00:00:00Z" },
      ],
      "acct-1",
    ),
    "already_owned_by_self",
  );
});

// ---------------------------------------------------------------------------
// Rate limiting (H2)
// ---------------------------------------------------------------------------

Deno.test("isClaimRateLimited thresholds", () => {
  assertEquals(isClaimRateLimited(0), false);
  assertEquals(isClaimRateLimited(4), false);
  assertEquals(isClaimRateLimited(5), true);
  assertEquals(isClaimRateLimited(6), true);
  assertEquals(isClaimRateLimited(3, 3), true);
  assertEquals(isClaimRateLimited(2, 3), false);
  assertEquals(CLAIM_RATE_LIMIT_THRESHOLD, 5);
  assertEquals(CLAIM_RATE_LIMIT_WINDOW_MS, 10 * 60 * 1000);
});

Deno.test("isStartRateLimited thresholds", () => {
  assertEquals(isStartRateLimited(0), false);
  assertEquals(isStartRateLimited(4), false);
  assertEquals(isStartRateLimited(5), true);
  assertEquals(isStartRateLimited(10), true);
  assertEquals(START_RATE_LIMIT_MAX_PENDING_PER_VEHICLE, 5);
});

// ---------------------------------------------------------------------------
// H1: one-time token delivery — poll should null car_token after first delivery
// Simulate the atomic consume pattern: first poll gets token, second gets null.
// ---------------------------------------------------------------------------

Deno.test("poll one-time delivery: token nulled after first poll (simulated atomic consume)", () => {
  // Simulate row and the consume_pairing_token logic (SELECT FOR UPDATE + UPDATE)
  type Row = { device_code: string; car_token: string | null; status: string };
  const row: Row = { device_code: "11111111-1111-4111-8111-111111111111", car_token: generateCarToken(), status: "approved" };
  function consumeToken(r: Row): string | null {
    const token = r.car_token;
    if (token !== null) r.car_token = null;
    return token;
  }
  const first = consumeToken(row);
  assertEquals(typeof first, "string");
  assertEquals(row.car_token, null);
  const second = consumeToken(row);
  assertEquals(second, null);
  assertEquals(row.car_token, null);
});

// ---------------------------------------------------------------------------
// H3: single active owner enforcement + bypass closed (schema checks)
// Verify migration/schema enforce partial unique index and remove client inserts
// ---------------------------------------------------------------------------

Deno.test("schema migration enforces single active owner and blocks client inserts", async () => {
  // Read the migration and schema_full to check H3 fixes without needing a DB
  const migrationPath = "../../migrations/20260901120000_device_pairing_and_vehicle_ownership.sql";
  const schemaPath = "../../schema_full.sql";
  let migration = "";
  let schema = "";
  try {
    migration = await Deno.readTextFile(migrationPath);
  } catch {
    migration = await Deno.readTextFile(new URL(migrationPath, import.meta.url).pathname);
  }
  try {
    schema = await Deno.readTextFile(schemaPath);
  } catch {
    schema = await Deno.readTextFile(new URL(schemaPath, import.meta.url).pathname);
  }
  const combined = migration + "\n" + schema;
  // Partial unique index for single active owner
  const hasPartialIdx = /create unique index.*vehicle_ownership_single_active_owner_idx.*where\s+revoked_at\s+is\s+null/is.test(combined);
  assertEquals(hasPartialIdx, true);
  // Insert policies for ownership/devices must have been removed (H3.3)
  const hasOwnershipInsertPolicy = /create policy\s+vehicle_ownership_owner_inserts/is.test(combined);
  const hasDevicesInsertPolicy = /create policy\s+vehicle_devices_owner_inserts/is.test(combined);
  assertEquals(hasOwnershipInsertPolicy, false);
  assertEquals(hasDevicesInsertPolicy, false);
  // Grants should not give insert to authenticated on those tables
  // The file should contain revoke or lack of grant insert to authenticated for those tables
  const hasPairingAttempts = /create table.*pairing_claim_attempts/is.test(combined);
  assertEquals(hasPairingAttempts, true);
  const hasClaimRpc = /create or replace function.*claim_pairing_session/is.test(combined);
  const hasConsumeRpc = /create or replace function.*consume_pairing_token/is.test(combined);
  assertEquals(hasClaimRpc, true);
  assertEquals(hasConsumeRpc, true);
});

// ---------------------------------------------------------------------------
// Pairing code lifetime: 5 minutes, single source (DB default), no second writer.
// The edge function must return the stored expires_at, never a local Date.now() + N.
// This test fails if the two places disagree or if a second writer is reintroduced.
// ---------------------------------------------------------------------------

Deno.test("pairing code expiry is five minutes and returned value is the stored row", async () => {
  // --- 1. Database is the single source of truth: every definition must be 5 minutes ---
  const schemaPath = "../../schema_full.sql";
  let schema = "";
  try {
    schema = await Deno.readTextFile(schemaPath);
  } catch {
    schema = await Deno.readTextFile(new URL(schemaPath, import.meta.url).pathname);
  }
  // Collect pairing migrations only (those that mention device_pairing_sessions)
  // We read the migrations directory but only keep files that contain the pairing table.
  const migrationsDir = "../../migrations";
  let pairingMigrationPaths: string[] = [];
  let allMigrationPaths: string[] = [];
  try {
    for await (const entry of Deno.readDir(migrationsDir)) {
      if (entry.isFile && entry.name.endsWith(".sql")) {
        allMigrationPaths.push(`${migrationsDir}/${entry.name}`);
      }
    }
  } catch {
    try {
      const dirUrl = new URL(migrationsDir + "/", import.meta.url);
      for await (const entry of Deno.readDir(dirUrl.pathname)) {
        if (entry.isFile && entry.name.endsWith(".sql")) {
          allMigrationPaths.push(dirUrl.pathname + entry.name);
        }
      }
    } catch { /* ignore */ }
  }
  if (allMigrationPaths.length === 0) {
    allMigrationPaths = ["../../migrations/20260901120000_device_pairing_and_vehicle_ownership.sql", "../../migrations/20260902180000_device_pairing_five_minute_expiry.sql"];
  }
  allMigrationPaths.sort();
  // Fail loudly if we couldn't read any migration — otherwise the test would pass vacuously.
  assertEquals(allMigrationPaths.length > 0, true);
  let pairingMigrations = "";
  let allMigrations = "";
  for (const p of allMigrationPaths) {
    let text = "";
    try {
      text = await Deno.readTextFile(p);
    } catch {
      try {
        text = await Deno.readTextFile(new URL(p, import.meta.url).pathname);
      } catch { continue; }
    }
    allMigrations += "\n" + text;
    if (/device_pairing_sessions/i.test(text)) {
      pairingMigrationPaths.push(p);
      pairingMigrations += "\n" + text;
    }
  }
  assertEquals(allMigrations.length > 0, true);
  assertEquals(pairingMigrations.length > 0, true);
  // Schema: column default must be 5 minutes
  const schemaExpiryMatches = [...schema.matchAll(/expires_at\s+timestamptz[^,]*default\s*\(now\(\)\s*\+\s*interval\s*'([^']+)'\)/gi)];
  assertEquals(schemaExpiryMatches.length >= 1, true);
  for (const m of schemaExpiryMatches) {
    assertEquals(m[1], "5 minutes");
  }
  assertEquals(/expires_at\s+timestamptz[^,]*default\s*\(now\(\)\s*\+\s*interval\s*'10 minutes'\)/i.test(schema), false);
  // Pairing migrations: every expires_at DEFAULT in pairing files must be 5 minutes.
  // Fresh installs see original (10 min historically) + forward migration (5 min); after fix original may still be 10
  // in history but forward migration is the effective writer. We assert the *effective* last writer is 5 min
  // and that no pairing file introduces a new 10-minute DEFAULT after the forward migration.
  // For this PR's shape: original may be 10 (historical) and forward is 5 — we check the forward migration exists and is 5.
  const pairingDefaultMatches = [...pairingMigrations.matchAll(/expires_at[^;]*default\s*\(now\(\)\s*\+\s*interval\s*'([^']+)'\)/gi)];
  // At least the forward migration must define 5 minutes
  const hasFiveMinuteDefault = pairingDefaultMatches.some((m) => m[1] === "5 minutes");
  assertEquals(hasFiveMinuteDefault, true);
  // The forward migration must override historical 10 — ensure pairing migrations contain a 5-minute writer
  // We check that the forward file specifically contains 5 minutes (direct read for robustness)
  let forwardText = "";
  const forwardPaths = ["../../migrations/20260902180000_device_pairing_five_minute_expiry.sql"];
  for (const fp of forwardPaths) {
    try {
      forwardText = await Deno.readTextFile(fp);
      break;
    } catch {
      try {
        forwardText = await Deno.readTextFile(new URL(fp, import.meta.url).pathname);
        break;
      } catch { /* continue */ }
    }
  }
  assertEquals(forwardText.length > 0, true);
  assertEquals(/interval\s*'5 minutes'/i.test(forwardText), true);
  // Effective: last writer among pairing migrations must be 5 minutes (allow historical 10 before it)
  if (pairingDefaultMatches.length > 0) {
    const last = pairingDefaultMatches[pairingDefaultMatches.length - 1];
    // If historical original is still 10, last will be 5 (forward); if original was already 5, last is also 5
    assertEquals(last[1], "5 minutes");
  }

  // --- 2. Edge function must NOT compute its own expiry; it must return the stored row ---
  let indexSrc = "";
  try {
    indexSrc = await Deno.readTextFile("./index.ts");
  } catch {
    indexSrc = await Deno.readTextFile(new URL("./index.ts", import.meta.url).pathname);
  }
  const handleStartBlock = indexSrc.split("async function handlePoll")[0].split("handleStart")[1] ?? indexSrc;
  const hasLocalExpiryComputation = /expires_at\s*=\s*new Date\(Date\.now\(\)/i.test(handleStartBlock) ||
    /Date\.now\(\)\s*\+\s*\d+\s*\*\s*60\s*\*\s*1000/i.test(handleStartBlock) && /expires_at/i.test(handleStartBlock);
  assertEquals(hasLocalExpiryComputation, false);
  const insertBlock = handleStartBlock.match(/\.insert\(\{[^}]+\}\)/s)?.[0] ?? "";
  if (insertBlock) {
    assertEquals(/expires_at/i.test(insertBlock), false);
  }
  assertEquals(/\.select\(\s*["']expires_at["']\s*\)/.test(handleStartBlock), true);
  assertEquals(/\.single\(\)/.test(handleStartBlock), true);
  // Stronger: the returned expires_at must be the selected data.expires_at, not a fresh Date
  // Look for `const expires_at =` after `.single()` — it should read from data.expires_at / rawExpiresAt
  const afterSingle = handleStartBlock.split(".single()")[1] ?? "";
  assertEquals(/const\s+expires_at\s*=\s*rawExpiresAt/.test(afterSingle) || /const\s+expires_at\s*=\s*data\.expires_at/.test(afterSingle), true);
  assertEquals(/const\s+expires_at\s*=\s*new Date\(/.test(afterSingle), false);
  assertEquals(/10\s*\*\s*60\s*\*\s*1000/.test(handleStartBlock), false);
});

Deno.test("handleStart returns the stored expires_at, not a locally computed one", async () => {
  // Fake Supabase client that emulates Postgres DEFAULT (now() + 5 minutes) via INSERT ... RETURNING
  const FAKE_TTL_MS = 5 * 60 * 1000;
  let lastInsertPayload: Record<string, unknown> | null = null;
  let storedRow: Record<string, unknown> | null = null;
  function makeFakeService() {
    // The service is the object returned by createClient; we only need .from()
    const service = {
      from: (_table: string) => {
        // Branch on table for rate-limit vs insert
        let table = _table;
        return {
          select: (_columns: string, _opts?: unknown) => {
            // Two usages:
            // 1) rate-limit: .select("device_code", {count:"exact", head:true}).eq(...).eq(...).gt(...)
            // 2) insert returning: .insert(...).select("expires_at").single()
            // For case 1, return a chain that ends with gt() returning a promise
            // For case 2, select is after insert, handled in insert() branch below
            // Here we are in the head:true path
            const opts = _opts as Record<string, unknown> | undefined;
            if (opts && opts["head"] === true) {
              const chain: Record<string, unknown> = {};
              chain["eq"] = (_col: string, _val: unknown) => chain;
              chain["gt"] = (_col: string, _val: unknown) => Promise.resolve({ count: 0, error: null });
              return chain;
            }
            // Not head — shouldn't happen in handleStart's rate-limit path without head,
            // but return a dummy chain
            const chain: Record<string, unknown> = {};
            chain["eq"] = () => chain;
            chain["gt"] = () => Promise.resolve({ count: 0, error: null });
            return chain;
          },
          insert: (payload: Record<string, unknown>) => {
            lastInsertPayload = { ...payload };
            return {
              select: (_col: string) => ({
                single: () => {
                  // Simulate DB default: if payload already has expires_at, respect it (old writer);
                  // otherwise apply now()+5min.
                  let expires_at: string;
                  if (typeof payload["expires_at"] === "string") {
                    expires_at = payload["expires_at"] as string;
                  } else {
                    expires_at = new Date(Date.now() + FAKE_TTL_MS).toISOString();
                  }
                  storedRow = { ...payload, expires_at };
                  return Promise.resolve({ data: { expires_at }, error: null });
                },
              }),
            };
          },
        };
      },
    };
    return service;
  }
  const fakeService = makeFakeService();
  const before = Date.now();
  const req = new Request("http://localhost/device-pairing/start", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ vehicle_id: "VIN-TEST-123" }),
  });
  // deno-lint-ignore no-explicit-any
  const res = await (handleStart as any)(req, fakeService);
  const after = Date.now();
  assertEquals(res.status, 201);
  const body = await res.json() as Record<string, unknown>;
  // Must not have inserted expires_at — the DB is the writer
  assertEquals(lastInsertPayload !== null && "expires_at" in lastInsertPayload, false);
  // Response expires_at must equal stored row's expires_at
  assertEquals(typeof body["expires_at"], "string");
  assertEquals(storedRow !== null, true);
  assertEquals(body["expires_at"], (storedRow as unknown as Record<string, unknown>)["expires_at"]);
  // Both must be approximately now()+5min (allow 5s skew for test runtime)
  const returnedMs = new Date(body["expires_at"] as string).getTime();
  const expectedMin = before + FAKE_TTL_MS - 5000;
  const expectedMax = after + FAKE_TTL_MS + 5000;
  assertEquals(returnedMs >= expectedMin && returnedMs <= expectedMax, true);
  // Mutation guard: if handleStart had returned new Date().toISOString() (now) instead of stored (now+5min),
  // the above equality would fail because stored is now+5min. We explicitly verify non-equality to now:
  const driftFromNow = Math.abs(returnedMs - Date.now());
  assertEquals(driftFromNow > 4 * 60 * 1000, true);
  assertEquals(driftFromNow < 6 * 60 * 1000, true);
});

// ---------------------------------------------------------------------------
// handleRegister: car device registration via register_device_identity RPC
// ---------------------------------------------------------------------------

function makeRegisterRequest(body: unknown): Request {
  return new Request("http://localhost/device-pairing/register", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

type RegisterService = NonNullable<Parameters<typeof handleRegister>[1]>;

function makeRegisterService(result: { data: unknown; error: unknown }): RegisterService {
  return {
    rpc: (_fn: string, _args: Record<string, string>) => Promise.resolve(result),
  } as unknown as RegisterService;
}

Deno.test("handleRegister returns 201 with car_token on valid vehicle_id", async () => {
  const service = makeRegisterService({ data: "raw-car-token", error: null });
  const res = await handleRegister(makeRegisterRequest({ vehicle_id: "VIN-TEST-123" }), service);
  assertEquals(res.status, 201);
  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["car_token"], "raw-car-token");
});

Deno.test("handleRegister rejects missing/empty/invalid vehicle_id with 400", async () => {
  const service = makeRegisterService({ data: "unused", error: null });
  for (const payload of [{}, { vehicle_id: "" }, { vehicle_id: "   " }, { vehicle_id: 42 }]) {
    const res = await handleRegister(makeRegisterRequest(payload), service);
    assertEquals(res.status, 400);
    const body = await res.json() as Record<string, unknown>;
    assertEquals(body["error"], "invalid_request");
    assertEquals(body["reason"], "invalid_vehicle_id");
  }
});

Deno.test("handleRegister rejects invalid JSON body with 400", async () => {
  const service = makeRegisterService({ data: "unused", error: null });
  const res = await handleRegister(makeRegisterRequest("{not-json"), service);
  assertEquals(res.status, 400);
  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["error"], "invalid_request");
  assertEquals(body["reason"], "invalid_body");
});

Deno.test("handleRegister returns 500 on RPC error", async () => {
  const service = makeRegisterService({ data: null, error: { code: "P0001", message: "boom" } });
  const res = await handleRegister(makeRegisterRequest({ vehicle_id: "VIN-TEST-123" }), service);
  assertEquals(res.status, 500);
  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["error"], "server_error");
  assertEquals(body["reason"], "register_failed");
});

// ---------------------------------------------------------------------------
// handleClaim: backfill count passthrough (P3-T2, issue #236)
// ---------------------------------------------------------------------------

function makeClaimRequest(body: unknown): Request {
  return new Request("http://localhost/device-pairing/claim", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: "Bearer test-jwt",
    },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

const pendingSession = {
  device_code: "00000000-0000-4000-8000-000000000000",
  user_code: "482-910",
  vehicle_id: "veh-1",
  status: "pending",
  expires_at: "2099-01-01T00:00:00.000Z",
  approved_by: null,
};

type ClaimServiceLike = {
  rpc(fn: string, args: Record<string, unknown>): Promise<{ data: unknown; error: unknown }>;
  from(table: string): unknown;
};

type ClaimAnonLike = {
  auth: {
    getUser(token: string): Promise<{ data: { user: { id: string } | null } | null; error: unknown }>;
  };
};

type ClaimDeps = {
  service: ClaimServiceLike;
  anon: ClaimAnonLike;
};

function makeClaimDeps(rpcResult: { data: unknown; error: unknown }, deps?: ClaimDeps): ClaimDeps {
  return {
    service: {
      rpc: () => Promise.resolve(rpcResult),
      from: () => ({
        select: () => ({
          in: () => ({ limit: () => Promise.resolve({ data: [pendingSession], error: null }) }),
          eq: () => ({ maybeSingle: () => Promise.resolve({ data: null, error: null }) }),
        }),
        insert: () => Promise.resolve({ error: null }),
        update: () => ({ eq: () => Promise.resolve({ error: null }) }),
      }),
    },
    anon: {
      auth: {
        getUser: () => Promise.resolve({ data: { user: { id: "acct-1" } }, error: null }),
      },
    },
    ...deps,
  };
}

function claimDepArg(deps: ClaimDeps) {
  return deps as unknown as Parameters<typeof handleClaim>[1];
}

Deno.test("handleClaim carries the RPC backfilled count in its response", async () => {
  const deps = makeClaimDeps({ data: { ok: true, backfilled: 17 }, error: null });
  const res = await handleClaim(makeClaimRequest({ user_code: "482-910" }), claimDepArg(deps));
  assertEquals(res.status, 200);
  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["status"], "approved");
  assertEquals(body["backfilled"], 17);
});

Deno.test("handleClaim reports backfilled 0 when the RPC returns no count", async () => {
  const deps = makeClaimDeps({ data: { ok: true }, error: null });
  const res = await handleClaim(makeClaimRequest({ user_code: "482-910" }), claimDepArg(deps));
  assertEquals(res.status, 200);
  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["backfilled"], 0);
});

// ---------------------------------------------------------------------------
// P5-T1: Registration rate limiting and strict isValidVehicleId
// ---------------------------------------------------------------------------

Deno.test("strict isValidVehicleId accepts valid identifiers and rejects invalid/unassigned", () => {
  // Valid
  assertEquals(isValidVehicleId("VIN12345678901234"), true);
  assertEquals(isValidVehicleId("veh-1"), true);
  assertEquals(isValidVehicleId("test_vehicle"), true);
  assertEquals(isValidVehicleId("0123456789abcdef"), true);
  assertEquals(isValidVehicleId("car:01.a"), true);
  assertEquals(isValidVehicleId("a".repeat(128)), true);

  // Invalid
  assertEquals(isValidVehicleId(""), false);
  assertEquals(isValidVehicleId("   "), false);
  assertEquals(isValidVehicleId(null), false);
  assertEquals(isValidVehicleId(undefined), false);
  assertEquals(isValidVehicleId(123), false);
  assertEquals(isValidVehicleId("unassigned"), false);
  assertEquals(isValidVehicleId("UNASSIGNED"), false);
  assertEquals(isValidVehicleId("Unassigned"), false);
  assertEquals(isValidVehicleId("veh 1"), false);
  assertEquals(isValidVehicleId("veh\n1"), false);
  assertEquals(isValidVehicleId("veh;DROP TABLE vehicle;"), false);
  assertEquals(isValidVehicleId("../../etc/passwd"), false);
  assertEquals(isValidVehicleId("a".repeat(129)), false);
});

Deno.test("isRegisterVehicleRateLimited and isRegisterIpRateLimited thresholds", () => {
  assertEquals(isRegisterVehicleRateLimited(4), false);
  assertEquals(isRegisterVehicleRateLimited(5), true);
  assertEquals(isRegisterVehicleRateLimited(6), true);

  assertEquals(isRegisterIpRateLimited(9), false);
  assertEquals(isRegisterIpRateLimited(10), true);
  assertEquals(isRegisterIpRateLimited(11), true);
});

Deno.test("handleRegister returns 429 when vehicle rate limit is reached", async () => {
  const fakeService = {
    rpc: () => Promise.resolve({ data: "car-token-xyz", error: null }),
    from: (table: string) => {
      if (table === "device_registration_attempts") {
        return {
          select: () => ({
            eq: () => ({
              gt: () => Promise.resolve({ count: 5, error: null }),
            }),
          }),
          insert: () => Promise.resolve({ error: null }),
        };
      }
      return {};
    },
  } as unknown as Parameters<typeof handleRegister>[1];

  const req = new Request("https://localhost/register", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ vehicle_id: "veh-1" }),
  });
  const res = await handleRegister(req, fakeService);
  assertEquals(res.status, 429);
  const body = (await res.json()) as Record<string, unknown>;
  assertEquals(body["error"], "rate_limited");
  assertEquals(body["reason"], "rate_limited");
});

Deno.test("handleRegister returns 429 when IP rate limit is reached", async () => {
  const fakeService = {
    rpc: () => Promise.resolve({ data: "car-token-xyz", error: null }),
    from: (table: string) => {
      if (table === "device_registration_attempts") {
        return {
          select: () => ({
            eq: (col: string) => {
              const count = col === "ip" ? 10 : 0;
              return {
                gt: () => Promise.resolve({ count, error: null }),
              };
            },
          }),
          insert: () => Promise.resolve({ error: null }),
        };
      }
      return {};
    },
  } as unknown as Parameters<typeof handleRegister>[1];

  const req = new Request("https://localhost/register", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-forwarded-for": "203.0.113.195",
    },
    body: JSON.stringify({ vehicle_id: "veh-1" }),
  });
  const res = await handleRegister(req, fakeService);
  assertEquals(res.status, 429);
  const body = (await res.json()) as Record<string, unknown>;
  assertEquals(body["error"], "rate_limited");
  assertEquals(body["reason"], "rate_limited");
});

Deno.test("getClientIp prioritizes cf-connecting-ip over x-forwarded-for (F2 anti-spoof)", () => {
  const reqWithBoth = new Request("https://localhost/register", {
    headers: {
      "cf-connecting-ip": "198.51.100.1",
      "x-forwarded-for": "203.0.113.195, 10.0.0.1",
    },
  });
  assertEquals(getClientIp(reqWithBoth), "198.51.100.1");

  const reqWithRealIp = new Request("https://localhost/register", {
    headers: {
      "x-real-ip": "198.51.100.2",
      "x-forwarded-for": "203.0.113.195",
    },
  });
  assertEquals(getClientIp(reqWithRealIp), "198.51.100.2");

  const reqWithForwardedOnly = new Request("https://localhost/register", {
    headers: {
      "x-forwarded-for": "203.0.113.195",
    },
  });
  assertEquals(getClientIp(reqWithForwardedOnly), "203.0.113.195");

  const reqWithNoIp = new Request("https://localhost/register");
  assertEquals(getClientIp(reqWithNoIp), null);
});


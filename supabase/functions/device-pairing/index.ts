import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import {
  CLAIM_RATE_LIMIT_THRESHOLD,
  CLAIM_RATE_LIMIT_WINDOW_MS,
  REGISTER_RATE_LIMIT_IP_THRESHOLD,
  REGISTER_RATE_LIMIT_VEHICLE_THRESHOLD,
  REGISTER_RATE_LIMIT_WINDOW_MS,
  START_RATE_LIMIT_MAX_PENDING_PER_VEHICLE,
  claimErrorReason,
  classifyOwnershipClaim,
  generateCarToken,
  generateDeviceCode,
  generateUserCode,
  hashToken,
  isClaimRateLimited,
  isRegisterIpRateLimited,
  isRegisterVehicleRateLimited,
  isStartRateLimited,
  isValidDeviceCode,
  isValidUserCodeFormat,
  isValidVehicleId,
  normalizeAndFormatUserCode,
  resolvePollStatus,
} from "./pairing.ts";

// ---------------------------------------------------------------------------
// Helpers: HTTP, CORS, env
// ---------------------------------------------------------------------------

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

function jsonResponse(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders,
      ...extraHeaders,
    },
  });
}

function errorResponse(
  status: number,
  error: string,
  reason: string,
  message: string,
  extra: Record<string, unknown> = {},
): Response {
  return jsonResponse({ error, reason, message, ...extra }, status);
}

function getServiceClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new Error("SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not set");
  }
  return createClient(url, key, { auth: { persistSession: false } });
}

function getAnonClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !key) {
    throw new Error("SUPABASE_URL or SUPABASE_ANON_KEY not set");
  }
  return createClient(url, key, { auth: { persistSession: false } });
}

function routeFromPath(pathname: string): "start" | "poll" | "claim" | "register" | null {
  // Supabase mounts at /functions/v1/device-pairing[/...]
  // Also support local serve at /device-pairing/...
  if (pathname.endsWith("/start")) return "start";
  if (pathname.endsWith("/poll")) return "poll";
  if (pathname.endsWith("/claim")) return "claim";
  if (pathname.endsWith("/register")) return "register";
  return null;
}

async function readJsonBody(
  req: Request,
): Promise<Record<string, unknown> | null> {
  try {
    const text = await req.text();
    if (!text) return {};
    return JSON.parse(text) as Record<string, unknown>;
  } catch {
    return null;
  }
}

export function getClientIp(req: Request): string | null {
  // In Supabase Edge Functions (hosted on Cloudflare), cf-connecting-ip
  // is authoritative from the edge proxy and cannot be spoofed by the client (F2).
  const cfIp = req.headers.get("cf-connecting-ip");
  if (cfIp && cfIp.trim()) return cfIp.trim();

  // Upstream reverse-proxy header
  const realIp = req.headers.get("x-real-ip");
  if (realIp && realIp.trim()) return realIp.trim();

  // Fallback for local development or testing environments:
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) {
    const parts = forwarded.split(",").map((p) => p.trim()).filter(Boolean);
    if (parts.length > 0) return parts[0];
  }
  return null;
}


// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

export async function handleStart(
  req: Request,
  serviceOverride?: SupabaseClient,
): Promise<Response> {
  const body = await readJsonBody(req);
  if (body === null) {
    return errorResponse(
      400,
      "invalid_request",
      "invalid_body",
      "Invalid JSON body",
    );
  }
  const vehicleId = body["vehicle_id"] as unknown;
  if (!isValidVehicleId(vehicleId)) {
    return errorResponse(
      400,
      "invalid_request",
      "invalid_vehicle_id",
      "vehicle_id is required (1-128 chars)",
    );
  }
  const vehicle_id = (vehicleId as string).trim();

  const service = serviceOverride ?? getServiceClient();

  // H2: per-vehicle pending session cap (no more than N pending at once)
  try {
    const { count: pendingCount, error: countErr } = await service
      .from("device_pairing_sessions")
      .select("device_code", { count: "exact", head: true })
      .eq("vehicle_id", vehicle_id)
      .eq("status", "pending")
      .gt("expires_at", new Date().toISOString());
    if (!countErr && typeof pendingCount === "number" && isStartRateLimited(pendingCount)) {
      return errorResponse(
        429,
        "rate_limited",
        "rate_limited",
        "Too many pending pairing sessions for this vehicle, try again later",
      );
    }
  } catch {
    // Rate-limit check is best-effort; don't block session creation if it fails
    console.warn("device-pairing/start rate-limit check failed");
  }

  const user_code = generateUserCode();
  const device_code = generateDeviceCode();

  const { data, error } = await service
    .from("device_pairing_sessions")
    .insert({
      device_code,
      user_code,
      vehicle_id,
      status: "pending",
    })
    .select("expires_at")
    .single();

  if (error || !data) {
    // Unique violation on user_code while pending is rare; retry once if needed.
    console.error("device-pairing/start insert failed", error);
    return errorResponse(
      500,
      "server_error",
      "insert_failed",
      "Failed to create pairing session",
    );
  }
  if (
    typeof data !== "object" ||
    data === null ||
    !("expires_at" in data)
  ) {
    console.error("device-pairing/start missing expires_at in db response");
    return errorResponse(
      500,
      "server_error",
      "insert_failed",
      "Failed to create pairing session",
    );
  }
  const rawExpiresAt = data.expires_at;
  if (typeof rawExpiresAt !== "string") {
    console.error("device-pairing/start invalid expires_at type");
    return errorResponse(
      500,
      "server_error",
      "insert_failed",
      "Failed to create pairing session",
    );
  }
  const expires_at = rawExpiresAt;

  return jsonResponse({ user_code, device_code, expires_at }, 201);
}

export async function handleRegister(
  req: Request,
  serviceOverride?: SupabaseClient,
): Promise<Response> {
  const body = await readJsonBody(req);
  if (body === null) {
    return errorResponse(
      400,
      "invalid_request",
      "invalid_body",
      "Invalid JSON body",
    );
  }
  const vehicleId = body["vehicle_id"] as unknown;
  if (!isValidVehicleId(vehicleId)) {
    return errorResponse(
      400,
      "invalid_request",
      "invalid_vehicle_id",
      "vehicle_id is required (1-128 chars, valid identifier)",
    );
  }
  const vehicle_id = (vehicleId as string).trim();
  const clientIp = getClientIp(req);

  const service = serviceOverride ?? getServiceClient();

  // P5-T1: per-vehicle and per-IP rate limiting.
  // Intentional fail-open trade-off (F3):
  // If the query to device_registration_attempts fails (e.g. database blip, RLS, or maintenance),
  // we catch the error, log a warning, and proceed with registration. Failing closed would reject
  // legitimate car registrations during backend blips, preventing vehicle telemetry recording and sync,
  // which is far worse than a temporary bypass of rate limiting.
  const windowStartIso = new Date(
    Date.now() - REGISTER_RATE_LIMIT_WINDOW_MS,
  ).toISOString();

  // Check per-vehicle rate limit
  try {

    const { count: vehicleAttempts, error: vehicleErr } = await service
      .from("device_registration_attempts")
      .select("id", { count: "exact", head: true })
      .eq("vehicle_id", vehicle_id)
      .gt("attempted_at", windowStartIso);
    if (
      !vehicleErr &&
      typeof vehicleAttempts === "number" &&
      isRegisterVehicleRateLimited(vehicleAttempts)
    ) {
      return errorResponse(
        429,
        "rate_limited",
        "rate_limited",
        "Too many registration attempts for this vehicle, try again later",
      );
    }
  } catch {
    console.warn("device-pairing/register vehicle rate-limit check failed");
  }

  // Check per-IP rate limit
  if (clientIp) {
    try {
      const { count: ipAttempts, error: ipErr } = await service
        .from("device_registration_attempts")
        .select("id", { count: "exact", head: true })
        .eq("ip", clientIp)
        .gt("attempted_at", windowStartIso);
      if (
        !ipErr &&
        typeof ipAttempts === "number" &&
        isRegisterIpRateLimited(ipAttempts)
      ) {
        return errorResponse(
          429,
          "rate_limited",
          "rate_limited",
          "Too many registration attempts from this IP, try again later",
        );
      }
    } catch {
      console.warn("device-pairing/register IP rate-limit check failed");
    }
  }

  // Record this attempt (best-effort, counted toward future limits)
  try {
    await service.from("device_registration_attempts").insert({
      vehicle_id,
      ip: clientIp,
    });
    // Fire-and-forget cleanup of old rows
    service.rpc("cleanup_old_registration_attempts").then(() => {}, () => {});
  } catch {
    // ignore insert failure — don't block registration
  }

  const { data, error } = await service.rpc("register_device_identity", {
    p_vehicle_id: vehicle_id,
  });
  if (error || typeof data !== "string") {
    console.error("device-pairing/register register failed", error);
    return errorResponse(
      500,
      "server_error",
      "register_failed",
      "Failed to register device identity",
    );
  }

  return jsonResponse({ car_token: data }, 201);
}

async function handlePoll(req: Request): Promise<Response> {
  const body = await readJsonBody(req);
  if (body === null) {
    return errorResponse(
      400,
      "invalid_request",
      "invalid_body",
      "Invalid JSON body",
    );
  }
  const deviceCode = body["device_code"] as unknown;
  if (!isValidDeviceCode(deviceCode)) {
    // Distinguish invalid format from expired — invalid_code vs expired
    return errorResponse(
      400,
      "invalid_request",
      "invalid_code",
      "device_code must be a UUID",
    );
  }
  const device_code = deviceCode as string;

  const service = getServiceClient();
  const { data, error } = await service
    .from("device_pairing_sessions")
    .select(
      "device_code, user_code, vehicle_id, status, expires_at, approved_by, car_token",
    )
    .eq("device_code", device_code)
    .maybeSingle();

  if (error) {
    console.error("device-pairing/poll lookup failed", error);
    return errorResponse(
      500,
      "server_error",
      "lookup_failed",
      "Failed to lookup pairing session",
    );
  }
  if (!data) {
    // Distinguishable: invalid_code (not found) vs expired
    return errorResponse(
      404,
      "not_found",
      "invalid_code",
      "Invalid device code",
    );
  }

  const resolved = resolvePollStatus(
    data as { status: string; expires_at: string },
  );
  if (resolved.expired) {
    // Mark expired if still pending
    if ((data as { status: string }).status === "pending") {
      await service.from("device_pairing_sessions").update({
        status: "expired",
      }).eq("device_code", device_code);
    }
    return jsonResponse({ status: "expired", reason: "expired" }, 200);
  }

  const status = (data as { status: string }).status;
  if (status === "approved") {
    const row = data as {
      car_token: string | null;
      approved_by: string | null;
    };
    // H1: one-time handshake — atomically consume and null car_token so it is
    // delivered only on the first approved poll. Use RPC that does SELECT FOR UPDATE + UPDATE.
    let deliveredToken: string | null = row.car_token;
    try {
      const { data: rpcToken, error: rpcErr } = await service.rpc(
        "consume_pairing_token",
        { p_device_code: device_code },
      );
      if (!rpcErr) {
        // RPC returns the token that was consumed (or null if already consumed)
        deliveredToken = rpcToken as string | null;
      } else {
        // Fallback path if RPC not available: clear via direct update and return previously selected token
        if (row.car_token !== null) {
          await service
            .from("device_pairing_sessions")
            .update({ car_token: null })
            .eq("device_code", device_code)
            .not("car_token", "is", null);
        }
        // deliveredToken stays as originally selected
      }
    } catch {
      // Best-effort: try direct update
      if (row.car_token !== null) {
        try {
          await service
            .from("device_pairing_sessions")
            .update({ car_token: null })
            .eq("device_code", device_code)
            .not("car_token", "is", null);
        } catch { /* ignore */ }
      }
    }
    // Best-effort cleanup of very old expired tokens (H1 cleanup)
    // Don't block poll response on this.
    service.rpc("cleanup_expired_pairing_tokens").then(() => {}, () => {});
    service.rpc("cleanup_old_claim_attempts").then(() => {}, () => {});

    return jsonResponse({
      status: "approved",
      car_token: deliveredToken,
      account_id: row.approved_by,
    });
  }
  if (status === "rejected") {
    return jsonResponse({ status: "rejected", reason: "rejected" });
  }
  // pending
  return jsonResponse({ status: "pending" });
}

export async function handleClaim(
  req: Request,
  deps?: { service?: SupabaseClient; anon?: SupabaseClient },
): Promise<Response> {
  // Auth: Bearer <user_jwt>
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.toLowerCase().startsWith("bearer ")) {
    return errorResponse(
      401,
      "unauthorized",
      "missing_token",
      "Missing Authorization Bearer token",
    );
  }
  const token = authHeader.slice(7).trim();
  if (!token) {
    return errorResponse(
      401,
      "unauthorized",
      "missing_token",
      "Missing Authorization Bearer token",
    );
  }

  // Verify JWT via anon client
  let accountId: string;
  try {
    const anon = deps?.anon ?? getAnonClient();
    const { data, error } = await anon.auth.getUser(token);
    if (error || !data?.user) {
      return errorResponse(
        401,
        "unauthorized",
        "invalid_token",
        "Invalid or expired token",
      );
    }
    accountId = data.user.id;
  } catch (e) {
    console.error("device-pairing/claim auth verify failed", e);
    return errorResponse(
      401,
      "unauthorized",
      "invalid_token",
      "Invalid or expired token",
    );
  }

  const body = await readJsonBody(req);
  if (body === null) {
    return errorResponse(
      400,
      "invalid_request",
      "invalid_body",
      "Invalid JSON body",
    );
  }
  const rawUserCode = body["user_code"] as unknown;
  if (typeof rawUserCode !== "string" || !isValidUserCodeFormat(rawUserCode)) {
    return errorResponse(
      400,
      "invalid_request",
      "invalid_code",
      "user_code must be 6 digits (e.g. 482-910)",
    );
  }
  const formatted = normalizeAndFormatUserCode(rawUserCode)!;
  const digits = rawUserCode.replace(/\D/g, "");
  // Also accept stored form with dash or without
  const candidateCodes = [formatted, digits];
  // Also handle edge: stored always formatted, but query both
  const service = deps?.service ?? getServiceClient();

  // H2: per-account claim rate limiting (5 attempts per 10 minutes)
  const windowStartIso = new Date(Date.now() - CLAIM_RATE_LIMIT_WINDOW_MS).toISOString();
  try {
    const { count: attemptCount, error: countErr } = await service
      .from("pairing_claim_attempts")
      .select("id", { count: "exact", head: true })
      .eq("account_id", accountId)
      .gt("attempted_at", windowStartIso);
    if (!countErr && typeof attemptCount === "number" && isClaimRateLimited(attemptCount)) {
      return errorResponse(
        429,
        "rate_limited",
        "rate_limited",
        "Too many pairing attempts, try again later",
      );
    }
  } catch {
    console.warn("device-pairing/claim rate-limit check failed");
  }
  // Record this attempt (best-effort, counted toward future limits)
  try {
    await service.from("pairing_claim_attempts").insert({ account_id: accountId });
    // Fire-and-forget cleanup of old rows
    service.rpc("cleanup_old_claim_attempts").then(() => {}, () => {});
  } catch {
    // ignore insert failure — don't block claim
  }

  // Lookup pending session by user_code (try both forms)
  // Use `in` filter for the two shapes
  const { data: sessions, error: lookupError } = await service
    .from("device_pairing_sessions")
    .select(
      "device_code, user_code, vehicle_id, status, expires_at, approved_by",
    )
    .in("user_code", candidateCodes)
    .limit(10);

  if (lookupError) {
    console.error("device-pairing/claim lookup failed", lookupError);
    return errorResponse(
      500,
      "server_error",
      "lookup_failed",
      "Failed to lookup pairing session",
    );
  }

  // Prefer exact formatted match, else any
  let session = (sessions as
    | Array<{
      device_code: string;
      user_code: string;
      vehicle_id: string;
      status: string;
      expires_at: string;
      approved_by: string | null;
    }>
    | null)?.find((s) => candidateCodes.includes(s.user_code)) ?? null;

  // Fallback: if in() missed due to case, try single eq on formatted
  if (!session) {
    const { data: single, error: singleErr } = await service
      .from("device_pairing_sessions")
      .select(
        "device_code, user_code, vehicle_id, status, expires_at, approved_by",
      )
      .eq("user_code", formatted)
      .maybeSingle();
    if (singleErr) {
      console.error("device-pairing/claim fallback lookup failed", singleErr);
      return errorResponse(
        500,
        "server_error",
        "lookup_failed",
        "Failed to lookup pairing session",
      );
    }
    if (single && typeof single === "object" && "device_code" in single) {
      session = single as unknown as typeof session;
    }
  }

  const reason = claimErrorReason(
    session as { status: string; expires_at: string } | null,
  );
  if (reason === "invalid_code") {
    return errorResponse(404, "not_found", "invalid_code", "Invalid user code");
  }
  if (reason === "expired") {
    if (session && (session as { status: string }).status === "pending") {
      await service
        .from("device_pairing_sessions")
        .update({ status: "expired" })
        .eq("device_code", (session as { device_code: string }).device_code);
    }
    return errorResponse(410, "expired", "expired", "Pairing code expired");
  }
  if (reason === "already_claimed") {
    return errorResponse(
      409,
      "already_claimed",
      "already_claimed",
      "Pairing code already used",
    );
  }

  // session is pending and not expired
  const vehicle_id = (session as { vehicle_id: string }).vehicle_id;
  const device_code = (session as { device_code: string }).device_code;

  // Check vehicle_ownership for conflict with another account
  const { data: ownerships, error: ownershipErr } = await service
    .from("vehicle_ownership")
    .select("account_id, revoked_at")
    .eq("vehicle_id", vehicle_id);

  if (ownershipErr) {
    console.error("device-pairing/claim ownership lookup failed", ownershipErr);
    return errorResponse(
      500,
      "server_error",
      "ownership_lookup_failed",
      "Failed to check vehicle ownership",
    );
  }

  const classification = classifyOwnershipClaim(
    (ownerships as Array<{ account_id: string; revoked_at: string | null }>) ??
      [],
    accountId,
  );
  if (classification === "already_owned_by_other") {
    return errorResponse(
      409,
      "vehicle_already_claimed",
      "vehicle_already_claimed",
      "Vehicle already linked to another account",
    );
  }

  // H3.2: atomic claim via security-definer RPC — ownership + device + approve in one transaction
  // Keeps the check-then-insert from racing and avoids orphan rows.
  // We keep the pre-check above for fast-path rejection, but the RPC is authoritative.
  const carToken = generateCarToken();
  const tokenHash = await hashToken(carToken);

  let rpcData: unknown = null;
  let rpcError: unknown = null;
  try {
    const res = await service.rpc("claim_pairing_session", {
      p_device_code: device_code,
      p_vehicle_id: vehicle_id,
      p_account_id: accountId,
      p_token_hash: tokenHash,
      p_car_token: carToken,
    });
    rpcData = res.data;
    rpcError = res.error;
  } catch (e) {
    rpcError = e;
  }

  if (rpcError) {
    const code = (rpcError as { code?: string }).code;
    const msg = (rpcError as { message?: string }).message ?? "";
    console.error("device-pairing/claim RPC failed", rpcError);
    // Map known pg error codes from the function
    if (code === "P0002" || msg.includes("already_claimed")) {
      return errorResponse(409, "already_claimed", "already_claimed", "Pairing code already used");
    }
    if (code === "P0001" || msg.includes("invalid_device_code")) {
      return errorResponse(404, "not_found", "invalid_code", "Invalid device code");
    }
    if (code === "P0003" || msg.includes("expired")) {
      return errorResponse(410, "expired", "expired", "Pairing code expired");
    }
    // Unique violation that escaped the function's own handling — treat as vehicle already claimed
    if (code === "23505") {
      return errorResponse(409, "vehicle_already_claimed", "vehicle_already_claimed", "Vehicle already linked to another account");
    }
    return errorResponse(500, "server_error", "claim_failed", "Failed to claim pairing session");
  }

  // Function returns {error: 'vehicle_already_claimed'} on active owner conflict
  if (rpcData && typeof rpcData === "object" && "error" in (rpcData as Record<string, unknown>)) {
    const errVal = (rpcData as Record<string, unknown>)["error"];
    if (errVal === "vehicle_already_claimed") {
      return errorResponse(409, "vehicle_already_claimed", "vehicle_already_claimed", "Vehicle already linked to another account");
    }
    // Generic conflict
    if (errVal) {
      return errorResponse(409, "conflict", String(errVal), "Claim conflict");
    }
  }

  // Success: rpcData should be {ok: true}; carry the RPC's backfill count
  // through for the client. Absent (older RPC) or non-numeric => 0.
  const rpcRecord = (rpcData ?? {}) as Record<string, unknown>;
  const backfilled = typeof rpcRecord["backfilled"] === "number"
    ? rpcRecord["backfilled"]
    : 0;
  return jsonResponse({
    status: "approved",
    vehicle_id,
    account_id: accountId,
    backfilled,
    message: "Vehicle linked",
  });
}

// ---------------------------------------------------------------------------
// Top-level handler — only serve when run as main, not when imported for tests
// ---------------------------------------------------------------------------

if (import.meta.main) {
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return errorResponse(
      405,
      "method_not_allowed",
      "method_not_allowed",
      "Only POST is allowed",
    );
  }

  const url = new URL(req.url);
  const route = routeFromPath(url.pathname);

  if (route === null) {
    // Provide helpful 404 distinguishing valid routes
    return errorResponse(
      404,
      "not_found",
      "invalid_route",
      "Unknown route. Use /device-pairing/start, /device-pairing/poll, /device-pairing/claim, or /device-pairing/register",
    );
  }

  try {
    switch (route) {
      case "start":
        return await handleStart(req);
      case "poll":
        return await handlePoll(req);
      case "claim":
        return await handleClaim(req);
      case "register":
        return await handleRegister(req);
    }
  } catch (e) {
    console.error(`device-pairing/${route} unhandled`, e);
    return errorResponse(
      500,
      "server_error",
      "unhandled",
      "Internal server error",
    );
  }
});
}

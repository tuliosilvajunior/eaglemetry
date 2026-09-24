// Pure helpers for device pairing flow — no Supabase I/O, fully unit-testable.

/**
 * Formats 6 digits as XXX-XXX (e.g. "482910" -> "482-910").
 */
export function formatUserCode(digits: string): string {
  if (digits.length !== 6 || !/^\d{6}$/.test(digits)) {
    throw new Error("formatUserCode expects exactly 6 digits");
  }
  return `${digits.slice(0, 3)}-${digits.slice(3)}`;
}

/**
 * Normalizes a user_code by stripping non-digits.
 * Returns 6-digit string or null if not 6 digits.
 */
export function normalizeUserCode(input: string): string | null {
  const digits = input.replace(/\D/g, "");
  if (digits.length !== 6) return null;
  return digits;
}

/**
 * Returns formatted XXX-XXX or null if input invalid.
 */
export function normalizeAndFormatUserCode(input: string): string | null {
  const digits = normalizeUserCode(input);
  if (digits === null) return null;
  return formatUserCode(digits);
}

/** Checks whether a user_code string is syntactically valid (6 digits with optional dash). */
export function isValidUserCodeFormat(input: string): boolean {
  return normalizeUserCode(input) !== null;
}

/**
 * Generates a random 6-digit user_code formatted as XXX-XXX.
 * Uses crypto.getRandomValues for entropy.
 */
export function generateUserCode(): string {
  const arr = new Uint8Array(6);
  crypto.getRandomValues(arr);
  // Map each byte to 0-9? Instead build a 0-999999 integer from random bytes.
  // Use 3 random bytes for 6 digits worth of entropy plus bias correction via modulo.
  const rand = new Uint32Array(1);
  crypto.getRandomValues(rand);
  const num = rand[0] % 1_000_000;
  const digits = num.toString().padStart(6, "0");
  return formatUserCode(digits);
}

/** Generates a high-entropy device_code (UUID v4). */
export function generateDeviceCode(): string {
  return crypto.randomUUID();
}

/**
 * Generates a scoped car token (32 random bytes, base64url).
 * 256 bits entropy, URL-safe, no padding.
 */
export function generateCarToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  // base64url encode
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  const base64 = btoa(binary);
  return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * SHA-256 hex hash of a token. Uses Web Crypto SubtleCrypto.
 * Never store raw token in vehicle_devices — only this hash.
 */
export async function hashToken(token: string): Promise<string> {
  const data = new TextEncoder().encode(token);
  const hash = await crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(hash);
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Returns true if expiresAt is in the past. */
export function isExpired(expiresAt: string | Date): boolean {
  const t = expiresAt instanceof Date
    ? expiresAt.getTime()
    : new Date(expiresAt).getTime();
  if (isNaN(t)) return true; // treat unparseable as expired
  return Date.now() > t;
}

/**
 * Strict vehicle_id validation (P5-T1):
 * - Must be a string.
 * - Trimmed length between 1 and 128 characters.
 * - Must not be the sentinel placeholder "unassigned" (case-insensitive).
 * - Must contain only alphanumeric characters, dashes, underscores, dots, or colons.
 *   Disallows spaces, control characters, newlines, path traversal, quotes, and symbols.
 */
export function isValidVehicleId(vehicleId: unknown): boolean {
  if (typeof vehicleId !== "string") return false;
  const trimmed = vehicleId.trim();
  if (trimmed.length < 1 || trimmed.length > 128) return false;
  if (trimmed.toLowerCase() === "unassigned") return false;
  return /^[a-zA-Z0-9_\-\.:]+$/.test(trimmed);
}

/** Validates device_code UUID format. */
export function isValidDeviceCode(code: unknown): boolean {
  if (typeof code !== "string") return false;
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
    code,
  );
}

/**
 * Claim idempotency helper (pure): decides whether an ownership insert
 * should be treated as idempotent success vs. conflict with another account.
 *
 * - existingOwnerships: rows for same vehicle_id with revoked_at=null
 * - claimantAccountId: the account attempting the claim
 * Returns "ok" | "already_owned_by_self" | "already_owned_by_other"
 */
export function classifyOwnershipClaim(
  existingOwnerships: Array<{ account_id: string; revoked_at: string | null }>,
  claimantAccountId: string,
): "ok" | "already_owned_by_self" | "already_owned_by_other" {
  const active = existingOwnerships.filter((r) => r.revoked_at === null);
  if (active.length === 0) return "ok";
  const ownedBySelf = active.some((r) => r.account_id === claimantAccountId);
  const ownedByOther = active.some((r) => r.account_id !== claimantAccountId);
  if (ownedBySelf && !ownedByOther) return "already_owned_by_self";
  if (ownedByOther) return "already_owned_by_other";
  return "ok";
}

/**
 * Determines the polling response status, including expiry handling.
 * Pure function to make expiry-vs-status logic testable.
 */
export function resolvePollStatus(
  session: { status: string; expires_at: string },
): { status: string; expired: boolean } {
  if (isExpired(session.expires_at)) {
    return { status: "expired", expired: true };
  }
  if (session.status === "expired") return { status: "expired", expired: true };
  return { status: session.status, expired: false };
}

/**
 * Determines the error reason for a claim lookup that failed or is not pending.
 * Distinguishes invalid_code vs expired vs already_claimed.
 */
export function claimErrorReason(
  session: { status: string; expires_at: string } | null,
): "invalid_code" | "expired" | "already_claimed" | null {
  if (session === null) return "invalid_code";
  if (isExpired(session.expires_at)) return "expired";
  if (session.status === "expired") return "expired";
  if (session.status !== "pending") return "already_claimed";
  return null; // no error, claim may proceed
}

// ---------------------------------------------------------------------------
// Rate limiting (H2)
// ---------------------------------------------------------------------------

/** Max claim attempts per account per window before `rate_limited`. */
export const CLAIM_RATE_LIMIT_THRESHOLD = 5;

/** Window for claim rate limiting (10 minutes). */
export const CLAIM_RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000;

/** Max concurrent pending sessions per vehicle_id before start is rate limited. */
export const START_RATE_LIMIT_MAX_PENDING_PER_VEHICLE = 5;

/** True when claim attempts in window meet or exceed threshold. */
export function isClaimRateLimited(
  attemptsInWindow: number,
  threshold: number = CLAIM_RATE_LIMIT_THRESHOLD,
): boolean {
  return attemptsInWindow >= threshold;
}

/** True when pending sessions for a vehicle meet or exceed max. */
export function isStartRateLimited(
  pendingCount: number,
  max: number = START_RATE_LIMIT_MAX_PENDING_PER_VEHICLE,
): boolean {
  return pendingCount >= max;
}

/** Max registration attempts per vehicle per window before `rate_limited`. */
export const REGISTER_RATE_LIMIT_VEHICLE_THRESHOLD = 5;

/** Max registration attempts per IP per window before `rate_limited`. */
export const REGISTER_RATE_LIMIT_IP_THRESHOLD = 10;

/** Window for registration rate limiting (10 minutes). */
export const REGISTER_RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000;

/** True when registration attempts for a vehicle meet or exceed threshold. */
export function isRegisterVehicleRateLimited(
  attemptsInWindow: number,
  threshold: number = REGISTER_RATE_LIMIT_VEHICLE_THRESHOLD,
): boolean {
  return attemptsInWindow >= threshold;
}

/** True when registration attempts for an IP meet or exceed threshold. */
export function isRegisterIpRateLimited(
  attemptsInWindow: number,
  threshold: number = REGISTER_RATE_LIMIT_IP_THRESHOLD,
): boolean {
  return attemptsInWindow >= threshold;
}

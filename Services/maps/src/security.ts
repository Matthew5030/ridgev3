import { Buffer } from 'node:buffer';
import { X509Certificate } from 'node:crypto';
import cbor from 'cbor';
import { verifyAttestation, verifyAssertion } from 'node-app-attest';

export class HTTPError extends Error {
  constructor(public status: number, public code: string) { super(code); }
}
export const seconds = () => Math.floor(Date.now() / 1000);
export const encode = (data: Uint8Array) => Buffer.from(data).toString('base64url');
export const random = () => encode(crypto.getRandomValues(new Uint8Array(32)));
export function base64(value: unknown, maximum: number): Buffer {
  if (typeof value !== 'string' || value.length > maximum * 2 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw new HTTPError(400, 'invalid_request');
  const bytes = Buffer.from(value, 'base64');
  if (!bytes.length || bytes.length > maximum || bytes.toString('base64') !== value) throw new HTTPError(400, 'invalid_request');
  return bytes;
}
export function keyID(value: unknown): string {
  if (base64(value, 32).length !== 32) throw new HTTPError(400, 'invalid_request');
  return value as string;
}
export async function boundedJSON(request: Request): Promise<Record<string, unknown>> {
  if (!request.headers.get('Content-Type')?.startsWith('application/json')) throw new HTTPError(415, 'json_required');
  if (Number(request.headers.get('Content-Length') || 0) > 32_768) throw new HTTPError(413, 'request_too_large');
  const reader = request.body?.getReader();
  if (!reader) throw new HTTPError(400, 'invalid_request');
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const {value, done} = await reader.read(); if (done) break;
      size += value.byteLength;
      if (size > 32_768) { await reader.cancel(); throw new HTTPError(413, 'request_too_large'); }
      chunks.push(value);
    }
    const parsed: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error();
    return parsed as Record<string, unknown>;
  } catch (error) { if (error instanceof HTTPError) throw error; throw new HTTPError(400, 'invalid_request'); }
  finally { reader.releaseLock(); }
}

export function attest(bytes: Buffer, challenge: string, keyId: string, env: Env) {
  // Supplement the protocol library's pinned Apple chain/signature checks with
  // certificate validity and ordering checks. Never accept development keys here.
  const decoded = cbor.decodeAllSync(bytes, {max_depth: 16});
  if (decoded.length !== 1) throw new Error('invalid_attestation');
  const certs = decoded[0]?.attStmt?.x5c;
  if (!Array.isArray(certs) || certs.length !== 2) throw new Error('invalid_chain');
  const chain = certs.map((der: Buffer) => new X509Certificate(der));
  const now = Date.now();
  if (chain[0].ca || !chain[1].ca || chain.some(c => now < Date.parse(c.validFrom) || now > Date.parse(c.validTo))) throw new Error('invalid_certificate');
  return verifyAttestation({attestation: bytes, challenge, keyId,
    bundleIdentifier: env.APPLE_BUNDLE_ID, teamIdentifier: env.APPLE_TEAM_ID,
    allowDevelopmentEnvironment: false});
}
export function assertSession(bytes: Buffer, challenge: string, publicKey: string, signCount: number, env: Env) {
  const decoded = cbor.decodeAllSync(bytes, {max_depth: 16});
  if (decoded.length !== 1 || !Buffer.isBuffer(decoded[0]?.authenticatorData) || decoded[0].authenticatorData.length < 37 || !Buffer.isBuffer(decoded[0]?.signature)) throw new Error('invalid_assertion');
  return verifyAssertion({assertion: bytes, payload: challenge, publicKey,
    bundleIdentifier: env.APPLE_BUNDLE_ID, teamIdentifier: env.APPLE_TEAM_ID, signCount});
}

interface Claims { sub: string; exp: number; iat: number; aud: string; prefix: string; }
async function signingKey(secret: string) {
  if (secret.length < 43) throw new Error('missing_token_secret');
  return crypto.subtle.importKey('raw', new TextEncoder().encode(secret), {name: 'HMAC', hash: 'SHA-256'}, false, ['sign','verify']);
}
export async function issueToken(key: string, origin: string, env: Env) {
  const now = seconds();
  const claims: Claims = {sub: key, iat: now, exp: now + 900, aud: origin, prefix: env.MAP_PREFIX};
  const payload = encode(new TextEncoder().encode(JSON.stringify(claims)));
  const signature = await crypto.subtle.sign('HMAC', await signingKey(env.TOKEN_SECRET), new TextEncoder().encode(payload));
  return {token: `${payload}.${encode(new Uint8Array(signature))}`, expiresAt: claims.exp};
}
export async function validateToken(request: Request, env: Env): Promise<Claims> {
  const value = request.headers.get('Authorization');
  if (!value || value.length > 2048 || !/^Bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(value)) throw new HTTPError(401, 'unauthorized');
  const [payload, signature] = value.slice(7).split('.');
  const ok = await crypto.subtle.verify('HMAC', await signingKey(env.TOKEN_SECRET), Buffer.from(signature, 'base64url'), new TextEncoder().encode(payload));
  if (!ok) throw new HTTPError(401, 'unauthorized');
  let claims: Claims;
  try { claims = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')); } catch { throw new HTTPError(401, 'unauthorized'); }
  const now = seconds();
  if (typeof claims.sub !== 'string' || claims.sub.length !== 44 || !Number.isInteger(claims.exp) || !Number.isInteger(claims.iat) || claims.exp <= now || claims.iat > now + 30 || claims.exp - claims.iat !== 900 || claims.aud !== new URL(request.url).origin || claims.prefix !== env.MAP_PREFIX) throw new HTTPError(401, 'unauthorized');
  return claims;
}

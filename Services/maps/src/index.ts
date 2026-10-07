import { HTTPError, seconds, random, base64, keyID, boundedJSON, attest, assertSession, issueToken, validateToken } from './security';

const json = (value: unknown, status = 200) => Response.json(value, {status, headers: {'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'}});
interface Installation { public_key: string; sign_count: number; revoked: number; }
async function authenticate(request: Request, env: Env): Promise<Response> {
  if (!(await env.AUTH_LIMIT.limit({key: request.headers.get('CF-Connecting-IP') || 'unknown'})).success) throw new HTTPError(429, 'try_later');
  const body = await boundedJSON(request);
  const id = keyID(body.keyId);
  const path = new URL(request.url).pathname;
  if (path === '/auth/challenge') {
    if (body.purpose !== 'register' && body.purpose !== 'session') throw new HTTPError(400, 'invalid_request');
    const challenge = random();
    await env.AUTH_DB.prepare('INSERT INTO challenges(challenge,key_id,purpose,expires_at) VALUES(?,?,?,?)').bind(challenge,id,body.purpose,seconds()+120).run();
    return json({challenge});
  }
  if (path !== '/auth/register' && path !== '/auth/session') throw new HTTPError(404, 'not_found');
  if (typeof body.challenge !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(body.challenge)) throw new HTTPError(400, 'invalid_request');
  const purpose = path === '/auth/register' ? 'register' : 'session';
  // Atomic claim: a challenge can be consumed once, including concurrent requests.
  const claimed = await env.AUTH_DB.prepare('DELETE FROM challenges WHERE challenge=? AND key_id=? AND purpose=? AND expires_at>? RETURNING challenge').bind(body.challenge,id,purpose,seconds()).first();
  if (!claimed) throw new HTTPError(401, 'challenge_expired');
  if (purpose === 'register') {
    const bytes = base64(body.attestation, 20_000);
    let result: ReturnType<typeof attest>;
    try { result = attest(bytes,body.challenge,id,env); } catch { throw new HTTPError(401, 'invalid_attestation'); }
    const inserted = await env.AUTH_DB.prepare('INSERT OR IGNORE INTO installations(key_id,public_key,receipt,created_at,last_seen) VALUES(?,?,?,?,?)').bind(id,result.publicKey,result.receipt.toString('base64'),seconds(),seconds()).run();
    if (!inserted.meta.changes) throw new HTTPError(409, 'already_registered');
  } else {
    const device = await env.AUTH_DB.prepare('SELECT public_key,sign_count,revoked FROM installations WHERE key_id=?').bind(id).first<Installation>();
    if (!device) throw new HTTPError(401, 'registration_required');
    if (device.revoked) throw new HTTPError(403, 'installation_blocked');
    const bytes = base64(body.assertion, 4096);
    let next: number;
    try { next = assertSession(bytes,body.challenge,device.public_key,device.sign_count,env).signCount; } catch { throw new HTTPError(401, 'invalid_assertion'); }
    const advanced = await env.AUTH_DB.prepare('UPDATE installations SET sign_count=?,last_seen=? WHERE key_id=? AND sign_count=? AND revoked=0').bind(next,seconds(),id,device.sign_count).run();
    if (!advanced.meta.changes) throw new HTTPError(401, 'invalid_assertion');
  }
  return json(await issueToken(id,new URL(request.url).origin,env));
}

export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      if (url.protocol !== 'https:' && url.hostname !== 'localhost' && url.hostname !== '127.0.0.1') throw new HTTPError(400, 'https_required');
      if (url.pathname === '/health' && request.method === 'GET') return json({service: 'ridge-maps', status: 'ok'});
      if (url.pathname.startsWith('/auth/')) {
        if (request.method !== 'POST') throw new HTTPError(405, 'method_not_allowed');
        return await authenticate(request, env);
      }
      if (!['GET','HEAD'].includes(request.method)) throw new HTTPError(405, 'method_not_allowed');
      // No map lookup or cache read is allowed before authentication.
      let claims: Awaited<ReturnType<typeof validateToken>>;
      try { claims = await validateToken(request, env); }
      catch (error) {
        if (!(await env.INVALID_LIMIT.limit({key: request.headers.get('CF-Connecting-IP') || 'unknown'})).success) throw new HTTPError(429, 'try_later');
        throw error;
      }
      if (!(await env.MAP_LIMIT.limit({key: claims.sub})).success) throw new HTTPError(429, 'try_later');
      const key = url.pathname.slice(1);
      // Immutable published assets only. No bucket listing, uploads or arbitrary paths.
      if (url.search || !key.startsWith(env.MAP_PREFIX) || !/^[a-zA-Z0-9_./-]+$/.test(key) || key.split('/').some(p => !p || p === '.' || p === '..') || !/\.(json|zlib|jpg)$/.test(key) || key.includes('upload-inventory')) throw new HTTPError(404, 'not_found');
      const cacheKey = new Request(url.origin + '/' + key, {method: 'GET'});
      let response = await caches.default.match(cacheKey);
      if (!response) {
        const object = await env.MAPS.get(key);
        if (!object) throw new HTTPError(404, 'not_found');
        const headers = new Headers(); object.writeHttpMetadata(headers);
        headers.delete('Content-Encoding');
        headers.set('Content-Type', key.endsWith('.json') ? 'application/json' : key.endsWith('.jpg') ? 'image/jpeg' : 'application/octet-stream');
        headers.set('Content-Length', String(object.size));
        headers.set('ETag', object.httpEtag);
        headers.set('Cache-Control','public, max-age=31536000, immutable');
        response = new Response(object.body,{headers});
        ctx.waitUntil(caches.default.put(cacheKey, response.clone()));
      }
      const headers = new Headers(response.headers);
      // Only the internal cache stores a public copy; browsers/proxies must reauthenticate.
      headers.set('Cache-Control','private, no-store');
      headers.set('X-Content-Type-Options','nosniff');
      return new Response(request.method === 'HEAD' ? null : response.body,{headers});
    } catch (error) {
      if (error instanceof HTTPError) {
        const response = json({error: error.code},error.status);
        if (error.status === 401) response.headers.set('WWW-Authenticate','Bearer realm="ridge-maps"');
        if (error.status === 429) response.headers.set('Retry-After','60');
        return response;
      }
      console.error(JSON.stringify({event: 'request_failed', kind: error instanceof Error ? error.name : 'unknown'}));
      return json({error:'temporarily_unavailable'},503);
    }
  },
  async scheduled(_event, env) {
    await env.AUTH_DB.prepare('DELETE FROM challenges WHERE expires_at<=?').bind(seconds()).run();
  }
} satisfies ExportedHandler<Env>;

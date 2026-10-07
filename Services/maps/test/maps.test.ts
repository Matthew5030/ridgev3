import {beforeAll, beforeEach, describe, expect, it} from 'vitest';
import {env, exports} from 'cloudflare:workers';
import {Buffer} from 'node:buffer';
import {createHash, createSign, generateKeyPairSync} from 'node:crypto';
import cbor from 'cbor';
import schema from '../migrations/0001_auth.sql?raw';
import {issueToken, seconds} from '../src/security';
const origin='https://maps.example.test';
const key=Buffer.alloc(32,7).toString('base64');
const object='pilot-2026-10-07/sources/world-test/tile.rat.zlib';
const pair=generateKeyPairSync('ec',{namedCurve:'prime256v1'});
const publicKey=pair.publicKey.export({type:'spki',format:'pem'});
const send=(path:string,body:unknown) => exports.default.fetch(origin+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
async function token() {return (await issueToken(key,origin,env)).token;}
async function get(t?:string,path=object) {return exports.default.fetch(origin+'/'+path,{headers:t?{Authorization:'Bearer '+t}:{}});}
async function challenge(purpose='session') {const r=await send('/auth/challenge',{keyId:key,purpose});expect(r.status).toBe(200);return (await r.json<{challenge:string}>()).challenge;}
function assertion(nonce:string,count=1,bundle=env.APPLE_BUNDLE_ID) {
 const auth=Buffer.alloc(37);createHash('sha256').update(env.APPLE_TEAM_ID+'.'+bundle).digest().copy(auth);auth.writeUInt32BE(count,33);
 const hash=createHash('sha256').update(Buffer.concat([auth,createHash('sha256').update(nonce).digest()])).digest();
 const signer=createSign('SHA256');signer.update(hash);
 return cbor.encode({authenticatorData:auth,signature:signer.sign(pair.privateKey)}).toString('base64');
}
beforeAll(async()=>{for(const sql of schema.split(';').filter(s=>s.trim())) await env.AUTH_DB.prepare(sql).run();});
beforeEach(async()=>{
 await env.AUTH_DB.batch([env.AUTH_DB.prepare('DELETE FROM installations'),env.AUTH_DB.prepare('DELETE FROM challenges')]);
 await env.MAPS.put(object,new Uint8Array([0,1,128,255]),{httpMetadata:{contentEncoding:'deflate'}});
});
describe('private map delivery',()=>{
 it('rejects anonymous and forged tokens before serving maps',async()=>{expect((await get()).status).toBe(401);expect((await get('fake.token')).status).toBe(401);});
 it('returns exact compressed bytes, and cache hits still require authentication',async()=>{
  const t=await token();const first=await get(t);expect(first.status).toBe(200);expect([...new Uint8Array(await first.arrayBuffer())]).toEqual([0,1,128,255]);
  expect(first.headers.get('Content-Encoding')).toBe(null);expect(first.headers.get('Cache-Control')).toBe('private, no-store');
  const second=await get(t);expect(second.status).toBe(200);await second.arrayBuffer();expect((await get()).status).toBe(401);
 });
 it('rejects tokens issued for another host or changed prefix',async()=>{
  const other=await issueToken(key,'https://other.test',env);expect((await get(other.token)).status).toBe(401);
  expect((await get(await token(),'different-version/tile.rat.zlib')).status).toBe(404);
 });
 it('rejects tampering and expired tokens',async()=>{
  const t=await token();const [p,s]=t.split('.');const claims=JSON.parse(Buffer.from(p,'base64url').toString());claims.exp=seconds()+999999;
  expect((await get(Buffer.from(JSON.stringify(claims)).toString('base64url')+'.'+s)).status).toBe(401);
  const old=seconds()-1000;claims.iat=old;claims.exp=old+900;
  const payload=Buffer.from(JSON.stringify(claims)).toString('base64url');const cryptoKey=await crypto.subtle.importKey('raw',new TextEncoder().encode(env.TOKEN_SECRET),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const signature=await crypto.subtle.sign('HMAC',cryptoKey,new TextEncoder().encode(payload));
  expect((await get(payload+'.'+Buffer.from(signature).toString('base64url'))).status).toBe(401);
 });
 it('has no public listing, write route, inventory or query bypass',async()=>{
  const t=await token();for(const path of ['pilot-2026-10-07/','pilot-2026-10-07/upload-inventory.json',object+'?token=x']) expect((await get(t,path)).status).toBe(404);
  expect((await exports.default.fetch(origin+'/'+object,{method:'PUT',headers:{Authorization:'Bearer '+t},body:'replace'})).status).toBe(405);
 });
});
describe('installation authentication',()=>{
 beforeEach(async()=>{await env.AUTH_DB.prepare('INSERT INTO installations(key_id,public_key,receipt,created_at,last_seen) VALUES(?,?,?,?,?)').bind(key,publicKey,'test',seconds(),seconds()).run();});
 it('verifies a signed assertion and refuses its replay',async()=>{
  const nonce=await challenge();const body={keyId:key,challenge:nonce,assertion:assertion(nonce)};
  const r=await send('/auth/session',body);expect(r.status).toBe(200);const session=await r.json<{token:string}>();const map=await get(session.token);expect(map.status).toBe(200);await map.arrayBuffer();
  expect((await send('/auth/session',body)).status).toBe(401);
 });
 it('atomically consumes a challenge during simultaneous attempts',async()=>{
  const nonce=await challenge();const body={keyId:key,challenge:nonce,assertion:assertion(nonce)};
  const responses=await Promise.all([send('/auth/session',body),send('/auth/session',body)]);expect(responses.map(r=>r.status).sort()).toEqual([200,401]);
 });
 it('rejects changed challenges, wrong app identities and stale counters',async()=>{
  let nonce=await challenge();expect((await send('/auth/session',{keyId:key,challenge:nonce,assertion:assertion('different')})).status).toBe(401);
  nonce=await challenge();expect((await send('/auth/session',{keyId:key,challenge:nonce,assertion:assertion(nonce,1,'another.bundle')})).status).toBe(401);
  await env.AUTH_DB.prepare('UPDATE installations SET sign_count=10').run();nonce=await challenge();expect((await send('/auth/session',{keyId:key,challenge:nonce,assertion:assertion(nonce,9)})).status).toBe(401);
 });
 it('rejects revoked installations and expired or wrong-purpose challenges',async()=>{
  await env.AUTH_DB.prepare('UPDATE installations SET revoked=1').run();let nonce=await challenge();expect((await send('/auth/session',{keyId:key,challenge:nonce,assertion:assertion(nonce)})).status).toBe(403);
  await env.AUTH_DB.prepare('UPDATE installations SET revoked=0').run();nonce=await challenge();await env.AUTH_DB.prepare('UPDATE challenges SET expires_at=0').run();expect((await send('/auth/session',{keyId:key,challenge:nonce,assertion:assertion(nonce)})).status).toBe(401);
  nonce=await challenge('register');expect((await send('/auth/session',{keyId:key,challenge:nonce,assertion:assertion(nonce)})).status).toBe(401);
 });
 it('rejects fabricated attestation without creating an installation',async()=>{
  await env.AUTH_DB.prepare('DELETE FROM installations').run();const nonce=await challenge('register');const r=await send('/auth/register',{keyId:key,challenge:nonce,attestation:cbor.encode({fmt:'apple-appattest'}).toString('base64')});expect(r.status).toBe(401);
  expect(await env.AUTH_DB.prepare('SELECT key_id FROM installations').first()).toBe(null);
 });
 it('bounds incoming data and requires canonical 32-byte key identifiers',async()=>{
  expect((await send('/auth/challenge',{keyId:'x',purpose:'register'})).status).toBe(400);
  expect((await send('/auth/challenge',{keyId:key,purpose:'register',extra:'x'.repeat(40000)})).status).toBe(413);
 });
});

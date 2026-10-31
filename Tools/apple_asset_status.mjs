#!/usr/bin/env node
// Read-only Apple processing status. JWTs and private-key bytes never leave memory.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
const [appID,pendingJSON='[]',mode='status']=process.argv.slice(2);
const keyID=process.env.ASC_KEY_ID,issuer=process.env.ASC_ISSUER_ID;
if(!/^\d+$/.test(appID??'')||!keyID||!issuer)throw Error('Missing Apple app/key/issuer identifiers');
const keyPath=path.join(os.homedir(),'.appstoreconnect','private_keys',`AuthKey_${keyID}.p8`);
const enc=x=>Buffer.from(JSON.stringify(x)).toString('base64url'),now=Math.floor(Date.now()/1000);
const unsigned=enc({alg:'ES256',kid:keyID,typ:'JWT'})+'.'+enc({iss:issuer,iat:now,exp:now+600,aud:'appstoreconnect-v1'});
const token=unsigned+'.'+crypto.sign('sha256',Buffer.from(unsigned),{key:fs.readFileSync(keyPath),dsaEncoding:'ieee-p1363'}).toString('base64url');
async function get(resource){
 const r=await fetch('https://api.appstoreconnect.apple.com/v1/'+resource,{headers:{Authorization:'Bearer '+token}});
 const body=await r.json();if(!r.ok)throw Error('Apple status request failed: '+r.status+' '+JSON.stringify(body.errors));return body;
}
const assets=await get(`apps/${appID}/backgroundAssets?limit=200&include=internalBetaVersion&fields[backgroundAssets]=assetPackIdentifier,usedBytes,archived,internalBetaVersion&fields[backgroundAssetVersions]=state,version,platforms`);
if(assets.links?.next)throw Error('Unexpected asset pagination; review the app pack limit');
const pending=JSON.parse(pendingJSON);
if(!Array.isArray(pending)||pending.length>200||pending.some(x=>!/^[-0-9a-f]{36}$/.test(x)))throw Error('Invalid pending version identifiers');
const versions=[],files=[];
for(let offset=0;offset<pending.length;offset+=4){
 const detail = mode==='files' ? 'include=assetFile&fields[backgroundAssetVersions]=state,version,assetFile&fields[backgroundAssetUploadFiles]=fileName,fileSize,sourceFileChecksum,sourceFileChecksums,assetDeliveryState,assetType' : 'fields[backgroundAssetVersions]=state,stateDetails,version';
 const batch=await Promise.all(pending.slice(offset,offset+4).map(id=>get(`backgroundAssetVersions/${id}?${detail}`)));
 versions.push(...batch.map(x=>x.data)); files.push(...batch.flatMap(x=>x.included??[]));
}
console.log(JSON.stringify({assets,versions,files}));

#!/usr/bin/env node
// Upload native screenshots into Ridge's draft only. Never submits or releases.
// Apple upload URLs, JWTs and private-key bytes remain in memory, never receipts.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

const root=path.dirname(fileURLToPath(import.meta.url));
const appID='6827223973';
const keyID=process.env.ASC_KEY_ID,issuer=process.env.ASC_ISSUER_ID;
if(!keyID||!issuer)throw Error('Set ASC_KEY_ID and ASC_ISSUER_ID; never pass key bytes');
const encode=value=>Buffer.from(JSON.stringify(value)).toString('base64url');
const now=Math.floor(Date.now()/1000);
const unsigned=encode({alg:'ES256',kid:keyID,typ:'JWT'})+'.'+encode({iss:issuer,iat:now,exp:now+600,aud:'appstoreconnect-v1'});
const token=unsigned+'.'+crypto.sign('sha256',Buffer.from(unsigned),{
  key:fs.readFileSync(path.join(os.homedir(),'.appstoreconnect/private_keys',`AuthKey_${keyID}.p8`)),
  dsaEncoding:'ieee-p1363'
}).toString('base64url');

async function api(resource,method='GET',body){
  const response=await fetch('https://api.appstoreconnect.apple.com/v1/'+resource,{
    method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},
    body:body?JSON.stringify(body):undefined
  });
  const responseText=await response.text();
  const json=responseText?JSON.parse(responseText):{};
  if(!response.ok)throw Error(`Apple ${method} failed (${response.status}): `+JSON.stringify(json.errors?.map(x=>({code:x.code,title:x.title,detail:x.detail}))));
  return json;
}
const versions=await api(`apps/${appID}/appStoreVersions?filter[platform]=IOS&filter[versionString]=1.0&include=appStoreVersionLocalizations`);
const version=versions.data.find(v=>v.attributes.appStoreState==='PREPARE_FOR_SUBMISSION');
if(!version||version.attributes.releaseType!=='MANUAL')throw Error('Ridge 1.0 must remain a manual-release draft');
const localization=versions.included?.find(x=>x.type==='appStoreVersionLocalizations'&&x.attributes.locale==='en-GB');
if(!localization)throw Error('English UK localization missing');
let sets=(await api(`appStoreVersionLocalizations/${localization.id}/appScreenshotSets?limit=40`)).data;
const receiptFile=path.join(root,'evidence/screenshot-upload.json');
const receipts=fs.existsSync(receiptFile)?JSON.parse(fs.readFileSync(receiptFile)):[];
function save(){fs.writeFileSync(receiptFile,JSON.stringify(receipts,null,2)+'\n');}

for(const [folder,type,dimensions] of [
  ['iphone-6.9','APP_IPHONE_67',[1320,2868]],
  ['ipad-13','APP_IPAD_PRO_3GEN_129',[2064,2752]]
]){
  const directory=path.join(root,'screenshots',folder);
  const files=fs.readdirSync(directory).filter(x=>x.endsWith('.png')).sort();
  if(!files.length)continue;
  if(files.length>10)throw Error('At most 10 screenshots per display');
  let set=sets.find(x=>x.attributes.screenshotDisplayType===type);
  if(!set){set=(await api('appScreenshotSets','POST',{data:{type:'appScreenshotSets',attributes:{screenshotDisplayType:type},relationships:{appStoreVersionLocalization:{data:{type:'appStoreVersionLocalizations',id:localization.id}}}}})).data;sets.push(set);}
  let existing=(await api(`appScreenshotSets/${set.id}/appScreenshots?limit=50`)).data;
  for(const fileName of files){
    const data=fs.readFileSync(path.join(directory,fileName));
    if(!data.subarray(0,8).equals(Buffer.from('89504e470d0a1a0a','hex'))||
       !((data.readUInt32BE(16)===dimensions[0]&&data.readUInt32BE(20)===dimensions[1])||
         (folder==='ipad-13'&&data.readUInt32BE(16)===dimensions[1]&&data.readUInt32BE(20)===dimensions[0]))||data[25]!==2)
      throw Error('Screenshot must be full-size RGB PNG: '+fileName);
    const md5=crypto.createHash('md5').update(data).digest('hex');
    const sha256=crypto.createHash('sha256').update(data).digest('hex');
    let asset=existing.find(x=>x.attributes.fileName===fileName);
    if(asset&&asset.attributes.sourceFileChecksum&&asset.attributes.sourceFileChecksum!==md5)
      throw Error('Existing screenshot has different bytes; review it instead of overwriting: '+fileName);
    if(!asset)asset=(await api('appScreenshots','POST',{data:{type:'appScreenshots',attributes:{fileName,fileSize:data.length},relationships:{appScreenshotSet:{data:{type:'appScreenshotSets',id:set.id}}}}})).data;
    let record=receipts.find(x=>x.id===asset.id);
    if(!record){record={id:asset.id,setID:set.id,type,file:folder+'/'+fileName,sha256,md5,bytes:data.length,state:asset.attributes.assetDeliveryState?.state};receipts.push(record);save();}
    if(asset.attributes.assetDeliveryState?.state==='AWAITING_UPLOAD'){
      for(const operation of asset.attributes.uploadOperations??[]){
        const destination=new URL(operation.url);
        if(destination.protocol!=='https:'||!destination.hostname.endsWith('.apple.com'))throw Error('Unexpected Apple upload host');
        if(operation.offset<0||operation.length<1||operation.offset+operation.length>data.length)throw Error('Invalid upload range');
        const headers=Object.fromEntries(operation.requestHeaders.map(x=>[x.name,x.value]));
        const result=await fetch(destination,{method:operation.method,headers,body:data.subarray(operation.offset,operation.offset+operation.length)});
        if(!result.ok)throw Error(`Apple binary upload failed (${result.status}); safe to rerun`);
      }
      asset=(await api('appScreenshots/'+asset.id,'PATCH',{data:{type:'appScreenshots',id:asset.id,attributes:{uploaded:true,sourceFileChecksum:md5}}})).data;
    }
    record.state=asset.attributes.assetDeliveryState?.state;save();
    console.log(JSON.stringify({file:record.file,state:record.state,id:asset.id}));
  }
  const all=(await api(`appScreenshotSets/${set.id}/appScreenshots?limit=50`)).data;
  if(all.every(x=>receipts.some(r=>r.id===x.id))){
    const ordered=all.slice().sort((a,b)=>a.attributes.fileName.localeCompare(b.attributes.fileName));
    if(ordered.some((x,i)=>x.id!==all[i].id))
      await api(`appScreenshotSets/${set.id}/relationships/appScreenshots`,'PATCH',{data:ordered.map(x=>({type:'appScreenshots',id:x.id}))});
  }
}
// Record immediate processing state; a later run can verify COMPLETE without
// re-uploading. Do not wait unboundedly or infer success from a PUT alone.
for(const receipt of receipts){
  const asset=(await api('appScreenshots/'+receipt.id)).data;
  receipt.state=asset.attributes.assetDeliveryState?.state;
  receipt.errors=asset.attributes.assetDeliveryState?.errors??[];
  save();console.log(JSON.stringify({file:receipt.file,state:receipt.state}));
  if(receipt.state==='FAILED'||receipt.errors.length)throw Error('Apple screenshot processing failed: '+receipt.file);
}

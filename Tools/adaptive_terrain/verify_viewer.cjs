// Optional browser smoke test; requires Playwright + its Chromium browser.
// NODE_PATH may point to an existing Playwright installation.
const {chromium}=require('playwright');
const fs=require('node:fs'),path=require('node:path');
const out=process.argv[2]||path.resolve(__dirname,'../reports/crib-goch-adaptive');
const url=process.argv[3]||'http://127.0.0.1:8769';
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.RIDGE_BROWSER_CHANNEL?{channel:process.env.RIDGE_BROWSER_CHANNEL}:{})});
 try{
  const page=await browser.newPage({viewport:{width:1500,height:1000},deviceScaleFactor:1}),errors=[],remote=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',route=>{if(new URL(route.request().url()).origin!==new URL(url).origin){remote.push(route.request().url());return route.abort();}return route.continue();});
  await page.goto(url);await page.waitForFunction(()=>window.ridgeLab?.ready);
  const catalog=await (await page.request.get(url+'/viewer.json')).json();
  await page.screenshot({path:path.join(out,catalog.experiment==='pack-layout'?'viewer-layout.png':'viewer-ridge.png')});
  for(const profile of catalog.profiles){
   await page.selectOption('#right',profile.id);
   await page.waitForFunction(id=>window.ridgeLab?.profiles[1]===id,profile.id);
   const actual=await page.evaluate(()=>window.ridgeLab);
   if(actual.triangles[1]!==profile.triangles)throw Error('Wrong triangle count for '+profile.id);
  }
  for(const id of ['error-0p4999','error-1','error-2','error-3']){
   await page.click('[data-profile="'+id+'"]');
   await page.waitForFunction(id=>window.ridgeLab?.profiles[1]===id,id);
   if(!await page.locator('[data-profile="'+id+'"]').evaluate(b=>b.classList.contains('active')))throw Error('Shortcut not active');
  }
  if(catalog.experiment==='pack-layout'){
   for(const id of ['layout-tiles-8','layout-tiles-32','layout-joined-32','layout-joined-uncapped']){
    await page.click('[data-profile="'+id+'"]');
    await page.waitForFunction(id=>window.ridgeLab?.profiles[1]===id,id);
   }
  }else await page.screenshot({path:path.join(out,'viewer-three-metres.png')});
  await page.selectOption('#right','matched');await page.waitForFunction(()=>window.ridgeLab?.profiles[1]==='matched');
  await page.click('#map');await page.click('#wire');await page.screenshot({path:path.join(out,catalog.experiment==='pack-layout'?'viewer-layout-wire.png':'viewer-wire.png')});
  await page.selectOption('#left','grid-1');await page.waitForFunction(()=>window.ridgeLab?.profiles[0]==='grid-1');
  await page.click('#overview');await page.click('#top');await page.mouse.move(500,500);await page.mouse.down();await page.mouse.move(540,550);await page.mouse.up();await page.mouse.wheel(0,-100);
  const glError=await page.evaluate(()=>document.querySelector('canvas').getContext('webgl2').getError());
  if(errors.length||remote.length||glError)throw Error(JSON.stringify({errors,remote,glError}));
  const report={passed:true,viewport:[1500,1000],checks:[`${catalog.profiles.length} terrain profiles loaded with verified triangle counts`,'All available tolerance/pack shortcuts switch the right panel','Shared camera orbit/zoom','Top/overview presets','Map texture toggle','Wireframe toggle','No JavaScript exceptions','No external network requests','No WebGL errors'],errors,remote,glError,scope:'Desktop browser smoke test; not an iPad performance benchmark'};
  fs.writeFileSync(path.join(out,'browser-qa.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});

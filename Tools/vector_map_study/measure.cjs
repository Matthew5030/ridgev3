// Browser-only experiment. Requires Playwright and an installed Chrome binary.
const fs=require('fs');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const out=process.argv[2],mode=process.argv[3]||'measure';
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_PATH||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 try{
  const page=await browser.newPage({viewport:{width:1440,height:1000},deviceScaleFactor:1});
  const errors=[];page.on('pageerror',e=>errors.push(String(e)));
  await page.goto('http://127.0.0.1:8775/');
  await page.waitForFunction(()=>window.vectorStudy?.getReport());
  if(mode==='control'){
   let image=await page.evaluate(async()=>{let r=await vectorStudy.renderVector(1024);return r.canvas.toDataURL('image/png').split(',')[1]});
   fs.writeFileSync(out+'/matched.png',Buffer.from(image,'base64'));return;
  }
  await page.waitForFunction(()=>window.ridgeLab?.ready===true);
  const benchmark=await page.evaluate(()=>vectorStudy.benchmark());
  fs.writeFileSync(out+'/browser-benchmark.json',JSON.stringify(benchmark,null,2));
  await page.selectOption('#quality','1024');
  await page.waitForFunction(()=>window.ridgeLab.vectorResolution===1024);
  // Same input, same size must have exactly the same raster result.
  const pixels=await page.evaluate(async()=>{
   const vector=await vectorStudy.renderVector(1024), c=document.createElement('canvas');c.width=vector.canvas.width;c.height=vector.canvas.height;
   let im=new Image();im.src='matched.webp';await im.decode();let ctx=c.getContext('2d');ctx.drawImage(im,0,0);
   let a=ctx.getImageData(0,0,c.width,c.height).data,b=vector.canvas.getContext('2d').getImageData(0,0,c.width,c.height).data,max=0;
   for(let i=0;i<a.length;i++)max=Math.max(max,Math.abs(a[i]-b[i]));return {maxChannelError:max,width:c.width,height:c.height};
  });
  if(pixels.maxChannelError!==0)throw Error('Matched control is not pixel-identical: '+JSON.stringify(pixels));
  await page.selectOption('#quality','2048');await page.waitForFunction(()=>window.ridgeLab.vectorResolution===2048);
  await page.screenshot({path:out+'/comparison.png'});
  await page.click('#top');await page.screenshot({path:out+'/top-down.png'});
  await page.click('#ridge');await page.selectOption('#quality','auto');
  await page.mouse.move(300,600);await page.mouse.wheel(0,800);await page.waitForTimeout(450);
  const distant=await page.evaluate(()=>window.ridgeLab.vectorResolution);
  await page.mouse.wheel(0,-1100);await page.waitForTimeout(450);
  const close=await page.evaluate(()=>window.ridgeLab.vectorResolution);
  if(close<=distant)throw Error('Automatic detail did not respond to zoom');
  const tests={pixels,automaticResolution:{distant,close},errors,state:await page.evaluate(()=>({...window.ridgeLab,glError:vectorStudy.checkGL()}))};
  if(errors.length||tests.state.glError!==0)throw Error(JSON.stringify(tests));
  fs.writeFileSync(out+'/verification.json',JSON.stringify(tests,null,2));
  // Save actual generated pixels for a magnified comparison independent of lighting.
  const flat=await page.evaluate(async()=>{let r=await vectorStudy.renderVector(2048);return r.canvas.toDataURL().split(',')[1]});
  fs.writeFileSync(out+'/vector-fine.png',Buffer.from(flat,'base64'));
  console.log(JSON.stringify({benchmark,tests},null,2));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});

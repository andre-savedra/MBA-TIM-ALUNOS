const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {once} = require('node:events');
const {createApp} = require('../src/server.cjs');

test('Cadastro e medição persistem e ficam visíveis pela API de coleta',async t=>{
 const dir = fs.mkdtempSync(path.join(os.tmpdir(),'mfm-post-'));
 t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
 const dbFile = path.join(dir,'db.json');
 fs.copyFileSync(path.join(__dirname,'../db.json'),dbFile);
 const deviceId = '300000000000000000000001';
 async function open(){
  const server = createApp({dbFile}).listen(0,'127.0.0.1');
  await once(server,'listening');
  t.after(()=>new Promise(done=>server.close(done)));
  return 'http://127.0.0.1:'+server.address().port;
 }
 let base = await open();
 const post=(url,body)=>fetch(base+url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
 const create=await post('/__sim/sensors',{deviceId,name:'Teste'});
 assert.equal(create.status,201);
 const {sensorId}=await create.json();
 const sample={sensorId,data:{surfaceTemperature:47.8}};
 const response=await post('/__sim/measurements',sample);
 assert.equal(response.status,201);
 const saved=await response.json();
 assert.ok(Number.isFinite(Date.parse(saved.timestamp)));
 assert.equal((await post('/__sim/measurements',saved)).status,409);
 assert.equal((await post('/__sim/measurements',{...sample,data:{surfaceTemperature:null}})).status,400);
 base=await open();
 const auth=await post('/exchange/auth',{username:'aluno@simulador.local',password:'senai-aula1'});
 const headers={Authorization:'Bearer '+(await auth.json()).token};
 const get=async url=>(await fetch(base+url,{headers})).json();
 assert.ok((await get('/exchange/devices/'+deviceId+'/sensors')).some(row=>row.sensorId===sensorId));
 assert.deepEqual((await get('/exchange/sensors/'+sensorId+'/data')).data,[{timestamp:saved.timestamp,data:sample.data}]);
});

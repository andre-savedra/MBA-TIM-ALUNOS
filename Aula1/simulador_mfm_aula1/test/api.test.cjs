const {test}=require('node:test'),assert=require('node:assert/strict');
const {createApp}=require('../src/server.cjs');
async function serve(options={}){const app=createApp(options);const server=await new Promise(resolve=>{const s=app.listen(0,'127.0.0.1',()=>resolve(s))});return {server,base:'http://127.0.0.1:'+server.address().port};}
test('Contrato de leitura, autenticação, paginação e cenários',async()=>{
 const {server,base}=await serve();
 try{
 const post=(path,body)=>fetch(base+path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
 assert.equal((await fetch(base+'/exchange/customers/sites')).status,401);
 assert.equal((await post('/exchange/auth',{username:'errado',password:'errado'})).status,401);
 const auth=await post('/exchange/auth',{username:'aluno@simulador.local',password:'senai-aula1'});assert.equal(auth.status,200);
 const {token}=await auth.json();const claims=JSON.parse(Buffer.from(token.split('.')[1],'base64url'));assert.equal(claims.exp-claims.iat,86400);
 const get=path=>fetch(base+'/exchange'+path,{headers:{Authorization:'Bearer '+token}});
 const sites=await (await get('/customers/sites')).json();assert.equal(sites[0].siteId,'100000000000000000000001');
 const plants=await (await get('/sites/'+sites[0].siteId+'/plants')).json();assert.equal(plants.length,2);
 const first=await (await get('/plants/'+plants[0].plantId+'/devices?perPage=1&page=0')).json();
 const second=await (await get('/plants/'+plants[0].plantId+'/devices?perPage=1&page=1')).json();
 assert.equal(first.page,0);assert.equal(first.perPage,1);assert.notEqual(first.devices[0].deviceId,second.devices[0].deviceId);
 assert.equal((await get('/plants/'+plants[0].plantId+'/devices?perPage=1&page=2')).status,204);
 assert.equal((await get('/plants/'+plants[1].plantId+'/devices')).status,204);
 assert.equal((await get('/plants/'+plants[0].plantId+'/devices?page=-1')).status,400);
 const d=first.devices[0].deviceId;assert.equal((await (await get('/devices/'+d)).json()).deviceId,d);
 assert.equal((await (await get('/devices/'+d+'/events')).json()).length,1);
 assert.equal((await get('/devices/xxx')).status,400);assert.equal((await get('/devices/999999999999999999999999')).status,403);
 const sensors=await (await get('/devices/'+d+'/sensors')).json();const path='/sensors/'+sensors[0].sensorId+'/data';
 const response=await get(path);assert.equal(response.headers.get('x-simulator'),'SENAI-MFM');const normal=await response.json();assert.equal(normal.data.length,12);assert.equal(normal.data[0].data.surfaceTemperature,41);
 const filtered=await (await get(path+'?initial_timestamp=2026-10-31T12:10:00.000Z&final_timestamp=2026-10-31T12:20:00.000Z')).json();assert.equal(filtered.data.length,2);
 assert.equal((await get(path+'?initial_timestamp=2026-10-31')).status,400);
 assert.equal((await get(path+'?initial_timestamp=2026-11-01T00:00:00Z&final_timestamp=2026-10-31T00:00:00Z')).status,400);
 for(const [scenario,count] of [['duplicado',13],['lacuna',12],['vazio',0],['atrasado',1],['aquecimento',12]]){
 assert.equal((await post('/__sim/scenario',{scenario})).status,200);const b=await (await get(path)).json();assert.equal(b.data.length,count);
 if(scenario==='lacuna')assert.equal(b.data[4].data.surfaceTemperature,null);
 if(scenario==='aquecimento')assert.equal(b.data.at(-1).data.surfaceTemperature,78);
 }
 await post('/__sim/scenario',{scenario:'erro500'});assert.equal((await get(path)).status,500);
 await post('/__sim/scenario',{scenario:'limite429'});const limited=await get(path);assert.equal(limited.status,429);assert.equal(limited.headers.get('retry-after'),'60');
 assert.equal((await get('/nao-implementado')).status,501);
 assert.equal((await fetch(base+'/devices')).status,404);
 await post('/__sim/expire-tokens',{});assert.equal((await get('/customers/sites')).status,401);
 }finally{await new Promise(r=>server.close(r));}
});
test('Token expirado é recusado',async()=>{const {server,base}=await serve({ttlSeconds:-1});try{const r=await fetch(base+'/exchange/auth',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:'aluno@simulador.local',password:'senai-aula1'})});const {token}=await r.json();assert.equal((await fetch(base+'/exchange/customers/sites',{headers:{Authorization:'Bearer '+token}})).status,401);}finally{await new Promise(r=>server.close(r))}});

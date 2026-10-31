const {root}=require('./env.cjs');
const jsonServer=require('json-server'),crypto=require('node:crypto'),path=require('node:path');
const SCENARIOS=['normal','aquecimento','lacuna','duplicado','vazio','atrasado','erro500','limite429'];
function createApp(options={}){
 const app=jsonServer.create();
 // JSON Server fornece HTTP, parser e banco. O CRUD genérico NÃO é publicado.
 const router=jsonServer.router(path.join(root,'db.json')),db=router.db;
 const secret=crypto.randomBytes(32),tokens=new Set();let scenario='normal';
 const username=options.username||process.env.SIM_USERNAME||'aluno@simulador.local';
 const password=options.password||process.env.SIM_PASSWORD||'senai-aula1';
 const ttl=options.ttlSeconds??86400;
 app.use(jsonServer.defaults({logger:false,static:path.join(root,'public')}));
 app.use('/swagger-assets',require('express').static(require('swagger-ui-dist').getAbsoluteFSPath()));
 app.get('/docs',(req,res)=>res.redirect('/swagger.html'));
 app.use(jsonServer.bodyParser);
 app.use((req,res,next)=>{res.set('X-Simulator','SENAI-MFM');res.set('Cache-Control','no-store');next()});
 const err=(res,code,message,type='SimulatorError')=>res.status(code).json({error:{message,type}});
 const unauthorized=res=>err(res,401,'Unauthorized','Unauthorized');
 app.get('/__sim/status',(req,res)=>res.json({simulated:true,scenario,scenarios:SCENARIOS,timeRange:db.get('metadata.timeRange').value(),username,notes:'Dados sintéticos; sem conexão com a WEG.'}));
 app.post('/__sim/scenario',(req,res)=>{if(!SCENARIOS.includes(req.body.scenario))return err(res,400,'Cenário inválido');scenario=req.body.scenario;res.json({simulated:true,scenario})});
 app.post('/__sim/expire-tokens',(req,res)=>{tokens.clear();res.json({simulated:true,revoked:true})});
 app.post('/exchange/auth',(req,res)=>{
  if(req.body.username!==username||req.body.password!==password)return unauthorized(res);
  const now=Math.floor(Date.now()/1000);
  const a=Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
  const b=Buffer.from(JSON.stringify({sub:username,iat:now,exp:now+ttl,jti:crypto.randomUUID(),simulated:true})).toString('base64url');
  const c=crypto.createHmac('sha256',secret).update(a+'.'+b).digest('base64url');
  const token=a+'.'+b+'.'+c;tokens.add(token);res.json({token});
 });
 app.use('/exchange',(req,res,next)=>{
  const m=/^Bearer (\S+)$/.exec(req.get('Authorization')||'');if(!m||!tokens.has(m[1]))return unauthorized(res);
  try{const [a,b,c]=m[1].split('.');const e=crypto.createHmac('sha256',secret).update(a+'.'+b).digest('base64url');if(c!==e||JSON.parse(Buffer.from(b,'base64url')).exp<=Date.now()/1000)return unauthorized(res);}catch{return unauthorized(res)}next();
 });
 function resource(collection,key,value,res){
  if(!/^[0-9a-f]{24}$/.test(value)){err(res,400,'Identificador inválido','Bad Request');return null}
  const found=db.get(collection).find({[key]:value}).value();if(!found){err(res,403,'Sem permissão de acesso','Forbidden');return null}return found;
 }
 const strip=(r,keys)=>Object.fromEntries(Object.entries(r).filter(([k])=>!keys.includes(k)));
 app.get('/exchange/customers/sites',(req,res)=>res.json(db.get('sites').value().map(x=>strip(x,['id']))));
 app.get('/exchange/sites/:siteId/plants',(req,res)=>{if(!resource('sites','siteId',req.params.siteId,res))return;res.json(db.get('plants').filter({siteId:req.params.siteId}).value().map(x=>strip(x,['id','siteId'])))});
 app.get('/exchange/plants/:plantId/devices',(req,res)=>{
  if(!resource('plants','plantId',req.params.plantId,res))return;
  const page=req.query.page===undefined?0:Number(req.query.page),perPage=req.query.perPage===undefined?500:Number(req.query.perPage);
  if(!Number.isInteger(page)||page<0||!Number.isInteger(perPage)||perPage<1||perPage>500)return err(res,400,'Paginação inválida (limite didático: 500)');
  const rows=db.get('devices').filter({parentId:req.params.plantId}).value().slice(page*perPage,(page+1)*perPage).map(x=>strip(x,['id']));
  if(!rows.length)return res.status(204).end();res.json({devices:rows,page,perPage});
 });
 app.get('/exchange/devices/:deviceId',(req,res)=>{const d=resource('devices','deviceId',req.params.deviceId,res);if(d)res.json(strip(d,['id']))});
 app.get('/exchange/devices/:deviceId/sensors',(req,res)=>{if(!resource('devices','deviceId',req.params.deviceId,res))return;res.json(db.get('sensors').filter({deviceId:req.params.deviceId}).value().map(x=>strip(x,['id'])))});
 app.get('/exchange/devices/:deviceId/events',(req,res)=>{if(!resource('devices','deviceId',req.params.deviceId,res))return;res.json(db.get('events').filter({deviceId:req.params.deviceId}).value())});
 const iso=s=>typeof s==='string'&&/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,3})?(?:Z|[+-]\d\d:\d\d)$/.test(s)&&Number.isFinite(Date.parse(s));
 app.get('/exchange/sensors/:sensorId/data',(req,res)=>{
  const sensor=resource('sensors','sensorId',req.params.sensorId,res);if(!sensor)return;
  const start=req.query.initial_timestamp,end=req.query.final_timestamp;
  if((start!==undefined&&!iso(start))||(end!==undefined&&!iso(end)))return err(res,400,'Timestamp ISO 8601 com fuso obrigatório');
  if(start&&end&&Date.parse(start)>Date.parse(end))return err(res,400,'Intervalo invertido');
  if(scenario==='erro500')return err(res,500,'Falha interna simulada');
  if(scenario==='limite429'){res.set('Retry-After','60');return err(res,429,'Limite didático de requisições')}
  let rows=structuredClone(db.get('measurements').filter({sensorId:sensor.sensorId}).value());
  if(scenario==='aquecimento')rows.forEach((r,i)=>r.data.surfaceTemperature=45+i*3);
  if(scenario==='lacuna'&&rows[4])rows[4].data.surfaceTemperature=null;
  if(scenario==='atrasado')rows=rows.slice(0,1);
  if(scenario==='duplicado'&&rows.length)rows.splice(1,0,structuredClone(rows[0]));
  if(scenario==='vazio')rows=[];
  rows=rows.filter(r=>(!start||Date.parse(r.timestamp)>=Date.parse(start))&&(!end||Date.parse(r.timestamp)<=Date.parse(end)));
  // Envelope escolhido pelo laboratório: o PDF não especifica o JSON de série.
  res.json({sensorId:sensor.sensorId,deviceId:sensor.deviceId,data:rows.map(x=>({timestamp:x.timestamp,data:x.data}))});
 });
 app.use('/exchange',(req,res)=>err(res,501,'Operação fora do recorte de leitura da Aula 1','Not Implemented'));
 app.use((error,req,res,next)=>err(res,400,'JSON ou requisição inválida','Bad Request'));
 return app;
}
if(require.main===module){const port=Number(process.env.SIM_PORT||3000);createApp().listen(port,'127.0.0.1',()=>console.log(`Simulador sintético: http://127.0.0.1:${port} | Exchange: /exchange`))}
module.exports={createApp};

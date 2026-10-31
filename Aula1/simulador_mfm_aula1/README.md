# Aula 1 — pacote dos alunos

**Simulador Exchange + Swagger + Node-RED inicialmente vazio.** Não contém fluxo resolvido, Functions de resposta nem painel pronto.

## Preparar e iniciar

Requisito: Node.js 22 ou 24 LTS com npm. Abra o terminal nesta pasta (onde está package.json).

```sh
npm ci
```

Copie `.env.example` para `.env`, mantendo os valores fictícios. No Windows, não salvar como `.env.txt`. A instalação exige Internet/cache; depois, a execução e o Swagger são locais.

Terminal 1:
```sh
npm start
```
Terminal 2, nesta mesma pasta:
```sh
npm run nodered
```

- Controle: <http://127.0.0.1:3000>
- Swagger: <http://127.0.0.1:3000/docs>
- Node red: <http://127.0.0.1:1880>
- `/pratica1-alt` dashboard.


1 - 
```javascript
const base=String(env.get('MFM_BASE_URL')||'').replace(/\/$/,'');
if(!/^https?:\/\//.test(base)) {node.error('Configure MFM_BASE_URL',msg);return null;}
msg.method='POST';msg.url=base+'/auth';
msg.headers={'Content-Type':'application/json','Accept':'application/json'};
msg.payload={username:env.get('MFM_USERNAME'),password:env.get('MFM_PASSWORD')};
return msg;
```

2 - 
```javascript
if(msg.statusCode!==200||typeof msg.payload?.token!=='string'){
 flow.set('mfm_token',null);flow.set('p1_last_status','Falha de autenticação HTTP '+msg.statusCode);
 msg.payload={status:msg.statusCode,action:'Login falhou. Conferir credenciais e serviço.'};delete msg.headers;delete msg.responseHeaders;return [null,msg];
}
flow.set('mfm_token',msg.payload.token);
msg.payload={status:200,message:'Token salvo somente em memória. Não exibir o token.'};
delete msg.headers;delete msg.responseHeaders;flow.set('p1_last_status','Autenticado; nenhuma consulta de série ainda.');
return [msg,null];
```

3 - 

```javascript
const token=flow.get('mfm_token');if(!token){node.error('Faça login antes de consultar.',msg);return null;}
const base=String(env.get('MFM_BASE_URL')||'').replace(/\/$/,'');
const site=env.get('MFM_SITE_ID')||'100000000000000000000001';
const plant=env.get('MFM_PLANT_ID')||'200000000000000000000001';
const device=env.get('MFM_DEVICE_ID')||'300000000000000000000001';
const sensor=env.get('MFM_SENSOR_ID')||'400000000000000000000001';
const start=env.get('MFM_INITIAL_TIMESTAMP')||'2026-10-31T12:00:00.000Z';
const end=env.get('MFM_FINAL_TIMESTAMP')||'2026-10-31T14:00:00.000Z';
const paths={sites:'/customers/sites',plants:'/sites/'+encodeURIComponent(site)+'/plants',
 devices:'/plants/'+encodeURIComponent(plant)+'/devices?page='+encodeURIComponent(msg.page??0)+'&perPage='+encodeURIComponent(msg.perPage??1),
 sensors:'/devices/'+encodeURIComponent(device)+'/sensors',events:'/devices/'+encodeURIComponent(device)+'/events',
 data:'/sensors/'+encodeURIComponent(sensor)+'/data?initial_timestamp='+encodeURIComponent(start)+'&final_timestamp='+encodeURIComponent(end)};
const kind=String(msg.topic||'');if(!paths[kind]){node.error('Consulta não prevista',msg);return null;}
msg.queryKind=kind;msg.method='GET';msg.url=base+paths[kind];
msg.headers={Authorization:'Bearer '+token,Accept:'application/json'};delete msg.payload;
return msg;
```

3.1 - 
```javascript
msg.isSimulator=msg.headers?.['x-simulator']==='SENAI-MFM';
msg.retryAfter=msg.headers?.['retry-after']||null;
delete msg.headers;delete msg.responseHeaders;
if(msg.statusCode===200){flow.set('p1_last_status','HTTP 200: '+msg.queryKind);return [msg,null];}
if(msg.statusCode===401)flow.set('mfm_token',null);
const action=({204:'Sem dispositivos nesta página; não há JSON a percorrer.',400:'Conferir parâmetros.',401:'Refazer login manualmente.',403:'Conferir permissão e identificador.',429:'Respeitar Retry-After; não repetir em loop.',500:'Serviço indisponível; preservar histórico.'})[msg.statusCode]||'Conferir resposta';
flow.set('p1_last_status','HTTP '+msg.statusCode+' — '+action);
msg.payload={status:msg.statusCode,action,retryAfter:msg.retryAfter};return [null,msg];
```




4 - 

```javascript
const body=msg.payload;
if(env.get('MFM_MODE')!=='simulado'||!msg.isSimulator){node.error('Adaptador didático bloqueado fora do simulador. Validar contrato real antes de migrar.',msg);return null;}
if(!body||typeof body.sensorId!=='string'||typeof body.deviceId!=='string'||!Array.isArray(body.data)){
 node.error('Envelope de série inesperado; não adaptar silenciosamente.',msg);return null;
}
msg.payload=body.data.map(row=>({asset_id:body.deviceId,sensor_id:body.sensorId,
 variable:'surfaceTemperature',unit:'degC',value:row.data?.surfaceTemperature,
 measured_at:row.timestamp,ingested_at:new Date().toISOString(),origin:'SIMULADOR_MFM',mode:'simulado'}));
flow.set('p1_last_status',msg.payload.length?'Série recebida: '+msg.payload.length+' linhas sintéticas.':'Série vazia: nenhum dado novo. Histórico anterior preservado.');
return msg;
```

5 - 
```javascript
const p=msg.payload;
function reject(reason){msg.payload={quality:'rejeitado',reason,record:p};return [null,msg];}
if(!p||typeof p!=='object'||Array.isArray(p))return reject('Esperado objeto por amostra');
if(typeof p.value!=='number'||!Number.isFinite(p.value))return reject('Valor ausente/não numérico; não substituir por zero');
if(p.variable!=='surfaceTemperature'||p.unit!=='degC')return reject('Variável/unidade fora do contrato');
if(!Number.isFinite(Date.parse(p.measured_at)))return reject('Timestamp inválido');
if(!p.asset_id||!p.sensor_id||p.origin!=='SIMULADOR_MFM'||p.mode!=='simulado')return reject('Identidade ou origem inválida');
const hist=flow.get('p1_records')||[];
const key=r=>JSON.stringify([r.origin,r.asset_id,r.sensor_id,r.variable,r.measured_at]);
const old=hist.find(r=>key(r)===key(p));
if(old){if(old.value!==p.value)return reject('Conflito: mesma medição com valor diferente. Use nova sessão para trocar cenário.');msg.payload={quality:'duplicata_ignorada',measured_at:p.measured_at};return [null,msg];}
p.quality='formato_valido';hist.push(p);flow.set('p1_records',hist.slice(-500));return [msg,null];
```


6 - 
```javascript
const rows=flow.get('p1_records')||[];
msg.payload={status:flow.get('p1_last_status')||'Sem consultas.',total:rows.length,empty:!rows.length,items:rows.slice().sort((a,b)=>Date.parse(b.measured_at)-Date.parse(a.measured_at)).slice(0,50).map(r=>({...r,age:Math.max(0,Math.floor((Date.now()-Date.parse(r.measured_at))/60000))}))};
msg.headers={'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store'};return msg;
```



7 - 
```html
<!doctype html><html lang="pt-BR"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Prática alternativa</title><style>body{font:17px system-ui;background:#f5f7fa;color:#16324e;padding:24px}table{border-collapse:collapse;background:white}th,td{padding:12px;border:1px solid #9faebe;text-align:left}th{background:#183d62;color:white}.aviso{padding:16px;background:#ffedb8}.wrap{overflow:auto}</style>
<h1>Do Exchange simulado ao dado rastreável</h1><p class="aviso">DADOS SINTÉTICOS • Sem diagnóstico mecânico • Nenhuma conexão com WEG</p><p>{{payload.status}}</p><p>Total da sessão: {{payload.total}}. <a href="/pratica1-alt">Atualizar página</a> não consulta o sensor.</p>{{#payload.empty}}<p>Sem medições aceitas na sessão.</p>{{/payload.empty}}<div class="wrap"><table><tr><th>Ativo / sensor</th><th>Variável / valor</th><th>Aquisição UTC</th><th>Ingestão UTC</th><th>Origem / qualidade</th></tr>{{#payload.items}}<tr><td>{{asset_id}}<br>{{sensor_id}}</td><td>{{variable}}<br>{{value}} {{unit}}</td><td>{{measured_at}}<br>Idade: {{age}} min</td><td>{{ingested_at}}</td><td>{{origin}} / {{mode}}<br>{{quality}}</td></tr>{{/payload.items}}</table></div><p>Memória limitada a 500 registros. Reinício limpa a sessão. Não há limiar de saúde aplicado no fluxo-base.</p></html>
```

8 - 
```javascript
flow.set('p1_last_status','Erro de execução/transporte; consultar diagnóstico.');
msg.payload={error:msg.error?.message||'Erro de transporte/execução'};delete msg.headers;delete msg.responseHeaders;delete msg.url;return msg;
```


9 -
```javascript
flow.set('p1_records', []);
flow.set('p1_last_status', 'Sessão limpa; token preservado.');
msg.payload = 'Sessão limpa';
return msg;
```
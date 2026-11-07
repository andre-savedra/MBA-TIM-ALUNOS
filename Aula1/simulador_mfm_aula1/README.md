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



----------------------


```javascript
if (msg.topic === 'pausar') {
    flow.set('coleta_pausada', true);
    node.status({fill:'grey', shape:'ring', text:'Automático pausado'});
    return;
}
if (msg.topic === 'retomar') flow.set('coleta_pausada', false);
if (msg.topic === 'timer' && (flow.get('coleta_pausada') ?? (env.get('MFM_AUTO') === 'false'))) return;
if (context.get('ocupado') || Date.now() < (context.get('aguardar') || 0)) return;
if (env.get('MFM_MODE') !== 'simulado') {
    node.warn('Conferir o contrato do MFM real antes de iniciar a coleta');
    return;
}
context.set('ocupado', true);
node.status({fill:'blue', shape:'dot', text:'Consultando sensores'});
let falhas = 0;
try {
    const total = await global.get('coletarSensores')({
        base: env.get('MFM_BASE_URL').replace(/\/$/, ''),
        username: env.get('MFM_USERNAME'), password: env.get('MFM_PASSWORD'),
        getToken: () => flow.get('mfm_token'),
        setToken: token => flow.set('mfm_token', token),
        since: id => (flow.get('ultimasMedicoes', 'disco') || {})[id],
        series: payload => node.send({payload, isSimulator:true, coleta:true}),
        warn: aviso => { falhas++; node.warn(aviso); }
    });
    node.status({fill:falhas ? 'yellow' : 'green', shape:'dot', text:total + ' sensores · ' + falhas + ' falhas'});
} catch (error) {
    if (error.status === 429) context.set('aguardar', Date.now() + error.retryAfter * 1000);
    node.status({fill:'red', shape:'ring', text:error.message});
    node.warn(error.message);
} finally {
    context.set('ocupado', false);
}

```

## MQTT


```javascript
mosquitto_sub -h 127.0.0.1 -p 1883 -u turma -P "turma" -t 'senai/tim2026/#' -q 1 -v
```

```javascript
mosquitto_pub -h 127.0.0.1 -p 1883 -u turma -P "turma" -t 'senai/tim2026/teste' -q 1 -m '{"origem":"teste-local","value":35.5}'
```

```javascript
sudo apt update
sudo apt install -y mosquitto mosquitto-clients
sudo systemctl enable --now mosquitto
sudo systemctl status mosquitto --no-pager
```


## M4. Instalar e configurar o broker

Dentro do terminal **da VM Ubuntu**:

```sh
sudo apt update
sudo apt install -y mosquitto mosquitto-clients
sudo systemctl enable --now mosquitto
sudo systemctl status mosquitto --no-pager
```

Criar usuário exclusivo do laboratório. O utilitário solicitará a senha duas vezes, sem colocá-la no comando:

```sh
sudo mosquitto_passwd -c /etc/mosquitto/passwd turma
sudo chown root:mosquitto /etc/mosquitto/passwd
sudo chmod 640 /etc/mosquitto/passwd
```

**`-c` somente na primeira criação:** ele sobrescreve o arquivo de senhas. Para acrescentar outro usuário, omitir `-c`.

Abrir:

```sh
sudo nano /etc/mosquitto/conf.d/public.conf
```

Substituir o conteúdo desse arquivo pelo seguinte; se já seguiu o anexo, remover daqui `allow_anonymous true`. Não criar dois listeners na mesma porta em arquivos diferentes.

```conf
listener 1883 0.0.0.0
protocol mqtt
allow_anonymous false
password_file /etc/mosquitto/passwd
acl_file /etc/mosquitto/acl
```

Salvar com Ctrl+O, Enter, Ctrl+X. Criar a ACL:

```sh
sudo nano /etc/mosquitto/acl
```

Conteúdo:

```conf
user turma
topic readwrite senai/tim2026/#
```

O usuário compartilhado permite ler/publicar em todos os tópicos da turma; separação por equipe é organização, não isolamento de segurança. Aplicar:

```sh
sudo chown root:mosquitto /etc/mosquitto/acl
sudo chmod 640 /etc/mosquitto/acl
sudo systemctl restart mosquitto
sudo systemctl status mosquitto --no-pager
sudo ss -ltnp | grep ':1883'
sudo ufw status
```

Esperado: serviço active/running e listener `0.0.0.0:1883`. Se UFW estiver ativo, adicionar regra para a origem pública autorizada (substituir o exemplo) e preservar a regra administrativa SSH existente:

```sh
sudo ufw allow from IP_PUBLICO_SENAI to any port 1883 proto tcp
```

Não habilitar UFW às cegas em uma sessão remota. Se o serviço falhar:

```sh
sudo journalctl -u mosquitto -n 50 --no-pager
```

Verificar sintaxe, arquivos legíveis pelo usuário mosquitto e listener duplicado. Para revisar as configurações:

```sh
sudo grep -R -n -E 'listener|allow_anonymous|password_file|acl_file' /etc/mosquitto
```

## M5. Testar dentro da VM antes do Node-RED

Abrir dois terminais na VM. Em cada um, obter a senha sem escrevê-la no histórico do shell:

```sh
read -s -p 'Senha MQTT do laboratório: ' MQTT_LAB_PASSWORD
printf '\n'
```

Terminal A, manter assinando:

```sh
mosquitto_sub -h 127.0.0.1 -p 1883 -u turma -P "turma" -t 'senai/tim2026/#' -q 1 -v
```

Terminal B:

```sh
mosquitto_pub -h 127.0.0.1 -p 1883 -u turma -P "turma" -t 'senai/tim2026/teste' -q 1 -m '{"origem":"teste-local","value":35.5}'
unset MQTT_LAB_PASSWORD
```

O terminal A deve exibir tópico e JSON. A senha é temporária: `-P` pode ficar visível nos argumentos do processo local; não usar conta de produção. Esse teste comprova listener e autenticação locais, **não** o caminho de rede notebook → Azure. Deixar A aberto para acompanhar a prova fim a fim.

## M6. Montar o ramo no Node-RED com os alunos

Pré-requisito: o fluxo principal já construído deve mostrar 12 medições aceitas no cenário normal. Não instalar nós extras: Function, MQTT out, Status e Debug são nativos.

### Passo 1 — escolher a saída correta

Localizar `Validar e deduplicar`. A **primeira saída**, já ligada ao Debug `Medição aceita`, fornece novas medições válidas. Manter esse fio e acrescentar outro para o novo ramo. A segunda saída é de rejeições/duplicatas e não será publicada.

### Passo 2 — Function de publicação

Arrastar Function, nomear `Preparar publicação MQTT`, uma saída. Colar exatamente:

```javascript
// Publicar somente o contrato interno; nunca headers ou token HTTP.
const p=msg.payload;
if(!p || p.quality!=="formato_valido" || p.mode!=="simulado" || p.origin!=="SIMULADOR_MFM" || !Number.isFinite(p.value)) {
    node.warn("MQTT: medição fora do contrato didático"); return null;
}
const team=(env.get("MQTT_TEAM")||"professor").trim();
if(!/^[a-zA-Z0-9_-]+$/.test(team)) { node.error("MQTT_TEAM: use letras, números, _ ou -"); return null; }
const record={schema_version:"1.0",asset_id:p.asset_id,sensor_id:p.sensor_id,variable:p.variable,unit:p.unit,value:p.value,measured_at:p.measured_at,ingested_at:p.ingested_at,origin:p.origin,mode:p.mode,quality:p.quality};
record.event_id=JSON.stringify([record.origin,record.asset_id,record.sensor_id,record.variable,record.measured_at]);
return {topic:`senai/tim2026/${team}/medicoes`,payload:JSON.stringify(record),qos:1,retain:false};
```

A Function cria uma nova mensagem, contendo somente os campos permitidos; `msg.headers`, token e credenciais HTTP não seguem para o broker. Não encapsular o JSON em uma string dentro de `jsonValue`, como ocorria no exemplo Wokwi: aqui o próprio payload MQTT é o documento JSON.

No `.env` local, acrescentar `MQTT_TEAM=equipe01` (cada equipe usa seu identificador, sem espaços ou barras). Reiniciar `npm run nodered`. Sem a variável, o padrão é `professor`. O tópico fica `senai/tim2026/equipe01/medicoes`.


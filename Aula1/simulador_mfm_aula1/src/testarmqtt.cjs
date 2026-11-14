// Teste de ponta a ponta do caminho MQTT do laboratorio.
// Le a configuracao REAL do Node-RED (no do broker + credenciais cifradas),
// conecta pelo mesmo WebSocket, publica e espera a propria mensagem voltar.
// Uso: npm run mqtt:teste
const {root}=require('./env.cjs');
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const mqtt=require('mqtt');

const dir=process.env.NODE_RED_USERDIR||path.join(root,'node-red','userdir');
const leia=n=>JSON.parse(fs.readFileSync(path.join(dir,n),'utf8'));

function configuracao(){
  let flows;
  try{ flows=leia('flows.json'); }
  catch{ throw new Error('flows.json nao encontrado em '+dir+'. Inicie o Node-RED pelo menos uma vez.'); }
  const broker=flows.find(n=>n.type==='mqtt-broker');
  if(!broker) throw new Error('Nenhum no de broker MQTT no fluxo. Configure o no "mqtt out" primeiro.');
  let user='',password='';
  try{
    const segredo=leia('.config.runtime.json')._credentialSecret;
    const bruto=leia('flows_cred.json')['$'];
    const chave=crypto.createHash('sha256').update(segredo).digest();
    const d=crypto.createDecipheriv('aes-256-ctr',chave,Buffer.from(bruto.substring(0,32),'hex'));
    const cred=JSON.parse(d.update(bruto.substring(32),'base64','utf8')+d.final('utf8'))[broker.id]||{};
    user=cred.user||''; password=cred.password||'';
  }catch(e){ console.log('[aviso] nao foi possivel ler as credenciais salvas: '+e.message); }
  // Mesma regra do Node-RED: com esquema na URL, o campo Port e ignorado.
  const url=String(broker.broker).includes('://')
    ? broker.broker
    : (broker.usetls?'mqtts://':'mqtt://')+broker.broker+':'+(broker.port||1883);
  return {url,user,password,nome:broker.name||broker.id};
}

(async()=>{
  const cfg=configuracao();
  const team=(process.env.MQTT_TEAM||'professor').trim();
  const topico=`senai/tim2026/${team}/testes`;
  console.log('----------------------------------------------------------');
  console.log(' Teste do caminho MQTT do laboratorio');
  console.log(' Broker ..: '+cfg.nome);
  console.log(' URL .....: '+cfg.url);
  console.log(' Usuario .: '+(cfg.user||'(nenhum)')+'   senha: '+(cfg.password?'<definida>':'(nenhuma)'));
  console.log(' Topico ..: '+topico);
  console.log('----------------------------------------------------------');

  const cliente=mqtt.connect(cfg.url,{username:cfg.user||undefined,password:cfg.password||undefined,
    protocolVersion:4,clean:true,reconnectPeriod:0,connectTimeout:12000});
  const marca=Date.now();
  let fim;
  const encerrar=(codigo,texto)=>{ if(fim)return; fim=true; console.log(texto);
    cliente.end(true,()=>process.exit(codigo)); setTimeout(()=>process.exit(codigo),1500); };

  cliente.on('connect',()=>{
    console.log('[1/3] conectado ao broker');
    cliente.subscribe(topico,{qos:1},err=>{
      if(err) return encerrar(1,'[2/3] FALHA ao assinar: '+err.message+
        '\n      A ACL do broker libera apenas senai/tim2026/#. Confira o usuario.');
      console.log('[2/3] assinatura aceita pela ACL');
      cliente.publish(topico,JSON.stringify({origem:'teste-local',marca}),{qos:1,retain:false},err2=>{
        if(err2) return encerrar(1,'[3/3] FALHA ao publicar: '+err2.message);
      });
    });
  });
  cliente.on('message',(t,carga)=>{
    try{ if(JSON.parse(carga.toString()).marca!==marca) return; }catch{ return; }
    encerrar(0,'[3/3] mensagem publicada e recebida de volta\n\nRESULTADO: CAMINHO MQTT FUNCIONANDO.\n'+
      'O Node-RED consegue publicar neste broker por esta rede.');
  });
  cliente.on('error',e=>{
    const m=e&&e.message?e.message:String(e);
    let dica='';
    if(/Not authorized|Connection refused.*not authorised|bad user name/i.test(m))
      dica='\n      Usuario ou senha incorretos no no do broker, ou o arquivo de senhas do broker nao foi criado.';
    else if(/ENOTFOUND|EAI_AGAIN/i.test(m))
      dica='\n      O nome DNS nao resolveu. Confira a URL no no do broker (campo\n'+
           '      URL_WEBSOCKET_NODE_RED do arquivo de credenciais). Se a URL estiver certa,\n'+
           '      a rede pode nao ter DNS livre: teste pelo IP publico da VM.';
    else if(/ECONNREFUSED/i.test(m))
      dica='\n      Nada escutando na porta. Rode ../../azure_mqtt/4-reparar-broker.sh <equipe>.';
    else if(/ETIMEDOUT|timeout|EHOSTUNREACH|socket hang up|Unexpected server response/i.test(m))
      dica='\n      Conexao barrada no caminho. Possiveis causas: regra de entrada do NSG,\n'+
           '      firewall de saida da escola, ou proxy bloqueando o cabecalho Upgrade do WebSocket.\n'+
           '      Se houver proxy, defina http_proxy antes de iniciar o Node-RED: o no MQTT o respeita.';
    encerrar(1,'FALHA na conexao: '+m+dica);
  });
  setTimeout(()=>encerrar(1,'FALHA: tempo esgotado sem concluir o teste.\n'+
    '      Se parou apos "conectado", a ACL ou o QoS podem estar barrando.'),20000);
})().catch(e=>{ console.error('[ERRO] '+e.message); process.exit(1); });

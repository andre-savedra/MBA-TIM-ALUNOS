const {root}=require('./env.cjs');
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),express=require('express'),RED=require('node-red');
const dir=process.env.NODE_RED_USERDIR||path.join(root,'node-red','userdir');fs.mkdirSync(dir,{recursive:true});
const target=path.join(dir,'flows.json');
if(!fs.existsSync(target))fs.writeFileSync(target,JSON.stringify([]));
// Defaults exclusivamente sintéticos, nunca credenciais WEG.
process.env.MFM_BASE_URL ||= 'http://127.0.0.1:3000/exchange';
process.env.MFM_USERNAME ||= 'aluno@simulador.local';process.env.MFM_PASSWORD ||= 'senai-aula1';process.env.MFM_MODE ||= 'simulado';
const app=express(),server=http.createServer(app);
RED.init(server,{httpAdminRoot:'/',httpNodeRoot:'/',userDir:dir,flowFile:'flows.json',uiPort:Number(process.env.NODE_RED_PORT||1880),functionGlobalContext:{},editorTheme:{projects:{enabled:false}},logging:{console:{level:'warn',metrics:false,audit:false}}});
app.use(RED.httpAdmin);app.use(RED.httpNode);
server.listen(Number(process.env.NODE_RED_PORT||1880),'127.0.0.1',async()=>{await RED.start();console.log('Node-RED local na porta '+(process.env.NODE_RED_PORT||1880));});
for(const signal of ['SIGINT','SIGTERM'])process.on(signal,async()=>{await RED.stop();server.close(()=>process.exit(0));});

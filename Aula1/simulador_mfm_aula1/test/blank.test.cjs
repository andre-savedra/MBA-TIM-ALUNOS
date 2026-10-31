const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{spawn}=require('node:child_process');
const wait=ms=>new Promise(r=>setTimeout(r,ms));
test('Aluno: editor vazio sem solução, painel ausente e edição preservada',{timeout:35000},async()=>{
 const root=path.resolve(__dirname,'..');assert(!fs.existsSync(path.join(root,'node-red/fluxo_base.json')));assert(!fs.existsSync(path.join(root,'node-red/functions')));
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tim-blank-'));const base='http://127.0.0.1:18890';let child;
 const start=()=>{child=spawn(process.execPath,['src/nodered.cjs'],{cwd:root,env:{...process.env,NODE_RED_USERDIR:dir,NODE_RED_PORT:'18890'},stdio:'ignore'});};
 async function ready(){for(let i=0;i<60;i++){try{const r=await fetch(base+'/flows');if(r.ok)return await r.json();}catch{}await wait(150)}throw Error('Node-RED não iniciou');}
 async function stop(){if(child){const c=child;child=null;await new Promise(resolve=>{c.once('exit',resolve);c.kill('SIGTERM');setTimeout(()=>{c.kill('SIGKILL');resolve()},2500).unref();});}}
 try{start();const flows=await ready();assert(Array.isArray(flows));assert.equal(flows.filter(x=>x.type!=='tab').length,0);assert.equal((await fetch(base+'/pratica1-alt')).status,404);
 const edit=[{id:'studenttab',type:'tab',label:'Trabalho do aluno'},{id:'note',type:'comment',z:'studenttab',name:'Minha anotação',x:100,y:100,wires:[]}];
 const response=await fetch(base+'/flows',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(edit)});assert.equal(response.status,204);
 await stop();start();const saved=await ready();assert(saved.some(x=>x.id==='note'));assert.equal((await fetch(base+'/pratica1-alt')).status,404);
 }finally{await stop();fs.rmSync(dir,{recursive:true,force:true});}
});

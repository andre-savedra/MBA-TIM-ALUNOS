const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {createApp}=require('../src/server.cjs');
test('Swagger local, referências OpenAPI e rotas do contrato',async()=>{
 const server=await new Promise(resolve=>{const s=createApp().listen(0,'127.0.0.1',()=>resolve(s))});
 const base='http://127.0.0.1:'+server.address().port;
 try{
 const html=await fetch(base+'/docs');assert.equal(html.status,200);assert((await html.text()).includes('SwaggerUIBundle'));
 assert.equal((await fetch(base+'/swagger-assets/swagger-ui-bundle.js')).status,200);
 assert.equal((await fetch(base+'/swagger-assets/swagger-ui.css')).status,200);
 const spec=await (await fetch(base+'/openapi.json')).json();assert.equal(spec.openapi,'3.0.3');assert.equal(spec.servers[0].url,'/');assert.equal(Object.keys(spec.paths).length,11);
 assert.deepEqual(spec.paths['/exchange/auth'].post.security,[]);assert.equal(spec.components.securitySchemes.bearerAuth.scheme,'bearer');
 const seen=new Set();for(const [p,methods] of Object.entries(spec.paths)){for(const op of Object.values(methods)){assert(!seen.has(op.operationId));seen.add(op.operationId);for(const name of [...p.matchAll(/\{([^}]+)\}/g)].map(x=>x[1]))assert(op.parameters.some(x=>x.name===name&&x.in==='path'&&x.required));}}
 function refs(v){if(!v||typeof v!=='object')return;if(v.$ref){assert(v.$ref.startsWith('#/'));let target=spec;for(const key of v.$ref.slice(2).split('/'))target=target[key];assert(target);}for(const value of Object.values(v))refs(value);}refs(spec);
 }finally{await new Promise(r=>server.close(r));}
});

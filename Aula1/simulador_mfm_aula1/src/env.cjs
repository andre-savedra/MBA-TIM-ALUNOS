const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..');
if(fs.existsSync(path.join(root,'.env')))process.loadEnvFile(path.join(root,'.env'));
module.exports={root};

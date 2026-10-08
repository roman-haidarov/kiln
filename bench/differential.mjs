import fs from 'node:fs';
import {createRequire} from 'node:module';
import {spawn} from 'node:child_process';
import readline from 'node:readline';
const require=createRequire(import.meta.url);
const wasm=process.env.LLHTTP_WASM;
if(!wasm) throw Error('Set LLHTTP_WASM to undici/lib/llhttp/llhttp-wasm.js');
let e,state;
const str=(at,len)=>Buffer.from(e.memory.buffer,at,len).toString('latin1');
const env={
 wasm_on_message_begin:()=>{state={url:'',body:'',headers:{},key:'',value:'',phase:'',messages:[]};return 0},
 wasm_on_url:(p,at,len)=>{state.url+=str(at,len);return 0},
 wasm_on_status:()=>0,
 wasm_on_header_field:(p,at,len)=>{if(state.phase==='value'){state.headers[state.key.toLowerCase()]=state.value.trim();state.key='';state.value=''}state.phase='field';state.key+=str(at,len);return 0},
 wasm_on_header_value:(p,at,len)=>{state.phase='value';state.value+=str(at,len);return 0},
 wasm_on_headers_complete:(p)=>{if(state.key)state.headers[state.key.toLowerCase()]=state.value.trim();state.method=cstring(e.llhttp_method_name(e.llhttp_get_method(p)));return 0},
 wasm_on_body:(p,at,len)=>{state.body+=Buffer.from(e.memory.buffer,at,len).toString('hex');return 0},
 wasm_on_message_complete:()=>21
};
function cstring(at){const b=new Uint8Array(e.memory.buffer);let end=at;while(b[end])end++;return Buffer.from(b.subarray(at,end)).toString()}
e=(await WebAssembly.instantiate(require(wasm),{env})).instance.exports;
function oracle(wire){const p=e.llhttp_alloc(1),at=e.malloc(wire.length),messages=[];new Uint8Array(e.memory.buffer,at,wire.length).set(wire);let offset=0,error=null;
 while(offset<wire.length){const code=e.llhttp_execute(p,at+offset,wire.length-offset);if(code!==21){if(code)error=cstring(e.llhttp_errno_name(code));else error='incomplete';break}const end=e.llhttp_get_error_pos(p)-at;let target=state.url,host=state.headers.host??null;if(/^https?:\/\//i.test(target)){const m=target.match(/^https?:\/\/([^/?]*)(.*)$/i);host=m[1];target=m[2]||'/';if(target.startsWith('?'))target='/'+target}const cut=target.indexOf('?');messages.push({status:200,method:state.method,path:Buffer.from(cut<0?target:target.slice(0,cut),'latin1').toString('hex'),query:Buffer.from(cut<0?'':target.slice(cut+1),'latin1').toString('hex'),host:host===null?null:Buffer.from(host,'latin1').toString('hex'),body:state.body,used:end-offset});if(end<=offset)throw Error('oracle failed to advance');offset=end;e.llhttp_resume(p)}e.llhttp_free(p);e.free(at);return {messages,error}}
let seed=Number(process.env.SEED||19112026)>>>0;
const random=n=>{seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return (seed>>>0)%n};
const next='GET /next?q=2 HTTP/1.1\r\nHost: next.example\r\n\r\n';
const initial=[
 'GET / HTTP/1.1\r\nHost: x\r\n\r\n',
 'POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc',
 'POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3;foo="bar"\r\nabc\r\n0\r\n\r\n',
 'GET http://example.test/a?q=1 HTTP/1.1\r\nHost: other\r\n\r\n',
 'OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n'
];
const chunks=['3;','3;=x','3;foo="','3;foo="a\\"b"','3;foo=bar','3;foo=bad space','3 ; foo = bar','0000000000000003','3;foo="a\x01b"','3;foo="a\tb"','3;foo=','3;foo;bar=b','3;foo\t="bar"'];
const corpus=initial.map(x=>Buffer.from(x+next,'latin1'));
for(const chunk of chunks)corpus.push(Buffer.from('POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n'+chunk+'\r\nabc\r\n0\r\n\r\n'+next,'latin1'));
for(const h of ['Host: x\r\nHost: y','Content-Length: 0\r\nContent-Length: 0','Content-Length: 0003','Content-Length: +3','Transfer-Encoding: chunked\r\nContent-Length: 3','X: a\tb','X : a','X: a\r\n b','Host:','X: a\x00b'])corpus.push(Buffer.from('POST / HTTP/1.1\r\n'+h+'\r\n\r\nabc'+next,'latin1'));
for(let i=0;i<Number(process.env.CASES||25000);i++){
 let base=initial[random(initial.length)];
 if(i%4===0){
   const length=random(512),payload=Buffer.alloc(length);for(let j=0;j<length;j++)payload[j]=random(256);
   const target=i%8===0?'/generated/'+i+'?q='+random(10000):'http://generated.test/generated/'+i;
   const host=i%12===0?'[::1]:8080':'generated.test';
   const fields=Array.from({length:random(12)},(_,j)=>'X-Field-'+j+': '+random(10000)+'\r\n').join('');
   const prefix='POST '+target+' HTTP/1.1\r\nHost: '+host+'\r\n'+fields;
   base=i%12===0?prefix+'Transfer-Encoding: chunked\r\n\r\n'+(length?length.toString(16)+';foo=bar\r\n'+payload.toString('latin1')+'\r\n':'')+'0\r\nX-Trace: yes\r\n\r\n':prefix+'Content-Length: '+length+'\r\n\r\n'+payload.toString('latin1');
 }
 let b=Buffer.from(base+next,'latin1');
 if(i%4!==0){const at=random(b.length),op=random(3),x=Buffer.from([random(256)]);b=op===0?Buffer.concat([b.subarray(0,at),x,b.subarray(at)]):op===1?Buffer.concat([b.subarray(0,at),b.subarray(at+1)]):Buffer.concat([b.subarray(0,at),x,b.subarray(at+1)])}
 corpus.push(b)
}
const rfcPolicies=new Set(['3;foo="a\\\"b"','3 ; foo = bar','3;foo\t="bar"'].map(chunk=>Buffer.from('POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n'+chunk+'\r\nabc\r\n0\r\n\r\n'+next,'latin1').toString('hex')));
const child=spawn(process.argv[2]||'build/parse_driver',[],{stdio:['pipe','pipe','inherit']});const exited=new Promise((resolve,reject)=>child.on('exit',code=>code?reject(Error('driver exit '+code)):resolve()));const lines=readline.createInterface({input:child.stdout})[Symbol.asyncIterator]();
child.stdin.end(corpus.map(b=>b.toString("hex")+"\n").join(""));
const counts={cases:corpus.length,exact:0,kiln_rejects:0,extension_methods:0,rfc_extension_policy:0,oracle_rejects:0,mismatch:0,both_reject:0},examples=[];
for(let i=0;i<corpus.length;i++){
 const wire=corpus[i];let ref=oracle(wire);const line=await lines.next();if(line.done)throw Error('driver exited at '+i);const actual=JSON.parse(line.value),ok=actual.filter(x=>x.status===200);let kind;
 if(ref.error==='HPE_INVALID_METHOD'&&ok.length>ref.messages.length){
   let offset=0;const pieces=[],methods=[];
   for(const m of ok){const part=wire.subarray(offset,offset+m.used),method=Buffer.from(m.method);if(part.subarray(0,method.length+1).toString()!==m.method+' ')break;pieces.push(Buffer.concat([Buffer.from('GET'),part.subarray(method.length)]));methods.push(m.method);offset+=m.used}
   pieces.push(wire.subarray(offset));const normalized=oracle(Buffer.concat(pieces));normalized.messages.forEach((m,j)=>{if(methods[j]){m.used+=methods[j].length-3;m.method=methods[j]}});
   if(!kind&&JSON.stringify(ok)===JSON.stringify(normalized.messages)){ref=normalized;kind='extension_methods'}
 }
 if(rfcPolicies.has(wire.toString('hex'))&&!kind){const expected=[{status:200,method:'POST',path:'2f',query:'',host:'78',body:'616263',used:wire.length-Buffer.byteLength(next)},{status:200,method:'GET',path:'2f6e657874',query:'713d32',host:'6e6578742e6578616d706c65',body:'',used:Buffer.byteLength(next)}];if(JSON.stringify(ok)===JSON.stringify(expected))kind='rfc_extension_policy'}

 if(!kind&&JSON.stringify(ok)===JSON.stringify(ref.messages)){kind=ref.error?'both_reject':'exact'}
 else if(!kind&&actual.some(x=>x.status!==200)&&ok.length<=ref.messages.length&&JSON.stringify(ok)===JSON.stringify(ref.messages.slice(0,ok.length))){kind='kiln_rejects'}else if(!kind&&ref.error && ok.length>ref.messages.length){kind='oracle_rejects'}else if(!kind)kind='mismatch';
 counts[kind]++;if((kind==='oracle_rejects'||kind==='mismatch')&&examples.length<150)examples.push({i,kind,wire:wire.toString('hex'),ref,actual});
}
await exited;const report={oracle_wasm_sha256:(await import('node:crypto')).createHash('sha256').update(require(wasm)).digest('hex'),seed:Number(process.env.SEED||19112026),counts,examples};const result=process.env.RESULT||`${process.env.KILN_VALIDATION_DIR||'/tmp/kiln-validation'}/differential.json`;fs.mkdirSync(require('node:path').dirname(result),{recursive:true});fs.writeFileSync(result,JSON.stringify(report,null,2));console.log(JSON.stringify(counts));if(counts.oracle_rejects||counts.mismatch)process.exitCode=1;

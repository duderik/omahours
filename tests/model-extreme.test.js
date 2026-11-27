const fs=require('fs');const path=require('path');const src=fs.readFileSync(process.argv[2]||path.join(__dirname,'..','Model.js'),'utf8').replace('.pragma library','');
const M=new Function(src+';return {read,check,serialize,format,parseInput,applyInput,toggle,stopIfStale,timeOf,findProject,emptyState,copyState};')();
const a=require('assert'); const out=[];
const e=t=>{const r=M.parseInput(t);return r?r.kind+':'+r.ms:null};
const fall=(t,soll)=>{const ist=e(t);out.push(`${JSON.stringify(t).slice(0,40)} -> ${ist===null?'invalid':ist}`);a.equal(ist,soll,t)};
// Extreme input: invalid means a red field border
fall('+123123123h',null); fall('-21232d212h',null); fall('9007199254740993m',null); fall('1e309',null);
fall('',null); fall('+',null); fall('-',null); fall('--5m',null); fall('+-5m',null); fall('-+5m',null);
fall('1.5h',null); fall('1,5h',null); fall('30s',null); fall('2d',null); fall('٣m',null); fall('３m',null);
fall('5'.repeat(100000)+'m',null); fall('h',null); fall('m',null); fall('hm',null); fall('1m1h',null);
fall('<b>1h</b>',null); fall('Infinity',null); fall('NaN',null); fall('0x10m',null); fall('1h30m5',null);
// Valid edge cases
fall('1h 30m','set:5400000'); fall(' + 20 m ','add:1200000'); fall('2H','set:7200000'); fall('0','set:0');
fall('00090m','set:5400000'); fall('99999h','set:'+99999*3600000); fall('9999999m',null);
fall('99999h','set:'+99999*3600000); fall('99999h1m',null); fall('100000h',null); fall('5999940m','set:'+5999940*60000); fall('5999941m',null);
fall('4166d15h',null); fall('+2d',null); fall('1d 2h',null);
fall('-0','subtract:0'); fall('+0','add:0');
// Results: never negative, never NaN
a.equal(M.applyInput(0,M.parseInput('-99999h')),0);
let x=0; for(let i=0;i<100000;i++) x=M.applyInput(x,M.parseInput('+99999h'));
out.push('100000× +99999h -> '+M.format(x)+' safe='+Number.isSafeInteger(x));
a.ok(Number.isSafeInteger(x)); a.ok(M.check(M.serialize({last:'',projects:[{name:'X',ms:x,since:0}]})).ok);
for (const v of [0,59999,60000,3599999,3600000,99999*3600000,Number.MAX_SAFE_INTEGER]) out.push('format '+v+' -> '+M.format(v));
a.equal(M.format(Number.MAX_SAFE_INTEGER),'2501999792h59m'); a.equal(M.format(-5),'0m'); a.equal(M.format(NaN),'NaN'.length?M.format(NaN):'');
// Names
const names=['👩‍💻 Client','עברית مرحبا','<b>x</b>','<img src="https://example.invalid/t">','a'.repeat(5000),'abc','ABC','  ','\t'];
let s=M.emptyState();
for (const n of names) if (n.trim()!=='' && M.findProject(s.projects,n.trim())<0) s.projects.push({name:n.trim(),ms:0,since:0});
a.equal(s.projects.length,7); a.equal(M.findProject(s.projects,'  '),-1);
let r=M.check(M.serialize(s)); a.ok(r.ok); a.deepEqual(r.store,s); out.push('7 names (emoji, RTL, markup, 5000 characters, abc/ABC) survive write and read');
// Broken files: ok=false, never overwritten
const unreadable={
 'invalid JSON':'{"projects":[', 'Array':'[]', 'number':'42', 'string':'"x"', 'null':'null',
 'projects not an array':'{"projects":{}}', 'Version 2':'{"version":2,"projects":[]}', 'last is a number':'{"last":5,"projects":[]}',
 'name is a number':'{"projects":[{"name":5}]}', 'empty name':'{"projects":[{"name":" "}]}', 'null entry':'{"projects":[null]}',
 'ms is text':'{"projects":[{"name":"A","ms":"viel"}]}', 'negative ms':'{"projects":[{"name":"A","ms":-1}]}', 'ms 1e309':'{"projects":[{"name":"A","ms":1e309}]}',
 'ms too large':'{"projects":[{"name":"A","ms":1e300}]}', 'since is an object':'{"projects":[{"name":"A","since":{}}]}',
 'duplicate':'{"projects":[{"name":"A"},{"name":"A"}]}', 'old German keys':'{"version":1,"zuletzt":"A","projekte":[{"name":"A","ms":1,"seit":0}]}', 'unknown entry field':'{"projects":[{"name":"A","note":"x"}]}',
 'two running':'{"projects":[{"name":"A","since":5},{"name":"B","since":6}]}',
};
for (const [k,t] of Object.entries(unreadable)) { const r=M.check(t); a.equal(r.ok,false,k); out.push('broken: '+k+' -> read-only'); }
for (const t of ['', '   ', '{}', '{"projects":[]}', '{"projects":[{"name":"A","ms":"100"}]}', '{"version":1,"last":null,"projects":[{"name":"A","ms":0,"since":null}]}'])
  { const r=M.check(t); a.equal(r.ok,true,t); }
out.push('empty, {}, number as text "100" -> ok');
console.log(out.join('\n')); console.log('ok');
// Regression: a project at MAX_SAFE_INTEGER that was started and paused exceeded it
{ const s={last:'',projects:[{name:'X',ms:Number.MAX_SAFE_INTEGER,since:0}]};
  M.toggle(s,'X',1000); a.equal(M.timeOf(s.projects[0],5000000),Number.MAX_SAFE_INTEGER);
  M.toggle(s,'X',5000000); a.equal(s.projects[0].ms,Number.MAX_SAFE_INTEGER); a.ok(M.check(M.serialize(s)).ok); console.log('MAX_SAFE_INTEGER plus running time stays valid'); }

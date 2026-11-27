const fs=require('fs');const path=require('path');const src=fs.readFileSync(process.argv[2]||path.join(__dirname,'..','Model.js'),'utf8').replace('.pragma library','');
const M=new Function(src+';return {read,serialize,format,parseInput,applyInput,toggle,stopIfStale,timeOf,findProject,emptyState,fitWidth,pauseRunning,resume};')();
const a=require('assert');
a.equal(M.format(0),'0m');a.equal(M.format(40*60000+59000),'40m');a.equal(M.format((22*60+2)*60000),'22h2m');a.equal(M.format(60*60000),'1h0m');
const e=t=>{const r=M.parseInput(t);return r?r.kind+':'+r.ms/60000:null};
a.equal(e('23h'),'set:1380');a.equal(e('1h30'),'set:90');a.equal(e('1h30m'),'set:90');a.equal(e('90m'),'set:90');
a.equal(e('+20m'),'add:20');a.equal(e('-1h'),'subtract:60');a.equal(e('0'),'set:0');a.equal(e(' 2 h '),'set:120');
for (const bad of ['', 'h', 'm', 'abc', '1x', '1h30h', '+', '--1h', '1.5h', '<img>']) a.equal(e(bad),null,bad);
a.equal(M.applyInput(30*60000,M.parseInput('-1h')),0);
// Examples from the help text
a.equal(e('2h22m'),'set:142');a.equal(e('+2h22m'),'add:142');a.equal(e('-90m'),'subtract:90');a.equal(e('90m'),'set:90');
a.equal(M.format(M.applyInput(0,M.parseInput('90m'))),'1h30m');
a.equal(M.format(M.applyInput(3*3600000,M.parseInput('-90m'))),'1h30m');
a.equal(M.format(M.applyInput(10*60000,M.parseInput('+2h22m'))),'2h32m');
a.equal(M.applyInput(60*60000,M.parseInput('-90m')),0);
// Case matters: abc and ABC differ, only exact duplicates are dropped
let s0=M.read('{"projects":[{"name":"ABC"},{"name":"abc"},{"name":"ABC "}]}');
a.equal(s0.projects.length,2);a.equal(M.findProject(s0.projects,'abc'),1);a.equal(M.findProject(s0.projects,'Abc'),-1);
let s=M.read('{"projects":[{"name":"ABC","ms":0,"since":0},{"name":"ABC"},{"name":"DEF","ms":5,"since":0}],"last":"XYZ"}');
a.equal(s.projects.length,2);a.equal(s.last,'');
M.toggle(s,'ABC',1000);M.toggle(s,'DEF',61000);a.equal(s.projects[0].since,0);a.equal(s.projects[0].ms,60000);a.equal(s.projects[1].since,61000);a.equal(s.last,'DEF');
// Stale heartbeat (passed separately); DEF has been running since 61000
a.equal(M.stopIfStale(s,121000,121000+100000),false);
a.equal(M.stopIfStale(s,121000,121000+200000),true);
a.equal(s.projects[1].since,0);a.equal(s.projects[1].ms,5+60000);
// No heartbeat file: the start time is the sign of life
M.toggle(s,'DEF',500000); a.equal(M.stopIfStale(s,0,500000+100000),false);
a.equal(M.stopIfStale(s,0,500000+200000),true); a.equal(s.projects[1].ms,5+60000);
// Old heartbeat from an earlier session, fresh start: keeps running
M.toggle(s,'DEF',900000); a.equal(M.stopIfStale(s,100,900000+60000),false);
M.toggle(s,'DEF',900000+60000);
// The project file holds no heartbeat
a.equal('heartbeat' in JSON.parse(M.serialize(s)),false);
a.equal('heartbeat' in M.read('{"heartbeat":5,"projects":[]}'),false);
a.deepEqual(M.read(M.serialize(s)),s);
a.deepEqual(M.read('unreadable'),M.emptyState());
// Two running projects in the file: only the first keeps running
s=M.read('{"projects":[{"name":"A","since":5},{"name":"B","since":6}]}');a.equal(s.projects[1].since,0);

// Panel width follows the widest row, never below min or above max
a.equal(M.fitWidth([],200,380),200);a.equal(M.fitWidth([150,260],200,380),260);a.equal(M.fitWidth([500],200,380),380);
// Lock: only the project running before the lock resumes after unlocking
let L=M.read('{"projects":[{"name":"A","ms":0,"since":1000},{"name":"B","ms":0,"since":0}],"last":"A"}');
a.equal(M.pauseRunning(L,61000),'A');a.equal(L.projects[0].since,0);a.equal(L.projects[0].ms,60000);
a.equal(M.pauseRunning(L,62000),'');                       // locked again, nothing runs: nothing remembered
a.equal(M.resume(L,'A',200000),true);a.equal(L.projects[0].since,200000);a.equal(L.projects[0].ms,60000);
let P=M.read('{"projects":[{"name":"A","ms":5,"since":0}],"last":"A"}');
a.equal(M.pauseRunning(P,1000),'');a.equal(M.resume(P,'',2000),false);a.equal(P.projects[0].since,0); // paused before lock stays paused
let O=M.read('{"projects":[{"name":"A","ms":0,"since":0},{"name":"B","ms":0,"since":5000}],"last":"B"}');
a.equal(M.resume(O,'A',9000),false);a.equal(O.projects[0].since,0);a.equal(O.projects[1].since,5000); // another runs meanwhile
a.equal(M.resume(O,'gone',9000),false);                    // deleted or renamed meanwhile
console.log('ok');

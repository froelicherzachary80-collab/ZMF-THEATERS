namespace ZMFTheaters.Home;

/// The iPhone / browser companion served by the Windows host at
/// http://PC-ADDRESS:8977/companion. Hosts sign in with the access code shown
/// in Home 4DX; friends open an invite link (?room=…&invite=…).
public static class CompanionPage
{
    public const string Html = """
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes"><meta name="theme-color" content="#0b0709">
<title>ZMF Home 4DX</title>
<style>
:root{--bg:#0b0709;--panel:#170f12;--line:#3a2a20;--gold:#ffc84b;--cyan:#4dd0e1;--red:#e53935;--text:#f3ece6;--dim:#a99b90}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px -apple-system,system-ui,Segoe UI,sans-serif;padding:env(safe-area-inset-top) 12px 90px}
h1{font-size:20px;letter-spacing:.08em;color:var(--gold);margin:14px 0 2px}h2{font-size:13px;letter-spacing:.12em;color:var(--dim);margin:18px 0 6px;text-transform:uppercase}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:12px;margin:8px 0}
input,button,select{font:inherit;border-radius:10px;border:1px solid var(--line);background:#22171b;color:var(--text);padding:10px 12px}
input{width:100%;margin:4px 0}button{cursor:pointer}button.gold{background:var(--gold);color:#1a1000;border:0;font-weight:700}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}.grow{flex:1}.tag{font-size:11px;padding:2px 7px;border-radius:999px;border:1px solid var(--line);color:var(--dim)}
.ok{color:#7ee787}.warn{color:#ffb74d}.bad{color:#ff7b72}.sim{color:var(--cyan)}.small{font-size:12px;color:var(--dim)}
#estop{position:fixed;left:12px;right:12px;bottom:calc(12px + env(safe-area-inset-bottom));background:var(--red);color:#fff;border:0;font-weight:800;font-size:18px;padding:16px;border-radius:16px;letter-spacing:.06em;box-shadow:0 8px 30px #e5393566}
#chat{height:300px;overflow:auto;display:flex;flex-direction:column;gap:6px}.msg{padding:6px 9px;border-radius:10px;background:#21161a}.msg.ai{border-left:3px solid var(--cyan)}.msg.sys{background:none;color:var(--dim);font-size:12px}
.ai-badge{font-size:10px;background:var(--cyan);color:#001b1f;border-radius:6px;padding:1px 5px;margin-left:4px;font-weight:700}
.hidden{display:none}
</style></head><body>
<h1>ZMF THEATERS+ · HOME 4DX</h1><div class="small" id="who">Not signed in</div>

<div id="login" class="card">
  <h2>Host sign-in</h2>
  <div class="small">Enter the access code shown on your PC in Admin → Immersive Home 4DX → PC + iPhone Companion.</div>
  <input id="code" placeholder="Access code" autocapitalize="characters" autocomplete="off">
  <input id="name" placeholder="Your name (optional)">
  <button class="gold" onclick="login()">Sign in</button>
  <div id="joinBox" class="hidden"><h2>Join private cinema</h2><input id="gname" placeholder="Your name"><button class="gold" onclick="join()">Join room</button></div>
  <div id="loginErr" class="bad small"></div>
</div>

<div id="host" class="hidden">
  <h2>Now playing</h2><div class="card" id="now">—</div>
  <div class="row"><button onclick="ctl('back')">⟲ 10s</button><button onclick="ctl('play')">▶ Play</button><button onclick="ctl('pause')">⏸ Pause</button><button onclick="ctl('forward')">30s ⟳</button></div>
  <h2>Scene director</h2><div class="card" id="director">—</div>
  <h2>Devices</h2><div id="devices"></div>
  <h2>Last commands</h2><div class="card small" id="telemetry">—</div>
  <h2>Private cinema rooms</h2>
  <div class="row"><input class="grow" id="roomName" placeholder="Room name"><button class="gold" onclick="createRoom()">Create</button></div>
  <div id="rooms"></div>
</div>

<div id="room" class="hidden">
  <h2 id="roomTitle">Room</h2>
  <div class="card small" id="roomPlay">—</div>
  <div class="card"><div id="members" class="small"></div></div>
  <div class="card"><div id="chat"></div>
  <div class="row"><input class="grow" id="msg" placeholder="Say something…" onkeydown="if(event.key==='Enter')send()"><button class="gold" onclick="send()">Send</button></div></div>
  <div id="aiBox" class="row hidden"></div>
</div>

<button id="estop" class="hidden" onclick="estop()">■ EMERGENCY STOP ALL EFFECTS</button>
<script>
const q=new URLSearchParams(location.search);let token=localStorage.getItem('zmfToken')||'',role=localStorage.getItem('zmfRole')||'',roomId=q.get('room')||localStorage.getItem('zmfRoom')||'',since=0;
const $=id=>document.getElementById(id);
function api(path,opt={}){opt.headers=Object.assign({'Content-Type':'application/json'},opt.headers||{});if(token)opt.headers.Authorization='Bearer '+token;return fetch(path,opt).then(r=>{if(r.status===401){if(role)logout();throw new Error('Not authorised')}return r.json()})}
function esc(s){return String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function fmt(t){t=Math.max(0,Math.floor(t||0));return Math.floor(t/3600)+':'+String(Math.floor(t/60)%60).padStart(2,'0')+':'+String(t%60).padStart(2,'0')}
function logout(){token='';role='';localStorage.removeItem('zmfToken');localStorage.removeItem('zmfRole');show()}
async function login(){try{const r=await api('/api/login',{method:'POST',body:JSON.stringify({code:$('code').value,name:$('name').value,clientTimeMs:Date.now()})});token=r.token;role='host';localStorage.setItem('zmfToken',token);localStorage.setItem('zmfRole',role);show()}catch(e){$('loginErr').textContent='Sign-in failed: check the access code.'}}
async function join(){try{const r=await api('/api/rooms/'+roomId+'/join',{method:'POST',body:JSON.stringify({invite:q.get('invite')||'',name:$('gname').value})});token=r.token;role='guest';localStorage.setItem('zmfToken',token);localStorage.setItem('zmfRole',role);localStorage.setItem('zmfRoom',roomId);show()}catch(e){$('loginErr').textContent='Could not join: the invite link may be wrong or the room was deleted.'}}
function show(){$('login').classList.toggle('hidden',!!role);$('joinBox').classList.toggle('hidden',!(q.get('room')&&q.get('invite')));$('host').classList.toggle('hidden',role!=='host');$('estop').classList.toggle('hidden',role!=='host');$('room').classList.toggle('hidden',!(role&&roomId));$('aiBox').classList.toggle('hidden',role!=='host');$('who').textContent=role?('Signed in as '+role):'Not signed in';if(role==='host')$('aiBox').innerHTML=['Nova','Alex','Mia','Jordan'].map(n=>`<button onclick="ai('${n}')">+ ${n} <span class=ai-badge>AI</span></button>`).join('')}
function stateClass(s){return s.startsWith('CONNECTED — TESTED')?'ok':s.startsWith('CONNECTED')?'warn':s==='SIMULATED'?'sim':'bad'}
async function poll(){if(role==='host'){try{const s=await api('/api/status');const p=s.pc&&s.pc.playing?s.pc:(s.phone||s.pc);
$('now').innerHTML=p?`<b>${esc(p.title||p.mediaId)}</b> · ${p.source==='iphone'?'📱 iPhone':'🖥 PC'} · ${p.playing?'▶':'⏸'} ${fmt(p.position)}<div class=small>${esc(s.phoneNote||'')}</div>`:'Nothing playing';
const d=s.director;$('director').innerHTML=`<b>${esc(d.scene)}</b> <span class=tag>confidence ${(d.sceneConfidence*100|0)}%</span><div class=small>${esc(d.state)}</div><div>Wind: ${d.wind?'<span class=ok>requested</span>':'off'} · Light: <span style="color:rgb(${d.light.r},${d.light.g},${d.light.b})">■</span> ${esc(d.light.palette)} ${(d.light.brightness*100|0)}%</div>`+(s.emergencyStopped?'<div class=bad><b>EMERGENCY STOP ACTIVE</b> <button onclick=rearm()>Re-arm</button></div>':'')+(s.physicalEnabled?'':'<div class=warn>Physical effects are off (virtual only or not armed on the PC).</div>');
$('devices').innerHTML=s.devices.map(v=>`<div class=card><div class=row><b class=grow>${esc(v.name)}</b><span class="tag ${stateClass(v.state)}">${esc(v.state)}</span></div><div class=small>${esc(v.role)} · ${esc(v.detail)}${v.latencyMs>=0?' · '+Math.round(v.latencyMs)+' ms':''}</div>${v.lastCommand?`<div class=small>Last: ${esc(v.lastCommand)} → ${esc(v.lastAck||v.lastError)}</div>`:''}</div>`).join('');
$('telemetry').innerHTML=s.telemetry.map(t=>`${new Date(t.at).toLocaleTimeString()} · ${esc(t.device)} ${esc(t.command)} → ${esc(t.ack)}`).join('<br>')||'No commands yet';
const rooms=await api('/api/rooms');$('rooms').innerHTML=rooms.map(r=>`<div class=card><div class=row><b class=grow>${esc(r.name)}</b><button onclick="openRoom('${r.id}')">Open</button><button onclick="del('${r.id}')">Delete</button></div><div class=small>Invite: ${location.origin}/companion?room=${r.id}&invite=${r.invite}</div><div class=small>${r.members.map(m=>esc(m.name)+(m.kind==='AI'?' (AI)':'')).join(', ')}</div></div>`).join('')}catch(e){}}
if(role&&roomId){try{const r=await api('/api/rooms/'+roomId+'/events?since='+since);
for(const i of r.items){since=Math.max(since,i.seq);const el=document.createElement('div');el.className='msg'+(i.ai?' ai':'')+(i.kind!=='chat'?' sys':'');el.innerHTML=i.kind==='chat'?`<b>${esc(i.from)}</b>${i.ai?'<span class=ai-badge>AI · scripted</span>':''}: ${esc(i.text)}`:esc(i.text);$('chat').appendChild(el);$('chat').scrollTop=1e9}
$('members').innerHTML='In the room: '+r.members.map(m=>`${esc(m.name)}${m.kind==='AI'?'<span class=ai-badge>AI</span>':''} <span class=tag>${esc(m.seat)}</span>`).join(' ');
$('roomPlay').innerHTML=r.playback.title?`${r.playback.playing?'▶':'⏸'} ${esc(r.playback.title)} @ ${fmt(r.playback.position)} — play your own copy and keep it at this time`:'Waiting for the host to start a film'}catch(e){}}}
async function ctl(a){await api('/api/playback/control',{method:'POST',body:JSON.stringify({action:a})})}
async function estop(){await api('/api/estop',{method:'POST'});poll()}
async function rearm(){await api('/api/rearm',{method:'POST'});poll()}
async function createRoom(){const r=await api('/api/rooms',{method:'POST',body:JSON.stringify({name:$('roomName').value})});openRoom(r.id)}
async function del(id){if(confirm('Delete this room?')){await api('/api/rooms/'+id,{method:'DELETE'});if(id===roomId){roomId='';show()}poll()}}
function openRoom(id){roomId=id;since=0;$('chat').innerHTML='';localStorage.setItem('zmfRoom',id);show();poll()}
async function send(){const t=$('msg').value.trim();if(!t)return;$('msg').value='';await api('/api/rooms/'+roomId+'/chat',{method:'POST',body:JSON.stringify({text:t})});poll()}
async function ai(n){await api('/api/rooms/'+roomId+'/ai',{method:'POST',body:JSON.stringify({name:n})});poll()}
show();poll();setInterval(poll,1000);
</script></body></html>
""";
}

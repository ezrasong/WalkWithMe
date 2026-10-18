const $ = id => document.getElementById(id);
const guardian = location.pathname === '/guardian';
const fragment = new URLSearchParams(location.hash.slice(1));
let credentials, state, lastResponse = 0, demoSeq = {phone:0,watch:0}, panel = 'map';
let map, evidenceLayer, fitted = false, lastTarget, arStream, arWatch, arPosition, arHeading, arHeadingAt = 0, arRequest = 0;
const key = guardian ? 'kaze-guardian' : 'kaze-owner';
if (fragment.has('session') && fragment.has('token')) {
  credentials = {id:fragment.get('session'),token:fragment.get('token')};
  sessionStorage.setItem(key,JSON.stringify(credentials)); history.replaceState(null,'',location.pathname);
} else { try { credentials = JSON.parse(sessionStorage.getItem(key)); } catch {} }
async function api(action = '', payload, method = 'POST') {
  const response = await fetch(`/api/sessions/${credentials.id}${action ? '/' + action : ''}`, {
    method: payload === undefined ? 'GET' : method, headers:{Authorization:`Bearer ${credentials.token}`,...(payload === undefined ? {} : {'Content-Type':'application/json'})},
    body:payload === undefined ? undefined : JSON.stringify(payload)});
  const data = await response.json(); if (!response.ok) { const e = new Error(data.error); e.status=response.status; throw e; } return data;
}
function notify(message) { $('message').textContent=message; }
function serverTime() { return (state?.serverNow ?? Date.now()) + (lastResponse ? Date.now()-lastResponse : 0); }
function ago(at) { if (!at) return 'No readings'; return `${Math.max(0,Math.floor((serverTime()-at)/1000))}s ago`; }
function time(at) { return at ? new Date(at).toLocaleTimeString() : 'None yet'; }
function selectPanel(next) {
  panel=next;
  for (const name of ['map','activity','settings']) $('panel-'+name).hidden = name !== panel;
  for (const button of document.querySelectorAll('[data-panel]')) { if(button.dataset.panel===panel) button.setAttribute('aria-current','page'); else button.removeAttribute('aria-current'); }
  if(panel==='map' && map) requestAnimationFrame(()=>map.invalidateSize());
  if(panel!=='map') closeAr();
}
for (const button of document.querySelectorAll('[data-panel]')) button.onclick=()=>selectPanel(button.dataset.panel);
function draw() {
  if (!map) {
    map=L.map('trail-map').setView([20,0],2);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'}).addTo(map);
    evidenceLayer=L.layerGroup().addTo(map);
  }
  evidenceLayer.clearLayers();
  const geo=state.geography, latest=geo?.latest;
  $('private-message').hidden=state.shared;
  $('empty-location').hidden=!state.shared || !!latest;
  if (!latest) { lastTarget=null; return; }
  for (const path of geo.mapPaths ?? geo.paths) {
    const color=path.source==='phone'?'#225cbe':'#7946ad';
    if(path.points.length>1) L.polyline(path.points.map(p=>[p.latitude,p.longitude]),{color,weight:4}).addTo(evidenceLayer);
    for (const p of path.points) L.circleMarker([p.latitude,p.longitude],{radius:3,color,fillOpacity:1}).bindTooltip(`${p.source}: ${new Date(p.fixAt).toLocaleTimeString()}, reported accuracy ${Math.round(p.accuracy)} m`).addTo(evidenceLayer);
  }
  L.circle([latest.latitude,latest.longitude],{radius:latest.accuracy,color:'#225cbe',weight:1,fillOpacity:.09}).addTo(evidenceLayer);
  L.marker([latest.latitude,latest.longitude],{icon:L.divIcon({className:'person-marker',iconSize:[20,20]}),title:'Last reported location'}).addTo(evidenceLayer);
  const target=[latest.latitude,latest.longitude];
  if(!fitted) { map.fitBounds(L.latLngBounds([target,...(geo.mapPaths ?? geo.paths).flatMap(path=>path.points.map(p=>[p.latitude,p.longitude]))]).pad(.2),{maxZoom:17}); fitted=true; }
  lastTarget=target;
}
function tick() {
  if(!state) return;
  const deadline=state.dueAt+(state.phase==='challenge'?state.graceSeconds*1000:0);
  $('countdown').textContent=state.phase==='alert'?'Check on them':state.phase==='resolved'?'Session ended':`${Math.max(0,Math.ceil((deadline-serverTime())/1000))}s`;
  $('countdown-label').textContent=state.phase==='armed'?'until check-in':state.phase==='challenge'?'to respond':state.phase==='alert'?'Assistance is not verified':'Sharing stopped';
  const latest=state.geography?.latest;
  $('location-status').textContent=latest ? `${latest.source === 'phone' ? 'Phone' : 'Watch'} location · ${ago(latest.fixAt)} · reported accuracy ${Math.round(latest.accuracy)} m${serverTime()-latest.fixAt>30000?' · Stale':''}\n${latest.latitude.toFixed(5)}, ${latest.longitude.toFixed(5)}` : state.shared?'No location received.':'Location is private.';
  updateAr();
}
function render() {
  $('setup').hidden=true; $('dashboard').hidden=false;
  $('session-title').textContent=guardian?'Your person': 'Safety session'; $('person-name').textContent=state.name;
  $('session-description').textContent=state.sensorMode==='simulated'?'Simulated session · generated readings, not hardware measurements':'Device session · readings appear only after a device connects';
  $('phase-pill').textContent={armed:'Session active',challenge:'Check in now',alert:'Check-in unanswered',resolved:'Session ended'}[state.phase]??state.phase;
  $('phase-pill').className='pill '+state.phase; $('alert-banner').hidden=state.phase!=='alert';
  $('owner-actions').hidden=guardian||state.phase==='resolved'; $('check-in').disabled=state.phase==='alert';
  $('guardian-actions').hidden=!guardian||state.phase!=='alert';
  $('acknowledge').disabled=!!state.acknowledgedAt; $('arrived').disabled=!!state.arrivalReportedAt;
  $('response-status').textContent=state.arrivalReportedAt?'Guardian reports being with the person. Arrival is not independently verified.':state.acknowledgedAt?'Guardian acknowledged the request. Arrival is not verified.':'';
  $('check-in-status').textContent=`Last server-accepted check-in: ${time(state.lastCheckInAt)}`;
  $('sharing-status').textContent=state.phase==='resolved'?'Session ended. Guardian sharing stopped.':state.guardianRevokedAt?'Guardian access revoked.':state.liveSharing?'Live sharing was explicitly enabled for this session.':'Trail shared with your guardian only after nonresponse.';
  $('timing-settings').textContent=`Check in every ${state.intervalSeconds}s with ${state.graceSeconds}s to respond. Expires ${new Date(state.expiresAt).toLocaleString()}.`;
  $('pairing-card').hidden=guardian||!!state.guardianRevokedAt; $('end-controls').hidden=guardian;
  $('demo-controls').hidden=guardian||state.sensorMode!=='simulated'||state.phase==='resolved';
  $('guardian-status').textContent=state.guardianConnected?'Guardian page recently connected. This does not prove anyone is watching.':'Guardian page not recently connected. No push, calls or SMS are configured.';
  $('sources').replaceChildren(...['phone','watch'].map(source=>{const p=document.createElement('p');p.textContent=`${source==='phone'?'Phone':'Watch'} connection: ${ago(state.sources[source]?.lastAt)}`;return p;}));
  const labels={started:'Session started',challenge:'Check-in due',alert:'Assistance requested after nonresponse','check-in':'Check-in accepted by server',acknowledge:'Guardian acknowledged (help not verified)',arrived:'Guardian reported arrival (not verified)',resolve:'Session ended','revoke-guardian':'Guardian access revoked','demo-take':'Simulated alert take restarted'};
  $('activity').replaceChildren(...(state.activity??[]).map(a=>{const li=document.createElement('li');li.textContent=`${time(a.at)} · ${labels[a.action]??a.action} · ${a.role}`;return li;}));
  const height=state.trail?.elevations.find(e=>e.source==='watch')??state.trail?.elevations[0];
  $('height-status').textContent=height?`Relative pressure height: ${height.relativeMeters.toFixed(1)} m (${height.source}). Weather and pressure drift can affect this. Floor, room and stairs are unknown.`:'';
  $('warnings').replaceChildren(...(state.geography?.warnings??[]).map(text=>{const li=document.createElement('li');li.textContent=text;return li;}));
  $('directions').hidden=!state.geography?.latest;
  if(state.geography?.latest) {const p=state.geography.latest;$('directions').href=`https://www.google.com/maps/dir/?api=1&destination=${p.latitude},${p.longitude}`;}
  $('open-ar').hidden=!guardian||state.phase!=='alert'||!state.geography?.latest;
  if(!state.shared||state.phase!=='alert') closeAr();
  if(!guardian&&credentials.guardianToken) {
    const url=new URL('/guardian',location.origin);url.hash=new URLSearchParams({session:credentials.id,token:credentials.guardianToken});$('guardian-link').href=url.href;
    $('phone-config').value=JSON.stringify({baseUrl:location.origin,id:credentials.id,ownerToken:credentials.token,watchToken:credentials.watchToken});
  } else if(!guardian) $('pairing-card').hidden=true;
  $('motion-consent-controls').hidden=guardian||state.phase==='resolved'||state.sensorMode!=='device';
  $('motion-consent').checked=state.motionSharingConsent===true;
  drawMotion();draw();tick();selectPanel(panel);
}
async function poll() {
  try {state=await api();lastResponse=Date.now();render();$('connection-status').textContent='Server connected. Only uploaded readings are available remotely.';}
  catch(e) {
    closeAr();
    if(e.status===401||e.status===404) { state=null; evidenceLayer?.clearLayers(); $('dashboard').hidden=true; $('setup').hidden=true; sessionStorage.removeItem(key); notify('Access expired, deleted or revoked. Private evidence has been cleared from this view.'); }
    else {$('connection-status').textContent='Server unavailable. Displayed evidence may be stale; new readings may still be queued on the device. The PC must be running for escalation.';}
  }
}
function begin() {poll();setInterval(poll,2000);setInterval(tick,500);}
async function create(simulated=false) {
  const form=$('create-form');if(!form.reportValidity())return;
  const fields=Object.fromEntries(new FormData(form));
  try { const response=await fetch('/api/sessions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:fields.name,consent:true,simulation:true,motionSharingConsent:!simulated,motionDiagnosticsConsent:!simulated,sensorMode:simulated?'simulated':'device',intervalSeconds:simulated?15:Number(fields.intervalSeconds),graceSeconds:simulated?5:Number(fields.graceSeconds),liveSharing:$('live-sharing').checked,liveSharingConsent:$('live-sharing').checked})});
    const data=await response.json();if(!response.ok)throw new Error(data.error);
    credentials={id:data.id,token:data.ownerToken,guardianToken:data.guardianToken,watchToken:data.watchToken};sessionStorage.setItem(key,JSON.stringify(credentials));begin();
  }catch(e){notify(e.message);}
}
$('create-form').onsubmit=e=>{e.preventDefault();create();};$('start-demo').onclick=()=>create(true);
for(const [id,action] of [['check-in','check-in'],['resolve','resolve'],['acknowledge','acknowledge'],['arrived','arrived'],['revoke-guardian','revoke-guardian']]) $(id).onclick=async()=>{
  $(id).disabled=true; if(action==='check-in')notify('Sending check-in. Waiting for server confirmation…');
  try {await api(action,{confirm:true});notify(action==='check-in'?'Check-in confirmed by server.':'Saved by server.');await poll();}catch(e){notify(`Not confirmed: ${e.message}. The server deadline may still be active.`);}finally{$(id).disabled=false;}
};
$('delete-session').onclick=async()=>{if(!confirm('Delete this session and revoke all access?'))return;try{await api('',{},'DELETE');sessionStorage.removeItem(key);location.reload();}catch(e){notify(e.message);}};
async function copy(value){try{await navigator.clipboard.writeText(value);notify('Copied. Keep this access private.');}catch{notify('Select and copy the field manually.');}}
$('copy-link').onclick=()=>copy($('guardian-link').href);$('copy-config').onclick=()=>copy($('phone-config').value);
async function demoEvents(events){if(state.sensorMode!=='simulated')return;const at=serverTime();const packet=events.map(e=>{demoSeq[e.source]=Math.max(demoSeq[e.source],state.sources[e.source]?.maxSeq??0)+1;return{id:crypto.randomUUID(),seq:demoSeq[e.source],at,...e};});try{await api('events',{events:packet});await poll();}catch(e){notify(e.message);}}
$('demo-walk').onclick=()=>demoEvents(Array.from({length:12},(_,i)=>({source:'phone',type:'gps',latitude:43.6532+Math.min(i,6)*.00003,longitude:-79.3832+Math.max(0,i-6)*.00004,accuracy:8,provider:'simulated',provenance:'unknown',fixAt:serverTime()-Math.min(5000,serverTime()-state.createdAt)+i*100,mock:true})));
$('demo-watch').onclick=()=>demoEvents(Array.from({length:12},(_,i)=>({source:'watch',type:'pressure',hpa:i<6?1013.25:1012.89})));
// Camera is guardian-only, local, approximate and never controls recording or alerts.
function heading(e){const h=Number.isFinite(e.webkitCompassHeading)?e.webkitCompassHeading:e.absolute&&Number.isFinite(e.alpha)?(360-e.alpha)%360:null;if(h!==null){arHeading=h;arHeadingAt=Date.now();}}
function closeAr(){arRequest++;arStream?.getTracks().forEach(t=>t.stop());arStream=null;if(arWatch!==undefined)navigator.geolocation.clearWatch(arWatch);arWatch=undefined;window.removeEventListener('deviceorientation',heading);window.removeEventListener('deviceorientationabsolute',heading);$('ar-video').srcObject=null;$('ar-panel').hidden=true;arPosition=null;arHeading=null;}
function updateAr(){if(!arStream)return;const target=state?.geography?.latest,p=arPosition;let text='Use the map: waiting for a fresh outdoor location and absolute compass heading.';
  if(target&&p&&Date.now()-p.timestamp<10000&&serverTime()-target.fixAt<30000&&!target.mock&&target.accuracy<=20&&p.coords.accuracy<=20&&arHeading!==null&&Date.now()-arHeadingAt<3000){
    const rad=Math.PI/180,a=p.coords.latitude*rad,b=target.latitude*rad,d=(target.longitude-p.coords.longitude)*rad;
    const bearing=(Math.atan2(Math.sin(d)*Math.cos(b),Math.cos(a)*Math.sin(b)-Math.sin(a)*Math.cos(b)*Math.cos(d))/rad+360)%360;
    const distance=6371000*Math.acos(Math.min(1,Math.max(-1,Math.sin(a)*Math.sin(b)+Math.cos(a)*Math.cos(b)*Math.cos(d))));
    const turn=((bearing-arHeading+540)%360)-180;
    text=distance<=p.coords.accuracy+target.accuracy?'Within combined reported location uncertainty. Use the map; no precise direction is supported.':`Approximate outdoor cue: ${Math.abs(turn)<20?'ahead':turn>0?'turn right':'turn left'} · ${Math.round(distance)} m to last recorded point. Compass alignment is unvalidated; no floor or obstacle guidance.`;
  }$('ar-cue').textContent=text;
}
$('open-ar').onclick=async()=>{if(!guardian||!state?.shared||state.phase!=='alert')return;closeAr();$('ar-panel').hidden=false;
  try {if(!window.isSecureContext||!navigator.mediaDevices?.getUserMedia)throw new Error('Camera preview requires HTTPS on a supported phone. Use the map.');
    if(typeof DeviceOrientationEvent!=='undefined'&&typeof DeviceOrientationEvent.requestPermission==='function'&&await DeviceOrientationEvent.requestPermission()!=='granted')throw new Error('Compass permission denied. Use the map.');
    const stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:'environment'},audio:false});
    if(requestId!==arRequest||!state?.shared||state.phase!=='alert'||panel!=='map'){stream.getTracks().forEach(t=>t.stop());return;}
    arStream=stream;$('ar-video').srcObject=stream;
    arWatch=navigator.geolocation.watchPosition(p=>{arPosition=p;},()=>{$('ar-cue').textContent='Location unavailable. Use the map.';},{enableHighAccuracy:true,maximumAge:0,timeout:10000});
    window.addEventListener('deviceorientationabsolute',heading);window.addEventListener('deviceorientation',heading);
  }catch(e){closeAr();notify(e.message);}};
$('close-ar').onclick=closeAr;document.addEventListener('visibilitychange',()=>{if(document.hidden)closeAr();});window.addEventListener('pagehide',closeAr);
if(credentials)begin();else if(guardian){$('setup').hidden=true;notify('Open the private guardian link from the wearer.');}

function drawMotion() {
  const motion=state?.relativeMotion, sections=motion?.segments??[], section=sections.at(-1);
  $('relative-motion').hidden=!state?.shared||!motion?.available;
  $('motion-diagram').replaceChildren();
  if(!motion?.available)return;
  $('motion-status').textContent=`${motion.stale?'STALE · ':''}${sections.length} separate sections · latest section shown. Growing drift budget: ${motion.driftBudgetMeters.toFixed(1)} m (uncalibrated). Accuracy unverified.`;
  $('motion-activity').textContent=`Watch activity: ${section?.activity?.status??'unavailable'}. No independent position correction.${section?.supported===false?' Conflicting activity: diagram withheld.':''}`;
  const points=section?.supported===false?[]:section?.points??[];
  if(!points.length)return;
  const xs=points.map(p=>p.x),ys=points.map(p=>p.y),xmin=Math.min(...xs),xmax=Math.max(...xs),ymin=Math.min(...ys),ymax=Math.max(...ys);
  const scale=Math.min(296/Math.max(2,xmax-xmin),136/Math.max(2,ymax-ymin));
  const line=document.createElementNS('http://www.w3.org/2000/svg','path');
  let drawing=false;line.setAttribute('d',points.map(p=>{if(p.supported===false){drawing=false;return '';}const command=drawing?'L':'M';drawing=true;return `${command}${160+(p.x-(xmin+xmax)/2)*scale},${80-(p.y-(ymin+ymax)/2)*scale}`;}).join(' '));
  line.setAttribute('fill','none');line.setAttribute('stroke','#ad59c4');line.setAttribute('stroke-width','3');$('motion-diagram').append(line);
}
$('motion-consent').onchange=async()=>{try{await api('motion-consent',{enabled:$('motion-consent').checked,confirm:true});await poll();}catch(e){notify(e.message);await poll();}};

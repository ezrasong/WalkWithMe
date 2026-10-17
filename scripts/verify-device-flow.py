"""Companion host for the real-device Flutter integration test. Reports are redacted.
Start the Flutter test first; this process observes its live log and operates only
KAZE's watch controls. Alternatively, --normal-app observes a fresh disposable
session started in the ordinary app, without installing an integration target.
--long-run also performs a bounded network outage and a 610-second screen-off
interval, without synthetic sensor/location injection.
"""
from pathlib import Path
from contextlib import closing
import argparse, json, os, re, shutil, sqlite3, subprocess, time
import xml.etree.ElementTree as ET
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--phone', required=True)
parser.add_argument('--watch', required=True)
parser.add_argument('--log', default='artifacts/vivo-watch-device-flow.txt')
parser.add_argument('--long-run', action='store_true')
parser.add_argument('--normal-app', action='store_true', help='Use a fresh local disposable session started in the normal phone UI; always end it on exit.')
parser.add_argument('--managed-backend', action='store_true', help='Start the dedicated local backend before creating a normal-app session; close sockets for the outage.')
args = parser.parse_args()
if args.managed_backend and not args.normal_app:
    parser.error('--managed-backend requires --normal-app')
cached_adb = Path.home()/'.cache/kaze-android-sdk/platform-tools'/('adb.exe' if os.name=='nt' else 'adb')
ADB = str(cached_adb) if cached_adb.is_file() else shutil.which('adb')
if not ADB:
    parser.error('ADB is unavailable; install the Android SDK platform tools first.')
LOG = ROOT/args.log
REPORT = ROOT/'artifacts'/('device-long-run.json' if args.long_run else 'watch-checkin-shutdown.json')
report = {'startedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'longRun': args.long_run, 'passed': False}
report['normalApp'] = args.normal_app
normal_phone = None
backend = None
backend_log = None
captured = set()
vibration_baseline = {}
private = (ROOT/'artifacts/private-queue-snapshot').resolve()
assert private.is_relative_to((ROOT/'artifacts').resolve())

def adb(serial, *command, binary=False, optional=False):
    p = subprocess.run([ADB, '-s', serial, *command], capture_output=True, timeout=20)
    if p.returncode and not optional:
        raise RuntimeError('ADB operation failed: ' + ' '.join(command[:3]))
    return p.stdout if binary else p.stdout.decode(errors='replace')

def pause(seconds):
    end = time.monotonic()+seconds
    while time.monotonic()<end:
        time.sleep(min(2, max(0, end-time.monotonic())))

def log_text():
    return LOG.read_text(encoding='utf-8-sig', errors='replace') if LOG.exists() else ''

def wait_marker(marker, seconds=180):
    if args.normal_app:
        return
    until = time.monotonic()+seconds
    while time.monotonic()<until:
        text = log_text()
        for name in ('ui-map-light','ui-map-dark','ui-settings-dark'):
            if 'KAZE_CAPTURE_'+name in text and name not in captured:
                screenshot=adb(args.phone,'exec-out','run-as','app.kaze.trail','cat','files/'+name+'.png',binary=True,optional=True)
                if screenshot.startswith(b'\x89PNG'):
                    (ROOT/'artifacts'/(name+'.png')).write_bytes(screenshot)
                    captured.add(name)
        if 'Some tests failed' in text:
            raise RuntimeError('The Flutter device test failed; inspect its redacted log.')
        if marker in text:
            return
        pause(1)
    raise RuntimeError('Device test did not reach '+marker)

def prefs(serial):
    raw = adb(serial, 'shell', 'run-as', 'app.kaze.trail', 'cat', 'shared_prefs/kaze.xml', optional=True)
    if not raw.strip().startswith('<?xml'):
        return {}
    root = ET.fromstring(raw)
    return {n.attrib['name']: (n.attrib.get('value') if n.tag!='string' else n.text) for n in root}

def config(serial):
    return json.loads(prefs(serial).get('config') or '{}')

def end_normal_session():
    # Only the fresh, validated disposable localhost session selected below.
    if normal_phone is None:
        return
    state, _, _ = server_state(normal_phone['id'])
    if state['phase'] == 'resolved':
        return
    request = Request('http://127.0.0.1:4174/api/sessions/'+normal_phone['id']+'/resolve',
        data=b'{"confirm":true}', headers={'Content-Type':'application/json',
        'Authorization':'Bearer '+normal_phone['ownerToken']})
    with urlopen(request, timeout=10) as response:
        if json.load(response)['phase'] != 'resolved':
            raise RuntimeError('Disposable session end was not confirmed.')

def test_network(offline):
    if backend is None:
        adb(args.phone,'reverse',*(['--remove','tcp:4174'] if offline else ['tcp:4174','tcp:4174']))
        return
    command='offline' if offline else 'online'
    backend.stdin.write(command+'\n')
    backend.stdin.flush()
    if backend.stdout.readline().strip()!=command:
        raise RuntimeError('Test backend did not acknowledge network control.')

def tap_watch(text):
    adb(args.watch, 'shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
    adb(args.watch, 'shell', 'am', 'start', '-n', 'app.kaze.trail/app.kaze.watch.MainActivity')
    adb(args.watch, 'shell', 'uiautomator', 'dump', '/data/local/tmp/kaze-flow.xml')
    ui = ET.fromstring(adb(args.watch, 'shell', 'cat', '/data/local/tmp/kaze-flow.xml'))
    node = next((n for n in ui.iter('node') if n.attrib.get('package')=='app.kaze.trail' and n.attrib.get('text')==text and n.attrib.get('enabled')=='true'), None)
    if node is None:
        raise RuntimeError('Enabled KAZE watch control not visible: '+text)
    x1,y1,x2,y2 = map(int, re.findall(r'\d+', node.attrib['bounds']))
    adb(args.watch, 'shell', f'input keyevent KEYCODE_WAKEUP; sleep 1; input tap {(x1+x2)//2} {(y1+y2)//2}')

def server_state(session):
    path = ROOT/'data/device-test.sqlite'
    with closing(sqlite3.connect(f'file:{path.as_posix()}?mode=ro', uri=True)) as db:
        row = db.execute('SELECT body FROM sessions WHERE id=?', (session,)).fetchone()
        if not row:
            raise RuntimeError('Test session absent from the expected disposable backend.')
        s = json.loads(row[0])
        events = [json.loads(r[0]) for r in db.execute('SELECT body FROM events WHERE session_id=?', (session,))]
        activity = [dict(zip(('at','action','role'),r)) for r in db.execute('SELECT at,action,role FROM activity WHERE session_id=?', (session,))]
    return s, events, activity

def queue_ids(serial, label, session):
    directory = private/label
    directory.mkdir(parents=True, exist_ok=True)
    paths = [directory/('outbox.db'+suffix) for suffix in ('','-wal','-shm')]
    for path in paths:
        if path.exists(): path.unlink()
    try:
        for suffix in ('','-wal'):
            data = adb(serial, 'exec-out', 'run-as', 'app.kaze.trail', 'cat', 'databases/outbox.db'+suffix, binary=True, optional=bool(suffix))
            if data.startswith(b'SQLite format 3') or (suffix and len(data)>32 and not data.startswith(b'cat:')):
                (directory/('outbox.db'+suffix)).write_bytes(data)
        if not paths[0].exists(): raise RuntimeError('Native queue snapshot unavailable for '+label)
        with closing(sqlite3.connect(str(paths[0]))) as db:
            return {json.loads(row[0])['id'] for row in db.execute('SELECT payload FROM queue WHERE session=?',(session,))}
    finally:
        for path in paths:
            if path.exists(): path.unlink()

def power(serial):
    text = adb(serial, 'shell', 'dumpsys', 'power')
    match = re.search(r'mWakefulness=(\w+)',text)
    return match.group(1) if match else 'Unknown'

def sleep_devices():
    for serial in (args.phone,args.watch): adb(serial,'shell','input','keyevent','KEYCODE_SLEEP')

def wake_devices():
    for serial in (args.phone,args.watch): adb(serial,'shell','input','keyevent','KEYCODE_WAKEUP', optional=True)

def vibration_records(serial):
    raw=adb(serial,'shell','dumpsys','vibrator_manager',optional=True)
    return {line.strip() for line in raw.splitlines() if 'app.kaze.trail' in line}

def long_run(session):
    wait_marker('KAZE_SCREEN_OFF_READY')
    initial, _, _ = server_state(session)
    sleep_devices()
    start = time.monotonic()
    print('Screen-off test started; waiting 90 seconds before the bounded outage.', flush=True)
    pause(90)
    test_network(True)
    report['offlineStartedAfterScreenOffSeconds']=round(time.monotonic()-start,1)
    report['outageTransport']='closed backend sockets' if backend else 'removed USB forwarding'
    print('Device backend connections interrupted; measuring buffered readings.', flush=True)
    try:
        # Avoid racing the server's one-second escalation tick at exactly 150 s.
        pause(max(60, (initial['dueAt']+initial['graceSeconds']*1000+2000-time.time()*1000)/1000))
        queued={label:queue_ids(serial,label,session) for label,serial in (('phone',args.phone),('watch',args.watch))}
        s, events, _ = server_state(session)
        report['phaseWhileDisconnected']=s['phase']
        report['offlineQueueCounts']={key:len(ids) for key,ids in queued.items()}
        report['nativeOfflineStatus']={label:(prefs(serial).get('status') or '').startswith('Offline') for label,serial in (('phone',args.phone),('watch',args.watch))}
        if not all(report['nativeOfflineStatus'].values()): raise RuntimeError('Devices did not report an actual backend outage; forwarding removal may leave existing sockets alive.')
        if s['dueAt'] != initial['dueAt']:
            raise RuntimeError('An additional check-in reset the test deadline; repeat with devices untouched.')
        if s['phase']!='alert': raise RuntimeError('Independent deadline did not reach alert during the measured outage.')
        present={e['id'] for e in events}
        queued={key:ids-present for key,ids in queued.items()}
        report['offlineUnreceivedCounts']={key:len(ids) for key,ids in queued.items()}
        if not all(queued.values()): raise RuntimeError('No unreceived buffered readings on one device; cannot prove its physical offline retry.')
    finally:
        test_network(False)
    until=time.monotonic()+60
    while time.monotonic()<until:
        _, events, _=server_state(session)
        present={e['id'] for e in events}
        if all(ids<=present for ids in queued.values()): break
        pause(2)
    else: raise RuntimeError('A captured offline batch did not reach the PC after reconnection.')
    report['offlineBatchDeliveredOnce']=len({e['id'] for e in events})==len(events)
    if not report['offlineBatchDeliveredOnce']: raise RuntimeError('Duplicate event identity found after retry.')
    print('Captured offline readings delivered once; starting 610-second screen-off interval.', flush=True)
    for label,serial in (('phone',args.phone),('watch',args.watch)):
        fresh=vibration_records(serial)-vibration_baseline[label]
        records=[]
        for line in sorted(fresh):
            status=re.search(r'effect\s*\|\s*(\w+)',line)
            duration=re.search(r'duration:\s*(\d+)ms',line)
            usage=re.search(r'usage:\s*(\w+)',line)
            records.append({'status':status.group(1) if status else 'unknown',
                'durationMillis':int(duration.group(1)) if duration else None,
                'usage':usage.group(1) if usage else 'unknown'})
        report.setdefault('newSystemVibrations',{})[label]=records
    # Reminders can briefly wake a watch. Establish a fresh uninterrupted interval
    # after the challenge/alert window, rather than calling that wake screen-off.
    sleep_devices()
    start=time.monotonic()
    samples=[]
    report['powerSamples']=samples
    while time.monotonic()-start<610:
        sample={'elapsedSeconds':round(time.monotonic()-start,1),'phone':power(args.phone),'watch':power(args.watch)}
        samples.append(sample)
        print('Screen-off sample: '+json.dumps(sample), flush=True)
        if sample['phone'] not in ('Asleep','Dozing') or sample['watch'] not in ('Asleep','Dozing'):
            raise RuntimeError('A device became awake; the contiguous screen-off claim is not proven.')
        if any(prefs(serial).get('active')!='true' for serial in (args.phone,args.watch)):
            raise RuntimeError('Recording stopped during the screen-off interval.')
        pause(min(30,max(0,610-(time.monotonic()-start))))
    report['screenOffIntervalSeconds']=round(time.monotonic()-start,1)
    report['powerSamples']=samples
    _, events, _=server_state(session)
    cutoff=int(time.time()*1000)-600000
    report['screenOffEvidenceBySource']={source:sum(e['source']==source and e['at']>=cutoff for e in events) for source in ('phone','watch')}
    if not all(report['screenOffEvidenceBySource'].values()): raise RuntimeError('No recorded evidence from one source during the screen-off interval.')
    report['humanFeltVibration']=False
    wake_devices()

if not args.normal_app and ('All tests passed!' in log_text() or 'Some tests failed' in log_text()):
    raise SystemExit('Start a fresh Flutter integration run before starting this companion.')
try:
    if args.managed_backend:
        if prefs(args.phone).get('active')=='true':
            raise RuntimeError('End the current phone session before starting a managed test backend.')
        backend_log=open(ROOT/'artifacts/device-test-backend.txt','w',encoding='utf-8')
        backend=subprocess.Popen(['node',str(ROOT/'scripts/device-test-backend.mjs')],
            cwd=ROOT,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=backend_log,text=True,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        if backend.stdout.readline().strip()!='ready':
            raise RuntimeError('Dedicated backend could not start. Port 4174 must be free.')
        since=time.time()*1000
        print('Managed backend ready. Create a fresh consented session in the normal Vivo app now.',flush=True)
        until=time.monotonic()+180
        while time.monotonic()<until:
            current=config(args.phone)
            if current.get('id') and prefs(args.phone).get('active')=='true':
                state,_,_=server_state(current['id'])
                if state['createdAt']>=since:
                    normal_phone=current
                    break
            pause(1)
        else: raise RuntimeError('No fresh normal-app session was created within three minutes.')
    wait_marker('KAZE_WATCH_DISCOVERY_READY')
    for name in ('ui-map-light','ui-map-dark','ui-settings-dark'):
        screenshot=adb(args.phone,'exec-out','run-as','app.kaze.trail','cat','files/'+name+'.png',binary=True,optional=True)
        if screenshot.startswith(b'\x89PNG'):
            (ROOT/'artifacts'/(name+'.png')).write_bytes(screenshot)
    phone=config(args.phone)
    session=phone['id']
    if args.normal_app:
        state, _, _ = server_state(session)
        if (phone.get('baseUrl') != 'http://127.0.0.1:4174'
                or not phone.get('ownerToken') or prefs(args.phone).get('active') != 'true'
                or state.get('simulation') is not True or state.get('sensorMode') != 'device'
                or state['phase'] != 'armed' or not 0 <= time.time()*1000-state['createdAt'] <= 180000):
            raise RuntimeError('Normal-app mode requires a fresh active disposable localhost device session.')
        normal_phone = phone
    until=time.monotonic()+40
    adb(args.watch,'shell','input','keyevent','KEYCODE_WAKEUP')
    adb(args.watch,'shell','am','start','-n','app.kaze.trail/app.kaze.watch.MainActivity')
    while time.monotonic()<until:
        watch=config(args.watch)
        if watch.get('id')==session:
            if 'ownerToken' in watch or 'guardianToken' in watch: raise RuntimeError('A non-watch credential reached the watch.')
            break
        pause(1)
    else: raise RuntimeError('Watch did not discover the current phone session.')
    report['automaticScopedDiscovery']=True
    # Opening KAZE joins the phone session automatically; no Start/enable tap.
    until=time.monotonic()+40
    while time.monotonic()<until:
        if prefs(args.watch).get('active')=='true': break
        # Wireless ADB round trips can outlast a watch's short display timeout.
        # Keep the actual foreground flow visible, without tapping activation.
        adb(args.watch,'shell','input','keyevent','KEYCODE_WAKEUP')
        adb(args.watch,'shell','am','start','-n','app.kaze.trail/app.kaze.watch.MainActivity')
        pause(1)
    else: raise RuntimeError('Watch did not automatically join the phone session.')
    report['noWatchActivationTap']=True
    wait_marker('KAZE_WATCH_CHECKIN_READY')
    if args.normal_app:
        until=time.monotonic()+40
        while time.monotonic()<until:
            _, events, _=server_state(session)
            if all(any(e['source']==source for e in events) for source in ('phone','watch')): break
            pause(1)
        else: raise RuntimeError('Both devices did not upload real evidence.')
    _,_,activity=server_state(session)
    previous_responses=sum(a['action']=='check-in' and a['role']=='watch' for a in activity)
    vibration_baseline={label:vibration_records(serial) for label,serial in (('phone',args.phone),('watch',args.watch))}
    tap_watch('Check in')
    wait_marker('KAZE_WATCH_CHECKIN_CONFIRMED',seconds=50)
    until=time.monotonic()+30
    while time.monotonic()<until:
        _,_,activity=server_state(session)
        if sum(a['action']=='check-in' and a['role']=='watch' for a in activity)>previous_responses: break
        pause(1)
    report['watchCheckInServerAccepted']=sum(a['action']=='check-in' and a['role']=='watch' for a in activity)>previous_responses
    if not report['watchCheckInServerAccepted']: raise RuntimeError('No authoritative watch response in Activity.')
    screenshot=adb(args.watch,'exec-out','screencap','-p',binary=True,optional=True)
    if screenshot.startswith(b'\x89PNG'):
        (ROOT/'artifacts/watch-interface.png').write_bytes(screenshot)
    print('Automatic discovery, real relay uploads and explicit watch check-in confirmed.',flush=True)
    if args.long_run:
        try:
            long_run(session)
            result={'passed':True}
        except Exception as e:
            result={'passed':False,'error':str(e)}
            raise
        finally:
            wake_devices()
            adb(args.phone,'reverse','tcp:4174','tcp:4174')
            if not args.normal_app:
                # Fixed test-only app-private path; no credential is written to a report.
                payload=json.dumps(result,separators=(',',':'))
                # ADB stdin keeps JSON out of shell interpolation and logs.
                adb(args.phone,'shell','run-as','app.kaze.trail','mkdir','-p','files')
                p=subprocess.run([ADB,'-s',args.phone,'shell','run-as','app.kaze.trail','tee','files/kaze-device-long-run.json'],input=payload.encode(),capture_output=True,timeout=15)
                if p.returncode: raise RuntimeError('Could not deliver the hardware result to the live device test.')
    if args.normal_app:
        end_normal_session()
    wait_marker('KAZE_SESSION_END_CONFIRMED',seconds=120)
    until=time.monotonic()+18
    while time.monotonic()<until:
        p=prefs(args.watch)
        if p.get('active')=='false' and p.get('phase')=='resolved': break
        pause(1)
    else: raise RuntimeError('Watch did not observe end through the phone relay before runner cleanup.')
    report['watchEndConfirmedThroughRelay']=True
    report['queuedReadingsAfterWatchEnd']=len(queue_ids(args.watch,'watch',session))
    if report['queuedReadingsAfterWatchEnd']: raise RuntimeError('Watch retained queued evidence after confirmed end.')
    if args.normal_app:
        until=time.monotonic()+15
        while time.monotonic()<until and prefs(args.phone).get('active')!='false': pause(1)
        if prefs(args.phone).get('active')!='false': raise RuntimeError('Phone recording did not stop after authoritative end.')
        report['queuedReadingsAfterPhoneEnd']=len(queue_ids(args.phone,'phone',session))
        if report['queuedReadingsAfterPhoneEnd']: raise RuntimeError('Phone retained queued evidence after confirmed end.')
    report['passed']=True
    print('Watch observed end through the phone relay; its queue is empty.',flush=True)
except Exception as e:
    report['error']=str(e)
    print('Device verification failed: '+str(e),flush=True)
finally:
    if args.normal_app and normal_phone is not None:
        try:
            adb(args.phone,'reverse','tcp:4174','tcp:4174')
            end_normal_session()
            wake_devices()
        except Exception:
            report['passed']=False
            report['cleanupError']='Could not confirm disposable session cleanup; inspect devices before continuing.'
    if backend is not None:
        try:
            if normal_phone is not None:
                until=time.monotonic()+20
                while time.monotonic()<until and any(prefs(serial).get('active')=='true' for serial in (args.phone,args.watch)): pause(1)
            if backend.poll() is None:
                backend.stdin.write('stop\n'); backend.stdin.flush()
            backend.wait(timeout=10)
        except Exception:
            report['passed']=False
            report['backendCleanupError']='Managed backend did not shut down cleanly.'
            backend.kill()
        finally:
            backend.stdin.close(); backend.stdout.close()
    if backend_log is not None: backend_log.close()
    report['finishedAt']=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())
    REPORT.parent.mkdir(parents=True,exist_ok=True)
    REPORT.write_text(json.dumps(report,indent=2),encoding='utf-8')
    print('Redacted report: '+str(REPORT),flush=True)
if not report['passed']: raise SystemExit(1)

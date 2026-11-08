#!/usr/bin/env python3
"""Silent native-frame smoke test in a disposable Chrome for Testing profile.

Requires browser-harness, Node, ffmpeg, and a separate testing browser.
Never attaches to personal Chrome or contacts the running DALI app.
"""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from urllib.parse import urlsplit, parse_qs


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--chrome', required=True, help='Chrome for Testing executable')
    parser.add_argument('--output', required=True)
    parser.add_argument('--real-extension', action='store_true', help='Load the actual MV3 extension and use an isolated fake app')
    parser.add_argument('--loop-probe', action='store_true', help='Verify continuous delay across native short-video loops')
    args = parser.parse_args()
    if args.real_extension and args.loop_probe:
        parser.error('Run the MV3 integration and short-loop checks separately')
    chrome = Path(args.chrome).resolve()
    if 'Google Chrome for Testing.app' not in str(chrome):
        parser.error('Use a separate Google Chrome for Testing executable')
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    harness = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix='dali-native-check-') as directory:
        root = Path(directory)
        for name in ['index.html', 'shim.js', 'beacon.js']:
            shutil.copy2(harness / name, root / name)
        shutil.copy2(harness.parent.parent / 'content.js', root / 'content.js')
        duration = 3 if args.loop_probe else 30
        (root / 'video.mjs').write_text((harness / 'gen-testvideo.mjs').read_text().replace('SECS = 180', 'SECS = ' + str(duration)))
        with (root / 'video.raw').open('wb') as raw:
            subprocess.run(['node', str(root / 'video.mjs')], stdout=raw, check=True)
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'rawvideo',
                        '-pix_fmt', 'rgb24', '-s', '640x360', '-r', '30', '-i',
                        str(root / 'video.raw'), '-c:v', 'libx264', '-crf', '12',
                        '-pix_fmt', 'yuv420p', str(root / 'test_a.mp4')], check=True)
        (root / 'video.raw').unlink()

        beacon = {'app': 'DALI', 'protocolVersion': 1, 'streaming': True, 'delayMs': 700}
        signals = []

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *unused):
                pass

            def do_GET(self):
                route = urlsplit(self.path)
                if args.real_extension and (route.path.startswith('/beacon/') or route.path in ['/control', '/signals']):
                    if route.path == '/control':
                        query = parse_qs(route.query)
                        if 'streaming' in query:
                            beacon['streaming'] = query['streaming'][0] == '1'
                        if 'delayMs' in query:
                            beacon['delayMs'] = int(query['delayMs'][0])
                    elif route.path.startswith('/beacon/') and route.path != '/beacon/':
                        signals.append(route.path.rsplit('/', 1)[-1])
                    data = json.dumps(signals if route.path == '/signals' else beacon).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Cache-Control', 'no-store')
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                super().do_GET()

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(root)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        extension_args = []
        if args.real_extension:
            extension = root / 'extension'
            extension.mkdir()
            source = harness.parent.parent
            manifest = json.loads((source / 'manifest.json').read_text())
            for name in ['manifest.json', 'background.js', 'content.js', 'beacon.js', *manifest['icons'].values()]:
                dest = extension / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source / name, dest)
            client = extension / 'beacon.js'
            endpoint = 'http://127.0.0.1:3697/'
            content = client.read_text()
            assert content.count(endpoint) == 1
            client.write_text(content.replace(endpoint, 'http://127.0.0.1:' + str(server.server_port) + '/beacon/'))
            fixture = root / 'index.html'
            html = fixture.read_text()
            for name in ['shim.js', 'beacon.js', 'content.js']:
                html = html.replace('<script src="' + name + '"></script>', '')
            fixture.write_text(html)
            # Use Chrome's supported DevTools test-install API. The driver
            # configures developer mode through the disposable profile's API
            # so reload follows normal unpacked-install policy as well. Only
            # this throwaway browser receives the debugging flag.
            extension_args = ['--enable-unsafe-extension-debugging']
        with (root / 'chrome.log').open('w') as log:
            browser = subprocess.Popen([str(chrome), '--headless=new', '--remote-debugging-port=0',
                '--user-data-dir=' + str(root / 'profile'), '--no-first-run', '--no-default-browser-check',
                '--mute-audio', '--autoplay-policy=no-user-gesture-required', *extension_args, 'about:blank'], stdout=log, stderr=log)
            env = dict(os.environ, BU_NAME='dali-native-' + uuid.uuid4().hex[:12])
            try:
                port_file = root / 'profile' / 'DevToolsActivePort'
                deadline = time.monotonic() + 20
                while not port_file.exists():
                    if time.monotonic() > deadline:
                        raise RuntimeError('Testing browser did not start')
                    time.sleep(.1)
                env['BU_CDP_URL'] = 'http://127.0.0.1:' + port_file.read_text().splitlines()[0]
                # Every assertion below runs the real content script, native
                # frame callbacks, and native bitmap capture. Only Chrome APIs
                # and the beacon are stubbed, avoiding personal audio changes.
                code = '''
import json,time
def read(expression): return js(expression)
def until(expression, timeout=8):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if read(expression): return
        time.sleep(.1)
    raise AssertionError(expression)
target=new_tab(URL)
activate_tab(current_tab()['targetId'])
until("!!window.__daliSync && $v().readyState>=2")
read("window.__errors=[];addEventListener('error',e=>__errors.push(e.message));addEventListener('unhandledrejection',e=>__errors.push(String(e.reason)));$v().muted=true;$v().loop=true;$v().play();true")
results={}
for delay in [300,700,2000]:
    read("__setBeacon({running:true,streaming:true,delayMs:"+str(delay)+"});true")
    until("presenting() && Math.abs(__daliSync.effDelayMs()-"+str(delay)+")<1")
    time.sleep(.5)
    read("window.__samples=[];window.__sampler=setInterval(()=>__samples.push(sample()),40);true")
    time.sleep(2)
    samples=read("clearInterval(__sampler);__samples")
    valid=[s['delayMs'] for s in samples if s and 'delayMs' in s]
    assert len(valid)>=30 and len(valid)==len(samples),samples
    valid.sort()
    median=valid[len(valid)//2]
    assert abs(median-delay)<=100, (delay,median)
    assert max(abs(v-delay) for v in valid)<=150,(delay,min(valid),max(valid))
    results[str(delay)]={'samples':len(valid),'medianMs':median,'minMs':min(valid),'maxMs':max(valid)}
read("$v().pause();true")
until("pageRestored() && (!$c() || $c().style.display==='none')",2)
results['pauseRestoresVideo']=True
read("$v().currentTime=10;$v().play();true")
until("presenting()")
time.sleep(2.3)
assert abs(read("sample().delayMs")-2000)<=150
results['seekRecovers']=True
read("__setBeacon({running:false,streaming:false,delayMs:0});true")
until("pageRestored()",5)
results['appStopRestoresVideo']=True
read("__setBeacon({running:true,streaming:true,delayMs:700});true")
until("presenting()")
read("dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}));true")
until("pageRestored()",2)
read("dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));true")
until("presenting()")
results['pageCacheRecovers']=True
read("(()=>{const old=$v();old.pause();const next=old.cloneNode();next.id='v';next.muted=true;next.loop=true;old.replaceWith(next);next.play();return true})()")
until("presenting() && __daliSync.S.pipeline.video===$v()")
time.sleep(1.3)
assert abs(read("sample().delayMs")-700)<=150
results['replacedVideoRecovers']=True
read("__daliSync.teardownAll('native check');true")
until("pageRestored() && document.querySelectorAll('canvas.dali-sync-overlay').length===0")
assert not read('window.__errors'),read('window.__errors')
results['teardownClean']=True
print('DALI_NATIVE_RESULT='+json.dumps(results))
'''.replace('URL', repr('http://127.0.0.1:' + str(server.server_port) + '/index.html?real=1'))
                if args.real_extension:
                    code = (harness / 'mv3-driver.py').read_text().replace('FIXTURE_URL', repr('http://127.0.0.1:' + str(server.server_port) + '/index.html?real=1'))
                    code = code.replace('EXTENSION_PATH', repr(str(extension)))
                elif args.loop_probe:
                    code = (harness / 'loop-driver.py').read_text().replace('FIXTURE_URL', repr('http://127.0.0.1:' + str(server.server_port) + '/index.html?real=1'))
                result = subprocess.run(['browser-harness'], input=code, text=True, capture_output=True, env=env, timeout=90)
                if result.returncode:
                    raise RuntimeError(result.stdout + result.stderr)
                line = next(line for line in result.stdout.splitlines() if line.startswith('DALI_NATIVE_RESULT='))
                data = json.loads(line.split('=', 1)[1])
                output.write_text(json.dumps(data, indent=2) + '\n')
                print(json.dumps(data, indent=2))
            finally:
                # End only the disposable harness daemon and browser we own.
                pid_file = Path.home() / '.config/browser-harness/runtime' / ('bu-' + env['BU_NAME'] + '.pid')
                if pid_file.exists():
                    try:
                        os.kill(int(pid_file.read_text()), 15)
                    except (ValueError, ProcessLookupError):
                        pass
                browser.terminate()
                try:
                    browser.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    browser.kill()
                    browser.wait(timeout=5)
                server.shutdown()


if __name__ == '__main__':
    main()

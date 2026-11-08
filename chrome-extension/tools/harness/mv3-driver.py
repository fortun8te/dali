# Executed by native-check.py inside browser-harness's helper namespace.
# The browser and fake app belong only to that disposable test.
import json
import time
import urllib.request

url = FIXTURE_URL
base = url.split('/index.html')[0]
worker_id = None
worker_sid = None


def until(fn, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if fn():
            return
        time.sleep(.1)
    raise AssertionError(json.dumps({'message': 'Native extension condition timed out',
        'state': snapshot(), 'targets': cdp('Target.getTargets')['targetInfos']}))


def worker(expression):
    global worker_id, worker_sid
    targets = [t for t in cdp('Target.getTargets')['targetInfos']
               if t.get('type') == 'service_worker' and t.get('url', '').endswith('/background.js')]
    if not targets:
        return None
    if worker_id not in [t['targetId'] for t in targets]:
        worker_id = None
        for target in targets:
            sid = cdp('Target.attachToTarget', targetId=target['targetId'], flatten=True)['sessionId']
            info = cdp('Runtime.evaluate', session_id=sid,
                       expression='chrome.runtime.getManifest().name', returnByValue=True)
            if info.get('result', {}).get('value') == 'DALI Video Sync':
                worker_id = target['targetId']
                worker_sid = sid
                cdp('Runtime.enable', session_id=worker_sid)
                break
            cdp('Target.detachFromTarget', sessionId=sid)
        if worker_id is None:
            return None
    try:
        result = cdp('Runtime.evaluate', session_id=worker_sid, expression=expression,
                     returnByValue=True, awaitPromise=True)
    except (RuntimeError, TimeoutError) as error:
        # Reload invalidates the old debugger session before discovery always
        # stops listing its target. Reattach on the next observed worker.
        if 'timed out' not in str(error) and 'closed' not in str(error):
            raise
        worker_id = None
        worker_sid = None
        return None
    assert not result.get('exceptionDetails'), result
    return result.get('result', {}).get('value')


def snapshot():
    return worker('''(async()=>{
      const tabs=await chrome.tabs.query({});
      const tab=tabs.find(t=>t.url&&t.url.includes('/index.html?real=1'));
      if(!tab)return null;
      const results=await chrome.scripting.executeScript({target:{tabId:tab.id},func:()=>{
        const api=window.__daliSync,p=api?.S.pipeline;
        return {version:api?.version,build:api?.build,reason:api?.S.reason,
          armed:!!p?.armed,eff:api?.effDelayMs(),captures:p?.captureCount,
          errors:p?.captureErrors,restored:!document.getElementById('v').hasAttribute('data-dali-sync-hidden')};
      }});
      return results[0].result;
    })()''')


def presenting():
    state = snapshot()
    return state and state['armed'] and state['captures'] > 5


def control(query):
    with urllib.request.urlopen(base + '/control?' + query, timeout=2) as reply:
        return json.load(reply)


# Match a normal unpacked installation in the disposable profile. Chrome 153
# drops its CDP-install exemption during runtime.reload, so use its actual
# profile API as well, rather than hand-writing a protected preference.
setup = new_tab('chrome://extensions/')
activate_tab(setup)
until(lambda: js("document.readyState==='complete' && !!chrome.developerPrivate"))
js("chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode:true});true")
until(lambda: js("chrome.developerPrivate.getProfileConfiguration().then(c=>c.inDeveloperMode)"))
# Install through Chrome's supported disposable-testing API.
browser_sid = cdp('Target.attachToBrowserTarget')['sessionId']
installed = cdp('Extensions.loadUnpacked', session_id=browser_sid, path=EXTENSION_PATH)
assert installed.get('id'), installed
target = new_tab(url)
activate_tab(target)
until(lambda: js("document.getElementById('v')?.readyState>=2"))
js("$v().muted=false;$v().loop=true;$v().play();true")
until(presenting)
state = snapshot()
results = {'mode': 'real-mv3-extension', 'version': state['version'], 'build': state['build']}

for delay in [300, 700, 2000]:
    control('streaming=1&delayMs=' + str(delay))
    until(lambda: abs((snapshot() or {}).get('eff', -10000) - delay) < 1)
    time.sleep(.5)
    js("window.__samples=[];window.__sampler=setInterval(()=>__samples.push(sample()),40);true")
    time.sleep(2)
    samples = js('clearInterval(__sampler);__samples')
    values = sorted(s['delayMs'] for s in samples if s and 'delayMs' in s)
    assert len(values) == len(samples) and len(values) >= 30, samples
    assert abs(values[len(values)//2] - delay) <= 100, values
    results[str(delay)] = {'samples': len(values), 'medianMs': values[len(values)//2],
                          'minMs': min(values), 'maxMs': max(values)}

js('$v().pause();true')
until(lambda: js('pageRestored()'), 2)
with urllib.request.urlopen(base + '/signals', timeout=2) as reply:
    signals = json.load(reply)
until(lambda: 'cut' in json.load(urllib.request.urlopen(base + '/signals', timeout=2)), 2)
js('$v().play();true')
until(presenting)
until(lambda: json.load(urllib.request.urlopen(base + '/signals', timeout=2))[-1] in ['resume', 'now'])
results['actualPauseResumeTransport'] = True

# Exercise the actual extension reload/disconnect/reinjection path. The page
# and its media remain in place, just as during the personal update.
worker("globalThis.__daliWorkerBeforeReload=true;true")
worker('setTimeout(()=>chrome.runtime.reload(),250);true')
cdp('Target.detachFromTarget', sessionId=worker_sid)
worker_id = None
worker_sid = None
time.sleep(.6)
until(lambda: worker('typeof globalThis.__daliWorkerBeforeReload === "undefined"'), 20)
until(presenting)
assert snapshot()['errors'] == 0
results['actualExtensionReloadRecovers'] = True

control('streaming=0')
until(lambda: js('pageRestored()'), 5)
control('streaming=1&delayMs=700')
until(presenting)
results['actualAppRestartRecovers'] = True

js("(()=>{const old=$v();old.pause();const next=old.cloneNode();next.id='v';next.muted=false;next.loop=true;old.replaceWith(next);next.play();return true})()")
until(presenting)
results['actualReplacementRecovers'] = True

control('streaming=0')
until(lambda: js('pageRestored()'), 5)
final = snapshot()
assert final['version'] == results['version']
assert final.get('errors', 0) == 0
errors = [event for event in drain_events() if event.get('method') == 'Runtime.exceptionThrown']
assert not errors, errors
results['runtimeExceptions'] = len(errors)
print('DALI_NATIVE_RESULT=' + json.dumps(results))

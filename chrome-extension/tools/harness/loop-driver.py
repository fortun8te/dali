# Executed by native-check.py inside its disposable browser-harness session.
import json
import time


def until(expression, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if js(expression):
            return
        time.sleep(.1)
    raise AssertionError(expression)


target = new_tab(FIXTURE_URL)
activate_tab(target)
until("!!window.__daliSync && $v().readyState>=2")
js("__setBeacon({running:true,streaming:true,delayMs:700});$v().muted=true;$v().loop=true;$v().play();true")
until("presenting() && Math.abs(__daliSync.effDelayMs()-700)<1")
js('''window.__loopEvents=[];
  for(const type of ['seeking','seeked'])$v().addEventListener(type,()=>{
    const p=__daliSync.S.pipeline;
    __loopEvents.push({type,media:$v().currentTime,armed:p?.armed,
      gen:p?.gen,delay:__daliSync.effDelayMs(),buffer:p?.buffer.length});
  });
  window.__loopSamples=[];
  window.__loopTimer=setInterval(()=>{const p=__daliSync.S.pipeline;
    __loopSamples.push({armed:p?.armed,gen:p?.gen,delay:__daliSync.effDelayMs()});},25);
  true''')
time.sleep(7)
result = js('clearInterval(__loopTimer);({duration:$v().duration,events:__loopEvents,samples:__loopSamples})')
seeks = [event for event in result['events'] if event['type'] == 'seeking']
assert len(seeks) >= 2, result
assert all(event['armed'] and event['buffer'] > 0 and abs(event['delay'] - 700) < 1 for event in seeks), seeks
generations = set(sample['gen'] for sample in result['samples'])
assert len(generations) == 1, generations
assert all(sample['armed'] and abs(sample['delay'] - 700) < 1 for sample in result['samples']), result
print('DALI_NATIVE_RESULT=' + json.dumps({'nativeLoops': len(seeks),
    'durationSeconds': result['duration'], 'samples': len(result['samples']),
    'generationCount': len(generations), 'delayMs': 700, 'events': result['events']}))

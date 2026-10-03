#!/usr/bin/env node
// Compile the production C functions with deterministic clocks and socket/event
// substitutes. No engine process, network traffic, or installed files are used.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const only = process.argv.find(value => value.startsWith('--only='))?.slice(7) ?? 'all';
assert.ok(new Set(['all','volume','backpressure','timeout','socket','progress','pts','timing','ownership']).has(only), `Unknown test group: ${only}`);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const sourceRoot = process.env.DALI_ENGINE_TEST_SOURCE ?? join(root, 'third_party/owntone');
const source = path => readFileSync(join(sourceRoot, 'src', path), 'utf8');
const airplay = source('outputs/airplay.c');
const raop = source('outputs/raop.c');
const player = source('player.c');

function functionBody(text, name) {
  const signature = new RegExp(`(?:^|\\n)(?:static(?: inline)?\\s+)?(?:void|int|float|bool|uint64_t)\\s*\\n${name}\\([^;]*?\\)\\s*\\n\\{`, 'g');
  const match = signature.exec(text);
  assert.ok(match, `Production function ${name} is missing`);
  const start = match.index;
  let depth = 1, cursor = signature.lastIndex;
  // Count C braces after masking strings and comments, leaving positions intact.
  const masked = text.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g, value => value.replace(/[^\n]/g, ' '));
  for (; cursor < text.length && depth; cursor++) {
    if (masked[cursor] === '{') depth++;
    if (masked[cursor] === '}') depth--;
  }
  assert.equal(depth, 0, `Unbalanced production function ${name}`);
  return text.slice(start, cursor);
}
function definition(text, name) {
  const value = text.match(new RegExp(`^#define ${name}\\s+([^\\n]+)`, 'm'));
  assert.ok(value, `Production constant ${name} is missing`);
  return `#define ${name} ${value[1]}`;
}

const common = [
  ...['AIRPLAY_CONFIG_MAX_VOLUME', 'AIRPLAY_STREAM_CONTROL_TIMEOUT_SEC'].map(name => definition(airplay, name)),
  definition(raop, 'RAOP_CONFIG_MAX_VOLUME'),
  '#define AIRPLAY_VOLUME_PROCEED_NON_OK ' + airplay.match(/\{ AIRPLAY_SEQ_SEND_VOLUME, "SET_PARAMETER \(volume\)"[^\n]*, (true|false) \}/)[1],
  functionBody(source('httpd_jsonapi.c'), 'jsonapi_reply_player_volume'),
  functionBody(source('outputs.c'), 'outputs_device_volume_set'),
  ...['airplay_volume_from_pct', 'airplay_volume_to_pct', 'volume_command_failure', 'deferred_session_failure_cb', 'deferred_session_failure', 'deferred_volume_failure', 'data_socket_prepare', 'packet_send', 'sequence_continue_cb', 'sequence_continue'].map(name => functionBody(airplay, name)),
  ...['raop_volume_from_pct', 'raop_volume_to_pct'].map(name => functionBody(raop, name)),
  ...['session_update_read', 'session_update_read_ts', 'device_volume_cb'].map(name => functionBody(player, name)),
].join('\n');

// Exercise the real callback's timing section in both platform branches. The
// omitted remainder handles source/encoder/output APIs, not tick accounting.
const playback = functionBody(player, 'playback_cb');
const timingEnd = playback.indexOf('// One compact timing-health line');
assert.ok(timingEnd > 0, 'Timing extraction boundary is missing');
const timing = playback.slice(0, timingEnd).replace('playback_cb(', 'playback_timing_test(')
  + '\n  test_skip_tick = skip_tick; test_overrun = overrun;\n}\n';

const fixture = readFileSync(join(root, 'scripts/tests/engine/regressions.c'), 'utf8')
  .replace('/* PRODUCTION_FUNCTIONS */', common)
  .replace('/* PRODUCTION_TIMING */', timing);
const directory = mkdtempSync(join(tmpdir(), 'dali-engine-c-'));
try {
  const file = join(directory, 'regressions.c');
  writeFileSync(file, fixture);
  for (const mode of only === 'ownership' ? [] : ['wallclock', 'timerfd']) {
    const binary = join(directory, mode);
    const compile = spawnSync(process.env.CC ?? 'cc', ['-std=c11', '-D_DEFAULT_SOURCE', '-D_POSIX_C_SOURCE=200809L', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-unused-variable', '-Wno-unused-function', '-Wno-sign-compare', '-fsanitize=address,undefined', ...(mode === 'timerfd' ? ['-DHAVE_TIMERFD'] : []), file, '-o', binary, '-lm'], { encoding: 'utf8' });
    assert.equal(compile.status, 0, `C ${mode} compile failed:\n${compile.stdout}${compile.stderr}`);
    const run = spawnSync(binary, [only], { encoding: 'utf8', timeout: 10000, env: { ...process.env, ASAN_OPTIONS: process.platform === 'darwin' ? 'detect_leaks=0' : 'detect_leaks=1' } });
    assert.equal(run.status, 0, `C ${mode} regressions failed:\n${run.stdout}${run.stderr}`);
    process.stdout.write(`${mode}: ${run.stdout}`);
  }
  if (only === 'all' || only === 'ownership') {
    const ownerFunctions = [
      functionBody(source('evrtsp/rtsp.c'), 'evrtsp_make_request'),
      functionBody(source('worker.c'), 'worker_try_execute'),
      ...['request_finished', 'requests_drain', 'request_async_cb', 'request_dispatch', 'request_cb'].map(name => functionBody(source('httpd.c'), name)),
    ].join('\n');
    const ownerFile = join(directory, 'ownership.c');
    writeFileSync(ownerFile, readFileSync(join(root, 'scripts/tests/engine/ownership.c'), 'utf8').replace('/* PRODUCTION_FUNCTIONS */', ownerFunctions));
    const binary = join(directory, 'ownership');
    const compile = spawnSync(process.env.CC ?? 'cc', ['-std=c11', '-D_DEFAULT_SOURCE', '-D_POSIX_C_SOURCE=200809L', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-unused-function', '-Wno-sign-compare', '-fsanitize=address,undefined', ownerFile, '-o', binary, '-pthread'], {encoding:'utf8'});
    assert.equal(compile.status, 0, `C ownership compile failed:\n${compile.stdout}${compile.stderr}`);
    const run = spawnSync(binary, [], {encoding:'utf8',timeout:10000,env:{...process.env,ASAN_OPTIONS:process.platform==='darwin'?'detect_leaks=0':'detect_leaks=1'}});
    assert.equal(run.status,0,`C ownership regressions failed:\n${run.stdout}${run.stderr}`);
    process.stdout.write(`ownership: ${run.stdout}`);
  }
} finally {
  rmSync(directory, { recursive: true, force: true });
}

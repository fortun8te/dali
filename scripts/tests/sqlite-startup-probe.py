#!/usr/bin/env python3
"""Compare bundled SQLite libraries using private synthetic OwnTone schemas.

Never opens a real library database or starts OwnTone, networking, or audio.
The controlled transaction hold stands in for filesystem work; its duration
is an input, not evidence that either SQLite version causes a slow scan.
"""
import argparse
import ast
import ctypes as C
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def probe(prefix):
    prefix = Path(prefix).resolve()
    library = prefix / 'lib/libsqlite3.dylib'
    extension = prefix / 'lib/owntone-sqlext.so'
    sql = C.CDLL(str(library))
    pointer = C.c_void_p
    callback_type = C.CFUNCTYPE(None, C.POINTER(pointer), C.c_int)
    sql.sqlite3_libversion.restype = C.c_char_p
    sql.sqlite3_sourceid.restype = C.c_char_p
    sql.sqlite3_errmsg.argtypes = [pointer]
    sql.sqlite3_errmsg.restype = C.c_char_p
    sql.sqlite3_open.argtypes = [C.c_char_p, C.POINTER(pointer)]
    sql.sqlite3_close.argtypes = [pointer]
    sql.sqlite3_exec.argtypes = [pointer, C.c_char_p, pointer, pointer, C.POINTER(C.c_char_p)]
    sql.sqlite3_free.argtypes = [pointer]
    sql.sqlite3_enable_load_extension.argtypes = [pointer, C.c_int]
    sql.sqlite3_load_extension.argtypes = [pointer, C.c_char_p, C.c_char_p, C.POINTER(C.c_char_p)]
    sql.sqlite3_prepare_v2.argtypes = [pointer, C.c_char_p, C.c_int, C.POINTER(pointer), pointer]
    sql.sqlite3_step.argtypes = [pointer]
    sql.sqlite3_finalize.argtypes = [pointer]
    sql.sqlite3_unlock_notify.argtypes = [pointer, callback_type, pointer]
    assert sql.sqlite3_config(2) == 0  # SQLITE_CONFIG_MULTITHREAD, db_init().
    assert sql.sqlite3_enable_shared_cache(1) == 0
    assert sql.sqlite3_initialize() == 0

    source = (ROOT / 'third_party/owntone/src/db_init.c').read_text()
    statements = []
    for match in re.finditer(r'^#define\s+((?:[TI]_|TRG_)\w+)\s+((?:[^\n]*\\\n)*[^\n]*)', source, re.M):
        statement = ''.join(ast.literal_eval(part) for part in re.findall(r'"(?:\\.|[^"\\])*"', match[2]))
        statements.append((match[1], statement))
    db_source = (ROOT / 'third_party/owntone/src/db.c').read_text()
    # Actual db_statements_prepare_ping("files") and db_speaker_get() queries.
    ping = 'UPDATE files SET db_timestamp = ?, disabled = 0 WHERE path = ? AND db_timestamp > ?;'
    assert 'UPDATE %s SET db_timestamp = ?, disabled = 0 WHERE path = ? AND db_timestamp > ?;' in db_source
    speaker = 'SELECT s.selected, s.volume, s.name, s.auth_key, s.format, s.offset_ms FROM speakers s WHERE s.id = 1;'
    assert speaker.split('1;')[0] in db_source

    def checked(code, connection):
        if code != 0:
            raise RuntimeError(f'SQLite {code}: {sql.sqlite3_errmsg(connection).decode()}')

    def execute(connection, statement):
        error = C.c_char_p()
        result = sql.sqlite3_exec(connection, statement.encode(), None, None, C.byref(error))
        if error:
            sql.sqlite3_free(C.cast(error, pointer))
        checked(result, connection)

    def open_db(path):
        connection = pointer()
        checked(sql.sqlite3_open(str(path).encode(), C.byref(connection)), connection)
        checked(sql.sqlite3_enable_load_extension(connection, 1), connection)
        error = C.c_char_p()
        result = sql.sqlite3_load_extension(connection, str(extension).encode(), None, C.byref(error))
        if error:
            sql.sqlite3_free(C.cast(error, pointer))
        checked(result, connection)
        checked(sql.sqlite3_enable_load_extension(connection, 0), connection)
        return connection

    with tempfile.TemporaryDirectory(prefix='dali-sqlite-ab-') as directory:
        database = Path(directory) / 'synthetic.db'
        writer = open_db(database)
        started = time.monotonic()
        for _, statement in statements:
            execute(writer, statement)
        for index in range(6):
            execute(writer, "INSERT INTO files(path,fname,album,album_artist,idx,tv_episode_sort,tv_season_num) "
                    f"VALUES('/fixture/{index}','fixture{index}','fixture','fixture',{index},0,0);")
            execute(writer, f"INSERT INTO playlists(title,type,db_timestamp,idx) VALUES('fixture{index}',0,0,{index});")
        schema_ms = (time.monotonic() - started) * 1000
        results = []
        for hold_ms in [0, 250]:
            result = {'controlledHoldMs': hold_ms, 'stages': [], 'waits': []}
            ready = threading.Event()
            failures = []
            committed_at = []
            if hold_ms:
                # bulk_scan() wraps process_directories() in this transaction.
                # These are db_directory_add() and db_watch_add() shapes, with
                # synthetic values only. No filesystem traversal is performed.
                execute(writer, 'BEGIN TRANSACTION;')
                execute(writer, "INSERT INTO directories(virtual_path,db_timestamp,disabled,parent_id,path,scan_kind) "
                        "VALUES(TRIM('/file:/fixture'),0,0,0,TRIM('/fixture'),0);")
                execute(writer, "INSERT INTO inotify(wd,cookie,path) VALUES(1,0,'/fixture');")

            def reader():
                connection = None
                try:
                    began = time.monotonic()
                    connection = open_db(database)
                    result['openMs'] = (time.monotonic() - began) * 1000
                    queries = [('startupPreparedPing', ping, False), ('startupSpeakerRead', speaker, True)]
                    if hold_ms:
                        # Positive control on a table the scan actually writes.
                        # This is not claimed to be the blocked player query.
                        queries.append(('sameTableLockPositiveControl', 'SELECT wd, cookie, path FROM inotify;', True))
                    for name, query, should_step in queries:
                        began = time.monotonic()
                        statement = pointer()

                        def wait_unlock():
                            notified = threading.Event()

                            @callback_type
                            def callback(arguments, count):
                                notified.set()

                            checked(sql.sqlite3_unlock_notify(connection, callback, None), connection)
                            ready.set()
                            if not notified.wait(2):
                                sql.sqlite3_unlock_notify(connection, callback_type(), None)
                                raise AssertionError('Unlock callback did not arrive within two seconds')
                            result['waits'].append(name)

                        while True:
                            code = sql.sqlite3_prepare_v2(connection, query.encode(), -1, C.byref(statement), None)
                            if code != 6:
                                checked(code, connection)
                                break
                            wait_unlock()
                        if should_step:
                            while True:
                                code = sql.sqlite3_step(statement)
                                if code == 6:
                                    wait_unlock()
                                    sql.sqlite3_reset.argtypes = [pointer]
                                    sql.sqlite3_reset(statement)
                                elif code == 100:
                                    continue
                                elif code == 101:
                                    break
                                else:
                                    checked(code, connection)
                        checked(sql.sqlite3_finalize(statement), connection)
                        result['stages'].append({'name': name, 'elapsedMs': (time.monotonic() - began) * 1000})
                    result['totalMs'] = (time.monotonic() - began_all) * 1000
                    if committed_at:
                        result['afterCommitMs'] = (time.monotonic() - committed_at[0]) * 1000
                except BaseException as error:
                    failures.append(repr(error))
                finally:
                    if connection:
                        sql.sqlite3_close(connection)
                    ready.set()

            began_all = time.monotonic()
            thread = threading.Thread(target=reader)
            thread.start()
            if hold_ms:
                assert ready.wait(2), 'Reader did not reach the controlled lock boundary'
                time.sleep(hold_ms / 1000)
                committed_at.append(time.monotonic())
                execute(writer, 'END TRANSACTION;')
            thread.join(3)
            assert not thread.is_alive(), 'Reader failed to finish after transaction release'
            assert not failures, failures
            results.append(result)
        checked(sql.sqlite3_close(writer), writer)
    return {'version': sql.sqlite3_libversion().decode(), 'sourceId': sql.sqlite3_sourceid().decode(),
            'librarySHA256': hashlib.sha256(library.read_bytes()).hexdigest(),
            'schemaStatements': len(statements), 'syntheticFiles': 6, 'syntheticPlaylists': 6,
            'schemaAndSeedMs': schema_ms, 'results': results,
            'limits': 'Synthetic DB and controlled transaction hold only. No real filesystem scan or blocked live SQL statement was captured.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--old-prefix', type=Path)
    parser.add_argument('--new-prefix', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--probe-prefix', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.probe_prefix:
        print(json.dumps(probe(args.probe_prefix)))
        return
    if not args.old_prefix or not args.new_prefix:
        parser.error('--old-prefix and --new-prefix are required')
    result = {}
    for label, prefix in [('old', args.old_prefix), ('new', args.new_prefix)]:
        result[label] = json.loads(subprocess.check_output(
            [sys.executable, str(Path(__file__).resolve()), '--probe-prefix', str(prefix.resolve())],
            text=True, timeout=15))
    rendered = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(rendered)
    print(rendered, end='')


if __name__ == '__main__':
    main()

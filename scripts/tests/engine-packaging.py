#!/usr/bin/env python3
"""Verify relocated helper dependencies and load its SQLite module in memory.

Never executes OwnTone or opens DALI's saved database, ports, or audio devices.
"""
import ctypes
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def verify_tree(root):
    extension = root / "lib/owntone-sqlext.so"
    if not extension.is_file():
        raise RuntimeError("bundled engine is missing runtime-loaded lib/owntone-sqlext.so")
    libraries = sorted((root / "lib").glob("*.dylib")) + [extension]
    for binary in [root / "owntone", *libraries]:
        output = subprocess.check_output(["otool", "-L", str(binary)], text=True)
        for line in output.splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith(("/usr/lib/", "/System/")):
                continue
            if dependency.startswith("@loader_path/"):
                target = binary.parent / dependency.removeprefix("@loader_path/")
            elif dependency.startswith("@executable_path/lib/"):
                target = root / "lib" / dependency.removeprefix("@executable_path/lib/")
            else:
                raise RuntimeError(f"unrelocated dependency: {binary.name} -> {dependency}")
            if not target.is_file():
                raise RuntimeError(f"missing bundled dependency: {binary.name} -> {dependency}")


def load_sqlite_extension(root):
    # Use the same SQLite dylib that OwnTone links, in an entirely new memory DB.
    sqlite = ctypes.CDLL(str(root / "lib/libsqlite3.dylib"))
    handle = ctypes.c_void_p()
    error = ctypes.c_char_p()
    sqlite.sqlite3_open.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    sqlite.sqlite3_enable_load_extension.argtypes = [ctypes.c_void_p, ctypes.c_int]
    sqlite.sqlite3_load_extension.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                             ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p)]
    sqlite.sqlite3_close.argtypes = [ctypes.c_void_p]
    sqlite.sqlite3_free.argtypes = [ctypes.c_void_p]
    if sqlite.sqlite3_open(b":memory:", ctypes.byref(handle)) != 0:
        raise RuntimeError("could not open isolated in-memory SQLite database")
    try:
        if sqlite.sqlite3_enable_load_extension(handle, 1) != 0:
            raise RuntimeError("could not enable SQLite extension loading")
        result = sqlite.sqlite3_load_extension(handle, str(root / "lib/owntone-sqlext.so").encode(),
                                                None, ctypes.byref(error))
        if result != 0:
            message = error.value.decode() if error.value else f"SQLite error {result}"
            sqlite.sqlite3_free(error)
            raise RuntimeError(f"Could not load SQLite extension: {message}")
        rows = []
        callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                                         ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_char_p))

        @callback_type
        def collect(_, count, values, names):
            rows.append(tuple(values[i].decode() for i in range(count)))
            return 0

        sqlite.sqlite3_exec.argtypes = [ctypes.c_void_p, ctypes.c_char_p, callback_type,
                                        ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
        query = "SELECT daap_no_zero(0, 7), daap_no_zero(8, 7), 'café' LIKE 'CAFE', 'A' = 'a' COLLATE DAAP"
        result = sqlite.sqlite3_exec(handle, query.encode(), collect, None, ctypes.byref(error))
        if result != 0:
            message = error.value.decode() if error.value else f"SQLite error {result}"
            sqlite.sqlite3_free(error)
            raise RuntimeError(f"SQLite extension function check failed: {message}")
        if rows != [("7", "8", "1", "1")]:
            raise RuntimeError(f"unexpected SQLite extension results: {rows}")
    finally:
        sqlite.sqlite3_close(handle)


def main():
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "vendor/owntone"
    verify_tree(source)
    with tempfile.TemporaryDirectory(prefix="dali SQLite relocation ") as scratch:
        relocated = Path(scratch) / "Moved DALI.app/Contents/Helpers/owntone"
        shutil.copytree(source, relocated)
        verify_tree(relocated)
        load_sqlite_extension(relocated)
    print("PASS: bundled dependencies and SQLite extension load after relocation; OwnTone was not started")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as failure:
        print(f"FAIL: {failure}", file=sys.stderr)
        sys.exit(1)

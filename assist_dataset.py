import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
from pathlib import Path
import sqlite3
import subprocess
import threading

import psutil

from convert_dataset import CONVERTER, MODEL, ROOT, arrow_complete

GIB = 2**30


def memory_estimate(path):
    with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True) as db:
        layers = db.execute("SELECT table_name FROM gpkg_geometry_columns WHERE table_name GLOB '*_Lden'")
        names = [row[0].replace('"', '""') for row in layers]
        largest = max((db.execute(f'SELECT max(length(geom)) FROM "{name}"').fetchone()[0] or 0
                       for name in names), default=0)
    return max(2 * GIB, 48 * largest)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('input', type=Path)
    parser.add_argument('--work-dir', type=Path, default=ROOT / 'data/h3/eea-work')
    parser.add_argument('--jobs', type=int)
    parser.add_argument('--reserve-gib', type=float, default=16)
    args = parser.parse_args()
    work = args.work_dir.resolve()
    state_path = work / 'state.json'
    state = json.loads(state_path.read_text())
    if state['status'] != 'processing' or state['model'] != MODEL:
        parser.error('The main runner must be processing the same cache model')
    if args.jobs is None:
        args.jobs = max(1, len(psutil.Process().cpu_affinity()) - state['jobs'])
    if args.jobs < 1 or args.reserve_gib < 0:
        parser.error('jobs must be positive; reserve-gib must not be negative')
    lock = (work / '.assist.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    logs = work / 'helpers'
    logs.mkdir(exist_ok=True)
    paths = [args.input.resolve() / f'{code}.gpkg' for code, record in state['countries'].items()
             if record['status'] == 'pending']
    paths.sort(key=lambda path: path.stat().st_size)
    admission = threading.Lock()
    reserved = 0

    def convert(path):
        nonlocal reserved
        record = json.loads(state_path.read_text())['countries'][path.stem]
        cache = Path(record['cache'])
        if record['status'] != 'pending' or arrow_complete(cache):
            return
        info = path.stat()
        if (info.st_size, info.st_mtime_ns) != (record['input_bytes'], record['input_mtime_ns']):
            raise ValueError(f'Input changed: {path}')
        estimate = memory_estimate(path)
        with admission:
            if psutil.virtual_memory().available - reserved - estimate < args.reserve_gib * GIB:
                print(f'{path.stem}: deferred to main runner (memory reserve)', flush=True)
                return
            reserved += estimate
        try:
            print(f'{path.stem}: helper started; reserved {estimate / GIB:.1f} GiB', flush=True)
            command = ['julia', '+1.10', f'--project={CONVERTER}', '--threads=1',
                       str(ROOT / 'convert_country.jl'), '--fine-cache', str(path), str(cache)]
            with (logs / f'{path.stem}.log').open('ab') as log:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            complete = result.returncode == 0 and arrow_complete(cache)
            print(f'{path.stem}: helper {"complete" if complete else "failed"}', flush=True)
            return complete
        finally:
            with admission:
                reserved -= estimate

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(convert, paths))
    return int(False in results)


if __name__ == '__main__':
    raise SystemExit(main())

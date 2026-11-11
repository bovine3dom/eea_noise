import argparse
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import subprocess
import time
import zipfile

ROOT = Path(__file__).resolve().parent
CONVERTER = ROOT.parent / 'geojson2h3'
MODEL = 'r10-family-max-v1'


def arrow_complete(path):
    if not path.is_file() or path.stat().st_size < 12:
        return False
    with path.open('rb') as file:
        start = file.read(6)
        file.seek(-6, 2)
        return start == file.read(6) == b'ARROW1'


def save(path, state):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, indent=2) + '\n')
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--work-dir', type=Path, default=ROOT / 'data/h3/eea-work')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--threads', type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1 or args.threads < 1:
        parser.error('jobs and threads must be positive')
    source, output, work = args.input.resolve(), args.output.resolve(), args.work_dir.resolve()
    if output.exists():
        parser.error(f'Output already exists: {output}')
    paths = sorted(source.glob('*.gpkg'), key=lambda p: p.stat().st_size, reverse=True)
    if not paths:
        parser.error('No GeoPackages found')
    if args.archive:
        with zipfile.ZipFile(args.archive) as archive:
            members = {Path(f.filename).name: f.file_size for f in archive.infolist()}
        expected = {Path(name).stem for name in members if name.endswith('.gpkg')}
        expected.update(name[:2] for name in members if name.endswith('-gpkg.7z'))
        if expected != {p.stem for p in paths}:
            parser.error(f'Country inventory mismatch: expected {sorted(expected)}')
        for path in paths:
            if path.name in members and path.stat().st_size != members[path.name]:
                parser.error(f'GeoPackage size mismatch: {path}')
    work.mkdir(parents=True, exist_ok=True)
    (work / 'countries').mkdir(exist_ok=True)
    lock = (work / '.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    state_path = work / 'state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {'model': MODEL, 'countries': {}}
    if state['model'] != MODEL:
        parser.error('Cache model mismatch; use a new work directory')
    state.pop('failed', None)
    state.update(status='processing', driver_pid=os.getpid(), output=str(output), jobs=args.jobs,
                 threads=args.threads, started_at=datetime.now(timezone.utc).isoformat())
    pending = []
    for path in paths:
        code = path.stem
        stat = path.stat()
        signature = {'input_bytes': stat.st_size, 'input_mtime_ns': stat.st_mtime_ns}
        cache = work / 'countries' / f'{code}.arrow'
        old = state['countries'].get(code, {})
        matches = all(old.get(key) == value for key, value in signature.items())
        if arrow_complete(cache) and matches:
            old.update(status='complete', exit_code=0, cache_reused=True)
            state['countries'][code] = old
            continue
        if cache.exists():
            parser.error(f'Stale or incomplete cache: {cache}; use a new work directory')
        state['countries'][code] = dict(signature, status='pending', cache=str(cache))
        pending.append(path)
    state['countries'] = {p.stem: state['countries'][p.stem] for p in paths}
    save(state_path, state)

    def convert(path):
        code = path.stem
        started = time.perf_counter()
        log_path = work / 'countries' / f'{code}.log'
        command = ['julia', '+1.10', f'--project={CONVERTER}', f'--threads={args.threads}',
                   str(ROOT / 'convert_country.jl'), '--fine-cache', str(path),
                   state['countries'][code]['cache']]
        with log_path.open('ab') as log:
            log.write(f'\nRun started {datetime.now(timezone.utc).isoformat()}\n'.encode())
            log.flush()
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        return result.returncode, time.perf_counter() - started, str(log_path)

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(convert, path): path.stem for path in pending}
        while futures:
            done, _ = wait(futures, timeout=5, return_when=FIRST_COMPLETED)
            for future in done:
                code = futures.pop(future)
                record = state['countries'][code]
                try:
                    exit_code, seconds, log = future.result()
                    complete = exit_code == 0 and arrow_complete(Path(record['cache']))
                    record.update(status='complete' if complete else 'failed',
                                  exit_code=exit_code, wall_seconds=seconds, log=log)
                except Exception as error:
                    record.update(status='failed', error=str(error))
                print(f'{code}: {record["status"]}', flush=True)
            for future, code in futures.items():
                state['countries'][code]['status'] = 'running' if future.running() else 'pending'
            save(state_path, state)
    failed = [code for code, record in state['countries'].items() if record['status'] != 'complete']
    if failed:
        state.update(status='failed', failed=failed)
        save(state_path, state)
        print(f'No combined file published; failed countries: {failed}', flush=True)
        return 1
    state['status'] = 'merging'
    save(state_path, state)
    staging = work / 'merged.arrow'
    if staging.exists():
        staging.unlink()
    caches = [state['countries'][p.stem]['cache'] for p in paths]
    command = ['julia', '+1.10', f'--project={CONVERTER}', f'--threads={args.threads}',
               str(ROOT / 'merge_dataset.jl'), str(staging), *caches]
    with (work / 'merge.log').open('ab') as log:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=log, text=True)
        if result.returncode:
            state.update(status='merge_failed')
            save(state_path, state)
            return result.returncode
        summary = json.loads(result.stdout)
        validation = subprocess.run(['node', str(ROOT / 'test_h3mon.mjs'), str(staging)],
                                    stdout=log, stderr=subprocess.STDOUT)
    if validation.returncode:
        state.update(status='validation_failed')
        save(state_path, state)
        return validation.returncode
    output.parent.mkdir(parents=True, exist_ok=True)
    os.link(staging, output)
    staging.unlink()
    state.update(status='complete', summary=summary, output_bytes=output.stat().st_size,
                 finished_at=datetime.now(timezone.utc).isoformat())
    save(state_path, state)
    print(json.dumps(summary), flush=True)
    print(f'Published {output}', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

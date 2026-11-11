import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import time

import psutil

if len(sys.argv) < 3:
    sys.exit('Usage: benchmark_country.py REPORT.json COMMAND [ARGS...]')

report = Path(sys.argv[1])
command = sys.argv[2:]
report.parent.mkdir(parents=True, exist_ok=True)
started = time.perf_counter()
peak_rss = peak_processes = 0
last_save = 0


def save(status, pid, code=None):
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    data = dict(status=status, command=command, pid=pid, exit_code=code,
                wall_seconds=time.perf_counter() - started,
                cpu_user_seconds=usage.ru_utime, cpu_system_seconds=usage.ru_stime,
                peak_sampled_tree_rss_bytes=peak_rss, peak_processes=peak_processes,
                sample_interval_seconds=0.25, available_cpus=len(os.sched_getaffinity(0)))
    temporary = report.with_suffix(report.suffix + '.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    temporary.replace(report)


with report.with_suffix('.log').open('wb') as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL, start_new_session=True)
    root = psutil.Process(process.pid)
    save('running', process.pid)
    try:
        while process.poll() is None:
            rss = count = 0
            try:
                processes = [root] + root.children(recursive=True)
            except psutil.NoSuchProcess:
                processes = []
            for child in processes:
                try:
                    rss += child.memory_info().rss
                    count += 1
                except psutil.NoSuchProcess:
                    pass
            peak_rss = max(peak_rss, rss)
            peak_processes = max(peak_processes, count)
            if time.perf_counter() - last_save >= 5:
                save('running', process.pid)
                last_save = time.perf_counter()
            time.sleep(0.25)
        code = process.wait()
    except BaseException:
        os.killpg(process.pid, 15)
        process.wait()
        save('interrupted', process.pid, process.returncode)
        raise
    save('complete', process.pid, code)
sys.exit(code)

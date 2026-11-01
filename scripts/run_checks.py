"""Run isolated check scripts and optionally report per-case wall times.

Fast is the routine pass; slow requests the expensive numerical comparisons;
all runs both. This instruments each script's existing main block, including
parameterized simulations, without maintaining another list of test cases.
Check files run in separate processes; bounded parallelism does not share
their fixture globals. Use --jobs 1 for comparable individual-case timings.
"""
import argparse
import ast
import functools
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[1]
# These scripts expose --slow / --slow-only. Their default is the fast pass.
SLOW_FILES = {'check_direct_return.py'}


def default_jobs():
    count = getattr(os, 'process_cpu_count', os.cpu_count)() or 1
    return min(4, count)


def positive_jobs(value):
    jobs = int(value)
    if jobs < 1:
        raise argparse.ArgumentTypeError('jobs must be at least 1')
    return jobs


def worker_environment():
    env = dict(os.environ)
    # These fixtures use small vectors. Avoid a BLAS thread pool per worker,
    # while respecting explicitly configured developer thread counts.
    for name in ('OPENBLAS_NUM_THREADS', 'OMP_NUM_THREADS', 'MKL_NUM_THREADS'):
        env.setdefault(name, '1')
    return env


def run_files(paths, suite, jobs, result_dir):
    """Keep process isolation, deterministic output and every failure/result."""
    if not paths:
        return []
    def run_one(path):
        result = result_dir/(path.stem+'.json')
        before = time.perf_counter()
        done = subprocess.run([sys.executable, '-B', __file__, '--worker', str(path),
                               '--suite', suite, '--result', str(result)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, env=worker_environment())
        row = json.loads(result.read_text()) if result.exists() else dict(module=path.name, cases=[])
        row.update(wall_seconds=time.perf_counter()-before, returncode=done.returncode)
        return row, done.stdout
    rows = []
    with ThreadPoolExecutor(max_workers=min(jobs, len(paths))) as pool:
        futures = [pool.submit(run_one, path) for path in paths]
        for future in futures:
            row, output = future.result()
            print(output, end='', flush=True)
            rows.append(row)
    return rows


def instrument(path):
    tree = ast.parse(path.read_text(), filename=str(path))
    definitions = {node.name for node in tree.body if isinstance(node, ast.FunctionDef)}
    mains = [node for node in tree.body if isinstance(node, ast.If)
             and ast.dump(node.test) == ast.dump(ast.parse("__name__ == '__main__'", mode='eval').body)]
    assert len(mains) == 1, f'{path}: expected one main block'
    entries = {node.func.id for node in ast.walk(mains[0])
               if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)} & definitions
    assert entries, f'{path}: no check entrypoints found'
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in entries:
            node.decorator_list.insert(0, ast.Name(id='__check_timed', ctx=ast.Load()))
    return ast.fix_missing_locations(tree)


def worker(path, suite, result):
    rows = []
    def timed(fn):
        @functools.wraps(fn)
        def wrapped(*args, **kwargs):
            started = time.perf_counter()
            try:
                return fn(*args, **kwargs)
            finally:
                rows.append(dict(case=fn.__name__, seconds=time.perf_counter()-started))
        return wrapped
    sys.path.insert(0, str(path.parent))
    sys.argv = [str(path)]
    if path.name in SLOW_FILES and suite != 'fast':
        sys.argv.append('--slow-only' if suite == 'slow' else '--slow')
    started = time.perf_counter()
    try:
        exec(compile(instrument(path), str(path), 'exec'),
             dict(__name__='__main__', __file__=str(path), __check_timed=timed))
    finally:
        result.write_text(json.dumps(dict(module=path.name, seconds=time.perf_counter()-started, cases=rows)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=('fast', 'slow', 'all'), default='fast')
    parser.add_argument('--timings', action='store_true', help='show slowest files and individual check calls')
    parser.add_argument('--jobs', type=positive_jobs, default=default_jobs(),
                        help='isolated check processes (default: up to 4 CPUs; use 1 for timings)')
    parser.add_argument('--json', type=Path, help='write complete timing results to this file')
    parser.add_argument('--worker', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--result', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        worker(args.worker, args.suite, args.result)
        return 0
    paths = sorted((ROOT/'scripts').glob('check_*.py'))
    assert SLOW_FILES <= {path.name for path in paths}, 'slow-pass script missing'
    if args.suite == 'slow':
        paths = [path for path in paths if path.name in SLOW_FILES]
    started = time.perf_counter()
    with tempfile.TemporaryDirectory(prefix='kos-check-times-') as temp:
        rows = run_files(paths, args.suite, args.jobs, Path(temp))
    failed = any(row['returncode'] != 0 for row in rows)
    elapsed = time.perf_counter()-started
    jobs = min(args.jobs, len(paths))
    print(f'{len(paths)} check files in {elapsed:.2f}s ({args.suite}, jobs={jobs}); '
          + ('FAILED' if failed else 'passed'))
    if args.timings:
        print('Slowest files, including interpreter startup/imports:')
        for row in sorted(rows, key=lambda row: -row['wall_seconds'])[:10]:
            print(f'  {row["wall_seconds"]:.3f}s {row["module"]}')
        print('Slowest individual check calls:')
        cases = [(case['seconds'], row['module'], case['case']) for row in rows for case in row['cases']]
        for seconds, module, name in sorted(cases, reverse=True)[:15]:
            print(f'  {seconds:.3f}s {module}:{name}')
    if args.json:
        args.json.write_text(json.dumps(dict(suite=args.suite, jobs=jobs,
                                            seconds=elapsed, files=rows), indent=2)+'\n')
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())

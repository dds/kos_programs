"""Run isolated check scripts and optionally report per-case wall times.

Fast is the routine pass; slow requests the expensive numerical comparisons;
all runs both. This instruments each script's existing main block, including
parameterized simulations, without maintaining another list of test cases.
Check files run in separate processes; bounded parallelism does not share
their fixture globals. Use --jobs 1 for comparable individual-case timings.
"""
import argparse
import ast
from contextlib import nullcontext
import functools
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from fixture_cache import Inputs, Results, context

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
    # Normalize build/shell bookkeeping before both execution and cache keys.
    # Thus make, direct CLI and different worker counts see the same inputs.
    for name in ('MAKEFLAGS', 'MAKELEVEL', 'MFLAGS', 'SHLVL', '_', 'CODEX_TOOL_CALL_ID'):
        env.pop(name, None)
    # These fixtures use small vectors. Avoid a BLAS thread pool per worker,
    # while respecting explicitly configured developer thread counts.
    for name in ('OPENBLAS_NUM_THREADS', 'OMP_NUM_THREADS', 'MKL_NUM_THREADS'):
        env.setdefault(name, '1')
    return env


def run_files(paths, suite, jobs, result_dir, cache=None):
    """Keep process isolation, deterministic output and every failure/result."""
    if not paths:
        return []
    def run_one(path):
        result = result_dir/(path.stem+'.json')
        before = time.perf_counter()
        command = [sys.executable, '-B', __file__, '--worker', str(path),
                   '--suite', suite, '--result', str(result)]
        if cache is not None:
            command.append('--record-inputs')
        done = subprocess.run(command,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, env=worker_environment())
        row = json.loads(result.read_text()) if result.exists() else dict(module=path.name, cases=[])
        row.update(wall_seconds=time.perf_counter()-before, returncode=done.returncode)
        return row, done.stdout
    hits = {path: cache.lookup(path) if cache is not None else None for path in paths}
    missing = [path for path in paths if hits[path] is None]
    rows = []
    with ThreadPoolExecutor(max_workers=max(1, min(jobs, len(missing)))) as pool:
        futures = {path: pool.submit(run_one, path) for path in missing}
        for path in paths:
            if hits[path] is not None:
                row = hits[path]
                print('CACHED: ' + path.name + ' (verified inputs unchanged)', flush=True)
            else:
                row, output = futures[path].result()
                row['cached'] = False
                print(output, end='', flush=True)
                if cache is not None:
                    try:
                        cache.save(path, row)
                    except OSError:
                        row['cache_skip_reason'] = 'cache-unwritable'
                        print('Cache write unavailable for ' + path.name + '; fresh result retained.')
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


def worker(path, suite, result, record_inputs=False):
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
    inputs = Inputs() if record_inputs else None
    try:
        with inputs if inputs is not None else nullcontext():
            exec(compile(instrument(path), str(path), 'exec'),
                 dict(__name__='__main__', __file__=str(path), __check_timed=timed))
    finally:
        row = dict(module=path.name, seconds=time.perf_counter()-started, cases=rows)
        if inputs is not None:
            row['input_proof'] = inputs.finish()
        result.write_text(json.dumps(row))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=('fast', 'slow', 'all'), default='fast')
    parser.add_argument('--timings', action='store_true', help='show slowest files and individual check calls')
    parser.add_argument('--jobs', type=positive_jobs, default=default_jobs(),
                        help='isolated check processes (default: up to 4 CPUs; use 1 for timings)')
    parser.add_argument('--json', type=Path, help='write complete timing results to this file')
    parser.add_argument('--no-cache', action='store_true', help='rerun every check without reading/writing cached passes')
    parser.add_argument('--cache-dir', type=Path, default=ROOT/'.cache/checks', help='local verified-result cache')
    parser.add_argument('--record-inputs', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--worker', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--result', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        worker(args.worker, args.suite, args.result, args.record_inputs)
        return 0
    paths = sorted((ROOT/'scripts').glob('check_*.py'))
    assert SLOW_FILES <= {path.name for path in paths}, 'slow-pass script missing'
    if args.suite == 'slow':
        paths = [path for path in paths if path.name in SLOW_FILES]
    started = time.perf_counter()
    cache = None
    if args.suite == 'fast' and not args.no_cache and not args.timings:
        try:
            args.cache_dir.mkdir(parents=True, exist_ok=True)
            cache = Results(args.cache_dir, context(ROOT, worker_environment()))
        except OSError:
            print('Cache unavailable; executing checks fresh.')
    with tempfile.TemporaryDirectory(prefix='kos-check-times-') as temp:
        rows = run_files(paths, args.suite, args.jobs, Path(temp), cache)
    failed = any(row['returncode'] != 0 for row in rows)
    if failed and cache is None:
        # A forced fresh failure must revoke any older cached pass as well.
        try:
            invalidator = Results(args.cache_dir, '')
            for path, row in zip(paths, rows):
                if row['returncode'] != 0:
                    invalidator.discard(path)
        except OSError:
            print('Cache invalidation unavailable; fresh failures remain failures.')
    elapsed = time.perf_counter()-started
    jobs = min(args.jobs, len(paths))
    cached = sum(bool(row.get('cached')) for row in rows)
    print(f'{len(paths)} check files in {elapsed:.2f}s ({args.suite}, jobs={jobs}, '
          f'{cached} cached, {len(rows)-cached} executed); '
          + ('FAILED' if failed else 'passed'))
    if args.timings:
        print('Slowest files, including interpreter startup/imports:')
        for row in sorted(rows, key=lambda row: -row['wall_seconds'])[:10]:
            print(f'  {row["wall_seconds"]:.3f}s {row["module"]}')
        print('Slowest individual check calls:')
        cases = [(case['seconds'], row['module'], case['case']) for row in rows for case in row['cases']]
        for seconds, module, name in sorted(cases, reverse=True)[:15]:
            print(f'  {seconds:.3f}s {module}:{name}')
    report = dict(suite=args.suite, jobs=jobs, cached=cached, seconds=elapsed, files=rows)
    if args.json:
        args.json.write_text(json.dumps(report, indent=2)+'\n')
    if cache is not None:
        try:
            (args.cache_dir/'last-run.json').write_text(json.dumps(report, indent=2)+'\n')
        except OSError:
            print('Cache report unavailable; check results above are unchanged.')
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())

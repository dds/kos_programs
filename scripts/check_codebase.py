"""Repository contracts, not a KerboScript compiler or a KSP simulator.

Check lexical balance, dependency cycles/files, phase bindings, profile
identities/sequences, undeclared configuration names, command entrypoints
and RETURN scope, plus unsupported NOT DEFINED syntax. --report also shows
source-token counts per band; these are NOT compiled byte sizes.
"""
import argparse
import collections
import re
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@lru_cache(maxsize=512)
def mask(source):
    """Preserve offsets/newlines while hiding comments and string contents."""
    return re.sub(r'"[^"\n]*"|//[^\n]*',
                  lambda m: ''.join('\n' if c == '\n' else ' ' for c in m[0]), source)


def function_body(source, name):
    clean = mask(source)
    match = re.search(r'\bFUNCTION\s+' + re.escape(name) + r'\s*\{', clean, re.I)
    if not match:
        raise ValueError(f'missing function {name}')
    start, depth = match.end(), 1
    for pos in range(start, len(clean)):
        depth += (clean[pos] == '{') - (clean[pos] == '}')
        if depth == 0:
            return source[start:pos]
    raise ValueError(f'unclosed function {name}')


def dependency_tables(source):
    tables = []
    for name in ('dependencyLibs', 'dependencyPhases', 'dependencyBands'):
        section = re.sub(r'//[^\n]*', '', function_body(source, name))
        tables.append({key.lower(): [v.lower() for v in re.findall(r'"([^"]+)"', values)]
                       for key, values in re.findall(r'"([^"]+)",\s*LIST\((.*?)\)', section, re.S)})
    return tables


def closure(roots, dependencies):
    result, visiting = set(), set()

    def visit(name):
        if name in visiting:
            raise ValueError(f'dependency cycle at {name}')
        if name in result:
            return
        visiting.add(name)
        for dep in dependencies.get(name, []):
            visit(dep)
        visiting.remove(name)
        result.add(name)

    for name in roots:
        visit(name)
    return result


def declared_names(source):
    names = re.findall(r'\b(?:LOCAL|GLOBAL)\s+(?!FUNCTION\b)(\w+)', source, re.I)
    names += re.findall(r'\bFUNCTION\s+(\w+)', source, re.I)
    names += re.findall(r'\bFOR\s+(\w+)\s+IN\b', source, re.I)
    for params in re.findall(r'\bPARAMETERS?\s+(.*?)\.', source, re.I | re.S):
        names += re.findall(r'(?:^|,)\s*(\w+)', params)
    return {name.lower() for name in names}


def unscoped_returns(source):
    """Find RETURN outside named/anonymous functions and WHEN/ON bodies.

    IF/FOR/UNTIL braces do not create a return scope. This is a lexical
    guard for the flight-found command error, not a KerboScript parser.
    """
    clean = mask(source)
    scopes = {match.end()-1 for match in re.finditer(
        r'\bFUNCTION(?:\s+\w+)?\s*\{|\bTHEN\s*\{|\bON\b(?:[^{}.]+|\.(?=\d))*\{'
        r'|(?:\bIS|\bTO|\(|,)\s*\{', clean, re.I)}
    stack, bad = [], []
    for match in re.finditer(r'\bRETURN\b|[{}]', clean, re.I):
        if match[0] == '{':
            stack.append(match.start() in scopes)
        elif match[0] == '}':
            if stack:
                stack.pop()
        elif not any(stack):
            bad.append(clean[:match.start()].count('\n')+1)
    return bad


def negated_defined_conditions(source):
    """Reject the flight-found NOT DEFINED form; use IF DEFINED/ELSE."""
    clean = mask(source)
    return [clean[:match.start()].count('\n')+1
            for match in re.finditer(r'\bNOT\s+DEFINED\b', clean, re.I)]


def command_entrypoint_errors(source):
    """Only declarations/directives and one local entry call at file scope."""
    clean = mask(source)
    remainder = list(clean)
    functions, covered = set(), -1
    for match in re.finditer(r'\b(LOCAL|GLOBAL)\s+FUNCTION\s+(\w+)\s*\{', clean, re.I):
        if match.start() < covered:
            continue  # A helper nested inside the entry function.
        depth, end = 1, match.end()
        while end < len(clean) and depth:
            depth += (clean[end] == '{') - (clean[end] == '}')
            end += 1
        if depth:
            return ['unclosed command function']
        if match[1].lower() == 'local':
            functions.add(match[2].lower())
        remainder[match.start():end] = ' ' * (end-match.start())
        covered = end
    statements = [s.strip() for s in re.split(r'\.(?!\d)', ''.join(remainder)) if s.strip()]
    calls = []
    for statement in statements:
        if re.match(r'^(?:@\w+\b|PARAMETERS?\b|GLOBAL\s+\w+\s+IS\b)', statement, re.I):
            continue
        call = re.fullmatch(r'(\w+)\s*\(\s*\)', statement)
        if not call or call[1].lower() not in functions:
            return ['command executable body must be inside a LOCAL FUNCTION']
        calls.append(call[1].lower())
    return [] if len(calls) == 1 else ['command must invoke one local entry function exactly once']


def audit(report=False):
    errors, warnings = [], []
    sources = {p.relative_to(ROOT).as_posix(): p.read_text()
               for folder in ('boot', 'lib', 'craft', 'missions', 'roles', 'cmd', 'configs')
               for p in (ROOT / folder).rglob('*.ks')}
    clean = {path: mask(src) for path, src in sources.items()}
    for path, src in clean.items():
        stack = []
        for pos, char in enumerate(src):
            if char == '"':
                errors.append(f'{path}: unterminated string on line {src[:pos].count(chr(10))+1}')
            elif char in '({[':
                stack.append(char)
            elif char in ')}]':
                if not stack or stack.pop() != dict(zip(')}]', '({['))[char]:
                    errors.append(f'{path}: mismatched delimiter at offset {pos}')
        if stack:
            errors.append(f'{path}: unclosed delimiters {stack}')
        for line in unscoped_returns(sources[path]):
            errors.append(f'{path}:{line}: RETURN outside a function or trigger')
        for line in negated_defined_conditions(sources[path]):
            errors.append(f'{path}:{line}: unsupported NOT DEFINED; use IF DEFINED ... {{ }} ELSE {{ ... }}')
        if path.startswith('cmd/'):
            errors.extend(f'{path}: {error}' for error in command_entrypoint_errors(sources[path]))

    libs = {Path(path).stem.lower(): src for path, src in sources.items() if path.startswith('lib/')}
    deps, phases, bands = dependency_tables(libs['dependencies'])
    providers = collections.defaultdict(set)
    for name, src in libs.items():
        for function in re.findall(r'\bGLOBAL\s+FUNCTION\s+(\w+)', mask(src), re.I):
            providers[function.lower()].add(name)
    for function, owners in providers.items():
        if len(owners) > 1:
            errors.append(f'duplicate global function {function}: {sorted(owners)}')
    for name in libs:
        try:
            missing = closure([name], deps) - libs.keys()
            if missing:
                errors.append(f'{name}: missing library files {sorted(missing)}')
        except ValueError as exc:
            errors.append(str(exc))

    membership = collections.defaultdict(list)
    for band, members in bands.items():
        for phase in members:
            membership[phase].append(band)
            if phase not in phases:
                errors.append(f'{band}: unknown phase {phase}')
    for phase, memberships in membership.items():
        if len(memberships) > 1:
            errors.append(f'{phase}: ambiguous bands {memberships}')
    binding_source = function_body(libs['dependencies'], 'dependencyBindPhase')
    bindings = dict((phase.lower(), handler.lower()) for phase, handler in re.findall(
        r'phaseKey = "([^"]+)".*?phaseMapSet\(phaseMap, phaseKey, (\w+)@\)', binding_source, re.S))
    for phase, roots in phases.items():
        handler = bindings.get(phase, 'phaseDone' if phase == 'done' else '')
        if not handler:
            errors.append(f'{phase}: missing binding')
            continue
        if not providers[handler]:
            message = f'{phase}: handler {handler} is absent; missions using this phase cannot complete'
            if re.search(r'\bDEFINED\s+' + re.escape(handler) + r'\b', binding_source, re.I):
                warnings.append(message + ' (runtime holds)')
            else:
                errors.append(message)
            continue
        band_phases = bands.get(membership.get(phase, [phase])[0], [phase])
        available = closure(['core', 'boot_lib', 'resume'] +
                            [lib for member in band_phases for lib in phases[member]], deps)
        if not providers[handler] & available:
            errors.append(f'{phase}: handler {handler} is outside its dependency closure')

    declarations = set().union(*(declared_names(src) for src in clean.values()))
    for path, src in clean.items():
        # Config-style identifiers only: built-in suffixes follow a colon,
        # and ordinary flight locals/delegates are checked by the kOS VM.
        for name in set(re.findall(r'(?<![:\w])([A-Z][A-Z0-9]*_[A-Z0-9_]+)\b', src)):
            if name.lower() not in declarations:
                errors.append(f'{path}: undeclared configuration {name}')
    profiles = [path for path in sources if path.startswith('missions/')]
    for path in profiles:
        src = re.sub(r'//[^\n]*', '', sources[path])
        identity = re.search(r'SET\s+MISSION_ID\s+TO\s+"([^"]+)"', src, re.I)
        if not identity or identity[1].lower() != Path(path).stem.lower():
            errors.append(f'{path}: MISSION_ID must match the profile filename')
        vehicle = Path(path).parent.name
        if not (ROOT / 'craft' / (vehicle + '.ks')).exists():
            errors.append(f'{path}: craft script missing for {vehicle}')
        sequence = re.search(r'SET\s+SEQUENCE\s+TO\s+LIST\((.*?)\)', src, re.S | re.I)
        if not sequence:
            errors.append(f'{path}: missing literal SEQUENCE')
            continue
        members = [x.lower() for x in re.findall(r'"([^"]+)"', sequence[1])]
        if len(members) != len(set(members)):
            errors.append(f'{path}: repeated phases cannot advance by value')
        for phase in members:
            if phase not in phases:
                errors.append(f'{path}: unknown phase {phase}')
        for extra in re.findall(r'SET\s+LIBS(?:_EXTRA)?\s+TO\s+LIST\((.*?)\)', src, re.S | re.I):
            for entry in re.findall(r'"([^"]+)"', extra):
                name, _, until = entry.lower().partition('@')
                if name not in libs or (until and until not in members):
                    errors.append(f'{path}: invalid library/scope {entry}')

    if report:
        print('Band source tokens (includes dependencies; excludes boot_lib/resume/craft; NOT KSM bytes):')
        sizes = []
        for band, members in bands.items():
            names = closure(['core'] + [lib for phase in members for lib in phases[phase]], deps)
            tokens = sum(len(re.findall(r'\w+|[^\s\w]', mask(libs[name]))) for name in names)
            sizes.append((tokens, band, len(names)))
        for tokens, band, count in sorted(sizes, reverse=True):
            print(f'  {band:22} {count:2} libraries {tokens:6} tokens')
    for message in sorted(set(warnings)):
        print('WARN:', message)
    for message in sorted(set(errors)):
        print('FAIL:', message)
    print(f'{len(sources)} scripts, {len(profiles)} profiles, {len(phases)} phases, '
          f'{len(bands)} bands; {len(set(errors))} errors, {len(set(warnings))} warnings')
    return bool(errors)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', action='store_true')
    raise SystemExit(audit(parser.parse_args().report))

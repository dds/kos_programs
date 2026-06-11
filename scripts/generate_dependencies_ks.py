#!/usr/bin/env python3

from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
INPUT = REPO / "lib" / "dependencies.txt"
OUTPUT = REPO / "lib" / "dependencies.ks"


def values(raw):
    return [item.strip() for item in raw.split(",") if item.strip()]


def phase_function_name(phase_name):
    return "phase" + "".join(
        part[:1].upper() + part[1:]
        for part in phase_name.lower().split("_")
        if part
    )


def parse_phases(raw):
    """Return [(phase, roots)] from PHASE rows, in file order."""
    phases = []
    seen = set()

    for raw_line in raw.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        if "=" not in line:
            continue
        lhs, rhs = line.split("=", 1)
        lhs = lhs.strip()
        if lhs.endswith("+") or lhs.endswith("-"):
            lhs = lhs[:-1].strip()
        keys = values(lhs.replace(" ", ","))
        if not keys:
            continue
        if keys[0].upper() == "PHASE":
            roots = values(rhs)
            for phase in keys[1:]:
                key = phase.upper()
                if key not in seen:
                    seen.add(key)
                    phases.append((key, roots))

    return phases


def main():
    phases = parse_phases(INPUT.read_text())
    # Each binding is guarded on the phase's root libs being present
    # on the local disk: referencing the handler delegate of a lib
    # that never loaded is a hard crash (flight-found: a no-link
    # reboot into the AEROBRAKE band could not sync aerobrake.ks,
    # and binding phaseAerobrake@ killed the boot). An unbound phase
    # degrades to runPhases' missing-handler path instead.
    lines = [
        "LOCAL FUNCTION _depLoaded {",
        "    PARAMETER libsCsv.",
        '    FOR libName IN libsCsv:SPLIT(",") {',
        '        IF libName <> "" {',
        '            IF NOT EXISTS("1:/lib/" + libName + ".ksm")',
        '                    AND NOT EXISTS("1:/lib/" + libName + ".ks") {',
        "                RETURN FALSE.",
        "            }",
        "        }",
        "    }",
        "    RETURN TRUE.",
        "}",
        "",
        "GLOBAL FUNCTION dependencyBindPhase {",
        "    PARAMETER phaseMap.",
        "    PARAMETER phaseName.",
        "    LOCAL phaseKey IS phaseName.",
    ]
    for index, (phase, roots) in enumerate(phases):
        fn = phase_function_name(phase)
        prefix = "    IF" if index == 0 else "    ELSE IF"
        bind = f'phaseMapSet(phaseMap, "{phase}", {fn}@).'
        if roots:
            guard = ",".join(roots)
            lines.append(
                f'{prefix} phaseKey = "{phase}" '
                f'{{ IF _depLoaded("{guard}") {{ {bind} }} }}'
            )
        else:
            lines.append(f'{prefix} phaseKey = "{phase}" {{ {bind} }}')
    lines.extend([
        "}",
        "",
    ])

    OUTPUT.write_text("\n".join(lines))
    print(f"generated {OUTPUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()

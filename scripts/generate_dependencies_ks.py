#!/usr/bin/env python3

from pathlib import Path
import json


REPO = Path(__file__).resolve().parent.parent
INPUT = REPO / "lib" / "dependencies.json"
OUTPUT = REPO / "lib" / "dependencies.ks"


def parse_phases(raw):
    """Return [(phase, roots)] from JSON PHASE rows, in file order."""
    spec = json.loads(raw)
    return [(phase.upper(), roots) for phase, roots in spec.get("phases", {}).items()]


def phase_function_name(phase_name):
    return "phase" + "".join(
        part[:1].upper() + part[1:]
        for part in phase_name.lower().split("_")
        if part
    )


def main():
    phases = parse_phases(INPUT.read_text())
    lines = [
        "GLOBAL FUNCTION dependencyAllPhases {",
        "    RETURN bootLibAllPhases().",
        "}",
        "",
        "GLOBAL FUNCTION dependencyBindPhase {",
        "    PARAMETER phaseMap.",
        "    PARAMETER phaseName.",
        "    LOCAL phaseKey IS phaseName.",
    ]
    for index, (phase, _roots) in enumerate(phases):
        fn = phase_function_name(phase)
        prefix = "    IF" if index == 0 else "    ELSE IF"
        bind = f'phaseMapSet(phaseMap, "{phase}", {fn}@).'
        lines.append(f'{prefix} phaseKey = "{phase}" {{ {bind} }}')
    lines.extend([
        "}",
        "",
    ])

    OUTPUT.write_text("\n".join(lines))
    print(f"generated {OUTPUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()

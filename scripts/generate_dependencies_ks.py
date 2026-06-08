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
    phases = []
    seen = set()

    for raw_line in raw.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        if "=" not in line:
            continue
        lhs = line.split("=", 1)[0].strip()
        if lhs.endswith("+") or lhs.endswith("-"):
            lhs = lhs[:-1].strip()
        keys = values(lhs.replace(" ", ","))
        if not keys:
            continue
        if keys[0].upper() == "PHASE":
            for phase in keys[1:]:
                key = phase.upper()
                if key not in seen:
                    seen.add(key)
                    phases.append(key)

    return phases


def main():
    phases = parse_phases(INPUT.read_text())
    lines = [
        "GLOBAL FUNCTION dependencyBindPhase {",
        "    PARAMETER phaseMap.",
        "    PARAMETER phaseName.",
        "    LOCAL phaseKey IS phaseName.",
    ]
    for index, phase in enumerate(phases):
        fn = phase_function_name(phase)
        prefix = "    IF" if index == 0 else "    ELSE IF"
        lines.append(f'{prefix} phaseKey = "{phase}" {{ phaseMapSet(phaseMap, "{phase}", {fn}@). }}')
    lines.extend([
        "}",
        "",
        "GLOBAL FUNCTION dependencyPhaseHandlers {",
        "    LOCAL phaseMap IS LEXICON().",
        '    LOCAL phases IS bootLibBandPhases(stateGet("lib_band", "")).',
        "    FOR phaseName IN phases {",
        "        dependencyBindPhase(phaseMap, phaseName).",
        "    }",
        "    RETURN phaseMap.",
        "}",
        "",
    ])

    OUTPUT.write_text("\n".join(lines))
    print(f"generated {OUTPUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()

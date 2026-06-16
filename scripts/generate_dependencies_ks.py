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
    # Each binding is guarded on the phase's root libs having RUN
    # this boot (BOOT_LIB_RAN): referencing the handler delegate of
    # a lib that never loaded is a hard crash (flight-found: a
    # no-link reboot into the AEROBRAKE band could not sync
    # aerobrake.ks, and binding phaseAerobrake@ killed the boot).
    # An unbound phase degrades to runPhases' missing-handler path.
    # Because the guard is exact, phaseHandlerMap can safely try
    # every parsed phase — phases whose libs arrived via LIBS_EXTRA
    # bind too, so a mission can avoid band-change reboots entirely
    # by pre-loading its libs.
    lines = [
        "LOCAL FUNCTION _depLoaded {",
        "    PARAMETER libsCsv.",
        '    FOR libName IN libsCsv:SPLIT(",") {',
        '        IF libName <> "" AND NOT BOOT_LIB_RAN:CONTAINS(libName) {',
        "            RETURN FALSE.",
        "        }",
        "    }",
        "    RETURN TRUE.",
        "}",
        "",
        "GLOBAL FUNCTION dependencyAllPhases {",
        "    bootLibLoadSpec().",
        "    RETURN BOOT_LIB_PHASES:KEYS.",
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

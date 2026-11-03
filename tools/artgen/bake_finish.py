"""The ending every kit bake shares: its report and its outcome line.

Each kit's bake.py imports this from the parent directory, so the kits cannot
drift in how they write the committed structural report or in the outcome line
the artgen workflow checks for (``RESULT: SUCCESS``).

This directory is part of the sanctioned Python/bpy exception (AGENTS.md,
Scripting); Python appears nowhere else in the repo.
"""
import hashlib
import os
import sys
import traceback


def finish_bake(out_path, report_lines):
    """Write and echo the structural report, then the GLB's sha and size.

    The report goes next to the GLB as ``<name>_report.txt``. The sha is only
    printed, for run-to-run determinism checks, and never written to the
    report: float bit-exactness across OS/arch is not guaranteed, structure is.
    """
    with open(out_path, "rb") as glb:
        sha = hashlib.sha256(glb.read()).hexdigest()
    with open(os.path.splitext(out_path)[0] + "_report.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(report_lines) + "\n")
    for line in report_lines:
        print("BAKE_REPORT " + line)
    print("BAKE_REPORT glb_sha256=%s size=%d" % (sha, os.path.getsize(out_path)))
    print("RESULT: SUCCESS")


def run_bake(main):
    """Run a kit's main(); any exception prints its traceback and fails the run."""
    try:
        main()
    except Exception:
        traceback.print_exc()
        print("RESULT: FAILURE")
        sys.exit(1)

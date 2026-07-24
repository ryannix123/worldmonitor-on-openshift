#!/usr/bin/env python3
"""Render a Grype JSON report as a GitHub step-summary table.

Usage: scan-summary.py scan-amd64.json amd64
"""
import collections
import json
import sys

SEVERITY_ORDER = ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"]


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: scan-summary.py <grype.json> <arch>", file=sys.stderr)
        return 2
    path, arch = sys.argv[1], sys.argv[2]

    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"_Could not read scan results for {arch}: {exc}_\n")
        return 0

    counts = collections.Counter(
        match.get("vulnerability", {}).get("severity", "Unknown")
        for match in data.get("matches", [])
    )

    print(f"### Vulnerabilities ({arch})\n")
    if not counts:
        print("No findings in OS packages.\n")
    else:
        print("| Severity | Count |")
        print("|---|---|")
        for severity in SEVERITY_ORDER:
            if counts.get(severity):
                print(f"| {severity} | {counts[severity]} |")
        print()

    # The caveat belongs next to the numbers, not in a README nobody opens
    # while reading a build result.
    print(
        "_OS packages only. Grype does not scan the npm dependency graph, "
        "which for this app is substantial. A clean table here means the base "
        "image is clean, not that the application is._\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

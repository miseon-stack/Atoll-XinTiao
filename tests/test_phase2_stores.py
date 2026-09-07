#!/usr/bin/env python3
"""Compile and run Foundation-only Phase 2 persistence regression checks."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
FEATURE = ROOT / "DynamicIsland" / "features" / "LiveEarnings"


def test_phase2_stores() -> None:
    sources = [
        FEATURE / "LiveEarningsModels.swift",
        FEATURE / "Calendar" / "WorkCalendarModels.swift",
        FEATURE / "Calendar" / "HolidayCalendarStore.swift",
        FEATURE / "Calendar" / "EffectiveWorkScheduleResolver.swift",
        FEATURE / "Calendar" / "WorkdayOverrideStore.swift",
        FEATURE / "LiveEarningsEngine.swift",
        FEATURE / "History" / "DayEarningsModels.swift",
        FEATURE / "History" / "DayEarningsStore.swift",
        FEATURE / "History" / "DayEarningsFinalizer.swift",
        ROOT / "tests" / "phase2_store_regression.swift",
    ]
    with tempfile.TemporaryDirectory(prefix="atoll-phase2-store-") as directory:
        executable = Path(directory) / "phase2-store-regression"
        subprocess.run(["swiftc", *map(str, sources), "-o", str(executable)], cwd=ROOT, check=True)
        result = subprocess.run([str(executable)], cwd=ROOT, check=True, capture_output=True, text=True)
        assert "11 checks passed" in result.stdout


if __name__ == "__main__":
    test_phase2_stores()
    print("Phase 2 store regression runner: passed")

#!/usr/bin/env python3
"""Compile and run the Foundation-only Live Earnings regression suite."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
FEATURE = ROOT / "DynamicIsland" / "features" / "LiveEarnings"


def test_live_earnings_regression() -> None:
    with tempfile.TemporaryDirectory(prefix="atoll-live-earnings-") as directory:
        executable = Path(directory) / "live-earnings-regression"
        subprocess.run(
            [
                "swiftc",
                str(FEATURE / "LiveEarningsModels.swift"),
                str(FEATURE / "Calendar" / "WorkCalendarModels.swift"),
                str(FEATURE / "Calendar" / "HolidayCalendarStore.swift"),
                str(FEATURE / "Calendar" / "EffectiveWorkScheduleResolver.swift"),
                str(FEATURE / "LiveEarningsEngine.swift"),
                str(ROOT / "tests" / "live_earnings_regression.swift"),
                "-o",
                str(executable),
            ],
            cwd=ROOT,
            check=True,
        )
        result = subprocess.run([str(executable)], cwd=ROOT, check=True, capture_output=True, text=True)
        assert "29 checks passed" in result.stdout


if __name__ == "__main__":
    test_live_earnings_regression()
    print("Live Earnings regression runner: passed")

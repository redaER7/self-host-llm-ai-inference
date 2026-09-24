#!/usr/bin/env python3
"""NVML telemetry sampler — the 'in-band' lens for Practise 2.

Polls the first visible GPU via pynvml and writes one CSV row per interval:
timestamp, gpu_util %, mem_util %, temp C, sm_clock MHz, mem_clock MHz,
power W, power_limit W, vram_used MiB, vram_total MiB, throttle_reasons bitmask.

Run ON the GPU node (needs the NVIDIA driver + pynvml):
    pip install nvidia-ml-py
    python3 01_nvml_probe.py --interval 1 --duration 300 --out /tmp/nvml.csv

Compare its output against `nvidia-smi dmon` and the DCGM dashboard for the
same time window — that comparison IS the interview answer for
"NVML vs nvidia-smi vs DCGM".
"""
import argparse
import csv
import sys
import time
from datetime import datetime, timezone


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--duration", type=float, default=300.0)
    ap.add_argument("--out", default="/tmp/nvml.csv")
    ap.add_argument("--gpu", type=int, default=0)
    args = ap.parse_args()

    try:
        import pynvml
    except ImportError:
        print("ERROR: pynvml not installed. Run: pip install nvidia-ml-py", file=sys.stderr)
        return 1

    pynvml.nvmlInit()
    try:
        handle = pynvml.nvmlDeviceGetHandleByIndex(args.gpu)
        name = pynvml.nvmlDeviceGetName(handle)
        print(f"Sampling GPU {args.gpu}: {name} every {args.interval}s for {args.duration}s -> {args.out}")
        end = time.time() + args.duration
        with open(args.out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["ts_utc", "gpu_util_pct", "mem_util_pct", "temp_c",
                        "sm_clock_mhz", "mem_clock_mhz", "power_w", "power_limit_w",
                        "vram_used_mib", "vram_total_mib", "throttle_reasons"])
            while time.time() < end:
                util = pynvml.nvmlDeviceGetUtilizationRates(handle)
                mem = pynvml.nvmlDeviceGetMemoryInfo(handle)
                try:
                    throttle = pynvml.nvmlDeviceGetCurrentClocksThrottleReasons(handle)
                except pynvml.NVMLError:
                    throttle = 0
                w.writerow([
                    datetime.now(timezone.utc).isoformat(timespec="seconds"),
                    util.gpu, util.memory,
                    pynvml.nvmlDeviceGetTemperature(handle, pynvml.NVML_TEMPERATURE_GPU),
                    pynvml.nvmlDeviceGetClockInfo(handle, pynvml.NVML_CLOCK_SM),
                    pynvml.nvmlDeviceGetClockInfo(handle, pynvml.NVML_CLOCK_MEM),
                    round(pynvml.nvmlDeviceGetPowerUsage(handle) / 1000.0, 1),
                    round(pynvml.nvmlDeviceGetPowerManagementLimit(handle) / 1000.0, 1),
                    round(mem.used / 1024**2, 1), round(mem.total / 1024**2, 1),
                    throttle,
                ])
                f.flush()
                time.sleep(args.interval)
    finally:
        pynvml.nvmlShutdown()
    print("done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

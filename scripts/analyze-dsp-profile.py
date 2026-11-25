#!/usr/bin/env python3
"""Calculate a conservative CPU concurrency bound from native DSP samples."""

import argparse
import json
import re
import sys
import uuid
from pathlib import Path


def read_json(path):
    return json.loads(path.read_text())


def worker_range(value):
    try:
        start, end = (int(part, 0) for part in value.split(":", 1))
        if 0 <= start < end:
            return range(start, end)
    except ValueError:
        pass
    raise argparse.ArgumentTypeError("expected START:END with START < END")


def cpu_snapshot(sample):
    return {
        (row["id"], row["name"]): row["user_us"] + row["system_us"]
        for row in sample["threads"]
    }


def summarize(samples, workers):
    start, end = samples[0], samples[-1]
    before, after = cpu_snapshot(start), cpu_snapshot(end)
    deltas = [
        {"name": thread[1], "cpu_seconds": (after[thread] - before[thread]) / 1e6}
        for thread in sorted(workers.intersection(before, after))
    ]
    if any(row["cpu_seconds"] < 0 for row in deltas):
        raise ValueError("an original worker CPU counter went backward")

    # Each worker's actual measurement interval fits inside this envelope.
    wall_seconds = (end["end_ns"] - start["begin_ns"]) / 1e9
    initial_audio, final_audio = start["audio"], end["audio"]
    counters = ("audible_frames", "produced_frames", "callbacks", "underrun_frames")
    audio_delta = {key: final_audio[key] - initial_audio[key] for key in counters}
    if any(value < 0 for value in audio_delta.values()):
        raise ValueError("a PCM counter went backward")

    stable_audio = all(
        row["audio"]["running"] == 1 and row["audio"]["error"] == 0
        and row["audio"]["rate"] == initial_audio["rate"]
        and row["audio"]["buffer_frames"] == initial_audio["buffer_frames"]
        for row in samples
    )
    return {
        "wall_seconds": wall_seconds,
        "original_worker_cpu": deltas,
        "core_equivalent_lower_bound": sum(row["cpu_seconds"] for row in deltas) / wall_seconds,
        "coherent_route": stable_audio,
        "audio_delta": audio_delta,
    }


def analyze(capture, before, after, nonce, offsets):
    if uuid.UUID(capture["nonce"]) != nonce:
        raise ValueError("capture nonce does not match the request")
    if capture["pid"] != before["pid"] or capture["pid"] != after["pid"]:
        raise ValueError("capture and JIT endpoint PIDs differ")
    if before["error"] or after["error"] or not before["finalizations"]:
        raise ValueError("no valid original JIT finalization state")
    for key in ("finalizations", "finalized_bytes"):
        if before[key] != after[key]:
            raise ValueError(f"JIT {key} changed during capture")

    samples = capture["samples"]
    if len(samples) < 2:
        raise ValueError("at least two sample sweeps are required")
    last_end = 0
    for sample in samples:
        if not last_end < sample["begin_ns"] <= sample["end_ns"]:
            raise ValueError("sample sweeps are out of order or overlap")
        last_end = sample["end_ns"]

    workers = {
        (row["id"], row["name"])
        for sample in samples
        for row in sample["threads"]
        if re.fullmatch(r"audio-[0-9]+", row["name"])
        and any(offset in offsets for offset in row["engine_frames"])
    }
    full = summarize(samples, workers)
    adjacent = [
        summarize(samples[index:index + 2], workers)
        for index in range(len(samples) - 1)
    ]
    clean_active = [
        window for window in adjacent
        if window["coherent_route"] and window["audio_delta"]["audible_frames"] > 0
        and window["audio_delta"]["underrun_frames"] == 0
    ]
    return {
        "sample_count": len(samples),
        "sample_rate": samples[0]["audio"]["rate"],
        "buffer_frames": samples[0]["audio"]["buffer_frames"],
        "jit_finalizations": after["finalizations"],
        "jit_finalized_bytes": after["finalized_bytes"],
        "full_window": full,
        "highest_clean_active_adjacent_window": max(
            clean_active, key=lambda row: row["core_equivalent_lower_bound"], default=None
        ),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("jit_before", type=Path)
    parser.add_argument("jit_after", type=Path)
    parser.add_argument("--nonce", type=uuid.UUID, required=True, help="UUID used to request this capture")
    parser.add_argument("--worker-range", type=worker_range, required=True,
                        help="half-open original worker image offset range for the selected engine build")
    args = parser.parse_args()
    try:
        result = analyze(
            read_json(args.capture), read_json(args.jit_before), read_json(args.jit_after),
            args.nonce, args.worker_range,
        )
    except (OSError, KeyError, TypeError, ValueError) as error:
        parser.exit(2, f"Unable to analyze capture: {error}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "evdev"
# ]
# ///

from pathlib import Path

import evdev

ENV_VAR = "LOCAL_SPEECH_KEYBOARD_DEVICE"
ENV_FILE = Path.home() / ".config" / "local-speech" / "dictation.env"


def keyboard_candidates() -> list[tuple[str, str]]:
    candidates: list[tuple[str, str]] = []

    for path in sorted(Path("/dev/input/by-id").glob("*-kbd")):
        try:
            dev = evdev.InputDevice(str(path))
        except OSError:
            continue
        candidates.append((str(path), dev.name))

    if candidates:
        return candidates

    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
            keys = set(dev.capabilities().get(evdev.ecodes.EV_KEY, []))
        except OSError:
            continue

        if evdev.ecodes.KEY_ENTER in keys and evdev.ecodes.KEY_A in keys:
            candidates.append((path, dev.name))

    return candidates


def read_env_file() -> dict[str, str]:
    values: dict[str, str] = {}
    if not ENV_FILE.exists():
        return values

    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def write_env_file(device_path: str) -> None:
    values = read_env_file()
    values[ENV_VAR] = device_path

    ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# local-speech runtime configuration"]
    lines.extend(f"{key}={values[key]}" for key in sorted(values))
    ENV_FILE.write_text("\n".join(lines) + "\n")


def main() -> int:
    candidates = keyboard_candidates()
    current = read_env_file().get(ENV_VAR)

    if not candidates:
        print("No keyboard candidates found.")
        return 1

    print("Available keyboard devices:\n")
    for idx, (path, name) in enumerate(candidates, start=1):
        marker = " (current)" if current == path else ""
        print(f"{idx:>2}. {name}")
        print(f"    {path}{marker}")

    print()
    choice = input("Select keyboard device number (blank to cancel): ").strip()
    if not choice:
        print("No changes made.")
        return 0

    try:
        selected = candidates[int(choice) - 1]
    except (ValueError, IndexError):
        print("Invalid selection.")
        return 1

    write_env_file(selected[0])
    print(f"Saved {ENV_VAR}={selected[0]} to {ENV_FILE}")
    print("Restart dictation after changing the device.")
    return 0


raise SystemExit(main())

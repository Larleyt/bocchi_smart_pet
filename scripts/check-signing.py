#!/usr/bin/python3
from __future__ import annotations

import datetime
import pathlib
import subprocess
import sys


PROJECT_ROOT = pathlib.Path(__file__).resolve().parent.parent
IDENTIFIER = "local.bocchi.smartpet"


def run(*args: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, capture_output=True, text=True, check=False, timeout=30)
    if result.returncode != expected:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(
            f"{' '.join(args[:2])} exited {result.returncode}, expected {expected}"
            + (f": {detail}" if detail else "")
        )
    return result


def designated_requirement(path: pathlib.Path) -> str:
    result = run("/usr/bin/codesign", "-d", "-r-", str(path))
    output = result.stdout + result.stderr
    prefix = "designated => "
    for line in output.splitlines():
        line = line.removeprefix("# ")
        if line.startswith(prefix):
            requirement = line.removeprefix(prefix).strip()
            if requirement:
                return requirement
    raise RuntimeError(f"codesign did not return a designated requirement for {path.name}")


def cdhash(path: pathlib.Path) -> str:
    output = run("/usr/bin/codesign", "-d", "--verbose=4", str(path)).stderr
    for line in output.splitlines():
        if line.startswith("CDHash="):
            value = line.removeprefix("CDHash=").strip()
            if value:
                return value
    raise RuntimeError(f"codesign did not return a CDHash for {path.name}")


def verify_requirement(path: pathlib.Path, requirement: str) -> bool:
    result = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", f"-R={requirement}", str(path)],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    return result.returncode == 0


def main() -> int:
    timestamp = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=5)))
    fixture_dir = PROJECT_ROOT / "artifacts" / timestamp.strftime("%Y%m%d_%H%M%S_signing_check")
    fixture_dir.mkdir(parents=True)

    sources = {
        "a": "int main(void) { return 11; }\n",
        "b": "int main(void) { return 22; }\n",
        "foreign": "int main(void) { return 33; }\n",
    }
    binaries: dict[str, pathlib.Path] = {}
    for name, source in sources.items():
        source_path = fixture_dir / f"{name}.c"
        binary_path = fixture_dir / name
        source_path.write_text(source, encoding="utf-8")
        run("/usr/bin/xcrun", "clang", str(source_path), "-o", str(binary_path))
        binaries[name] = binary_path

    checks = 0

    def check(condition: bool, message: str) -> None:
        nonlocal checks
        if not condition:
            raise RuntimeError(message)
        checks += 1
        print(f"PASS: {message}")

    for name in ("a", "b", "foreign"):
        run(
            "/usr/bin/codesign",
            "--force",
            "--sign",
            "-",
            "--identifier",
            IDENTIFIER,
            "--timestamp=none",
            str(binaries[name]),
        )

    ad_hoc_requirement = designated_requirement(binaries["a"])
    check(
        verify_requirement(binaries["a"], ad_hoc_requirement),
        "ad-hoc requirement accepts its original binary",
    )
    check(
        not verify_requirement(binaries["b"], ad_hoc_requirement),
        "ad-hoc requirement rejects a different binary with the same identifier",
    )

    signer = PROJECT_ROOT / "scripts" / "sign-app.py"
    for name in ("a", "b"):
        run("/usr/bin/python3", str(signer), str(binaries[name]))

    requirement_a = designated_requirement(binaries["a"])
    requirement_b = designated_requirement(binaries["b"])
    check(cdhash(binaries["a"]) != cdhash(binaries["b"]), "different binaries have different CDHashes")
    check(requirement_a == requirement_b, "project-signed binaries have the same designated requirement")
    check(
        designated_requirement(PROJECT_ROOT / "dist" / "Bocchi Smart Pet.app") == requirement_a,
        "packaged app uses the persistent project requirement",
    )
    check(
        verify_requirement(binaries["b"], requirement_a),
        "the first project requirement accepts the second project-signed binary",
    )
    check(
        not verify_requirement(binaries["foreign"], requirement_a),
        "the project requirement rejects a foreign ad-hoc signer with the same identifier",
    )

    run("/usr/bin/python3", str(signer), str(binaries["b"]))
    check(
        designated_requirement(binaries["b"]) == requirement_b,
        "re-signing preserves the designated requirement",
    )

    print(f"SIGNING-CHECK RESULT: PASS ({checks} checks, 0 failed)")
    print(f"Artifacts: {fixture_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"SIGNING-CHECK RESULT: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)

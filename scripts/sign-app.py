#!/usr/bin/python3
"""Keep this local app's signing requirement stable across rebuilds."""

import fcntl
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
STATE = ROOT / ".local-signing"
KEYCHAIN = STATE / "identity.keychain-db"
CERTIFICATE = STATE / "certificate.pem"
PASSWORD = STATE / "password"
IDENTIFIER = "local.bocchi.smartpet"


def run(arguments):
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{Path(arguments[0]).name} timed out") from None
    if result.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def remove_own_search_entry():
    entries = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
    remaining = [entry for entry in entries if Path(entry).resolve() != KEYCHAIN.resolve()]
    if remaining != entries:
        run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *remaining])


def add_own_search_entry():
    entries = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
    if not any(Path(entry).resolve() == KEYCHAIN.resolve() for entry in entries):
        run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", str(KEYCHAIN), *entries])


def initialize():
    if CERTIFICATE.exists():
        if not KEYCHAIN.is_file() or not PASSWORD.is_file():
            raise RuntimeError("Local signing files are incomplete; recover the existing identity before rebuilding.")
        return
    if KEYCHAIN.exists() or PASSWORD.exists():
        raise RuntimeError("Local signing setup was interrupted; inspect .local-signing before retrying.")
    password = secrets.token_hex(32)
    PASSWORD.write_text(password)
    with tempfile.TemporaryDirectory(dir=STATE) as directory:
        temporary = Path(directory)
        config = temporary / "openssl.cnf"
        key = temporary / "private.pem"
        certificate = temporary / "certificate.pem"
        archive = temporary / "identity.p12"
        config.write_text("""[req]
distinguished_name = name
x509_extensions = codesign
prompt = no
[name]
CN = Bocchi Smart Pet Local Signing
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
""")
        run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-sha256", "-days", "3650", "-config", str(config), "-keyout", str(key),
             "-out", str(certificate)])
        run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key),
             "-in", str(certificate), "-out", str(archive), "-passout", f"file:{PASSWORD}"])
        run(["/usr/bin/security", "create-keychain", "-p", password, str(KEYCHAIN)])
        run(["/usr/bin/security", "import", str(archive), "-k", str(KEYCHAIN),
             "-P", password, "-x", "-T", "/usr/bin/codesign"])
        run(["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
             "-s", "-k", password, str(KEYCHAIN)])
        certificate.replace(CERTIFICATE)


def main():
    if len(sys.argv) != 2:
        raise RuntimeError("Usage: sign-app.py <existing code path>")
    target = Path(sys.argv[1]).resolve(strict=True)
    os.umask(0o077)
    STATE.mkdir(mode=0o700, exist_ok=True)
    with (STATE / "setup.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            initialize()
            add_own_search_entry()
            password = PASSWORD.read_text().strip()
            run(["/usr/bin/security", "unlock-keychain", "-p", password, str(KEYCHAIN)])
            fingerprint = run(["/usr/bin/openssl", "x509", "-in", str(CERTIFICATE),
                               "-noout", "-fingerprint", "-sha1"]).split("=", 1)[1].replace(":", "")
            requirement = f'designated => identifier "{IDENTIFIER}" and certificate leaf = H"{fingerprint}"'
            run(["/usr/bin/codesign", "--force", "--sign", fingerprint,
                 "--identifier", IDENTIFIER, "--keychain", str(KEYCHAIN),
                 "--timestamp=none", "--requirements", "=" + requirement,
                 str(target)])
            run(["/usr/bin/codesign", "--verify", "--strict", str(target)])
            print(f"Signed with persistent local certificate: {target.name}")
        finally:
            try:
                remove_own_search_entry()
            finally:
                if KEYCHAIN.exists():
                    run(["/usr/bin/security", "lock-keychain", str(KEYCHAIN)])


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"Signing failed: {error}", file=sys.stderr)
        sys.exit(1)

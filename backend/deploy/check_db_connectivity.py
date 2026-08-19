"""Diagnose a PostgreSQL/Supabase endpoint before attempting a migration.

Separating "the host is unreachable" from "the credentials are wrong" saves a
lot of guessing: a hosting panel URL (https dashboard) is not the same thing as
a database endpoint, and this prints which of the two you actually have.

Usage:
    python backend/deploy/check_db_connectivity.py <host> [port ...]
    python backend/deploy/check_db_connectivity.py --url        # uses DATABASE_URL
"""
from __future__ import annotations

import os
import socket
import sys
from urllib.parse import urlparse

# 5432 = direct PostgreSQL, 6543 = Supabase pooler, 443 = web dashboard.
# 443 is probed only to distinguish "wrong kind of URL" from "host down"; it is
# never accepted as a database endpoint.
DB_PORTS = (5432, 6543)
DEFAULT_PORTS = DB_PORTS + (443,)
TIMEOUT_SECONDS = 6



def probe(host: str, ports: tuple[int, ...]) -> int:
    try:
        addresses = sorted({info[4][0] for info in socket.getaddrinfo(host, None)})
        print(f"DNS {host} -> {', '.join(addresses)}")
    except OSError as exc:
        print(f"DNS {host} -> FAILED: {exc}")
        print("The name does not resolve: the host is wrong, or it is internal-only.")
        return 1

    reachable = []
    for port in ports:
        sock = socket.socket()
        sock.settimeout(TIMEOUT_SECONDS)
        try:
            sock.connect((host, port))
            print(f"port {port}: OPEN")
            reachable.append(port)
        except OSError as exc:
            print(f"port {port}: closed/filtered ({type(exc).__name__})")
        finally:
            sock.close()

    db_reachable = [port for port in reachable if port in DB_PORTS]
    if not db_reachable:
        # An open 443 with closed 5432/6543 is the common Sohobcom/Supabase case:
        # you were given the dashboard address, not the database endpoint.
        if 443 in reachable:
            print(
                "Only 443 (web) answered: this is the hosting dashboard, not a\n"
                "PostgreSQL endpoint. Open the panel and copy the connection\n"
                "string (its host usually differs, e.g. db.<ref>...), or ask the\n"
                "provider to expose 5432/6543 for external access."
            )
        else:
            print("No port answered: the service may be down or firewalled.")
        return 1
    print(f"Database port reachable: {db_reachable}.")
    print("Next: run `alembic upgrade head` with DATABASE_URL set.")
    return 0



def main() -> int:
    args = sys.argv[1:]
    if args and args[0] == "--url":
        raw = (os.getenv("DATABASE_URL") or "").strip()
        if not raw:
            print("DATABASE_URL is not set")
            return 2
        parsed = urlparse(raw)
        if not parsed.hostname:
            print(f"cannot parse a host out of DATABASE_URL: {raw!r}")
            return 2
        return probe(parsed.hostname, (parsed.port or 5432,))
    if not args:
        print(__doc__)
        return 2
    host = args[0].replace("https://", "").replace("http://", "").rstrip("/")
    ports = tuple(int(value) for value in args[1:]) or DEFAULT_PORTS
    return probe(host, ports)


if __name__ == "__main__":
    raise SystemExit(main())

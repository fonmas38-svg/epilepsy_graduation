"""Inspect local SQLite database and sync data to Supabase Cloud via REST API."""
import sqlite3
import json
import os
import urllib.request
import urllib.error
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
SQLITE_PATH = BACKEND_DIR / "data" / "epilepsy.db"

SUPABASE_URL = os.getenv("SUPABASE_URL", "https://vigxfzfalfvenepuoelz.supabase.co")
SERVICE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "sb_secret_KSXdt6bZPwgiYojvM4f7GQ_k1a6q83X")

def get_sqlite_tables_and_counts():
    conn = sqlite3.connect(SQLITE_PATH)
    conn.row_factory = sqlite3.Row
    c = conn.cursor()
    c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    tables = [r[0] for r in c.fetchall()]
    stats = {}
    for t in tables:
        cnt = c.execute(f'SELECT count(*) FROM "{t}"').fetchone()[0]
        stats[t] = cnt
    conn.close()
    return stats

def delete_matching(table_name, filter_param):
    url = f"{SUPABASE_URL}/rest/v1/{table_name}?{filter_param}"
    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
    }
    req = urllib.request.Request(url, headers=headers, method="DELETE")
    try:
        with urllib.request.urlopen(req) as resp:
            pass
    except Exception as e:
        print(f"  Note: cleanup for {table_name}: {e}")

def sync_table(conn, table_name, bool_cols=None, batch_size=100, on_conflict=None):
    c = conn.cursor()
    c.execute(f'SELECT * FROM "{table_name}"')
    col_names = [d[0] for d in c.description]
    rows = c.fetchall()
    if not rows:
        print(f"  - {table_name}: 0 rows to sync")
        return 0

    records = []
    for r in rows:
        rec = dict(zip(col_names, r))
        if bool_cols:
            for b in bool_cols:
                if b in rec and rec[b] is not None:
                    rec[b] = bool(rec[b])
        records.append(rec)

    url = f"{SUPABASE_URL}/rest/v1/{table_name}"
    if on_conflict:
        url += f"?on_conflict={on_conflict}"

    headers = {
        "apikey": SERVICE_KEY,
        "Authorization": f"Bearer {SERVICE_KEY}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=minimal"
    }

    total_synced = 0
    for i in range(0, len(records), batch_size):
        chunk = records[i:i + batch_size]
        data = json.dumps(chunk).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req) as resp:
                total_synced += len(chunk)
        except urllib.error.HTTPError as e:
            err_msg = e.read().decode("utf-8")
            print(f"  [ERROR] {table_name} chunk {i}: HTTP {e.code} - {err_msg}")
            raise e
        except Exception as e:
            print(f"  [ERROR] {table_name}: {e}")
            raise e

    print(f"  [OK] {table_name}: synced {total_synced} rows successfully")
    return total_synced



def main():
    print("=== 1. Checking Local SQLite Database ===")
    stats = get_sqlite_tables_and_counts()
    for t, cnt in stats.items():
        print(f"  {t}: {cnt} rows")

    print("\n=== 2. Migrating Data to Supabase Cloud ===")
    conn = sqlite3.connect(SQLITE_PATH)

    # 1. Users: remove placeholder admin seed, then sync real users
    delete_matching("users", "username=eq.admin")
    sync_table(conn, "users", bool_cols=["disabled"], on_conflict="username")


    # 2. Patients
    sync_table(conn, "patients")

    # 3. Assignments
    sync_table(conn, "assignments")

    # 4. Caregiver Links
    sync_table(conn, "caregiver_links")

    # 5. Devices (boolean: disabled)
    sync_table(conn, "devices", bool_cols=["disabled"])

    # 6. Push Tokens
    sync_table(conn, "push_tokens")

    # 7. Audit Logs
    sync_table(conn, "audit_logs")

    # 8. Readings
    sync_table(conn, "readings", batch_size=100)

    # 9. Assessments
    sync_table(conn, "assessments", batch_size=100)

    # 10. Alerts (boolean: acknowledged)
    sync_table(conn, "alerts", bool_cols=["acknowledged"])

    # 11. Alert Acknowledgments
    sync_table(conn, "alert_acknowledgments")

    # 12. Outcomes
    sync_table(conn, "outcomes")

    # 13. Alert Outbox
    sync_table(conn, "alert_outbox")

    # 14. Store Imports
    sync_table(conn, "store_imports")

    # 15. Messages
    sync_table(conn, "messages")

    conn.close()
    print("\n=== 3. Migration Complete! ===")

if __name__ == "__main__":
    main()


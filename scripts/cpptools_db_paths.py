"""Show which folders a VS Code C/C++ extension browse database (.BROWSE.VC.DB) indexed.

Read-only: opens the SQLite file immutable, so it never touches the -wal/-shm files.
A database of tens of GB usually means build output, a Unity Library/Build folder or a
virtualenv got indexed; the top folders tell you what to put in C_Cpp.files.exclude.

usage: python -I cpptools_db_paths.py <path-to-.BROWSE.VC.DB> [more ...] [--depth 5] [--top 12]
"""
import argparse
import collections
import pathlib
import sqlite3

PATH_COLUMNS = ("name", "path", "filename", "file_name", "fullpath")


def summarize(db: str, depth: int, top: int) -> None:
    uri = pathlib.Path(db).resolve().as_uri() + "?mode=ro&immutable=1"
    con = sqlite3.connect(uri, uri=True)
    try:
        # Only touch the files table: other tables use FTS options older SQLite builds reject.
        cols = [r[1] for r in con.execute("pragma table_info('files')")]
        col = next((c for c in cols if c.lower() in PATH_COLUMNS), None)
        if col is None:
            print(f"== {db}\n   no files table with a path column (columns: {cols})")
            return
        counts = collections.Counter()
        total = 0
        for (p,) in con.execute(f"select {col} from files"):
            total += 1
            counts["\\".join(str(p).replace("/", "\\").split("\\")[:depth])] += 1
        print(f"== {db}\n   {total:,} indexed files; top folders:")
        for k, v in counts.most_common(top):
            print(f"   {v:>9,}  {k}")
    finally:
        con.close()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("db", nargs="+", help=".BROWSE.VC.DB file(s)")
    ap.add_argument("--depth", type=int, default=5, help="path components to group by (default 5)")
    ap.add_argument("--top", type=int, default=12, help="folders to show per database (default 12)")
    args = ap.parse_args()
    for db in args.db:
        summarize(db, args.depth, args.top)


if __name__ == "__main__":
    main()

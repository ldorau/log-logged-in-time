#!/usr/bin/env python3
"""Export log-history (browser History SQLite) to semicolon CSV."""
from __future__ import print_function

import argparse
import csv
import os
import shutil
import sqlite3
import sys
import tempfile
from datetime import date, datetime, timedelta


EXPORT_SQL = """
SELECT
  datetime(v.visit_time / 1000000 - 11644473600, 'unixepoch', 'localtime') AS visit_time_local,
  u.url AS url,
  u.title AS title,
  v.visit_duration AS visit_duration_us,
  v.transition AS transition,
  v.from_visit AS from_visit,
  u.visit_count AS visit_count,
  u.typed_count AS typed_count,
  u.hidden AS hidden,
  u.id AS url_id,
  v.id AS visit_id
FROM visits v
JOIN urls u ON u.id = v.url
WHERE (? IS NULL OR v.visit_time >= ?)
ORDER BY v.visit_time ASC
"""

FIELDNAMES = [
    'visit_time_local',
    'url',
    'title',
    'visit_duration',
    'transition',
    'from_visit',
    'visit_count',
    'typed_count',
    'hidden',
    'url_id',
    'visit_id',
]


def open_readonly_copy(src_path):
    fd, tmp = tempfile.mkstemp(prefix='log-history-', suffix='.sqlite')
    os.close(fd)
    shutil.copy2(src_path, tmp)
    # Also copy -wal/-shm when present so a hot copy stays consistent.
    for suffix in ('-wal', '-shm'):
        side = src_path + suffix
        if os.path.isfile(side):
            shutil.copy2(side, tmp + suffix)
    con = sqlite3.connect('file:{0}?mode=ro'.format(tmp.replace('\\', '/')), uri=True)
    con.row_factory = sqlite3.Row
    return con, tmp


def cleanup_tmp(tmp):
    for path in (tmp, tmp + '-wal', tmp + '-shm'):
        try:
            if os.path.isfile(path):
                os.remove(path)
        except OSError:
            pass


def quote_none(value):
    if value is None:
        return ''
    return value


def format_duration_hhmmss(duration_us):
    """History visit_duration is microseconds; emit HH:MM:SS (hours may exceed 24)."""
    try:
        micros = int(duration_us or 0)
    except (TypeError, ValueError):
        micros = 0
    if micros < 0:
        micros = 0
    total_seconds = micros // 1000000
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    seconds = total_seconds % 60
    return '{0:02d}:{1:02d}:{2:02d}'.format(hours, minutes, seconds)


def parse_start_date(text):
    """Parse YYYY-MM-DD as a local calendar date."""
    try:
        return datetime.strptime(text, '%Y-%m-%d').date()
    except ValueError:
        raise argparse.ArgumentTypeError(
            'Start date must be YYYY-MM-DD (local), got: {0}'.format(text)
        )


def local_day_start_history_micros(day):
    """
    History visit_time: microseconds since 1601-01-01 UTC.
    Convert local midnight of day -> History micros via local timestamp().
    """
    local_midnight = datetime(day.year, day.month, day.day, 0, 0, 0)
    unix_seconds = local_midnight.timestamp()
    return int((unix_seconds + 11644473600) * 1000000)


def resolve_start_bound(start_date, previous_days):
    if start_date is not None and previous_days is not None:
        raise SystemExit('Use only one of --start-date or --previous-days.')
    if start_date is None and previous_days is None:
        return None, None
    if previous_days is not None:
        if previous_days < 1:
            raise SystemExit('--previous-days must be >= 1.')
        # Include today and the previous (N-1) local calendar days.
        start = date.today() - timedelta(days=(previous_days - 1))
        label = 'previous_days={0} (from {1} local)'.format(previous_days, start.isoformat())
    else:
        start = start_date
        label = 'start_date={0} local'.format(start.isoformat())
    return local_day_start_history_micros(start), label


def main(argv):
    parser = argparse.ArgumentParser(description='Convert log-history SQLite to CSV.')
    parser.add_argument('--input', required=True, help='Path to log-history SQLite file')
    parser.add_argument('--output', required=True, help='Output CSV path')
    parser.add_argument('--separator', default=';', help='CSV field separator (default: ;)')
    parser.add_argument(
        '--start-date',
        type=parse_start_date,
        default=None,
        help='Include visits from this local calendar day onward (YYYY-MM-DD)',
    )
    parser.add_argument(
        '--previous-days',
        type=int,
        default=None,
        help='Include visits from the last N local calendar days (including today)',
    )
    args = parser.parse_args(argv)

    src = os.path.abspath(args.input)
    out = os.path.abspath(args.output)
    if not os.path.isfile(src):
        print('Input not found: {0}'.format(src), file=sys.stderr)
        return 2

    start_micros, range_label = resolve_start_bound(args.start_date, args.previous_days)

    con = None
    tmp = None
    try:
        con, tmp = open_readonly_copy(src)
        cur = con.cursor()
        # Fail early with a clear message when schema is unexpected.
        tables = {
            row[0]
            for row in cur.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
        if 'urls' not in tables or 'visits' not in tables:
            print(
                'Not a History DB (missing urls/visits). Tables: {0}'.format(
                    ', '.join(sorted(tables)) or '(none)'
                ),
                file=sys.stderr,
            )
            return 3

        rows = cur.execute(EXPORT_SQL, (start_micros, start_micros)).fetchall()

        out_dir = os.path.dirname(out)
        if out_dir and not os.path.isdir(out_dir):
            os.makedirs(out_dir)

        with open(out, 'w', newline='', encoding='utf-8') as fh:
            writer = csv.DictWriter(
                fh,
                fieldnames=FIELDNAMES,
                delimiter=args.separator,
                quotechar='"',
                quoting=csv.QUOTE_MINIMAL,
                lineterminator='\n',
            )
            writer.writeheader()
            for row in rows:
                item = {k: quote_none(row[k]) for k in FIELDNAMES if k != 'visit_duration'}
                item['visit_duration'] = format_duration_hhmmss(row['visit_duration_us'])
                writer.writerow(item)

        if range_label:
            print('Filter: {0}'.format(range_label))
        else:
            print('Filter: all visits')
        print('Wrote {0} visit row(s) to {1}'.format(len(rows), out))
        return 0
    finally:
        if con is not None:
            con.close()
        if tmp is not None:
            cleanup_tmp(tmp)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

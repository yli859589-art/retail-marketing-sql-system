import os
from contextlib import contextmanager
import pymysql
from pymysql.cursors import DictCursor

def config():
    return dict(host=os.getenv('DB_HOST', '127.0.0.1'), port=int(os.getenv('DB_PORT', '3308')),
                user=os.getenv('DB_USER', 'root'), password=os.getenv('DB_PASSWORD', ''),
                database=os.getenv('DB_NAME', 'retail_marketing_codex'), charset='utf8mb4',
                cursorclass=DictCursor, autocommit=True)

@contextmanager
def cursor():
    conn = pymysql.connect(**config())
    try:
        with conn.cursor() as cur:
            yield cur
    finally:
        conn.close()

def one(sql, params=()):
    with cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()

def all_rows(sql, params=()):
    with cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()

def scalar(sql, params=(), key=None):
    row = one(sql, params)
    return None if row is None else (row[key] if key else next(iter(row.values())))

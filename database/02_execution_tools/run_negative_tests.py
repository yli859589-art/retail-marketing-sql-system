"""逐条执行 T-01..T-27；每条均在独立事务中回滚，绝不污染业务数据。"""
from __future__ import annotations
import csv, os, re, sys
from pathlib import Path
import pymysql
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
load_dotenv(ROOT.parent / ".env")
SQL_FILE = ROOT / "01_fixed_sql" / "04_negative_tests.sql"
OUT = ROOT / "04_test_results" / "negative_tests_results.csv"

def connect():
    return pymysql.connect(host=os.getenv("MYSQL_HOST", "127.0.0.1"),
        port=int(os.getenv("MYSQL_PORT", "3307")), user=os.getenv("MYSQL_USER", "root"),
        password=os.getenv("MYSQL_PASSWORD", ""), database=os.getenv("MYSQL_DATABASE", "retail_marketing_codex"),
        charset="utf8mb4", autocommit=False)

def cases(text: str):
    matches = list(re.finditer(r"(?m)^-- T-(\d{2}) .*?$", text))
    for i, match in enumerate(matches):
        section = text[match.end():matches[i + 1].start() if i + 1 < len(matches) else len(text)]
        sql_lines = [line for line in section.splitlines() if not line.lstrip().startswith("--")]
        statement = "\n".join(sql_lines).strip()
        if statement.endswith(";"):
            statement = statement[:-1]
        expected = "1062" if int(match.group(1)) in {1,2,4,5,6,23,24,25} else ("1048" if match.group(1)=="03" else ("1452" if 7 <= int(match.group(1)) <= 10 else "3819"))
        yield f"T-{match.group(1)}", match.group(0)[3:], expected, statement

def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    rows=[]; conn=connect()
    try:
      with conn.cursor() as cur:
        for tid, target, expected, sql in cases(SQL_FILE.read_text(encoding="utf-8-sig")):
            try:
                cur.execute(sql); conn.rollback()
                rows.append([tid,target,expected,"","", "FAIL", "违规 SQL 意外执行成功"])
            except pymysql.MySQLError as exc:
                conn.rollback(); code=str(exc.args[0]); message=str(exc.args[1])
                passed = code == expected
                rows.append([tid,target,expected,code,message,"PASS" if passed else "FAIL", "" if passed else "错误类型不符"])
    finally: conn.close()
    with OUT.open("w",newline="",encoding="utf-8-sig") as f:
        w=csv.writer(f); w.writerow(["测试编号","目标","预期错误码","实际错误码","实际错误信息","状态","备注"]); w.writerows(rows)
    failures=sum(r[5]!="PASS" for r in rows)
    print(f"{len(rows)} 项测试完成；PASS={len(rows)-failures}, FAIL={failures}")
    return 1 if failures else 0
if __name__ == "__main__": raise SystemExit(main())

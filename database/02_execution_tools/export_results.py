"""运行审计、业务规则和演示 SQL，将每个结果集真实导出为 UTF-8 CSV。"""
from __future__ import annotations
import csv, os, time
from pathlib import Path
import pymysql
from pymysql.constants import CLIENT

ROOT=Path(__file__).resolve().parents[1]; SQL=ROOT/"01_fixed_sql"
def conn():
 return pymysql.connect(host=os.getenv("MYSQL_HOST","127.0.0.1"),port=int(os.getenv("MYSQL_PORT","3307")),
  user=os.getenv("MYSQL_USER","root"),password=os.getenv("MYSQL_PASSWORD",""),database=os.getenv("MYSQL_DATABASE","retail_marketing_codex"),
  charset="utf8mb4",autocommit=True,client_flag=CLIENT.MULTI_STATEMENTS,cursorclass=pymysql.cursors.DictCursor)
def write(path, rows):
 fields=sorted({k for r in rows for k in r}) or ["result"]
 path.parent.mkdir(parents=True,exist_ok=True)
 with path.open("w",newline="",encoding="utf-8-sig") as f:
  w=csv.DictWriter(f,fieldnames=fields,extrasaction="ignore");w.writeheader();w.writerows(rows)
def collect(file):
 results=[]; started=time.perf_counter()
 with conn() as c:
  with c.cursor() as cur:
   cur.execute(file.read_text(encoding="utf-8-sig"))
   while True:
    if cur.description: results.append(cur.fetchall())
    if not cur.nextset(): break
 return results,time.perf_counter()-started
def main():
 integrity,t1=collect(SQL/"05_verify_integrity.sql")
 flattened=[]
 for i, rows in enumerate(integrity,1):
  for r in rows: flattened.append({"检查序号":i,**r})
 write(ROOT/"04_test_results"/"integrity_audit.csv",flattened)
 # 仅将明确代表违规数量的统计列和直接异常行写入 failures；不能再无条件写空文件。
 def positive(value):
  try: return float(value) > 0
  except (TypeError, ValueError): return False
 failures=[row for row in flattened if any(positive(row.get(k)) for k in ("异常行数","孤儿行数","重复组数"))]
 # 直接列出业务主键的“期望 0 行”结果集没有汇总列时，也必须保留。
 failures += [row for row in flattened if any(k in row for k in ("order_id","instance_id","member_id")) and row not in failures]
 write(ROOT/"04_test_results"/"integrity_failures.csv",failures)
 rules,t2=collect(SQL/"06_br_validation.sql")
 flattened=[]
 for i, rows in enumerate(rules,1):
  for r in rows: flattened.append({"检查序号":i,**r})
 write(ROOT/"04_test_results"/"business_rules_validation.csv",flattened)
 demos,t3=collect(SQL/"07_demo_queries.sql")
 names=["D-1_coupon_effect","D-2_coupon_vs_no_coupon","D-3_price_snapshot","D-4_rfm","D-5_repurchase","D-6_strategy"]
 for name,rows in zip(names,demos[:6]): write(ROOT/"08_demo_outputs"/(name+".csv"),rows)
 write(ROOT/"08_demo_outputs"/"D-7_quality_audit.csv", [dict({"检查序号":1}, **row) for row in demos[6]])
 write(ROOT/"08_demo_outputs"/"D-8_index_comparison.csv", [dict({"计划编号":i+1}, **row) for i, rows in enumerate(demos[7:9]) for row in rows])
 print(f"导出完成：完整性 {len(integrity)} 结果集/{t1:.2f}s，业务规则 {len(rules)} 个/{t2:.2f}s，演示 {len(demos)} 个/{t3:.2f}s")
if __name__=="__main__":main()

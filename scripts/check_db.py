import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.db import all_rows, scalar
def main():
    expected={'member','member_level','category','product','sales_order','order_item','coupon_template','coupon_instance'}
    tables={r['Tables_in_retail_marketing_codex'] for r in all_rows('SHOW TABLES')}
    missing=expected-tables
    if missing: raise RuntimeError(f'数据库缺少核心表：{sorted(missing)}')
    print('数据库连接正常；八张核心表齐全。')
    for table in ('member','sales_order','order_item','coupon_instance'):
        print(f'{table}: {scalar("SELECT COUNT(*) FROM `"+table+"`")}')
if __name__=='__main__': main()

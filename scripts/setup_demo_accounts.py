"""执行增量 migration，并创建/更新两个演示账号。不会改动任何业务记录。"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from werkzeug.security import generate_password_hash
from app.db import cursor, one

ROOT=Path(__file__).resolve().parents[1]
ADMIN_PASSWORD='Retail@2026'
CUSTOMER_PASSWORD='Retail@2026'

def main():
    migration=(ROOT/'sql'/'migrations'/'001_user_account.sql').read_text(encoding='utf-8')
    with cursor() as cur:
        cur.execute(migration)
        demo=one('''SELECT m.member_id FROM member m WHERE EXISTS(SELECT 1 FROM sales_order o WHERE o.member_id=m.member_id AND o.order_status='已完成') AND EXISTS(SELECT 1 FROM coupon_instance c WHERE c.member_id=m.member_id) ORDER BY m.total_amount DESC LIMIT 1''')
        if not demo: raise RuntimeError('找不到同时具有订单和优惠券的真实会员，未创建客户账号。')
        accounts=[('admin',ADMIN_PASSWORD,'ADMIN',None),('customer001',CUSTOMER_PASSWORD,'CUSTOMER',demo['member_id'])]
        for username,password,role,member_id in accounts:
            cur.execute('''INSERT INTO user_account(username,password_hash,role,member_id,status) VALUES(%s,%s,%s,%s,'ACTIVE') ON DUPLICATE KEY UPDATE password_hash=VALUES(password_hash),role=VALUES(role),member_id=VALUES(member_id),status='ACTIVE' ''',(username,generate_password_hash(password),role,member_id))
    print(f'演示账户创建成功：admin；customer001 绑定真实会员 {demo["member_id"]}。')
if __name__=='__main__': main()

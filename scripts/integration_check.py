"""顺序运行双端页面集成检查，避免大表聚合并发。"""
import json, sys, time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from run import create_app
from app.db import scalar

OUT=Path(__file__).resolve().parents[1]/'04_test_results'/'integration_report.json'

def check(client, path):
    started=time.perf_counter(); resp=client.get(path); elapsed=round(time.perf_counter()-started,2)
    print(f'{resp.status_code:3} {elapsed:6.2f}s {path}')
    return {'path':path,'status':resp.status_code,'seconds':elapsed}

def login(client, username, password):
    r=client.post('/login',data={'username':username,'password':password},follow_redirects=False)
    if r.status_code!=302: raise RuntimeError(f'{username} 登录失败：{r.status_code}')

def main():
    app=create_app();app.config.update(TESTING=True)
    results=[]
    with app.test_client() as c:
        results.append(check(c,'/api/health')); login(c,'customer001','Retail@2026')
        demo_order=scalar("SELECT order_id FROM sales_order WHERE member_id=20000 ORDER BY order_time DESC LIMIT 1")
        for p in ['/my','/my/orders?size=10',f'/my/orders/{demo_order}','/my/analytics','/my/coupons','/my/profile']:
            results.append(check(c,p))
        c.post('/logout'); login(c,'admin','Retail@2026')
        for p in ['/admin','/admin/sales','/admin/orders?size=10','/admin/products?size=10','/admin/members?size=10','/admin/members/rfm','/admin/members/repurchase','/admin/members/recall','/admin/coupons','/admin/marketing','/admin/data-quality','/admin/performance']:
            results.append(check(c,p))
    OUT.parent.mkdir(exist_ok=True); OUT.write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
    failed=[r for r in results if r['status']!=200]
    print(f'完成：{len(results)-len(failed)}/{len(results)} 页面 200。报告：{OUT}')
    raise SystemExit(1 if failed else 0)
if __name__=='__main__': main()

"""比较进程内缓存清空后的冷启动与同进程预热后的页面响应时间。"""
import json, sys, time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from run import create_app
from app import web

PATHS=['/admin','/admin/sales','/admin/members/rfm','/admin/members/repurchase','/admin/members/recall','/admin/coupons','/admin/data-quality']
OUT=Path(__file__).resolve().parents[1]/'04_test_results'/'performance_benchmark.json'

def request_time(client,path):
    started=time.perf_counter(); response=client.get(path); elapsed=round(time.perf_counter()-started,2)
    if response.status_code!=200: raise RuntimeError(f'{path}: HTTP {response.status_code}')
    return elapsed

def main():
    web._cache.clear()
    app=create_app();app.config.update(TESTING=True)
    with app.test_client() as client:
        with client.session_transaction() as s:s.update(user_id=1,username='admin',role='ADMIN',member_id=None)
        cold={path:request_time(client,path) for path in PATHS}
        warm={path:request_time(client,path) for path in PATHS}
    OUT.write_text(json.dumps({'cold_seconds':cold,'warm_seconds':warm},ensure_ascii=False,indent=2),encoding='utf-8')
    for path in PATHS: print(f'{path:28} cold={cold[path]:6.2f}s warm={warm[path]:6.2f}s')
if __name__=='__main__':main()

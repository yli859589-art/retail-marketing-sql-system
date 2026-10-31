"""供 Windows run.cmd 使用：等待本机 Web 已监听且同进程统计预热完成。"""
import json, sys, time
from urllib.request import urlopen

BASE='http://127.0.0.1:5000'
deadline=time.time()+420
while time.time()<deadline:
    try:
        with urlopen(BASE+'/api/warmup-status', timeout=3) as response:
            state=json.loads(response.read().decode('utf-8'))
        print('预热状态：'+state.get('state','unknown'), flush=True)
        if state.get('state')=='completed': sys.exit(0)
        if state.get('state')=='failed':
            print('预热失败：'+str(state.get('error')), file=sys.stderr);sys.exit(1)
    except Exception:
        print('等待 Web 服务就绪...', flush=True)
    time.sleep(2)
print('等待预热超时（420 秒）。', file=sys.stderr)
sys.exit(1)

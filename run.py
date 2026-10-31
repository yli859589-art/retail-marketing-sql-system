import os
import secrets
import threading
from dotenv import load_dotenv
from flask import Flask
load_dotenv()
from werkzeug.serving import make_server
from app.web import bp, warmup_heavy_cache

def create_app():
    app=Flask(__name__)
    # Do not ship a predictable Session key. A configured key keeps sessions
    # across restarts; the fallback is a fresh local-development key each run.
    app.config['SECRET_KEY']=os.getenv('FLASK_SECRET_KEY') or secrets.token_urlsafe(32)
    app.register_blueprint(bp)
    return app

app=create_app()
if __name__=='__main__':
    # 同一 Flask 进程先监听端口、再预热重型统计缓存；run.cmd 会等待状态完成后打开浏览器。
    server=make_server('127.0.0.1',5000,app,threaded=True)
    worker=threading.Thread(target=server.serve_forever,name='retail-web-server',daemon=True)
    worker.start()
    print('Web 已就绪：http://127.0.0.1:5000；正在同进程预热重型统计缓存...',flush=True)
    try:
        warmup_heavy_cache()
        print('统计预热完成。',flush=True)
        worker.join()
    except KeyboardInterrupt:
        server.shutdown()

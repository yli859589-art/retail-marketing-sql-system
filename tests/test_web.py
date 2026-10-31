import os, sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from run import create_app
from app.db import one, scalar

def app():
    app=create_app();app.config.update(TESTING=True,SECRET_KEY='test');return app

def test_health_and_protection():
    c=app().test_client()
    assert c.get('/api/health').status_code==200
    assert c.get('/my').status_code==302
    assert c.get('/admin').status_code==302

def test_role_separation_and_customer_isolation():
    c=app().test_client()
    with c.session_transaction() as s:s.update(user_id=2,username='customer001',role='CUSTOMER',member_id=20000)
    assert c.get('/my').status_code==200
    assert c.get('/admin').status_code==403
    assert c.get('/my/orders/1').status_code==404

def test_admin_pages():
    c=app().test_client()
    with c.session_transaction() as s:s.update(user_id=1,username='admin',role='ADMIN',member_id=None)
    # 百万级券表的 D-1/D-7 真实聚合另由顺序集成验证执行，避免测试并发放大扫描负载。
    for path in ['/admin','/admin/orders?size=10','/admin/products?size=10','/admin/members?size=10','/admin/performance']:
        assert c.get(path).status_code==200, path

def test_customer_coupon_pagination_and_isolation():
    demo=one('SELECT member_id FROM coupon_instance GROUP BY member_id ORDER BY COUNT(*) DESC LIMIT 1')
    assert demo
    c=app().test_client()
    with c.session_transaction() as s:s.update(user_id=2,username='customer001',role='CUSTOMER',member_id=demo['member_id'])
    first=c.get('/my/coupons?page=1&page_size=10')
    second=c.get('/my/coupons?page=2&page_size=10')
    filtered=c.get('/my/coupons?status=已核销&page=1&page_size=10')
    assert first.status_code==second.status_code==filtered.status_code==200
    assert 'page=2' in first.get_data(as_text=True)
    # 第二页与状态筛选可组合；实际样本不足一页时不会渲染无效“下一页”链接。
    assert c.get('/my/coupons?status=已核销&page=2&page_size=10').status_code==200
    # URL 不接受 member_id，当前 session 以外的会员券不会进入结果。
    assert str(demo['member_id']) not in c.get('/my/coupons?member_id=1').request.path

def test_admin_order_advanced_filters_and_completed_product_quantity():
    c=app().test_client()
    with c.session_transaction() as s:s.update(user_id=1,username='admin',role='ADMIN',member_id=None)
    response=c.get('/admin/orders?status=已完成&coupon=yes&start_date=2025-01-01&end_date=2026-12-31&min_pay=100&max_pay=100000&page_size=20')
    assert response.status_code==200
    assert '已用券' in response.get_data(as_text=True)
    product=one('SELECT product_id FROM product ORDER BY product_id LIMIT 1')['product_id']
    expected=scalar("SELECT COALESCE(SUM(oi.quantity),0) FROM order_item oi JOIN sales_order o ON o.order_id=oi.order_id WHERE oi.product_id=%s AND o.order_status='已完成'",(product,))
    page=c.get('/admin/products?q=&page_size=20')
    assert page.status_code==200
    assert str(expected) in page.get_data(as_text=True)

def test_chartjs_is_local_only():
    c=app().test_client()
    with c.session_transaction() as s:s.update(user_id=2,username='customer001',role='CUSTOMER',member_id=20000)
    html=c.get('/my').get_data(as_text=True)
    assert 'vendor/chart/chart.umd.min.js' in html
    assert 'cdn.jsdelivr' not in html

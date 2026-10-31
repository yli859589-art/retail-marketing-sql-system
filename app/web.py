import json, math, os, time
from datetime import date
from decimal import Decimal
from functools import wraps
from flask import Blueprint, abort, flash, redirect, render_template, request, session, url_for
from werkzeug.security import check_password_hash
from .db import all_rows, one, scalar

bp = Blueprint('web', __name__)
_cache = {}

def as_json(value):
    return json.dumps(value, ensure_ascii=False, default=lambda x: float(x) if isinstance(x, Decimal) else str(x))

def cached(key, seconds, loader):
    now = time.time()
    if key not in _cache or now - _cache[key][0] > seconds:
        _cache[key] = (now, loader())
    return _cache[key][1]

def login_required(role=None):
    def deco(fn):
        @wraps(fn)
        def wrapped(*args, **kwargs):
            if not session.get('user_id'):
                return redirect(url_for('web.login', next=request.path))
            if role and session.get('role') != role:
                abort(403)
            return fn(*args, **kwargs)
        return wrapped
    return deco

def page_args():
    page = max(1, request.args.get('page', 1, type=int))
    size = request.args.get('page_size', type=int)
    if size is None: size = request.args.get('size', 20, type=int)
    return page, min(max(size, 10), 100), (page - 1) * min(max(size, 10), 100)

def page_url(endpoint, page, size):
    args=request.args.to_dict(flat=True); args['page']=page; args['page_size']=size
    return url_for(endpoint, **args)

@bp.app_template_filter('money')
def money(v): return f'{Decimal(v or 0):,.2f}'

@bp.app_template_filter('date_cn')
def date_cn(v): return v.strftime('%Y-%m-%d %H:%M') if v else '—'

@bp.route('/')
def index():
    return redirect(url_for('web.admin_dashboard' if session.get('role') == 'ADMIN' else 'web.customer_dashboard')) if session.get('user_id') else redirect(url_for('web.login'))

@bp.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form.get('username', '').strip(); password = request.form.get('password', '')
        account = one('SELECT user_id,username,password_hash,role,member_id,status FROM user_account WHERE username=%s', (username,))
        if not account or account['status'] != 'ACTIVE' or not check_password_hash(account['password_hash'], password):
            flash('用户名或密码不正确。', 'error')
        else:
            session.clear(); session.update(user_id=account['user_id'], username=account['username'], role=account['role'], member_id=account['member_id'])
            return redirect(request.args.get('next') or ('/admin' if account['role'] == 'ADMIN' else '/my'))
    return render_template('login.html')

@bp.post('/logout')
def logout():
    session.clear(); return redirect(url_for('web.login'))

@bp.route('/my')
@login_required('CUSTOMER')
def customer_dashboard():
    mid = session['member_id']
    profile = one('''SELECT m.member_id,m.member_name,m.card_no,m.total_amount,m.register_time,m.status,l.level_name,
        (SELECT COUNT(*) FROM sales_order o WHERE o.member_id=m.member_id AND o.order_status='已完成') completed_orders,
        (SELECT MAX(order_time) FROM sales_order o WHERE o.member_id=m.member_id AND o.order_status='已完成') last_order_time,
        (SELECT COUNT(*) FROM coupon_instance c WHERE c.member_id=m.member_id AND c.coupon_status='未使用' AND c.expire_time>NOW()) available_coupons
        FROM member m JOIN member_level l ON l.level_id=m.level_id WHERE m.member_id=%s''', (mid,))
    trend = all_rows('''SELECT DATE_FORMAT(order_time,'%%Y-%%m') label,ROUND(SUM(pay_amount),2) value FROM sales_order
        WHERE member_id=%s AND order_status='已完成' GROUP BY label ORDER BY label DESC LIMIT 6''', (mid,))[::-1]
    categories = all_rows('''SELECT c.category_name label,ROUND(SUM(oi.amount),2) value FROM sales_order o JOIN order_item oi ON oi.order_id=o.order_id
        JOIN product p ON p.product_id=oi.product_id JOIN category c ON c.category_id=p.category_id
        WHERE o.member_id=%s AND o.order_status='已完成' GROUP BY c.category_id,c.category_name ORDER BY value DESC LIMIT 8''', (mid,))
    orders = all_rows('''SELECT order_id,order_no,order_time,pay_amount,order_status,coupon_discount FROM sales_order
        WHERE member_id=%s ORDER BY order_time DESC LIMIT 8''', (mid,))
    coupons = all_rows("SELECT coupon_status status,COUNT(*) value FROM coupon_instance WHERE member_id=%s GROUP BY coupon_status", (mid,))
    return render_template('customer_dashboard.html', profile=profile, trend=trend, categories=categories, orders=orders, coupons=coupons, chart=as_json({'trend':trend,'categories':categories,'coupons':coupons}))

@bp.route('/my/orders')
@login_required('CUSTOMER')
def customer_orders():
    page,size,offset=page_args(); mid=session['member_id']
    total=scalar('SELECT COUNT(*) FROM sales_order WHERE member_id=%s',(mid,))
    rows=all_rows('''SELECT o.*, CASE WHEN o.coupon_discount>0 THEN '是' ELSE '否' END has_coupon FROM sales_order o
        WHERE o.member_id=%s ORDER BY o.order_time DESC LIMIT %s OFFSET %s''',(mid,size,offset))
    return render_template('orders.html', rows=rows, total=total, page=page, size=size, title='我的订单', customer=True,
                           prev_url=page_url('web.customer_orders',page-1,size) if page>1 else None,
                           next_url=page_url('web.customer_orders',page+1,size) if page*size<total else None)

@bp.route('/my/orders/<int:order_id>')
@login_required('CUSTOMER')
def customer_order_detail(order_id):
    order=one('SELECT * FROM sales_order WHERE order_id=%s AND member_id=%s',(order_id,session['member_id']))
    if not order: abort(404)
    items=all_rows('''SELECT oi.*,p.product_name,c.category_name FROM order_item oi JOIN product p ON p.product_id=oi.product_id
        JOIN category c ON c.category_id=p.category_id WHERE oi.order_id=%s ORDER BY oi.item_id''',(order_id,))
    return render_template('order_detail.html',order=order,items=items,customer=True)

@bp.route('/my/analytics')
@login_required('CUSTOMER')
def customer_analytics():
    mid=session['member_id']
    metrics=one('''SELECT COUNT(*) frequency,COALESCE(ROUND(SUM(pay_amount),2),0) monetary,COALESCE(ROUND(AVG(pay_amount),2),0) aov,MAX(order_time) last_order
      FROM sales_order WHERE member_id=%s AND order_status='已完成' ''',(mid,))
    monthly=all_rows("SELECT DATE_FORMAT(order_time,'%%Y-%%m') label,ROUND(SUM(pay_amount),2) value FROM sales_order WHERE member_id=%s AND order_status='已完成' GROUP BY label ORDER BY label",(mid,))
    cats=all_rows('''SELECT c.category_name, SUM(oi.quantity) quantity,ROUND(SUM(oi.amount),2) amount FROM sales_order o JOIN order_item oi ON oi.order_id=o.order_id JOIN product p ON p.product_id=oi.product_id JOIN category c ON c.category_id=p.category_id WHERE o.member_id=%s AND o.order_status='已完成' GROUP BY c.category_id,c.category_name ORDER BY amount DESC''',(mid,))
    return render_template('analytics.html',metrics=metrics,monthly=monthly,cats=cats,chart=as_json({'monthly':monthly,'cats':cats}))

@bp.route('/my/coupons')
@login_required('CUSTOMER')
def customer_coupons():
    page,size,offset=page_args(); status=request.args.get('status',''); params=[session['member_id']]; where='c.member_id=%s'
    if status in ('未使用','已核销','已过期','已锁定'): where+=' AND c.coupon_status=%s';params.append(status)
    total=scalar(f'SELECT COUNT(*) FROM coupon_instance c WHERE {where}',params)
    rows=all_rows(f'''SELECT c.instance_id,c.coupon_code,c.coupon_status,c.issue_time,c.expire_time,c.face_value_snap,c.min_amount_snap,c.used_time,t.template_name,o.order_no
      FROM coupon_instance c JOIN coupon_template t ON t.template_id=c.template_id LEFT JOIN sales_order o ON o.order_id=c.used_order_id WHERE {where} ORDER BY c.issue_time DESC LIMIT %s OFFSET %s''',params+[size,offset])
    return render_template('coupons.html',rows=rows,status=status,total=total,page=page,size=size,
                           prev_url=page_url('web.customer_coupons',page-1,size) if page>1 else None,
                           next_url=page_url('web.customer_coupons',page+1,size) if page*size<total else None)

@bp.route('/my/profile')
@login_required('CUSTOMER')
def customer_profile():
    profile=one('SELECT m.member_id,m.card_no,m.member_name,m.register_time,m.register_channel,m.total_amount,m.status,l.level_name,l.upgrade_threshold FROM member m JOIN member_level l ON l.level_id=m.level_id WHERE m.member_id=%s',(session['member_id'],))
    return render_template('profile.html',profile=profile)

def dashboard_data():
    kpi=one('''SELECT (SELECT COUNT(*) FROM member) members,(SELECT COUNT(*) FROM sales_order) orders,
      (SELECT COUNT(*) FROM sales_order WHERE order_status='已完成') completed_orders,
      (SELECT COALESCE(SUM(pay_amount),0) FROM sales_order WHERE order_status='已完成') sales,
      (SELECT COALESCE(AVG(pay_amount),0) FROM sales_order WHERE order_status='已完成') aov,
      (SELECT COUNT(*) FROM product) products,(SELECT COUNT(*) FROM coupon_instance) issued,
      (SELECT COUNT(*) FROM coupon_instance WHERE coupon_status='已核销') redeemed''')
    kpi['redemption_rate']=round(float(kpi['redeemed'])*100/float(kpi['issued']),2) if kpi['issued'] else 0
    trend=all_rows("SELECT DATE_FORMAT(order_time,'%%Y-%%m') label,ROUND(SUM(pay_amount),2) value FROM sales_order WHERE order_status='已完成' GROUP BY label ORDER BY label")
    levels=all_rows('SELECT l.level_name label,COUNT(*) value FROM member m JOIN member_level l ON l.level_id=m.level_id GROUP BY l.level_id,l.level_name ORDER BY l.level_rank')
    return kpi,trend,levels

def sales_data():
    """D-销售：所有销量、金额、覆盖订单统一限定为已完成订单。"""
    return (
      all_rows("SELECT DATE_FORMAT(order_time,'%%Y-%%m') label,COUNT(*) orders,ROUND(SUM(pay_amount),2) sales,ROUND(AVG(pay_amount),2) aov FROM sales_order WHERE order_status='已完成' GROUP BY label ORDER BY label"),
      all_rows("SELECT p.product_id,p.product_name,SUM(oi.quantity) quantity,ROUND(SUM(oi.amount),2) sales,COUNT(DISTINCT o.order_id) order_count FROM sales_order o JOIN order_item oi ON oi.order_id=o.order_id JOIN product p ON p.product_id=oi.product_id WHERE o.order_status='已完成' GROUP BY p.product_id,p.product_name ORDER BY sales DESC LIMIT 15"),
      all_rows("SELECT c.category_name,SUM(oi.quantity) quantity,ROUND(SUM(oi.amount),2) sales,COUNT(DISTINCT o.order_id) order_count FROM sales_order o JOIN order_item oi ON oi.order_id=o.order_id JOIN product p ON p.product_id=oi.product_id JOIN category c ON c.category_id=p.category_id WHERE o.order_status='已完成' GROUP BY c.category_id,c.category_name ORDER BY sales DESC LIMIT 15")
    )

def coupon_ops_data():
    return all_rows('''SELECT t.template_id,t.template_name,t.face_value,t.min_amount,COUNT(c.instance_id) issued,SUM(c.coupon_status='已核销') redeemed,ROUND(SUM(c.coupon_status='已核销')*100/COUNT(c.instance_id),2) redemption_rate,ROUND(SUM(CASE WHEN c.coupon_status='已核销' THEN c.face_value_snap ELSE 0 END),2) discount_total,COUNT(DISTINCT c.member_id) members FROM coupon_template t JOIN coupon_instance c ON c.template_id=t.template_id GROUP BY t.template_id,t.template_name,t.face_value,t.min_amount HAVING issued>=1000 ORDER BY redemption_rate DESC''')

def marketing_data():
    return all_rows("SELECT issue_channel,strategy_version,COUNT(*) issued,COUNT(DISTINCT member_id) members,ROUND(AVG(reco_score),4) avg_score,SUM(coupon_status='已核销') redeemed,ROUND(SUM(coupon_status='已核销')*100/COUNT(*),2) redemption_rate FROM coupon_instance GROUP BY issue_channel,strategy_version ORDER BY issue_channel,strategy_version")

def quality_data():
    sql="""SELECT '订单金额恒等式' name,COUNT(*) abnormal FROM sales_order WHERE pay_amount<>items_amount-coupon_discount UNION ALL SELECT '券优惠金额未超过订单原价',COUNT(*) FROM coupon_instance c JOIN sales_order o ON o.order_id=c.used_order_id WHERE c.coupon_status='已核销' AND c.face_value_snap>o.items_amount UNION ALL SELECT '核销时仍在有效期内',COUNT(*) FROM coupon_instance WHERE coupon_status='已核销' AND used_time>expire_time UNION ALL SELECT '同会员同模板无重复持有',COUNT(*) FROM(SELECT member_id,template_id FROM coupon_instance WHERE coupon_status IN('未使用','已锁定') GROUP BY member_id,template_id HAVING COUNT(*)>1)x UNION ALL SELECT '下架商品未进入订单明细',COUNT(*) FROM order_item oi JOIN product p ON p.product_id=oi.product_id WHERE p.shelf_status='下架' UNION ALL SELECT '订单时间早于注册',COUNT(*) FROM sales_order o JOIN member m ON m.member_id=o.member_id WHERE o.order_time<m.register_time UNION ALL SELECT '优惠券领取早于注册',COUNT(*) FROM coupon_instance c JOIN member m ON m.member_id=c.member_id WHERE c.issue_time<m.register_time UNION ALL SELECT '核销券与订单会员不一致',COUNT(*) FROM coupon_instance c JOIN sales_order o ON o.order_id=c.used_order_id WHERE c.coupon_status='已核销' AND c.member_id<>o.member_id"""
    return all_rows(sql)

def recall_data(days, amount, orders):
    return all_rows('''SELECT m.member_id,m.member_name,l.level_name,MAX(o.order_time) last_order,ROUND(SUM(o.pay_amount),2) monetary,COUNT(*) frequency,
       (SELECT COUNT(*) FROM coupon_instance c WHERE c.member_id=m.member_id AND c.coupon_status='已核销') redeemed
       FROM member m JOIN member_level l ON l.level_id=m.level_id JOIN sales_order o ON o.member_id=m.member_id AND o.order_status='已完成'
       GROUP BY m.member_id,m.member_name,l.level_name HAVING MAX(o.order_time)<DATE_SUB('2026-10-01',INTERVAL %s DAY) AND SUM(o.pay_amount)>=%s AND COUNT(*)>=%s ORDER BY monetary DESC LIMIT 500''',(days,amount,orders))

_warmup_state={'state':'not_started','current':None,'completed':[], 'error':None, 'started_at':None, 'finished_at':None}

def warmup_heavy_cache():
    """在 Flask 同一进程内填充重型统计缓存；不写入业务表。"""
    tasks=[('经营总览',lambda:cached('dashboard',900,dashboard_data)),('销售分析',lambda:cached('sales',900,sales_data)),('RFM',lambda:cached('rfm',900,rfm_data)),('复购分析',lambda:cached('repurchase',900,repurchase_data)),('会员召回',lambda:cached('recall_default',900,lambda:recall_data(180,5000,3))),('优惠券运营',lambda:cached('coupon_ops',900,coupon_ops_data)),('营销策略',lambda:cached('marketing',900,marketing_data)),('数据质量',lambda:cached('quality',900,quality_data))]
    _warmup_state.update(state='running',current=None,completed=[],error=None,started_at=time.time(),finished_at=None)
    try:
        for name, task in tasks:
            _warmup_state['current']=name; started=time.perf_counter(); task()
            _warmup_state['completed'].append({'name':name,'seconds':round(time.perf_counter()-started,2)})
        _warmup_state.update(state='completed',current=None,finished_at=time.time())
    except Exception as exc:
        _warmup_state.update(state='failed',error=str(exc),finished_at=time.time())
        raise

@bp.route('/admin')
@login_required('ADMIN')
def admin_dashboard():
    kpi,trend,levels=cached('dashboard',900,dashboard_data)
    return render_template('admin_dashboard.html',kpi=kpi,trend=trend,levels=levels,chart=as_json({'trend':trend,'levels':levels}))

@bp.route('/admin/sales')
@login_required('ADMIN')
def admin_sales():
    data=cached('sales',900,sales_data)
    return render_template('sales.html',monthly=data[0],products=data[1],categories=data[2],chart=as_json({'monthly':data[0],'categories':data[2]}))

@bp.route('/admin/orders')
@login_required('ADMIN')
def admin_orders():
    page,size,offset=page_args(); status=request.args.get('status',''); keyword=request.args.get('q','').strip(); params=[]; where='1=1'
    start_date=request.args.get('start_date','').strip(); end_date=request.args.get('end_date','').strip(); coupon=request.args.get('coupon','')
    min_pay=request.args.get('min_pay',type=float); max_pay=request.args.get('max_pay',type=float)
    if status in ('待支付','已支付','已完成','已取消','已退款'): where+=' AND o.order_status=%s';params.append(status)
    if keyword: where+=' AND (o.order_no LIKE %s OR CAST(o.member_id AS CHAR) LIKE %s)';params+=['%'+keyword+'%','%'+keyword+'%']
    try:
        if start_date: date.fromisoformat(start_date); where+=' AND o.order_time >= %s'; params.append(start_date)
        else: start_date=''
    except ValueError: start_date=''
    try:
        if end_date: date.fromisoformat(end_date); where+=' AND o.order_time < DATE_ADD(%s, INTERVAL 1 DAY)'; params.append(end_date)
        else: end_date=''
    except ValueError: end_date=''
    if coupon == 'yes': where+=' AND o.coupon_discount > 0'
    elif coupon == 'no': where+=' AND o.coupon_discount = 0'
    else: coupon=''
    if min_pay is not None and min_pay>=0: where+=' AND o.pay_amount >= %s';params.append(min_pay)
    else: min_pay=None
    if max_pay is not None and max_pay>=0: where+=' AND o.pay_amount <= %s';params.append(max_pay)
    else: max_pay=None
    total=scalar(f'SELECT COUNT(*) FROM sales_order o WHERE {where}',params)
    rows=all_rows(f'''SELECT o.order_id,o.order_no,o.member_id,m.member_name,o.order_time,o.items_amount,o.coupon_discount,o.pay_amount,o.order_status FROM sales_order o JOIN member m ON m.member_id=o.member_id WHERE {where} ORDER BY o.order_time DESC LIMIT %s OFFSET %s''',params+[size,offset])
    return render_template('orders.html',rows=rows,total=total,page=page,size=size,title='订单中心',customer=False,status=status,keyword=keyword,
                           start_date=start_date,end_date=end_date,coupon=coupon,min_pay=min_pay,max_pay=max_pay,
                           prev_url=page_url('web.admin_orders',page-1,size) if page>1 else None,
                           next_url=page_url('web.admin_orders',page+1,size) if page*size<total else None)

@bp.route('/admin/orders/<int:order_id>')
@login_required('ADMIN')
def admin_order_detail(order_id):
    order=one('SELECT o.*,m.member_name,m.card_no FROM sales_order o JOIN member m ON m.member_id=o.member_id WHERE o.order_id=%s',(order_id,))
    if not order: abort(404)
    items=all_rows('SELECT oi.*,p.product_name,c.category_name FROM order_item oi JOIN product p ON p.product_id=oi.product_id JOIN category c ON c.category_id=p.category_id WHERE oi.order_id=%s',(order_id,))
    return render_template('order_detail.html',order=order,items=items,customer=False)

@bp.route('/admin/products')
@login_required('ADMIN')
def admin_products():
    page,size,offset=page_args(); q=request.args.get('q','').strip(); category=request.args.get('category',''); status=request.args.get('status',''); params=[];where='1=1'
    if q:where+=' AND p.product_name LIKE %s';params.append('%'+q+'%')
    if category.isdigit():where+=' AND p.category_id=%s';params.append(int(category))
    if status in ('上架','下架'):where+=' AND p.shelf_status=%s';params.append(status)
    total=scalar(f'SELECT COUNT(*) FROM product p WHERE {where}',params)
    rows=all_rows(f'''SELECT p.product_id,p.product_name,c.category_name,p.list_price,p.shelf_status,
       COALESCE((SELECT SUM(oi.quantity) FROM order_item oi JOIN sales_order o ON o.order_id=oi.order_id WHERE oi.product_id=p.product_id AND o.order_status='已完成'),0) quantity,
       COALESCE((SELECT SUM(oi.amount) FROM order_item oi JOIN sales_order o ON o.order_id=oi.order_id WHERE oi.product_id=p.product_id AND o.order_status='已完成'),0) sales
       ,COALESCE((SELECT COUNT(DISTINCT oi.order_id) FROM order_item oi JOIN sales_order o ON o.order_id=oi.order_id WHERE oi.product_id=p.product_id AND o.order_status='已完成'),0) order_count
       FROM product p JOIN category c ON c.category_id=p.category_id WHERE {where} ORDER BY p.product_id LIMIT %s OFFSET %s''',params+[size,offset])
    return render_template('products.html',rows=rows,total=total,page=page,size=size,categories=all_rows('SELECT category_id,category_name FROM category WHERE level_no=2 ORDER BY category_name'),selected_category=category,selected_status=status,q=q)

@bp.route('/admin/members')
@login_required('ADMIN')
def admin_members():
    page,size,offset=page_args(); level=request.args.get('level',''); min_amount=request.args.get('min_amount',type=float); params=[];where='1=1'
    if level.isdigit():where+=' AND m.level_id=%s';params.append(int(level))
    if min_amount is not None:where+=' AND m.total_amount>=%s';params.append(min_amount)
    total=scalar(f'SELECT COUNT(*) FROM member m WHERE {where}',params)
    rows=all_rows(f'''SELECT m.member_id,m.member_name,m.total_amount,l.level_name,
       (SELECT COUNT(*) FROM sales_order o WHERE o.member_id=m.member_id AND o.order_status='已完成') frequency,
       (SELECT MAX(order_time) FROM sales_order o WHERE o.member_id=m.member_id AND o.order_status='已完成') last_order,
       (SELECT COUNT(*) FROM coupon_instance c WHERE c.member_id=m.member_id AND c.coupon_status='已核销') redeemed
       FROM member m JOIN member_level l ON l.level_id=m.level_id WHERE {where} ORDER BY m.total_amount DESC LIMIT %s OFFSET %s''',params+[size,offset])
    return render_template('members.html',rows=rows,total=total,page=page,size=size,levels=all_rows('SELECT level_id,level_name FROM member_level ORDER BY level_rank'),selected_level=level,min_amount=min_amount)

def rfm_data():
    return all_rows('''WITH rfm AS (SELECT m.member_id,COALESCE(DATEDIFF('2026-10-01',MAX(o.order_time)),9999) recency_days,COUNT(DISTINCT o.order_id) frequency,COALESCE(SUM(o.pay_amount),0) monetary FROM member m LEFT JOIN sales_order o ON o.member_id=m.member_id AND o.order_status='已完成' GROUP BY m.member_id), scored AS (SELECT r.*,CASE WHEN frequency=0 THEN 1 ELSE 6-CEIL(CUME_DIST() OVER(ORDER BY recency_days)*5) END r_score,CASE WHEN frequency=0 THEN 1 ELSE CEIL(CUME_DIST() OVER(ORDER BY frequency)*5) END f_score,CASE WHEN monetary=0 THEN 1 ELSE CEIL(CUME_DIST() OVER(ORDER BY monetary)*5) END m_score FROM rfm r) SELECT CONCAT(r_score,f_score,m_score) segment,COUNT(*) members,ROUND(AVG(monetary),2) avg_monetary,ROUND(AVG(recency_days),0) avg_recency FROM scored GROUP BY segment ORDER BY segment DESC''')

@bp.route('/admin/members/rfm')
@login_required('ADMIN')
def admin_rfm():
    rows=cached('rfm',900,rfm_data)
    return render_template('rfm.html',rows=rows,chart=as_json(rows))

def repurchase_data():
    return all_rows('''WITH gaps AS (SELECT member_id,DATEDIFF(order_time,LAG(order_time) OVER(PARTITION BY member_id ORDER BY order_time)) gap_days FROM sales_order WHERE order_status='已完成'), ranked AS (SELECT member_id,gap_days,ROW_NUMBER() OVER(PARTITION BY member_id ORDER BY gap_days) rn,COUNT(*) OVER(PARTITION BY member_id) cnt FROM gaps WHERE gap_days IS NOT NULL), per_member AS (SELECT member_id,AVG(gap_days) median_gap FROM ranked WHERE rn IN(FLOOR((cnt+1)/2),CEIL((cnt+1)/2)) GROUP BY member_id) SELECT CASE WHEN median_gap<=90 THEN '90 天内' WHEN median_gap<=180 THEN '91-180 天' WHEN median_gap<=365 THEN '181-365 天' ELSE '365 天以上' END segment,COUNT(*) members,ROUND(AVG(median_gap),1) avg_gap FROM per_member GROUP BY segment ORDER BY MIN(median_gap)''')

@bp.route('/admin/members/repurchase')
@login_required('ADMIN')
def admin_repurchase():
    rows=cached('repurchase',900,repurchase_data);return render_template('repurchase.html',rows=rows,chart=as_json(rows))

@bp.route('/admin/members/recall')
@login_required('ADMIN')
def admin_recall():
    days=max(30,request.args.get('days',180,type=int)); amount=max(0,request.args.get('amount',5000,type=float)); orders=max(1,request.args.get('orders',3,type=int))
    rows=cached('recall_default',900,lambda:recall_data(180,5000,3)) if (days,amount,orders)==(180,5000,3) else recall_data(days,amount,orders)
    return render_template('recall.html',rows=rows,days=days,amount=amount,orders=orders)

@bp.route('/admin/coupons')
@login_required('ADMIN')
def admin_coupons():
    rows=cached('coupon_ops',900,coupon_ops_data)
    return render_template('coupon_ops.html',rows=rows,chart=as_json(rows))

@bp.route('/admin/marketing')
@login_required('ADMIN')
def admin_marketing():
    rows=cached('marketing',900,marketing_data)
    return render_template('marketing.html',rows=rows)

@bp.route('/admin/data-quality')
@login_required('ADMIN')
def admin_quality():
    rows=cached('quality',900,quality_data);return render_template('quality.html',rows=rows)

@bp.route('/admin/performance')
@login_required('ADMIN')
def admin_performance():
    indexed=all_rows("EXPLAIN SELECT order_id,order_no,order_time,pay_amount FROM sales_order WHERE member_id=12345 AND order_time>='2025-01-01'")
    ignored=all_rows("EXPLAIN SELECT order_id,order_no,order_time,pay_amount FROM sales_order IGNORE INDEX(idx_order_member_time) WHERE member_id=12345 AND order_time>='2025-01-01'")
    return render_template('performance.html',indexed=indexed,ignored=ignored)

@bp.route('/api/health')
def health():
    return {'status':'ok','database':scalar('SELECT DATABASE()'),'version':scalar('SELECT VERSION()')}

@bp.route('/api/warmup-status')
def warmup_status():
    """仅本机启动脚本轮询；不返回数据库凭证或业务明细。"""
    return dict(_warmup_state)

@bp.app_errorhandler(403)
def forbidden(e): return render_template('error.html',code=403,message='你没有访问该页面的权限。'),403
@bp.app_errorhandler(404)
def not_found(e): return render_template('error.html',code=404,message='页面或订单不存在。'),404

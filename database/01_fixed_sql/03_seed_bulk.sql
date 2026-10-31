-- =============================================================================
--  测试数据生成脚本(二):主数据与事实表  03_seed_bulk.sql
-- -----------------------------------------------------------------------------
--  前置:01_schema.sql(建表)→ 02_seed_dict.sql(序号表与字典表)
--  特点:全部由 seq_numbers 派生,确定性公式,**不使用 RAND()**;重复执行结果一致。
--
--  写入顺序概述(与正文 ① ~ ⑭ 的具体步骤对应,不可调换,原因是订单金额与券优惠互相依赖):
--     · 商品、会员(金额类字段先置 0)
--     · 订单(金额先置 0,满足"实付 = 明细合计 − 券优惠 = 0 − 0")
--     · 订单明细
--     · 回写订单的明细合计金额
--     · 已核销券(需读取订单的明细合计金额,以校验券门槛)
--     · 回写订单的券优惠金额与实付金额
--     · 未使用/已锁定券、已过期券
--     · 计算会员累计消费额 → 按门槛升级 → 回填券的发放时等级
--
--  性能提示:大表插入耗时较长(合计约 430 万行)。建议:
--     · 插入前 SET SESSION sql_log_bin = 0;(若无二进制日志需求)
--     · 或分批执行:把 WHERE s.n <= N 的 N 调小,分多次插入;
--     · 明细聚合回写前,适当调大 tmp_table_size 与 sort_buffer_size。
-- =============================================================================

SET NAMES utf8mb4;
SET SESSION cte_max_recursion_depth = 2000;


-- =============================================================================
-- ① 商品(20,000 行)
-- 约束:list_price > 0;shelf_status ∈ {上架,下架};category_id 必须存在且为二级品类
-- 设计:编号 1..20000;编号 > 19900 的 100 个商品置为"下架",用于验证
--       BR-11(下架商品不得出现在订单明细中),因此订单明细只取 1..19900。
-- =============================================================================
INSERT INTO product (product_id, product_name, category_id, list_price, shelf_status, created_at)
SELECT s.n,
       CONCAT(c.category_name, '系列', LPAD(s.n, 5, '0')),
       100 + ((s.n - 1) MOD 50) DIV 5 * 10 + ((s.n - 1) MOD 5) + 1,
       ROUND(3.50 + (s.n MOD 500) * 0.37, 2),
       CASE WHEN s.n > 19900 THEN '下架' ELSE '上架' END,
       DATE_ADD('2023-01-01 00:00:00', INTERVAL (s.n MOD 900) DAY)
FROM seq_numbers s
JOIN category c
  ON c.category_id = 100 + ((s.n - 1) MOD 50) DIV 5 * 10 + ((s.n - 1) MOD 5) + 1
WHERE s.n <= 20000;


-- =============================================================================
-- ② 会员(200,000 行)
-- 约束:card_no、mobile 唯一;mobile 为 11 位数字;total_amount >= 0;
--       status ∈ {正常,冻结,注销};level_id 必须存在
-- 设计:手机号统一以 138 开头 + 8 位序号,保证唯一且符合格式,且明显为合成号码;
--       姓名统一为"合成会员 + 编号",不含任何真实个人信息;
--       每 1000 个会员中有 1 个"注销"、另外每 500 个中有 1 个"冻结",用于验证
--       BR-07(冻结/注销会员不得领取新券)。
--       累计消费额先置 0,等级先置"普通会员",最后按订单结果回算(第 ⑧ 步)。
-- =============================================================================
INSERT INTO member (member_id, card_no, member_name, mobile, level_id, register_time,
                    register_channel, total_amount, status, created_at, updated_at)
SELECT s.n,
       CONCAT('M', LPAD(s.n, 10, '0')),
       CONCAT('合成会员', LPAD(s.n, 6, '0')),
       CONCAT('138', LPAD(s.n MOD 100000000, 8, '0')),
       1,
       DATE_ADD('2022-01-01 00:00:00', INTERVAL (s.n MOD 1500) DAY),
       CASE WHEN s.n MOD 10 = 0 THEN '线上广告'
            WHEN s.n MOD 10 = 1 THEN '朋友推荐'
            WHEN s.n MOD 3  = 0 THEN '门店'
            ELSE '小程序' END,
       0.00,
       CASE WHEN s.n MOD 1000 = 0 THEN '注销'
            WHEN s.n MOD 500  = 0 THEN '冻结'
            ELSE '正常' END,
       DATE_ADD('2022-01-01 00:00:00', INTERVAL (s.n MOD 1500) DAY),
       DATE_ADD('2022-01-01 00:00:00', INTERVAL (s.n MOD 1500) DAY)
FROM seq_numbers s
WHERE s.n <= 200000;


-- =============================================================================
-- ③ 订单(600,000 行,金额字段先置 0)
-- 约束:order_no 唯一;member_id 必须存在;三个金额字段 >= 0;
--       pay_amount = items_amount − coupon_discount;状态与支付时间必须一致
-- 设计:每位会员 3 单((n-1) MOD 200000 + 1);
--       下单时间为基准时间与会员注册后 1 天两者较晚者,从源头保证不会早于注册;
--       仍均早于当前时间(满足"下单时间不晚于当前时间");
--       状态分布:已完成 85%、已支付 5%、待支付 3%、已取消 3%、已退款 4%;
--       仅"已支付/已完成/已退款"三种状态填写支付时间(与检查约束一致)。
-- =============================================================================
INSERT INTO sales_order (order_id, order_no, member_id, order_time,
                         items_amount, coupon_discount, pay_amount, order_status, pay_time)
SELECT s.n,
       CONCAT('SO', LPAD(s.n, 14, '0')),
       m.member_id,
       GREATEST(DATE_ADD(DATE_ADD('2023-09-01 00:00:00', INTERVAL ((s.n - 1) MOD 1095) DAY),
                         INTERVAL ((s.n * 37) MOD 86400) SECOND),
                DATE_ADD(m.register_time, INTERVAL 1 DAY)),
       0.00, 0.00, 0.00,
       CASE WHEN s.n MOD 100 < 85 THEN '已完成'
            WHEN s.n MOD 100 < 90 THEN '已支付'
            WHEN s.n MOD 100 < 93 THEN '待支付'
            WHEN s.n MOD 100 < 96 THEN '已取消'
            ELSE '已退款' END,
       CASE WHEN s.n MOD 100 < 90 OR s.n MOD 100 >= 96
             THEN DATE_ADD(GREATEST(DATE_ADD(DATE_ADD('2023-09-01 00:00:00', INTERVAL ((s.n - 1) MOD 1095) DAY),
                                             INTERVAL ((s.n * 37) MOD 86400) SECOND),
                                    DATE_ADD(m.register_time, INTERVAL 1 DAY)),
                          INTERVAL ((s.n MOD 3600) + 1) SECOND)
            ELSE NULL END
FROM seq_numbers s
JOIN member m ON m.member_id = ((s.n - 1) MOD 200000) + 1
WHERE s.n <= 600000;


-- =============================================================================
-- ④ 订单明细(第一部分:每单 3 行,订单 1..600000,共 1,800,000 行)
-- 约束:quantity > 0;unit_price > 0;amount > 0 且 amount = quantity × unit_price;
--       (order_id, product_id) 唯一
-- 设计:product_id = ((订单号 × 7 + 行号 × 1237) MOD 19900) + 1
--         —— 只取 1..19900(全部为"上架"商品,满足 BR-11);
--         —— 同一订单内三个行号相差 1237 或 2474,对 19900 取模后不为 0,保证不重复;
--       成交单价 = 商品当前售价 × (1 − 订单号 MOD 7 × 1.5%)
--         —— 模拟不同订单享受的促销折扣,使成交单价与当前售价**不相等**,
--            从而让"成交单价快照"(BR-15)在数据上真实可验证;
--       数量 = (订单号 + 行号) MOD 5 + 1,取值 1..5; 对少量高价值会员提高至
--         20 或 100 件,形成白金/钻石等级的可演示样本，等级仍完全由既定门槛计算。
-- =============================================================================
INSERT INTO order_item (item_id, order_id, product_id, quantity, unit_price, amount)
WITH base AS (
  SELECT s.n,
         ((s.n - 1) DIV 3) + 1 AS oid,
         ((s.n - 1) MOD 3) + 1 AS seq
  FROM seq_numbers s
  WHERE s.n <= 1800000
),
calc AS (
  SELECT b.n, b.oid,
         ((b.oid * 7 + b.seq * 1237) MOD 19900) + 1 AS pid,
          CASE WHEN (((b.oid - 1) MOD 200000) + 1) MOD 10000 = 0 THEN 100
               WHEN (((b.oid - 1) MOD 200000) + 1) MOD 1000 = 0 THEN 20
               ELSE ((b.oid + b.seq) MOD 5) + 1 END   AS qty
  FROM base b
)
SELECT c.n, c.oid, c.pid, c.qty,
       ROUND(p.list_price * (1 - (c.oid MOD 7) * 0.015), 2),
       c.qty * ROUND(p.list_price * (1 - (c.oid MOD 7) * 0.015), 2)
FROM calc c
JOIN product p ON p.product_id = c.pid;


-- =============================================================================
-- ⑤ 订单明细(第二部分:订单 1..200000 各追加 1 行,共 200,000 行)
-- 合计 1,800,000 + 200,000 = 2,000,000 行,平均每单约 3.3 行。
-- 第 4 行的 product_id 与前三行的差值分别为 1237、2474、3711,对 19900 取模均不为 0,
-- 因此同一订单内不会出现重复商品,满足唯一约束。
-- =============================================================================
INSERT INTO order_item (item_id, order_id, product_id, quantity, unit_price, amount)
WITH calc AS (
  SELECT s.n                                     AS n,
         s.n                                     AS oid,
         4                                       AS seq,
         ((s.n * 7 + 4 * 1237) MOD 19900) + 1    AS pid,
          CASE WHEN s.n MOD 10000 = 0 THEN 100
               WHEN s.n MOD 1000 = 0 THEN 20
               ELSE ((s.n + 4) MOD 5) + 1 END      AS qty
  FROM seq_numbers s
  WHERE s.n <= 200000
)
SELECT 1800000 + c.n, c.oid, c.pid, c.qty,
       ROUND(p.list_price * (1 - (c.oid MOD 7) * 0.015), 2),
       c.qty * ROUND(p.list_price * (1 - (c.oid MOD 7) * 0.015), 2)
FROM calc c
JOIN product p ON p.product_id = c.pid;


-- =============================================================================
-- ⑥ 回写订单的明细合计金额
-- 此时 coupon_discount 仍为 0,故 pay_amount = items_amount 满足
-- "实付 = 明细合计 − 券优惠"的检查约束。
-- =============================================================================
UPDATE sales_order o
JOIN (SELECT order_id, SUM(amount) AS s FROM order_item GROUP BY order_id) t
  ON t.order_id = o.order_id
SET o.items_amount = t.s,
    o.pay_amount   = t.s;


-- =============================================================================
-- ⑦ 已核销券(由订单驱动,预计约 22 万行)
-- 约束:coupon_code 唯一;used_order_id 唯一(即一个订单最多核销一张券);
--       已核销时 used_order_id 与 used_time 必须非空且状态为"已核销";
--       expire_time > issue_time;券门槛不得高于订单明细合计;面额不得超过订单金额
-- 设计:取 40% 的已支付类订单((order_id MOD 5 ∈ {0,1}) 且状态为已支付/已完成/已退款)
--       → 在这些订单上,从"启用"模板中选择满足
--           min_amount <= 明细合计金额 且 face_value <= 明细合计金额
--         且受限品类券至少命中订单内一个同品类商品的模板;
--       → 对可选模板按订单号/模板号的确定性散列选取,避免核销券集中在单一模板;
--       领取时间取订单时间前 1..5 天,过期时间 = 领取时间 + 模板有效天数;
--         由于最短有效期为 7 天,券在核销时必然仍在有效期内。
-- =============================================================================
INSERT INTO coupon_instance (coupon_code, template_id, member_id, issue_time, expire_time,
                             coupon_status, used_order_id, used_time, issue_channel,
                             strategy_version, reco_score, issue_level_id,
                             face_value_snap, min_amount_snap)
WITH cand AS (
  SELECT o.order_id, o.member_id, o.order_time, o.pay_time,
         COALESCE(restricted_t.template_id, 1) AS template_id
  FROM sales_order o
  -- 每单第一条明细作为可复现的选券依据；其商品品类与受限模板完全一致。
  JOIN order_item oi ON oi.item_id = (o.order_id - 1) * 3 + 1
  JOIN product p ON p.product_id = oi.product_id
  LEFT JOIN coupon_template restricted_t
    ON restricted_t.category_id = p.category_id
   AND restricted_t.status = '启用'
   AND restricted_t.min_amount <= o.items_amount
   AND restricted_t.face_value <= o.items_amount
  WHERE o.order_id MOD 5 IN (0, 1)
    AND o.order_status IN ('已支付', '已完成', '已退款')
)
SELECT CONCAT('CP', LPAD(c.order_id, 14, '0')),
       t.template_id,
       c.member_id,
       GREATEST(DATE_SUB(c.order_time, INTERVAL ((c.order_id MOD 5) + 1) DAY),
                DATE_ADD(m.register_time, INTERVAL 1 DAY)),
       DATE_ADD(GREATEST(DATE_SUB(c.order_time, INTERVAL ((c.order_id MOD 5) + 1) DAY),
                         DATE_ADD(m.register_time, INTERVAL 1 DAY)),
                INTERVAL t.valid_days DAY),
       '已核销',
       c.order_id,
       c.pay_time,
       CASE WHEN c.order_id MOD 10 < 7 THEN '智能体推荐'
            WHEN c.order_id MOD 10 < 9 THEN '运营活动'
            ELSE '新客注册' END,
       CONCAT('v', (c.order_id MOD 5) + 1),
       ROUND((c.order_id MOD 1000) / 1000, 4),
       1,                      -- 占位:发放时等级在第 ⑬ 步统一回填
        t.face_value,
        t.min_amount
FROM cand c
JOIN coupon_template t ON t.template_id = c.template_id
JOIN member m ON m.member_id = c.member_id;


-- =============================================================================
-- ⑧ 回写订单的券优惠金额与实付金额
-- 两个字段必须在同一条 UPDATE 中写定,否则中间态会违反 ck_order_amount。
-- =============================================================================
UPDATE sales_order o
JOIN coupon_instance c
  ON c.used_order_id = o.order_id
 AND c.coupon_status = '已核销'
SET o.coupon_discount = c.face_value_snap,
    o.pay_amount       = o.items_amount - c.face_value_snap;


-- =============================================================================
-- ⑨ 未使用券与已锁定券(共 450,000 行)
-- 关键约束:**同一会员对同一模板在券未失效前不得重复持有**(BR-27),
--           该约束落在生成列 active_key 的唯一索引上。
-- 实现:构造 (会员, 模板) 的一一映射,确保任意两个"未失效"的券组合不重复——
--       令 k = (n × 7919) MOD 6400000(k 在 1..450000 上各不相同,因 7919 与
--       6400000 = 2^11 × 5^5 互质),再令 会员 = k DIV 32 + 1、模板 = k MOD 32 + 1,
--       于是 450000 组 (会员, 模板) 两两不同。
-- 状态:每 6 个中有 1 个"已锁定",其余"未使用";
--       领取时间为 2026-10-20..2026-10-22,过期时间 = 领取时间 + 有效天数,
--       最短有效期 7 天,故全部券在生成当日仍未过期。
-- =============================================================================
INSERT INTO coupon_instance (coupon_code, template_id, member_id, issue_time, expire_time,
                             coupon_status, used_order_id, used_time, issue_channel,
                             strategy_version, reco_score, issue_level_id,
                             face_value_snap, min_amount_snap)
WITH act AS (
  SELECT s.n,
         (((s.n * 7919) MOD 6400000) DIV 32) + 1 AS mid,
         ((s.n * 7919) MOD 6400000) MOD 32 + 1   AS tid
  FROM seq_numbers s
  WHERE s.n <= 450000
)
SELECT CONCAT('CP', LPAD(900000000 + a.n, 14, '0')),
       a.tid,
       a.mid,
       DATE_SUB('2026-10-22 10:00:00', INTERVAL ((a.n - 1) MOD 3) DAY),
       DATE_ADD(DATE_SUB('2026-10-22 10:00:00', INTERVAL ((a.n - 1) MOD 3) DAY),
                INTERVAL t.valid_days DAY),
       CASE WHEN a.n MOD 6 = 0 THEN '已锁定' ELSE '未使用' END,
       NULL,
       NULL,
       CASE WHEN a.n MOD 10 < 7 THEN '智能体推荐'
            WHEN a.n MOD 10 < 9 THEN '运营活动'
            ELSE '新客注册' END,
       CONCAT('v', (a.n MOD 5) + 1),
       ROUND((a.n MOD 1000) / 1000, 4),
       1,                      -- 占位:发放时等级在第 ⑬ 步统一回填
       t.face_value,
       t.min_amount
FROM act a
JOIN coupon_template t ON t.template_id = a.tid
JOIN member m          ON m.member_id   = a.mid
                      AND m.status      = '正常';   -- BR-07:冻结/注销会员不发新券


-- =============================================================================
-- ⑩ 已过期券(824,400 行)
-- 此类券的 active_key 为 NULL(生成列仅在"未使用/已锁定"时取值),
-- 因此不受 BR-27 的唯一性限制,可自由组合会员与模板。
-- 设计:领取时间在 2025-12-04..2026-06-01 之间,过期时间 = 领取时间 + 有效天数,
--       最长有效期 35 天,故全部券的过期时间都早于当前时间,状态为"已过期"合理。
-- =============================================================================
INSERT INTO coupon_instance (coupon_code, template_id, member_id, issue_time, expire_time,
                             coupon_status, used_order_id, used_time, issue_channel,
                             strategy_version, reco_score, issue_level_id,
                             face_value_snap, min_amount_snap)
WITH expired_source AS (
SELECT s.n, t.template_id, t.valid_days, m.member_id,
       GREATEST(DATE_SUB('2026-06-01 00:00:00', INTERVAL ((s.n - 1) MOD 180) DAY),
                DATE_ADD(m.register_time, INTERVAL 1 DAY)) AS issue_time,
       t.face_value, t.min_amount
FROM seq_numbers s
JOIN coupon_template t ON t.template_id = ((s.n - 1) MOD 32) + 1
JOIN member m          ON m.member_id   = ((s.n - 1) MOD 200000) + 1
                      AND m.status      = '正常'
WHERE s.n <= 824400
)
SELECT CONCAT('CP', LPAD(500000000 + e.n, 14, '0')),
       e.template_id, e.member_id, e.issue_time,
       DATE_ADD(e.issue_time, INTERVAL e.valid_days DAY),
       '已过期',
       NULL,
       NULL,
        CASE WHEN e.n MOD 10 < 7 THEN '智能体推荐'
             WHEN e.n MOD 10 < 9 THEN '运营活动'
            ELSE '新客注册' END,
        CONCAT('v', (e.n MOD 5) + 1),
        ROUND((e.n MOD 1000) / 1000, 4),
       1,                      -- 占位:发放时等级在第 ⑬ 步统一回填
        e.face_value,
        e.min_amount
FROM expired_source e;


-- =============================================================================
-- ⑪ 计算会员累计消费额(派生属性,口径:全部"已完成"订单的实付金额之和)
-- 说明:该口径必须与报告中声明的口径完全一致,否则第 05 号验证脚本会报不一致。
-- =============================================================================
UPDATE member m
JOIN (SELECT member_id, SUM(pay_amount) AS total
      FROM sales_order
      WHERE order_status = '已完成'
      GROUP BY member_id) x
  ON x.member_id = m.member_id
SET m.total_amount = x.total;


-- =============================================================================
-- ⑫ 按门槛升级会员等级(BR-05:累计消费额达到更高等级门槛即升级,等级只升不降)
-- 实现:取"门槛不超过累计消费额"的等级中序号最大者。
-- =============================================================================
UPDATE member m
SET m.level_id = (SELECT l.level_id
                  FROM member_level l
                  WHERE l.upgrade_threshold <= m.total_amount
                  ORDER BY l.level_rank DESC
                  LIMIT 1);


-- =============================================================================
-- ⑬ 回填券实例的"发放时会员等级"
-- 说明:生成脚本先算出会员的最终等级,再回填到券实例。真实系统中该值由智能体在
--       发放当时写入;本脚本采用回填方式,是为避免在生成脚本中模拟三年的等级变更历史。
--       此简化已在报告的"人工校验说明与已知取舍"中如实披露。
-- =============================================================================
UPDATE coupon_instance c
JOIN member m ON m.member_id = c.member_id
SET c.issue_level_id = m.level_id;


-- =============================================================================
-- ⑭ 生成结果自检
-- =============================================================================
SELECT 'product'          AS table_name, COUNT(*) AS row_count FROM product
UNION ALL SELECT 'member',          COUNT(*) FROM member
UNION ALL SELECT 'sales_order',     COUNT(*) FROM sales_order
UNION ALL SELECT 'order_item',      COUNT(*) FROM order_item
UNION ALL SELECT 'coupon_instance', COUNT(*) FROM coupon_instance;

-- 券状态分布
SELECT coupon_status, COUNT(*) AS cnt FROM coupon_instance GROUP BY coupon_status ORDER BY cnt DESC;

-- 订单状态分布
SELECT order_status, COUNT(*) AS cnt FROM sales_order GROUP BY order_status ORDER BY cnt DESC;

-- 会员等级分布
SELECT l.level_name, COUNT(*) AS member_cnt
FROM member m JOIN member_level l ON l.level_id = m.level_id
GROUP BY l.level_name, l.level_rank ORDER BY l.level_rank;

-- 辅助表清理(确认数据无误后可执行,不影响业务表)
-- DROP TABLE seq_numbers;
-- DROP TABLE seq_small;

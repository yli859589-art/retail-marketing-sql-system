-- =============================================================================
--  完整性审计与验证脚本  05_verify_integrity.sql
-- -----------------------------------------------------------------------------
--  用途:本脚本与 04_negative_tests.sql 互补——
--        04 验证"数据库能否拒绝违规数据"(靠约束);
--        05 验证"库里的数据本身是否合规"(靠查询)。
--
--  阅读方式:每段查询都写明**期望结果**。
--    · 标注"期望 0 行"的查询,若返回任何行即为数据不一致,必须修正;
--    · 标注"期望数值"的查询,用于核对数据规模与分布,结果填入报告。
--
--  本脚本可整体执行,不会修改任何数据(全部为只读查询)。
-- =============================================================================

SET NAMES utf8mb4;

-- =============================================================================
-- 第一部分:数据规模核对(V-00)
-- 说明:这些数字要填入报告"数据规模"一节。实际值由本机执行结果确定,
--       报告中不得填写预期值以外的数字。预期量级见注释。
-- =============================================================================
SELECT 'member_level'    AS 表名, COUNT(*) AS 实际行数, '5(字典)'            AS 预期量级 FROM member_level
UNION ALL SELECT 'category',        COUNT(*), '60(10 个一级 + 50 个二级)'      FROM category
UNION ALL SELECT 'product',         COUNT(*), '20000'                          FROM product
UNION ALL SELECT 'member',          COUNT(*), '200000'                         FROM member
UNION ALL SELECT 'coupon_template', COUNT(*), '40(32 启用 + 8 停用)'           FROM coupon_template
UNION ALL SELECT 'sales_order',     COUNT(*), '600000'                         FROM sales_order
UNION ALL SELECT 'order_item',      COUNT(*), '2000000'                        FROM order_item
UNION ALL SELECT 'coupon_instance', COUNT(*), '约 1500000'                     FROM coupon_instance;


-- =============================================================================
-- 第二部分:引用完整性(外键)检查(V-01)
-- 期望:每一行的"孤儿行数"均为 0
-- =============================================================================
SELECT 'member.level_id → member_level'      AS 引用关系, COUNT(*) AS 孤儿行数
  FROM member c LEFT JOIN member_level p ON p.level_id = c.level_id WHERE p.level_id IS NULL
UNION ALL
SELECT 'category.parent_id → category',      COUNT(*)
  FROM category c LEFT JOIN category p ON p.category_id = c.parent_id
 WHERE c.parent_id IS NOT NULL AND p.category_id IS NULL
UNION ALL
SELECT 'product.category_id → category',     COUNT(*)
  FROM product c LEFT JOIN category p ON p.category_id = c.category_id WHERE p.category_id IS NULL
UNION ALL
SELECT 'coupon_template.category_id → category', COUNT(*)
  FROM coupon_template c LEFT JOIN category p ON p.category_id = c.category_id
 WHERE c.category_id IS NOT NULL AND p.category_id IS NULL
UNION ALL
SELECT 'sales_order.member_id → member',     COUNT(*)
  FROM sales_order c LEFT JOIN member p ON p.member_id = c.member_id WHERE p.member_id IS NULL
UNION ALL
SELECT 'order_item.order_id → sales_order',  COUNT(*)
  FROM order_item c LEFT JOIN sales_order p ON p.order_id = c.order_id WHERE p.order_id IS NULL
UNION ALL
SELECT 'order_item.product_id → product',    COUNT(*)
  FROM order_item c LEFT JOIN product p ON p.product_id = c.product_id WHERE p.product_id IS NULL
UNION ALL
SELECT 'coupon_instance.template_id → coupon_template', COUNT(*)
  FROM coupon_instance c LEFT JOIN coupon_template p ON p.template_id = c.template_id WHERE p.template_id IS NULL
UNION ALL
SELECT 'coupon_instance.member_id → member', COUNT(*)
  FROM coupon_instance c LEFT JOIN member p ON p.member_id = c.member_id WHERE p.member_id IS NULL
UNION ALL
SELECT 'coupon_instance.used_order_id → sales_order', COUNT(*)
  FROM coupon_instance c LEFT JOIN sales_order p ON p.order_id = c.used_order_id
 WHERE c.used_order_id IS NOT NULL AND p.order_id IS NULL
UNION ALL
SELECT 'coupon_instance.issue_level_id → member_level', COUNT(*)
  FROM coupon_instance c LEFT JOIN member_level p ON p.level_id = c.issue_level_id WHERE p.level_id IS NULL;


-- =============================================================================
-- 第三部分:一致性恒等式检查(全部期望 0 行)
-- =============================================================================

-- V-02 订单金额恒等式:实付 = 明细合计 − 券优惠(BR-16)
SELECT order_id, order_no, items_amount, coupon_discount, pay_amount
FROM sales_order
WHERE pay_amount <> items_amount - coupon_discount;

-- V-02A 会员时间线：订单与券的发放均不得早于会员注册（期望 0 行）
SELECT '订单早于会员注册' AS 异常类型, o.order_id AS 业务编号
FROM sales_order o JOIN member m ON m.member_id = o.member_id
WHERE o.order_time < m.register_time
UNION ALL
SELECT '优惠券早于会员注册', c.instance_id
FROM coupon_instance c JOIN member m ON m.member_id = c.member_id
WHERE c.issue_time < m.register_time;

-- V-02B 限定品类券的核销订单必须至少包含一个同品类商品（期望 0 行）
SELECT c.instance_id, c.used_order_id, t.category_id AS 限定品类
FROM coupon_instance c
JOIN coupon_template t ON t.template_id = c.template_id
WHERE c.coupon_status = '已核销' AND t.category_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM order_item oi JOIN product p ON p.product_id = oi.product_id
      WHERE oi.order_id = c.used_order_id AND p.category_id = t.category_id
  );

-- V-03 明细金额恒等式:金额 = 数量 × 成交单价
SELECT item_id, order_id, product_id, quantity, unit_price, amount
FROM order_item
WHERE amount <> quantity * unit_price;

-- V-04 订单的明细合计金额 = 该订单明细金额之和(跨关系物化聚合的一致性)
SELECT o.order_id, o.items_amount AS 订单记录值, COALESCE(t.s, 0) AS 明细实际合计
FROM sales_order o
LEFT JOIN (SELECT order_id, SUM(amount) AS s FROM order_item GROUP BY order_id) t
       ON t.order_id = o.order_id
WHERE o.items_amount <> COALESCE(t.s, 0);

-- V-05 会员累计消费额 = 该会员"已完成"订单的实付金额之和
SELECT m.member_id, m.total_amount AS 会员记录值, COALESCE(x.s, 0) AS 订单实际合计
FROM member m
LEFT JOIN (SELECT member_id, SUM(pay_amount) AS s
           FROM sales_order WHERE order_status = '已完成' GROUP BY member_id) x
       ON x.member_id = m.member_id
WHERE m.total_amount <> COALESCE(x.s, 0);

-- V-06 券状态与核销字段一致性(BR-34)
SELECT instance_id, coupon_code, coupon_status, used_order_id, used_time
FROM coupon_instance
WHERE (coupon_status =  '已核销' AND (used_order_id IS NULL OR used_time IS NULL))
   OR (coupon_status <> '已核销' AND (used_order_id IS NOT NULL OR used_time IS NOT NULL));

-- V-07 过期时间 = 领取时间 + 模板有效天数(BR-35 及派生一致性)
SELECT c.instance_id, c.issue_time, c.expire_time, t.valid_days,
       DATE_ADD(c.issue_time, INTERVAL t.valid_days DAY) AS 应有过期时间
FROM coupon_instance c
JOIN coupon_template t ON t.template_id = c.template_id
WHERE c.expire_time <> DATE_ADD(c.issue_time, INTERVAL t.valid_days DAY);

-- V-08 订单状态与支付时间一致性(BR-18)
SELECT order_id, order_no, order_status, pay_time
FROM sales_order
WHERE (order_status IN ('已支付', '已完成', '已退款') AND pay_time IS NULL)
   OR (order_status IN ('待支付', '已取消')            AND pay_time IS NOT NULL);

-- V-09 下单时间不得晚于当前时间(BR-19)
SELECT order_id, order_no, order_time
FROM sales_order
WHERE order_time > NOW();


-- =============================================================================
-- 第四部分:业务规则检查(全部期望 0 行)
-- =============================================================================

-- V-10 同一会员对同一模板存在多张未失效券(BR-27)
SELECT member_id, template_id, COUNT(*) AS 未失效券张数
FROM coupon_instance
WHERE coupon_status IN ('未使用', '已锁定')
GROUP BY member_id, template_id
HAVING COUNT(*) > 1;

-- V-11 一个订单核销了多张券(BR-31)
SELECT used_order_id, COUNT(*) AS 核销券张数
FROM coupon_instance
WHERE coupon_status = '已核销'
GROUP BY used_order_id
HAVING COUNT(*) > 1;

-- V-12 券优惠金额超过订单明细合计金额(BR-32)
SELECT c.instance_id, c.coupon_code, c.face_value_snap, o.items_amount
FROM coupon_instance c
JOIN sales_order o ON o.order_id = c.used_order_id
WHERE c.coupon_status = '已核销'
  AND c.face_value_snap > o.items_amount;

-- V-13 核销时订单金额未达到券的使用门槛(BR-28)
SELECT c.instance_id, c.coupon_code, c.min_amount_snap, o.items_amount
FROM coupon_instance c
JOIN sales_order o ON o.order_id = c.used_order_id
WHERE c.coupon_status = '已核销'
  AND o.items_amount < c.min_amount_snap;

-- V-14 券在核销时已经过期(BR-29:只有未过期的券可以核销)
SELECT c.instance_id, c.coupon_code, c.expire_time, c.used_time
FROM coupon_instance c
WHERE c.coupon_status = '已核销'
  AND c.used_time > c.expire_time;

-- V-15 下架商品出现在订单明细中(BR-11)
SELECT DISTINCT oi.order_id, oi.product_id, p.shelf_status
FROM order_item oi
JOIN product p ON p.product_id = oi.product_id
WHERE p.shelf_status = '下架'
LIMIT 50;

-- V-16 冻结或注销的会员持有未失效券(BR-07)
SELECT c.instance_id, c.coupon_code, c.coupon_status, m.member_id, m.status
FROM coupon_instance c
JOIN member m ON m.member_id = c.member_id
WHERE c.coupon_status IN ('未使用', '已锁定')
  AND m.status IN ('冻结', '注销')
LIMIT 50;

-- V-17 停用的券模板仍被发放过券(BR-24 的业务含义:停用模板不再发放)
SELECT t.template_id, t.status, COUNT(*) AS 券张数
FROM coupon_instance c
JOIN coupon_template t ON t.template_id = c.template_id
WHERE t.status = '停用'
GROUP BY t.template_id, t.status;

-- V-18 等级序号与升级门槛未同向递增(BR-04 的跨行规则:序号越大门槛越高)
SELECT a.level_rank AS 较低序号, a.upgrade_threshold AS 较低门槛,
       b.level_rank AS 较高序号, b.upgrade_threshold AS 较高门槛
FROM member_level a
JOIN member_level b ON b.level_rank > a.level_rank
WHERE b.upgrade_threshold <= a.upgrade_threshold;

-- V-19 会员当前等级与其累计消费额不匹配(BR-05:达到门槛应升级)
SELECT m.member_id, m.total_amount, m.level_id AS 当前等级, l.level_id AS 应有等级
FROM member m
JOIN member_level l ON l.level_id = (SELECT l2.level_id FROM member_level l2
                                     WHERE l2.upgrade_threshold <= m.total_amount
                                     ORDER BY l2.level_rank DESC LIMIT 1)
WHERE m.level_id <> l.level_id
LIMIT 50;

-- V-20 只有"未使用/已锁定"以外的状态却取到了活跃持有键(生成列自检)
SELECT instance_id, coupon_status, active_key
FROM coupon_instance
WHERE (coupon_status IN ('未使用', '已锁定') AND active_key IS NULL)
   OR (coupon_status NOT IN ('未使用', '已锁定') AND active_key IS NOT NULL)
LIMIT 50;

-- V-21 数量、单价、金额等非正数(约束的二次复核)
SELECT 'order_item' AS 表名, COUNT(*) AS 异常行数 FROM order_item
 WHERE quantity <= 0 OR unit_price <= 0 OR amount <= 0
UNION ALL
SELECT 'product',    COUNT(*) FROM product    WHERE list_price <= 0
UNION ALL
SELECT 'member',     COUNT(*) FROM member     WHERE total_amount < 0
UNION ALL
SELECT 'sales_order',COUNT(*) FROM sales_order WHERE items_amount < 0 OR coupon_discount < 0 OR pay_amount < 0;


-- =============================================================================
-- 第五部分:数据分布合理性检查(说明性,用于报告)
-- =============================================================================

-- V-22 时间跨度:订单、券的起止时间应落在合理区间,不留空档
SELECT '订单下单时间' AS 项目, MIN(order_time) AS 最早, MAX(order_time) AS 最晚 FROM sales_order
UNION ALL
SELECT '券领取时间',         MIN(issue_time), MAX(issue_time) FROM coupon_instance
UNION ALL
SELECT '券过期时间',         MIN(expire_time), MAX(expire_time) FROM coupon_instance
UNION ALL
SELECT '会员注册时间',       MIN(register_time), MAX(register_time) FROM member;

-- V-23 券状态分布(可用于报告中说明券的生命周期构成)
SELECT coupon_status AS 券状态, COUNT(*) AS 张数,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM coupon_instance), 2) AS 占比百分比
FROM coupon_instance GROUP BY coupon_status ORDER BY 张数 DESC;

-- V-24 会员等级分布(可用于说明等级体系是否被真实使用)
SELECT l.level_rank AS 序号, l.level_name AS 等级, COUNT(*) AS 会员数,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM member), 2) AS 占比百分比
FROM member m JOIN member_level l ON l.level_id = m.level_id
GROUP BY l.level_rank, l.level_name ORDER BY l.level_rank;

-- V-25 券模板使用情况(应体现"启用模板有券、停用模板无券")
SELECT t.template_id, t.status AS 模板状态, t.face_value AS 面额, t.min_amount AS 门槛,
       COUNT(c.instance_id) AS 发放张数
FROM coupon_template t LEFT JOIN coupon_instance c ON c.template_id = t.template_id
GROUP BY t.template_id, t.status, t.face_value, t.min_amount
ORDER BY 发放张数 DESC, t.template_id
LIMIT 45;

-- V-26 成交单价快照有效性:明细的成交单价与商品当前售价应当存在差异
-- 期望:差异行数 > 0(说明确实按当时价格留了快照,而非直接引用当前售价)
SELECT COUNT(*) AS 明细总行数,
       SUM(CASE WHEN oi.unit_price <> p.list_price THEN 1 ELSE 0 END) AS 与当前售价不同的行数,
       ROUND(SUM(CASE WHEN oi.unit_price <> p.list_price THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS 差异占比
FROM order_item oi JOIN product p ON p.product_id = oi.product_id;

-- V-27 空表检查(期望 0 行:不应存在任何无数据的业务表)
SELECT 'member_level' AS 空表 FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM member_level)
UNION ALL SELECT 'category'        FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM category)
UNION ALL SELECT 'product'         FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM product)
UNION ALL SELECT 'member'          FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM member)
UNION ALL SELECT 'coupon_template' FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM coupon_template)
UNION ALL SELECT 'sales_order'     FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM sales_order)
UNION ALL SELECT 'order_item'      FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM order_item)
UNION ALL SELECT 'coupon_instance' FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM coupon_instance);

-- V-28 单值列检查:某些维度列若只有一个取值,说明数据分布不合理
SELECT 'member.status'          AS 字段, COUNT(DISTINCT status)           AS 不同取值数 FROM member
UNION ALL SELECT 'member.register_channel', COUNT(DISTINCT register_channel) FROM member
UNION ALL SELECT 'sales_order.order_status',COUNT(DISTINCT order_status)    FROM sales_order
UNION ALL SELECT 'coupon_instance.issue_channel', COUNT(DISTINCT issue_channel) FROM coupon_instance
UNION ALL SELECT 'coupon_instance.strategy_version', COUNT(DISTINCT strategy_version) FROM coupon_instance
UNION ALL SELECT 'order_item.quantity',     COUNT(DISTINCT quantity)        FROM order_item
UNION ALL SELECT 'product.shelf_status',    COUNT(DISTINCT shelf_status)    FROM product;


-- =============================================================================
-- 使用说明
-- -----------------------------------------------------------------------------
-- 1. 第二、三、四部分的全部查询都必须返回 **0 行**。若出现非 0 结果:
--      · V-04/V-05 出现差异 → 说明派生字段与源数据不一致,需检查 03 脚本第 ⑥⑧⑪ 步;
--      · V-10/V-11 出现结果   → 说明 BR-27/BR-31 的唯一约束失效;
--      · V-15/V-16 出现结果   → 说明生成脚本的业务规则过滤条件失效;
--      · V-07 出现差异        → 说明过期时间未按模板有效天数派生。
-- 2. 第一、五部分的结果用于填写报告中的"数据规模"与"数据分布"小节。
-- 3. 本脚本为只读,可反复执行。
-- =============================================================================

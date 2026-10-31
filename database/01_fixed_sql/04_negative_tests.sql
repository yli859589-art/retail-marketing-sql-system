-- =============================================================================
--  反向约束测试脚本  04_negative_tests.sql
-- -----------------------------------------------------------------------------
--  用途:验证约束**真的在起作用**。每条语句都是故意违规的写入,执行后**必须报错**。
--        若某条语句竟然执行成功,说明对应的约束缺失或未生效(例如 MySQL 5.7
--        会静默忽略 CHECK 约束),必须立即排查。
--
--  ★ 重要执行方式:本脚本必须**逐条单独执行**,不能整体执行。
--    因为第一条违规语句就会中断整个批处理,后面的测试不会被执行。
--    建议:在客户端中选中单条语句执行,记录返回的错误码与约束名,填入下表。
--
--  结果记录表(执行后填写):
--    测试编号 | 是否按预期报错 | 错误码 | 报出的约束名 | 备注
--    T-01     |                |        |              |
--    ...(共 27 条,即 T-01 至 T-27)
--
--  前置:01_schema.sql → 02_seed_dict.sql → 03_seed_bulk.sql 均已执行。
-- =============================================================================

SET NAMES utf8mb4;

-- =============================================================================
-- 一、主键与唯一性约束(6 条)
-- =============================================================================

-- T-01 主键重复:等级编号 1 已存在
-- 预期:错误 1062,Duplicate entry '1' for key 'member_level.PRIMARY'
INSERT INTO member_level (level_id, level_name, upgrade_threshold, level_rank) VALUES
  (1, '重复编号等级', 0.00, 99);

-- T-02 唯一约束:等级名称"普通会员"已存在(BR-03)
-- 预期:错误 1062,Duplicate entry '普通会员' for key 'uk_level_name'
INSERT INTO member_level (level_id, level_name, upgrade_threshold, level_rank) VALUES
  (99, '普通会员', 0.00, 98);

-- T-03 NOT NULL:会员姓名不得为空
-- 预期:错误 1048,Column 'member_name' cannot be null
INSERT INTO member (card_no, member_name, mobile, level_id, register_time, register_channel, total_amount, status)
VALUES ('M-TEST-0001', NULL, '13900000001', 1, '2026-01-01 00:00:00', '小程序', 0.00, '正常');

-- T-04 唯一约束:手机号重复(BR-01)
-- 预期:错误 1062,Duplicate entry ... for key 'uk_member_mobile'
INSERT INTO member (card_no, member_name, mobile, level_id, register_time, register_channel, total_amount, status)
SELECT 'M-TEST-0002', '合成会员测试', m.mobile, 1, '2026-01-01 00:00:00', '小程序', 0.00, '正常'
FROM member m WHERE m.member_id = 1;

-- T-05 唯一约束:会员卡号重复(BR-02)
-- 预期:错误 1062,Duplicate entry ... for key 'uk_member_card'
INSERT INTO member (card_no, member_name, mobile, level_id, register_time, register_channel, total_amount, status)
SELECT m.card_no, '合成会员测试', '13900000002', 1, '2026-01-01 00:00:00', '门店', 0.00, '正常'
FROM member m WHERE m.member_id = 1;

-- T-06 唯一约束:券码重复(BR-25)
-- 预期:错误 1062,Duplicate entry ... for key 'uk_coupon_code'
-- (取一条"已过期"券复制,其 active_key 为 NULL,不会触发持有唯一性约束)
INSERT INTO coupon_instance (coupon_code, template_id, member_id, issue_time, expire_time,
                             coupon_status, used_order_id, used_time, issue_channel,
                             strategy_version, reco_score, issue_level_id,
                             face_value_snap, min_amount_snap)
SELECT c.coupon_code, c.template_id, c.member_id, c.issue_time, c.expire_time,
       '已过期', NULL, NULL, c.issue_channel, c.strategy_version, c.reco_score,
       c.issue_level_id, c.face_value_snap, c.min_amount_snap
FROM coupon_instance c WHERE c.coupon_status = '已过期' LIMIT 1;


-- =============================================================================
-- 二、外键约束(4 条)
-- =============================================================================

-- T-07 外键:会员引用不存在的等级(使用 TINYINT UNSIGNED 合法范围内的 6,
-- 避免 999 先触发数值越界而掩盖外键验证)
-- 预期:错误 1452,Cannot add or update a child row ... fk_member_level
INSERT INTO member (card_no, member_name, mobile, level_id, register_time, register_channel, total_amount, status)
VALUES ('M-TEST-0003', '合成会员测试', '13900000003', 6, '2026-01-01 00:00:00', '小程序', 0.00, '正常');

-- T-08 外键:订单引用不存在的会员
-- 预期:错误 1452,... fk_order_member
INSERT INTO sales_order (order_no, member_id, order_time, items_amount, coupon_discount,
                         pay_amount, order_status, pay_time)
VALUES ('SO-TEST-0001', 9999999, '2026-01-01 10:00:00', 100.00, 0.00, 100.00, '待支付', NULL);

-- T-09 外键:券模板引用不存在的品类
-- 预期:错误 1452,... fk_template_category
INSERT INTO coupon_template (template_name, face_value, min_amount, valid_days, category_id,
                             status, created_by, created_at)
VALUES ('测试模板-非法品类', 5.00, 10.00, 7, 9999, '停用', '测试', '2026-01-01 00:00:00');

-- T-10 外键:品类自引用到不存在的上级
-- 预期:错误 1452,... fk_category_parent
INSERT INTO category (category_id, category_name, parent_id, level_no)
VALUES (999, '非法二级品类', 8888, 2);


-- =============================================================================
-- 三、检查约束:取值范围(7 条)
-- =============================================================================

-- T-11 检查约束:手机号不是 11 位以 1 开头的数字(BR-01)
-- 预期:错误 3819,Check constraint 'ck_member_mobile' is violated
INSERT INTO member (card_no, member_name, mobile, level_id, register_time, register_channel, total_amount, status)
VALUES ('M-TEST-0004', '合成会员测试', '23800000000', 1, '2026-01-01 00:00:00', '小程序', 0.00, '正常');

-- T-12 检查约束:累计消费额为负数(BR-06)
-- 预期:错误 3819,Check constraint 'ck_member_total' is violated
INSERT INTO member (card_no, member_name, mobile, level_id, register_time, register_channel, total_amount, status)
VALUES ('M-TEST-0005', '合成会员测试', '13900000005', 1, '2026-01-01 00:00:00', '小程序', -1.00, '正常');

-- T-13 检查约束:会员状态取值非法
-- 预期:错误 3819,Check constraint 'ck_member_status' is violated
INSERT INTO member (card_no, member_name, mobile, level_id, register_time, register_channel, total_amount, status)
VALUES ('M-TEST-0006', '合成会员测试', '13900000006', 1, '2026-01-01 00:00:00', '小程序', 0.00, '休眠');

-- T-14 检查约束:商品标准售价为 0(BR-10)
-- 预期:错误 3819,Check constraint 'ck_product_price' is violated
INSERT INTO product (product_name, category_id, list_price, shelf_status, created_at)
VALUES ('测试商品-零价', 101, 0.00, '上架', '2026-01-01 00:00:00');

-- T-15 检查约束:券模板有效天数为 0(BR-22)
-- 预期:错误 3819,Check constraint 'ck_template_days' is violated
INSERT INTO coupon_template (template_name, face_value, min_amount, valid_days, category_id,
                             status, created_by, created_at)
VALUES ('测试模板-零天', 5.00, 10.00, 0, 101, '停用', '测试', '2026-01-01 00:00:00');

-- T-16 检查约束:券状态取值非法(BR-26)
-- 预期:错误 3819,Check constraint 'ck_coupon_status' is violated
-- (状态非法时 active_key 生成列为 NULL,不会触发持有唯一性约束)
INSERT INTO coupon_instance (coupon_code, template_id, member_id, issue_time, expire_time,
                             coupon_status, used_order_id, used_time, issue_channel,
                             strategy_version, reco_score, issue_level_id,
                             face_value_snap, min_amount_snap)
VALUES ('CPZ0000000000016', 1, 1, '2026-10-01 00:00:00', '2026-10-20 00:00:00', '已作废',
        NULL, NULL, '运营活动', 'v1', 0.5000, 1, 5.00, 10.00);

-- T-17 检查约束:推荐得分超出 0~1 区间
-- 预期:错误 3819,Check constraint 'ck_coupon_score' is violated
-- (选取一个当前没有未失效券的会员-模板组合,避免干扰其他约束)
INSERT INTO coupon_instance (coupon_code, template_id, member_id, issue_time, expire_time,
                             coupon_status, used_order_id, used_time, issue_channel,
                             strategy_version, reco_score, issue_level_id,
                             face_value_snap, min_amount_snap)
SELECT 'CPZ0000000000017', t.template_id, m.member_id, '2026-10-01 00:00:00', '2026-10-20 00:00:00',
       '未使用', NULL, NULL, '运营活动', 'v1', 1.5000, m.level_id, t.face_value, t.min_amount
FROM member m
JOIN coupon_template t ON t.template_id = 1
LEFT JOIN coupon_instance c
       ON c.member_id = m.member_id AND c.template_id = 1
      AND c.coupon_status IN ('未使用', '已锁定')
WHERE c.instance_id IS NULL
LIMIT 1;


-- =============================================================================
-- 四、检查约束:跨列一致性与业务规则(5 条)
-- =============================================================================

-- T-18 检查约束:券模板门槛低于面额(BR-21:门槛不得低于面额)
-- 预期:错误 3819,Check constraint 'ck_template_threshold' is violated
INSERT INTO coupon_template (template_name, face_value, min_amount, valid_days, category_id,
                             status, created_by, created_at)
VALUES ('测试模板-门槛低于面额', 20.00, 5.00, 7, 101, '停用', '测试', '2026-01-01 00:00:00');

-- T-19 检查约束:品类层级与上级不一致(BR-08:一级品类不得有上级)
-- 预期:错误 3819,Check constraint 'ck_category_parent_by_level' is violated
INSERT INTO category (category_id, category_name, parent_id, level_no)
VALUES (998, '非法一级品类', 1, 1);

-- T-20 检查约束:订单实付金额 ≠ 明细合计 − 券优惠(BR-16)
-- 预期:错误 3819,Check constraint 'ck_order_amount' is violated
INSERT INTO sales_order (order_no, member_id, order_time, items_amount, coupon_discount,
                         pay_amount, order_status, pay_time)
VALUES ('SO-TEST-0002', 1, '2026-01-01 10:00:00', 100.00, 10.00, 95.00, '待支付', NULL);

-- T-21 检查约束:订单状态与支付时间不一致(BR-18:待支付却填了支付时间)
-- 预期:错误 3819,Check constraint 'ck_order_pay_time' is violated
INSERT INTO sales_order (order_no, member_id, order_time, items_amount, coupon_discount,
                         pay_amount, order_status, pay_time)
VALUES ('SO-TEST-0003', 1, '2026-01-01 10:00:00', 100.00, 0.00, 100.00, '待支付', '2026-01-01 11:00:00');

-- T-22 检查约束:订单明细金额 ≠ 数量 × 成交单价(BR-13/14 的派生一致性)
-- 预期:错误 3819,Check constraint 'ck_item_amount_calc' is violated
-- (商品 19900 未被订单 1 使用,因此不会先触发唯一约束)
INSERT INTO order_item (order_id, product_id, quantity, unit_price, amount)
VALUES (1, 19900, 2, 10.00, 25.00);


-- =============================================================================
-- 五、业务规则类唯一约束(3 条)
-- =============================================================================

-- T-23 唯一约束:同一订单内同一商品重复出现(BR-12)
-- 预期:错误 1062,Duplicate entry ... for key 'uk_item_order_product'
INSERT INTO order_item (order_id, product_id, quantity, unit_price, amount)
SELECT oi.order_id, oi.product_id, 1, oi.unit_price, oi.unit_price
FROM order_item oi WHERE oi.order_id = 1 LIMIT 1;

-- T-24 唯一约束:同一会员对同一模板重复持有未失效券(BR-27)
-- 预期:错误 1062,Duplicate entry ... for key 'uk_coupon_active_hold'
-- (复制一条"未使用"券,会员与模板相同 → active_key 相同)
INSERT INTO coupon_instance (coupon_code, template_id, member_id, issue_time, expire_time,
                             coupon_status, used_order_id, used_time, issue_channel,
                             strategy_version, reco_score, issue_level_id,
                             face_value_snap, min_amount_snap)
SELECT CONCAT('CPX', LPAD(c.instance_id, 13, '0')), c.template_id, c.member_id,
       c.issue_time, c.expire_time, '未使用', NULL, NULL, '运营活动', 'v1', 0.5000,
       c.issue_level_id, c.face_value_snap, c.min_amount_snap
FROM coupon_instance c WHERE c.coupon_status = '未使用' LIMIT 1;

-- T-25 唯一约束:一个订单核销两张券(BR-31)
-- 预期:错误 1062,Duplicate entry ... for key 'uk_coupon_used_order'
-- (复制一条"已核销"券;已核销时 active_key 为 NULL,故只会触发核销订单唯一性)
INSERT INTO coupon_instance (coupon_code, template_id, member_id, issue_time, expire_time,
                             coupon_status, used_order_id, used_time, issue_channel,
                             strategy_version, reco_score, issue_level_id,
                             face_value_snap, min_amount_snap)
SELECT CONCAT('CPY', LPAD(c.instance_id, 13, '0')), c.template_id, c.member_id,
       c.issue_time, c.expire_time, '已核销', c.used_order_id, c.used_time, '运营活动', 'v1', 0.5000,
       c.issue_level_id, c.face_value_snap, c.min_amount_snap
FROM coupon_instance c WHERE c.coupon_status = '已核销' LIMIT 1;


-- =============================================================================
-- 六、检查约束:券状态与时间(2 条)
-- =============================================================================

-- T-26 检查约束:过期时间早于领取时间(BR-35)
-- 预期:错误 3819,Check constraint 'ck_coupon_expire' is violated
INSERT INTO coupon_instance (coupon_code, template_id, member_id, issue_time, expire_time,
                             coupon_status, used_order_id, used_time, issue_channel,
                             strategy_version, reco_score, issue_level_id,
                             face_value_snap, min_amount_snap)
SELECT 'CPZ0000000000026', t.template_id, m.member_id, '2026-10-01 00:00:00', '2026-09-01 00:00:00',
       '未使用', NULL, NULL, '运营活动', 'v1', 0.5000, m.level_id, t.face_value, t.min_amount
FROM member m
JOIN coupon_template t ON t.template_id = 1
LEFT JOIN coupon_instance c
       ON c.member_id = m.member_id AND c.template_id = 1
      AND c.coupon_status IN ('未使用', '已锁定')
WHERE c.instance_id IS NULL
LIMIT 1;

-- T-27 检查约束:券状态与核销字段不一致(BR-34:已核销却无核销订单与核销时间)
-- 预期:错误 3819,Check constraint 'ck_coupon_used_consistency' is violated
INSERT INTO coupon_instance (coupon_code, template_id, member_id, issue_time, expire_time,
                             coupon_status, used_order_id, used_time, issue_channel,
                             strategy_version, reco_score, issue_level_id,
                             face_value_snap, min_amount_snap)
VALUES ('CPZ0000000000027', 1, 1, '2026-10-01 00:00:00', '2026-10-20 00:00:00', '已核销',
        NULL, NULL, '运营活动', 'v1', 0.5000, 1, 5.00, 10.00);


-- =============================================================================
-- 测试结束。若以上 27 条语句全部按预期报错,说明 61 个约束对象均真实生效。
-- 若某条未报错,请记录该约束名并检查:
--   ① 是否为 MySQL 5.7 或更早版本(CHECK 约束被静默忽略);
--   ② 该约束是否在 01_schema.sql 中真实创建(可用 SHOW CREATE TABLE 表名 查看)。
-- =============================================================================

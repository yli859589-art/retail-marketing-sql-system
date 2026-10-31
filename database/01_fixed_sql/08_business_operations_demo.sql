-- 业务操作演示：所有写入均在事务内回滚，不污染正式模拟数据。
SET NAMES utf8mb4;
START TRANSACTION;

-- A. 领取资格：正常会员、启用模板且不存在有效同模板券才可领取。
SELECT m.member_id, t.template_id,
       CASE WHEN m.status <> '正常' THEN '拒绝：会员非正常'
            WHEN t.status <> '启用' THEN '拒绝：模板停用'
            WHEN EXISTS (SELECT 1 FROM coupon_instance c WHERE c.member_id=m.member_id AND c.template_id=t.template_id AND c.coupon_status IN ('未使用','已锁定')) THEN '拒绝：已有有效同模板券'
            ELSE '允许领取' END AS 领取结论
FROM member m CROSS JOIN coupon_template t
WHERE m.member_id=1 AND t.template_id=1;

-- B. 核销资格：核对归属、状态、有效期、门槛、品类；正式更新前仅计算结论。
SELECT c.instance_id, c.used_order_id,
       CASE WHEN c.coupon_status<>'已核销' THEN '拒绝：券状态不可核销'
            WHEN c.member_id<>o.member_id THEN '拒绝：会员不一致'
            WHEN c.used_time NOT BETWEEN c.issue_time AND c.expire_time THEN '拒绝：不在有效期'
            WHEN o.items_amount<c.min_amount_snap THEN '拒绝：未达门槛'
            WHEN c.face_value_snap<>o.coupon_discount THEN '拒绝：优惠金额不一致'
            ELSE '核销记录有效' END AS 核销结论
FROM coupon_instance c JOIN sales_order o ON o.order_id=c.used_order_id
WHERE c.coupon_status='已核销' LIMIT 3;
ROLLBACK;

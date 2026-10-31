-- =============================================================================
--  业务规则逐条验证脚本  06_br_validation.sql
-- -----------------------------------------------------------------------------
--  用途:把第 2 章的 36 条业务规则(BR-01 ~ BR-36)逐条落实到可执行的验证语句上,
--        形成"需求 → 约束 → 验证"的完整闭环。
--
--  为什么本脚本不像 05 那样罗列全部检查:
--    36 条规则中,27 条已由数据库约束直接保证,其生效性由 04_negative_tests.sql
--    的反向测试(T-01 ~ T-27)证明;数据层面的合规性由 05_verify_integrity.sql
--    的审计查询(V-01 ~ V-28)证明。本脚本只补充**两者都未覆盖**的部分:
--      · 需业务逻辑配合、无法用单表约束表达的规则;
--      · 需要按业务口径(而非纯数据一致性)判断的规则;
--      · 规则的"正向证据"——不只是证明没有违规,还要证明规则确实在起作用。
--
--  完整对照表见报告第 8 章 8.3 节(36 行逐条列出验证方式与验证编号)。
--
--  阅读方式:每段查询前都标注了对应的 BR 编号与**期望结果**。
--            期望 0 行的查询若返回数据,即为规则失效,必须排查。
--  前置:01 → 02 → 03 三个脚本已执行完毕。
-- =============================================================================

SET NAMES utf8mb4;

-- =============================================================================
-- 一、业务标识唯一性复核(Q-1)——BR-01、BR-02、BR-03、BR-25
-- 说明:唯一约束已由 T-02、T-04、T-05 证明生效,此处对**全部业务标识**做一次复核,
--       确保生成脚本没有绕过约束写入重复值。
-- 期望:每一行的"重复组数"均为 0
-- =============================================================================
SELECT 'BR-01 会员手机号' AS 业务标识, COUNT(*) AS 重复组数
  FROM (SELECT mobile      FROM member          GROUP BY mobile      HAVING COUNT(*) > 1) t
UNION ALL
SELECT 'BR-02 会员卡号',   COUNT(*)
  FROM (SELECT card_no     FROM member          GROUP BY card_no     HAVING COUNT(*) > 1) t
UNION ALL
SELECT 'BR-03 等级名称',   COUNT(*)
  FROM (SELECT level_name  FROM member_level    GROUP BY level_name  HAVING COUNT(*) > 1) t
UNION ALL
SELECT 'BR-03 等级序号',   COUNT(*)
  FROM (SELECT level_rank  FROM member_level    GROUP BY level_rank  HAVING COUNT(*) > 1) t
UNION ALL
SELECT 'BR-25 券码',       COUNT(*)
  FROM (SELECT coupon_code FROM coupon_instance GROUP BY coupon_code HAVING COUNT(*) > 1) t
UNION ALL
SELECT '订单号(参照)',     COUNT(*)
  FROM (SELECT order_no    FROM sales_order     GROUP BY order_no    HAVING COUNT(*) > 1) t;


-- =============================================================================
-- 二、券模板参数合法性与等级规则复核(Q-2、Q-3)——BR-04、BR-20、BR-21、BR-22
-- =============================================================================

-- Q-2 券模板参数:面额 > 0、门槛 >= 面额、有效天数 > 0
-- 期望:0 行
SELECT template_id, template_name, face_value, min_amount, valid_days,
       CASE WHEN face_value <= 0            THEN '面额非正'
            WHEN min_amount < face_value    THEN '门槛低于面额'
            WHEN valid_days <= 0            THEN '有效天数非正'
       END AS 违规原因
FROM coupon_template
WHERE face_value <= 0 OR min_amount < face_value OR valid_days <= 0;

-- Q-3.1 等级门槛非负
-- 期望:0 行
SELECT level_id, level_name, upgrade_threshold
FROM member_level
WHERE upgrade_threshold < 0;

-- Q-3.2 相邻等级的序号与门槛必须同向递增(BR-04 的跨行规则,单表 CHECK 无法表达)
-- 说明:与 05 脚本的 V-18 相比,此处用"相邻等级"比较,结果更直观,
--       便于现场演示时直接看到违反的相邻两行。
-- 期望:0 行
SELECT a.level_rank AS 较低序号, a.level_name AS 较低等级, a.upgrade_threshold AS 较低门槛,
       b.level_rank AS 较高序号, b.level_name AS 较高等级, b.upgrade_threshold AS 较高门槛
FROM member_level a
JOIN member_level b ON b.level_rank = a.level_rank + 1
WHERE b.upgrade_threshold <= a.upgrade_threshold;


-- =============================================================================
-- 三、券状态的静态一致性(Q-4)——BR-29、BR-33
-- 规则:只有"未使用"状态的券可被核销(BR-29);已核销不得回退、已过期不得核销(BR-33)。
-- 可观测的静态后果:"已过期/已锁定"的券上不得残留任何核销信息。
-- 期望:0 行
-- =============================================================================
SELECT instance_id, coupon_code, coupon_status, used_order_id, used_time
FROM coupon_instance
WHERE coupon_status IN ('已过期', '已锁定')
  AND (used_order_id IS NOT NULL OR used_time IS NOT NULL);


-- =============================================================================
-- 四、券核销时间轴(Q-5)——BR-29 的正向证据
-- 规则:券必须在有效期内被核销。
-- 期望:核销总张数 > 0,且"越界核销"为 0(即全部核销都落在 领取时间 ~ 过期时间 之间)
-- =============================================================================
SELECT COUNT(*) AS 核销总张数,
       SUM(CASE WHEN used_time >= issue_time AND used_time <= expire_time THEN 1 ELSE 0 END) AS 有效期内核销,
       SUM(CASE WHEN used_time <  issue_time OR  used_time >  expire_time THEN 1 ELSE 0 END) AS 越界核销,
       ROUND(AVG(DATEDIFF(expire_time, used_time)), 1) AS `平均剩余有效天数(核销时)`
FROM coupon_instance
WHERE coupon_status = '已核销';


-- =============================================================================
-- 五、未失效券的持有者状态分布(Q-6)——BR-07 的正向证据
-- 规则:状态为"冻结"或"注销"的会员不得领取新券。
-- 期望:只出现"正常"一行;若出现"冻结/注销"行,说明 F5 的校验与生成过滤失效。
-- =============================================================================
SELECT m.status AS 会员状态, COUNT(*) AS 未失效券张数
FROM coupon_instance c
JOIN member m ON m.member_id = c.member_id
WHERE c.coupon_status IN ('未使用', '已锁定')
GROUP BY m.status
ORDER BY 未失效券张数 DESC;


-- =============================================================================
-- 六、成交单价的快照有效性(Q-7)——BR-15 的正向证据
-- 规则:成交单价必须是下单当时的售价快照,不能等于"当前售价"的代名词。
-- 判断标准:若成交单价只是引用商品当前售价,则同一商品的所有明细单价必然完全相同。
--           因此"存在多个不同成交单价的商品数"应当**远大于 0**。
-- 期望:存在多个成交单价的商品数接近商品总数(说明快照真实生效)
-- =============================================================================
SELECT COUNT(*) AS 被购买过的商品数,
       SUM(CASE WHEN 不同单价数 > 1  THEN 1 ELSE 0 END) AS 存在多个成交单价的商品数,
       SUM(CASE WHEN 不同单价数 = 1  THEN 1 ELSE 0 END) AS `成交单价唯一(存疑)的商品数`,
       ROUND(SUM(CASE WHEN 不同单价数 > 1 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS 快照生效占比
FROM (SELECT product_id, COUNT(DISTINCT unit_price) AS 不同单价数
      FROM order_item
      GROUP BY product_id) t;


-- =============================================================================
-- 七、券的发放依据字段完整性(Q-8)——BR-36 的正向证据
-- 规则:券实例必须记录发放依据(发放渠道、策略版本、推荐得分、发放时会员等级)。
-- 判断标准:若依据字段只是形式上的非空占位,分布会高度集中;真实的决策依据应当
--           在渠道、版本、得分三个维度上都有分布。
-- 期望:3 个渠道 × 5 个策略版本,每格都有券;平均推荐得分在 0~1 之间且各版本不同
-- =============================================================================
SELECT issue_channel AS 发放渠道,
       strategy_version AS 策略版本,
       COUNT(*) AS 券张数,
       ROUND(AVG(reco_score), 4) AS 平均推荐得分,
       COUNT(DISTINCT issue_level_id) AS 覆盖会员等级数,
       COUNT(DISTINCT member_id) AS 覆盖会员数
FROM coupon_instance
GROUP BY issue_channel, strategy_version
ORDER BY 发放渠道, 策略版本;


-- =============================================================================
-- 八、模板状态与券发放的关系(Q-9)——BR-23、BR-24 的正向证据
-- 规则:模板停用后不再发放新券(BR-24 的业务含义);停用模板的条款不得修改,
--       因此其历史券的条款快照应与模板当前条款一致(BR-23 的可观测后果)。
-- 期望:启用模板发放张数 > 0;停用模板发放张数 = 0
-- =============================================================================
SELECT t.status AS 模板状态,
       COUNT(DISTINCT t.template_id) AS 模板数,
       COUNT(c.instance_id) AS 发放张数,
       SUM(CASE WHEN c.instance_id IS NOT NULL
                 AND (c.face_value_snap <> t.face_value OR c.min_amount_snap <> t.min_amount)
                THEN 1 ELSE 0 END) AS 快照与模板条款不一致张数
FROM coupon_template t
LEFT JOIN coupon_instance c ON c.template_id = t.template_id
GROUP BY t.status;


-- =============================================================================
-- 九、规则覆盖情况说明(无需执行,供核对用)
-- -----------------------------------------------------------------------------
--  BR 编号   落地方式          验证编号              期望结果
--  -------   ---------------   -------------------   -------------------------
--  BR-01     约束              T-04、T-11、Q-1       报错 / 0 重复
--  BR-02     约束              T-05、Q-1             报错 / 0 重复
--  BR-03     约束              T-02、Q-1             报错 / 0 重复
--  BR-04     约束 + 跨行规则    Q-3.1、Q-3.2          0 行
--  BR-05     业务逻辑          V-19                  0 行
--  BR-06     约束              T-12                  报错
--  BR-07     业务逻辑          V-16、Q-6             0 行 / 仅"正常"
--  BR-08     约束              T-19                  报错
--  BR-09     约束              V-01                  0 行
--  BR-10     约束              T-14                  报错
--  BR-11     业务逻辑          V-15                  0 行
--  BR-12     约束              T-23                  报错
--  BR-13     约束              V-21                  0 行
--  BR-14     约束              V-21                  0 行
--  BR-15     建模规则          Q-7、V-26             快照生效占比接近 100%
--  BR-16     约束 + 验证        T-20、V-02            报错 / 0 行
--  BR-17     约束              V-21                  0 行
--  BR-18     约束 + 业务逻辑    T-21、V-08            报错 / 0 行
--  BR-19     约束              T-08、V-09            报错 / 0 行
--  BR-20     约束              Q-2、T-18             0 行 / 报错
--  BR-21     约束              Q-2、T-18             0 行 / 报错
--  BR-22     约束              Q-2、T-15             0 行 / 报错
--  BR-23     业务逻辑          Q-9                   停用模板发放张数 = 0
--  BR-24     约束 + 业务逻辑    Q-9、T-(券模板状态)    报错 / 停用模板无券
--  BR-25     约束              T-06、Q-1             报错 / 0 重复
--  BR-26     约束              T-16                  报错
--  BR-27     约束(生成列)      T-24、V-10            报错 / 0 行
--  BR-28     业务逻辑 + 验证    V-13                  0 行
--  BR-29     业务逻辑 + 约束    Q-4、Q-5、V-14        0 行 / 越界核销 = 0
--  BR-30     约束              V-11                  0 行
--  BR-31     约束              T-25、V-11            报错 / 0 行
--  BR-32     约束 + 验证        V-12                  0 行
--  BR-33     业务逻辑 + 验证    Q-4、V-06、V-14       0 行
--  BR-34     约束              T-27、V-06            报错 / 0 行
--  BR-35     约束              T-26、V-07            报错 / 0 行
--  BR-36     约束 + 正向验证    Q-8                   依据字段有真实分布
--
--  说明:BR-24 的"状态取值受限"部分由 ck_template_status 约束保证,其反向测试
--        未单独编号(与 T-16 同属取值域测试),如需补齐可按 T-16 的写法仿写一条。
-- =============================================================================

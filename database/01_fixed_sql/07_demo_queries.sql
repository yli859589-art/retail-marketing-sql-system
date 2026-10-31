-- =============================================================================
--  现场演示脚本  07_demo_queries.sql
-- -----------------------------------------------------------------------------
--  设计目标:用最少的查询讲清"这个数据库管住了什么、能回答什么"。
--
--  ★ 时间预算:汇报建议 10 分钟,其中数据库演示 3 分钟。
--    3 分钟最多跑 4 条。**推荐现场只跑 D-1、D-3、D-5、D-7 四条(下表标注 ●)**,
--    其余四条作为备用:被追问时随时调出,既显得准备充分,又不会超时。
--
--  ★ 风险控制:每条查询都已给出"预期结果形态"。请在本地执行后**把真实输出固化**
--    (导出 CSV 或截图,存入 08_demo_outputs 目录)。现场以"回放式执行"为主:
--    先展示已固化的输出,再现场重跑一次验证;若现场环境异常,直接展示固化的输出。
--
--  ◆ 演示顺序与讲什么
--    D-1 ● 券效果归因       —— 这个库能回答"哪种券真的被用了"
--    D-2   用券/未用券对比   —— 券到底带来了什么
--    D-3 ● 快照有效性       —— 设计上的关键取舍:为什么必须存快照
--    D-4   会员分层 RFM     —— 智能决策的数据基础
--    D-5 ● 复购间隔中位数   —— SQL 功底(MySQL 无中位数函数,需自行定位)
--    D-6   发放依据分布     —— 智能体的决策是否可追溯
--    D-7 ● 数据质量一条审计 —— 收尾:65 项验证(27 条反向测试 + 29 项审计 +
--                                9 组规则验证)如何压缩成一条可复现语句
--    D-8   索引对比         —— 有索引与无索引的差别
-- =============================================================================

SET NAMES utf8mb4;
-- 分析基准日固定为常量,不用 CURDATE(),保证每次执行结果一致、可复现
-- (本脚本统一以 '2026-10-01' 作为分析基准日)


-- =============================================================================
-- D-1 ● 券效果归因:每种券模板的发放量、核销率与带动金额
-- 讲什么:营销最关心的问题——"我发的券,哪些真的被用了、带来了多大的单"。
-- 涉及:D-1 用到 coupon_template、coupon_instance、sales_order 三张表的分组聚合。
-- 预期形态:10 行以内(仅展示发放量 ≥ 1000 张的模板),
--           核销率应散布在较大区间(不同面额/门槛的券效果不同),
--           核销订单平均金额应**高于**对应模板的使用门槛。
-- =============================================================================
SELECT t.template_id                                        AS 模板编号,
       t.template_name                                      AS 模板名称,
       t.face_value                                         AS 面额,
       t.min_amount                                         AS 门槛,
       t.valid_days                                         AS 有效天数,
       COUNT(c.instance_id)                                 AS 发放张数,
       SUM(c.coupon_status = '已核销')                       AS 核销张数,
       ROUND(SUM(c.coupon_status = '已核销') * 100.0
             / COUNT(c.instance_id), 2)                     AS 核销率百分比,
       ROUND(SUM(CASE WHEN c.coupon_status = '已核销'
                      THEN c.face_value_snap ELSE 0 END), 2) AS 优惠金额合计,
       ROUND(AVG(CASE WHEN c.coupon_status = '已核销'
                      THEN o.items_amount END), 2)           AS 核销订单平均原价
FROM coupon_template t
JOIN coupon_instance c ON c.template_id = t.template_id
LEFT JOIN sales_order o ON o.order_id = c.used_order_id
GROUP BY t.template_id, t.template_name, t.face_value, t.min_amount, t.valid_days
HAVING 发放张数 >= 1000
ORDER BY 核销率百分比 DESC
LIMIT 10;


-- =============================================================================
-- D-2 用券订单与未用券订单的对比:券到底带来了什么
-- 讲什么:同一批已完成订单里,用券订单的客单价与优惠力度差异。
-- 注意:这是**相关性**而非因果性——用券的会员本身可能就更活跃。
--       现场若被追问"这能证明券有效吗",应如实回答:证明相关性需要与对照实验
--       (A/B)配合,本系统记录的是归因数据,不是因果结论。
-- 预期形态:2 行;用券订单的平均原价应高于未用券订单
--           (因为券有使用门槛,用券本身筛选了高客单订单);平均实付则可能接近或略低。
-- =============================================================================
SELECT CASE WHEN c.instance_id IS NULL THEN '未用券订单' ELSE '用券订单' END AS 订单类型,
       COUNT(*)                          AS 订单数,
       ROUND(AVG(o.items_amount), 2)     AS 平均订单原价,
       ROUND(AVG(o.coupon_discount), 2)  AS 平均优惠金额,
       ROUND(AVG(o.pay_amount), 2)       AS 平均实付金额
FROM sales_order o
LEFT JOIN coupon_instance c
       ON c.used_order_id = o.order_id
      AND c.coupon_status = '已核销'
WHERE o.order_status = '已完成'
GROUP BY 订单类型
ORDER BY 订单类型;


-- =============================================================================
-- D-3 ● 快照有效性:同一商品在不同订单中的成交单价并不相同
-- 讲什么:这是第 6 章"快照切断传递依赖"论证的**数据证据**。
--         若成交单价只是引用商品当前售价,同一商品的所有明细单价必然完全相同;
--         实际存在多个单价,说明按订单当时的售价留了快照。
-- 涉及:第 6 章 6.3.8 的快照论证、BR-15。
-- 预期形态:10 行;每行"不同成交单价个数"应大于 1,
--           且最高成交单价应等于该商品的当前售价(未打折的那一档)。
-- =============================================================================
SELECT oi.product_id                             AS 商品编号,
       p.product_name                            AS 商品名称,
       p.list_price                              AS 当前售价,
       COUNT(*)                                  AS 出现明细行数,
       COUNT(DISTINCT oi.unit_price)             AS 不同成交单价个数,
       MIN(oi.unit_price)                        AS 最低成交单价,
       MAX(oi.unit_price)                        AS 最高成交单价
FROM order_item oi
JOIN product p ON p.product_id = oi.product_id
GROUP BY oi.product_id, p.product_name, p.list_price
HAVING 不同成交单价个数 >= 5
ORDER BY 不同成交单价个数 DESC, oi.product_id
LIMIT 10;


-- =============================================================================
-- D-4 会员分层(RFM):用窗口函数给 20 万会员打分层标签
-- 讲什么:这是"营销决策智能体"圈选人群的数据基础——分层结果反哺发券策略,
--         发券产生的数据又回到分层中,构成闭环(见第 3 章 3.2.2)。
-- 涉及:NTILE 窗口函数、LEFT JOIN 处理未消费会员、COALESCE 处理空值。
-- 关键点:未消费会员的最近消费时间用 9999 代替——若直接用 NULL,
--         NTILE 在 ORDER BY ... DESC 下会把 NULL 排到"最近"的一端,导致分层错误。
-- 预期形态:若干行(按分层代码分组);消费额随分层代码升高而升高。
-- =============================================================================
WITH rfm AS (
  SELECT m.member_id,
         l.level_name,
         COALESCE(DATEDIFF('2026-10-01', MAX(o.order_time)), 9999) AS recency_days,
         COUNT(DISTINCT o.order_id)                                AS frequency,
         COALESCE(SUM(o.pay_amount), 0)                            AS monetary
  FROM member m
  JOIN member_level l ON l.level_id = m.level_id
  LEFT JOIN sales_order o
         ON o.member_id = m.member_id
        AND o.order_status = '已完成'
  GROUP BY m.member_id, l.level_name
),
scored AS (
  SELECT r.*,
          -- CUME_DIST 保证相同指标值获得相同分数；R 越近分越高。
          CASE WHEN frequency = 0 THEN 1 ELSE 6 - CEIL(CUME_DIST() OVER (ORDER BY recency_days ASC) * 5) END AS r_score,
          CASE WHEN frequency = 0 THEN 1 ELSE CEIL(CUME_DIST() OVER (ORDER BY frequency ASC) * 5) END AS f_score,
          CASE WHEN monetary = 0 THEN 1 ELSE CEIL(CUME_DIST() OVER (ORDER BY monetary ASC) * 5) END AS m_score
  FROM rfm r
)
SELECT CONCAT(r_score, f_score, m_score) AS 分层代码,
       COUNT(*)                          AS 会员数,
       ROUND(AVG(monetary), 2)           AS 平均消费额,
       ROUND(AVG(recency_days), 0)       AS 平均最近消费间隔天数,
       ROUND(AVG(frequency), 2)          AS 平均订单数
FROM scored
GROUP BY 分层代码
ORDER BY 分层代码 DESC;


-- =============================================================================
-- D-5 ● 会员复购间隔的中位数
-- 讲什么:MySQL 没有 PERCENTILE_CONT,无法直接算中位数——必须自己定位。
--         这一步最能体现 SQL 功底,也是"提问组出难题"的高频考点。
-- 思路:① 用 LAG 求每位会员相邻订单的间隔天数;
--       ② 对每位会员的间隔排序,取中间位置的编号(偶数个取两个);
--       ③ 按区间分桶汇总。
-- 预期形态:4 行(90 天内 / 91~180 天 / 181~365 天 / 365 天以上);
--           数据为每位会员 3 单、共 2 个间隔,故每位会员取两个间隔的平均值。
-- =============================================================================
WITH gaps AS (
  SELECT member_id,
         DATEDIFF(order_time,
                  LAG(order_time) OVER (PARTITION BY member_id ORDER BY order_time)) AS gap_days
  FROM sales_order
  WHERE order_status = '已完成'
),
ranked AS (
  SELECT member_id, gap_days,
         ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY gap_days) AS rn,
         COUNT(*)     OVER (PARTITION BY member_id)                   AS cnt
  FROM gaps
  WHERE gap_days IS NOT NULL
),
per_member AS (
  SELECT member_id, AVG(gap_days) AS median_gap
  FROM ranked
  WHERE rn IN (FLOOR((cnt + 1) / 2), CEIL((cnt + 1) / 2))
  GROUP BY member_id
)
SELECT CASE WHEN median_gap <= 90  THEN '90 天内'
            WHEN median_gap <= 180 THEN '91~180 天'
            WHEN median_gap <= 365 THEN '181~365 天'
            ELSE '365 天以上' END      AS 复购间隔区间,
       COUNT(*)                        AS 会员数,
        ROUND(AVG(median_gap), 1)       AS 区间平均会员中位复购间隔,
        ROUND(MIN(median_gap), 1)       AS 区间最短会员中位间隔,
        ROUND(MAX(median_gap), 1)       AS 区间最长会员中位间隔
FROM per_member
GROUP BY 复购间隔区间
ORDER BY MIN(median_gap);


-- =============================================================================
-- D-6 智能体发放依据的可追溯性
-- 讲什么:系统不只记录"发了什么券",还记录"依据哪一版策略、打分多少、当时什么等级"。
--         这是考核要求里"智能系统"属性最实在的体现,也是 BR-36 的正向证据。
-- 预期形态:15 行(3 个渠道 × 5 个策略版本);
--           各版本的平均推荐得分应互不相同(说明得分不是常量占位);
--           覆盖会员等级数应大于 1。
-- =============================================================================
SELECT issue_channel                  AS 发放渠道,
       strategy_version               AS 策略版本,
       COUNT(*)                       AS 券张数,
       ROUND(AVG(reco_score), 4)      AS 平均推荐得分,
       ROUND(MIN(reco_score), 4)      AS 最低得分,
       ROUND(MAX(reco_score), 4)      AS 最高得分,
       COUNT(DISTINCT issue_level_id) AS 覆盖会员等级数,
       COUNT(DISTINCT member_id)      AS 覆盖会员数
FROM coupon_instance
GROUP BY issue_channel, strategy_version
ORDER BY 发放渠道, 策略版本;


-- =============================================================================
-- D-7 ● 一条 SQL 完成数据质量审计(收尾)
-- 讲什么:把最关键的 5 条一致性检查压成一条语句,全部应为 0。
--         这句话可以作为演示的收尾:"我们不仅写了约束,还能用一条 SQL 证明
--         库里的 430 万行数据没有违反这些约束。"
-- 相关:完整的 29 项审计见 05_verify_integrity.sql。
-- 预期形态:5 行,全部为 0
-- =============================================================================
SELECT '订单金额恒等式(实付 = 明细合计 − 券优惠)' AS 检查项, COUNT(*) AS 异常行数
  FROM sales_order WHERE pay_amount <> items_amount - coupon_discount
UNION ALL
SELECT '券优惠金额未超过订单原价', COUNT(*)
  FROM coupon_instance c
  JOIN sales_order o ON o.order_id = c.used_order_id
 WHERE c.coupon_status = '已核销' AND c.face_value_snap > o.items_amount
UNION ALL
SELECT '核销时券仍在有效期内', COUNT(*)
  FROM coupon_instance
 WHERE coupon_status = '已核销' AND used_time > expire_time
UNION ALL
SELECT '同一会员同模板无重复持有', COUNT(*)
  FROM (SELECT member_id, template_id FROM coupon_instance
        WHERE coupon_status IN ('未使用', '已锁定')
        GROUP BY member_id, template_id HAVING COUNT(*) > 1) t
UNION ALL
SELECT '下架商品未进入订单明细', COUNT(*)
  FROM order_item oi
  JOIN product p ON p.product_id = oi.product_id
 WHERE p.shelf_status = '下架'
UNION ALL
SELECT '订单时间早于会员注册', COUNT(*)
  FROM sales_order o JOIN member m ON m.member_id=o.member_id
 WHERE o.order_time < m.register_time
UNION ALL
SELECT '优惠券领取早于会员注册', COUNT(*)
  FROM coupon_instance c JOIN member m ON m.member_id=c.member_id
 WHERE c.issue_time < m.register_time
UNION ALL
SELECT '核销券与订单会员不一致', COUNT(*)
  FROM coupon_instance c JOIN sales_order o ON o.order_id=c.used_order_id
 WHERE c.coupon_status='已核销' AND c.member_id<>o.member_id;


-- =============================================================================
-- D-8 索引对比:有索引与无索引的差别
-- 讲什么:证明第 5 章的索引不是摆设。重点看两处字段:
--           · key   :有索引时为 idx_order_member_time,忽略索引时为 NULL
--           · rows  :预估扫描行数,忽略索引时会跳到数十万行
--           · type  :有索引时为 ref,忽略索引时为 ALL(全表扫描)
-- 版本要求:EXPLAIN ANALYZE 需要 MySQL 8.0.18 及以上;若版本不足,只跑前两条 EXPLAIN。
-- 预期形态:两个执行计划的关键字段明显不同。
-- =============================================================================

-- D-8.1 使用索引
EXPLAIN
SELECT o.order_id, o.order_no, o.order_time, o.pay_amount
FROM sales_order o
WHERE o.member_id = 12345
  AND o.order_time >= '2025-01-01';

-- D-8.2 强制忽略该索引,模拟"没有设计这个索引"的情况
EXPLAIN
SELECT o.order_id, o.order_no, o.order_time, o.pay_amount
FROM sales_order o IGNORE INDEX (idx_order_member_time)
WHERE o.member_id = 12345
  AND o.order_time >= '2025-01-01';

-- D-8.3 实际执行对比(可选,MySQL 8.0.18+)
-- EXPLAIN ANALYZE
-- SELECT o.order_id, o.order_no, o.order_time, o.pay_amount
-- FROM sales_order o
-- WHERE o.member_id = 12345 AND o.order_time >= '2025-01-01';


-- =============================================================================
-- 结果固化操作步骤(现场风险控制)
-- -----------------------------------------------------------------------------
-- 1. 在本地执行本脚本,把 D-1 ~ D-8 的实际输出导出:
--      · 命令行:mysql -u用户 -p 库名 < 07_demo_queries.sql > demo_output.txt
--      · 或用客户端把结果集导出为 CSV,放入 08_demo_outputs 目录。
-- 2. 核对每条结果的形态是否与上面的"预期形态"一致。若明显不符:
--      · D-3 若"不同成交单价个数"全部为 1 → 快照未生效,检查 03 脚本第 ④ 步;
--      · D-5 若只有 1 行或 0 行 → 会员订单数不足,检查 03 脚本第 ③ 步;
--      · D-6 若平均推荐得分在各版本间完全相同 → 依据字段是占位值;
--      · D-7 若任一行为非 0 → 先跑 05_verify_integrity.sql 定位具体问题行。
-- 3. 现场演示时按"先展示固化输出 → 再现场重跑"的顺序进行,两种方式互为备份。
-- =============================================================================

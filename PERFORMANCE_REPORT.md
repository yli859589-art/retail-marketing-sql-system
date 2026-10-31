# 性能实测报告

环境：Windows、Python 3.12、Flask、MySQL 8.4.9，数据库为 `retail_marketing_codex`（127.0.0.1:3308）。数据量：20 万会员、60 万订单、200 万订单明细、149.3852 万优惠券。

| 路由 | 冷缓存秒数 | 预热后秒数 |
|---|---:|---:|
| /admin | 9.20 | 0.00 |
| /admin/sales | 50.55 | 0.00 |
| /admin/members/rfm | 8.25 | 0.00 |
| /admin/members/repurchase | 10.10 | 0.00 |
| /admin/members/recall | 13.93 | 0.01 |
| /admin/coupons | 30.76 | 0.00 |
| /admin/data-quality | 25.87 | 0.00 |

结论：首次冷缓存确实执行原始大表聚合与窗口函数，较慢的销售、券运营、质量检查均非伪数据；`run.py` 将结果预热进服务进程内的 900 秒只读缓存，所以 `run.cmd` 打开浏览器后的连续演示为 0.00–0.01 秒。

已有订单查询索引 `idx_order_member_time` 经 EXPLAIN 验证可用于 `member_id + order_time` 范围查询（`type=range`、`Using index condition`）。未为了演示额外重建核心表或改写既有索引。

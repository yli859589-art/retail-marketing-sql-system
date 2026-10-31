# 浏览器验收记录

Windows 本机浏览器对 `http://127.0.0.1:5000` 的实际检查完成：登录页加载本地 Chart.js；管理员登录后经营驾驶舱显示真实 KPI 与两张图表；管理订单复合筛选状态、日期、券、实付区间和 50 条/页已生效，下一页链接保留所有参数；客户 `customer001` 登录后“我的优惠券”仅显示绑定会员 #20000 的 3 张券。

对应原始浏览器截图：`screenshots/admin_dashboard.jpg`、`screenshots/admin_orders_filtered.jpg`、`screenshots/customer_coupons.jpg`。

本机启动脚本的预热状态接口返回 `completed` 后才打开页面。该记录不包含用户隐私数据或数据库密码。

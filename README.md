# 智能零售会员营销与优惠券运营系统

基于 **MySQL 8.0.16+** 与 **Flask 3.1** 的课程设计源码，包含可再现的数据库结构、合成数据生成、完整性/业务规则验证、客户会员中心和商家经营后台。

## 功能

- 数据库 `retail_marketing_codex`：会员、商品、订单、优惠券八张核心表及约束。
- 建表、字典、批量合成数据、负向约束测试、完整性验证和业务 SQL。
- CUSTOMER：个人概览、订单、消费分析、优惠券、资料。
- ADMIN：经营总览、销售、订单、商品、会员、RFM、复购、召回、券运营、营销、质量和性能页面。
- Flask/Jinja2 后端，参数化 SQL 查询和本地图表资源。

## 安装与数据库部署

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
Copy-Item .env.example .env
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

将最后一条命令生成的值填入 `.env` 的 `FLASK_SECRET_KEY`，并填写 MySQL 账户。`.env` 不得提交。

运行环境为 MySQL **8.0.16 或更高版本**（原验收环境为 MySQL 8.4.9）。`CHECK` 约束在旧版 MySQL 中不会可靠执行。

```powershell
# .env 中的 MYSQL_* 参数用于以下可再现导入与验证脚本。
python database/02_execution_tools/run_all.py --database retail_marketing_codex
python database/02_execution_tools/run_negative_tests.py
```

`database/01_fixed_sql/` 按顺序提供：`01_schema.sql`、`02_seed_dict.sql`、`03_seed_bulk.sql`、`04_negative_tests.sql`、`05_verify_integrity.sql`、`06_br_validation.sql`、`07_demo_queries.sql` 和 `08_business_operations_demo.sql`。

## 启动 Web 系统

```powershell
python run.py
```

打开 `http://127.0.0.1:5000`。`run.cmd` 可用于 Windows。本机演示账户由 `scripts/setup_demo_accounts.py` 创建，属于公开的合成开发账号；在任何网络部署前必须更换或禁用。

## 测试证据与限制

- 随项目附带的最终验收记录为：SQL 负向约束测试 **27/27** 通过，Web pytest **6/6** 通过。
- SQL 与 Web 测试记录分别在 `database/04_test_results/` 和 `04_test_results/`；截图仅显示合成编号和聚合数据。
- 本次发布未在每个新克隆中重新导入数百万条合成数据：完整运行需要本地 MySQL 实例与相应资源。
- 这是本地课程项目演示系统，不是生产级认证、授权、备份、监控或部署方案。

## 结构

```text
app/                         Flask routes and database access
templates/                   CUSTOMER and ADMIN pages
static/                      CSS and local Chart.js bundle
database/01_fixed_sql/        Schema, seed, validation and demo SQL
database/02_execution_tools/  Reproducible import and negative-test scripts
database/04_test_results/     SQL validation evidence
scripts/                      Flask integration and database helper scripts
tests/                        Flask pytest suite
.env.example                 Safe configuration template
```

## 安全边界

数据库种子为合成数据。仓库不含 MySQL 备份、真实凭据、静态 Session 密钥、个人客户数据或私人绝对路径。`.env`、缓存、字节码、日志、数据库转储和发布 ZIP 均被 `.gitignore` 排除。

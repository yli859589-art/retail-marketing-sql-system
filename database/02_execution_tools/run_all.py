"""在指定的 MySQL 8 实例中重建并填充本项目数据库。

连接参数只从环境变量读取：MYSQL_HOST、MYSQL_PORT、MYSQL_USER、MYSQL_PASSWORD。
默认连接为 127.0.0.1:3307 的 root 用户；口令从不写入日志。
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "01_fixed_sql"
LOG = ROOT / "05_logs" / "database_execution.log"
SCRIPTS = ("01_schema.sql", "02_seed_dict.sql", "03_seed_bulk.sql")

def mysql_command(database: str) -> list[str]:
    cmd = [os.environ.get("MYSQL_BIN", "mysql"), "--protocol=TCP",
           "--host", os.environ.get("MYSQL_HOST", "127.0.0.1"),
           "--port", os.environ.get("MYSQL_PORT", "3307"),
           "--user", os.environ.get("MYSQL_USER", "root"),
           "--default-character-set=utf8mb4", "--database", database,
           "--show-warnings"]
    return cmd

def run_sql(database: str, file: Path) -> None:
    started = time.perf_counter()
    env = os.environ.copy()
    if env.get("MYSQL_PASSWORD"):
        env["MYSQL_PWD"] = env["MYSQL_PASSWORD"]
    source = file.read_text(encoding="utf-8-sig")
    result = subprocess.run(mysql_command(database), input=source, text=True,
                            encoding="utf-8", errors="replace", env=env,
                            capture_output=True)
    elapsed = time.perf_counter() - started
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as log:
        log.write(f"{file.name}\t{elapsed:.2f}s\texit={result.returncode}\n")
        log.write(result.stdout)
        log.write(result.stderr)
        log.write("\n")
    if result.returncode:
        raise RuntimeError(f"{file.name} 执行失败，详见 {LOG}")

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", default="retail_marketing_codex")
    args = parser.parse_args()
    LOG.parent.mkdir(parents=True, exist_ok=True)
    # 先在系统库创建目标库；后续 schema 的 DROP TABLE 仅影响这个数据库。
    create = "CREATE DATABASE IF NOT EXISTS `{}` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;".format(args.database)
    env = os.environ.copy()
    if env.get("MYSQL_PASSWORD"):
        env["MYSQL_PWD"] = env["MYSQL_PASSWORD"]
    result = subprocess.run(mysql_command("mysql"), input=create, text=True,
                            encoding="utf-8", env=env, capture_output=True)
    if result.returncode:
        LOG.write_text("创建目标数据库失败（敏感连接信息未记录）。\n" + result.stderr, encoding="utf-8")
        return result.returncode
    LOG.write_text("", encoding="utf-8")
    try:
        for name in SCRIPTS:
            run_sql(args.database, SQL_DIR / name)
    except RuntimeError as exc:
        print(exc, file=sys.stderr)
        return 1
    print(f"数据库 {args.database} 已完成 schema、字典和全量模拟数据导入。")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

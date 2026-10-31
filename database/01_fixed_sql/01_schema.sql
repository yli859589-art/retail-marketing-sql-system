-- =============================================================================
--  智能零售会员营销与优惠券运营系统 — 建表脚本(01_schema.sql)
-- -----------------------------------------------------------------------------
--  目标数据库:MySQL 8.0.16 及以上
--    重要:CHECK 约束自 MySQL 8.0.16 起才真正生效。若使用 5.7 或更早版本,
--          本脚本仍可执行,但全部 CHECK 约束会被静默忽略,必须改用触发器实现,
--          否则"约束设计"与"测试数据满足约束"两部分要求都无法成立。
--  字符集:utf8mb4
--  可重复执行:脚本先按外键反向依赖顺序删除旧表,再重新创建。
--  建议执行方式:在客户端(如 MySQL Workbench、Navicat、命令行 mysql)中整体执行。
-- =============================================================================

SET NAMES utf8mb4;
-- 若尚未建库,取消下面两行注释
-- CREATE DATABASE IF NOT EXISTS retail_marketing DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
-- USE retail_marketing;

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS coupon_instance;
DROP TABLE IF EXISTS order_item;
DROP TABLE IF EXISTS sales_order;
DROP TABLE IF EXISTS coupon_template;
DROP TABLE IF EXISTS product;
DROP TABLE IF EXISTS member;
DROP TABLE IF EXISTS category;
DROP TABLE IF EXISTS member_level;
SET FOREIGN_KEY_CHECKS = 1;


-- =============================================================================
-- 表 1:member_level  会员等级
-- 用途:定义会员等级及其升级门槛,是会员归属等级与升级评估的依据。
-- 主键:level_id      候选键:level_name、level_rank
-- 对应业务规则:BR-03(名称唯一)、BR-04(门槛非负、序号为正)
-- 说明:"序号越大门槛越高"是跨行规则,无法用单表 CHECK 表达,由业务逻辑保证,
--       并在验证脚本中以 SQL 核对(见后续章节 V-04)。
-- =============================================================================
CREATE TABLE member_level (
  level_id          TINYINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '等级编号,代理主键',
  level_name        VARCHAR(20)      NOT NULL                COMMENT '等级名称,业务唯一标识',
  upgrade_threshold DECIMAL(12,2)    NOT NULL DEFAULT 0.00   COMMENT '升级门槛金额:累计消费额达到该值即可升级',
  level_rank        TINYINT UNSIGNED NOT NULL                COMMENT '等级序号,数值越大等级越高',
  created_at        DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (level_id),
  UNIQUE KEY uk_level_name (level_name),
  UNIQUE KEY uk_level_rank (level_rank),
  CONSTRAINT ck_level_threshold CHECK (upgrade_threshold >= 0),
  CONSTRAINT ck_level_rank      CHECK (level_rank > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='会员等级字典表';


-- =============================================================================
-- 表 2:category  商品品类
-- 用途:商品的两级分类,承载"商品→二级品类→一级品类"的层级结构。
-- 主键:category_id   候选键:(parent_id, category_name)
-- 对应业务规则:BR-08(品类最多两级;二级必须有上级,一级不得有上级)
-- 说明:parent_key 为生成列,把 NULL 归一为 0,使一级品类的名称唯一性约束
--       也能生效(MySQL 唯一索引允许多个 NULL,直接用 parent_id 会导致一级品类漏检)。
-- =============================================================================
CREATE TABLE category (
  category_id   SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '品类编号,代理主键',
  category_name VARCHAR(30)       NOT NULL                COMMENT '品类名称,同一上级下唯一',
  parent_id     SMALLINT UNSIGNED NULL                    COMMENT '上级品类编号,一级品类为空',
  level_no      TINYINT UNSIGNED  NOT NULL                COMMENT '层级:1=一级品类,2=二级品类',
  parent_key    SMALLINT UNSIGNED GENERATED ALWAYS AS (IFNULL(parent_id, 0)) STORED
                                                          COMMENT '上级键:NULL 归一为 0,供唯一约束使用',
  PRIMARY KEY (category_id),
  UNIQUE KEY uk_parent_name (parent_key, category_name),
  KEY idx_parent (parent_id),
  CONSTRAINT fk_category_parent FOREIGN KEY (parent_id) REFERENCES category (category_id)
      ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_category_level CHECK (level_no IN (1, 2)),
  CONSTRAINT ck_category_parent_by_level CHECK (
        (level_no = 1 AND parent_id IS NULL)
     OR (level_no = 2 AND parent_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品品类表(两级,自引用层级)';


-- =============================================================================
-- 表 3:product  商品
-- 用途:商品主数据。list_price 为标准售价的当前值,不承担历史职责。
-- 主键:product_id    可选候选键:(category_id, product_name)(本设计未强制)
-- 对应业务规则:BR-09(必须归属一个品类)、BR-10(标准售价大于 0)
-- 说明:商品名称不冗余进订单明细,查询时通过外键关联获取(见规范化分析)。
-- =============================================================================
CREATE TABLE product (
  product_id   INT UNSIGNED      NOT NULL AUTO_INCREMENT COMMENT '商品编号,代理主键',
  product_name VARCHAR(60)       NOT NULL                COMMENT '商品名称',
  category_id  SMALLINT UNSIGNED NOT NULL                COMMENT '所属品类编号',
  list_price   DECIMAL(10,2)     NOT NULL                COMMENT '标准售价(当前值)',
  shelf_status VARCHAR(6)        NOT NULL DEFAULT '上架'  COMMENT '上架状态:上架/下架',
  created_at   DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (product_id),
  KEY idx_product_category (category_id),
  CONSTRAINT fk_product_category FOREIGN KEY (category_id) REFERENCES category (category_id)
      ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_product_price CHECK (list_price > 0),
  CONSTRAINT ck_product_shelf CHECK (shelf_status IN ('上架', '下架'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品表';


-- =============================================================================
-- 表 4:member  会员
-- 用途:会员主数据与等级归属。total_amount 为派生属性,由已完成订单累加。
-- 主键:member_id     候选键:card_no、mobile
-- 对应业务规则:BR-01(手机号唯一且 11 位数字)、BR-02(卡号唯一)、BR-06(累计消费额非负)
-- 说明:会员表不保存等级自身的属性(如升级门槛金额),以避免传递依赖。
-- =============================================================================
CREATE TABLE member (
  member_id        BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT '会员编号,代理主键',
  card_no          VARCHAR(20)      NOT NULL                COMMENT '会员卡号,业务唯一标识',
  member_name      VARCHAR(30)      NOT NULL                COMMENT '会员姓名(合成数据)',
  mobile           CHAR(11)         NOT NULL                COMMENT '手机号,11 位数字且唯一',
  level_id         TINYINT UNSIGNED NOT NULL                COMMENT '所属等级编号',
  register_time    DATETIME         NOT NULL                COMMENT '注册时间',
  register_channel VARCHAR(20)      NOT NULL                COMMENT '注册渠道:小程序/门店/线上广告/朋友推荐',
  total_amount     DECIMAL(14,2)    NOT NULL DEFAULT 0.00   COMMENT '累计消费额(派生属性)',
  status           VARCHAR(6)       NOT NULL DEFAULT '正常'  COMMENT '会员状态:正常/冻结/注销',
  created_at       DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  updated_at       DATETIME         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (member_id),
  UNIQUE KEY uk_member_card   (card_no),
  UNIQUE KEY uk_member_mobile (mobile),
  KEY idx_member_level (level_id),
  CONSTRAINT fk_member_level FOREIGN KEY (level_id) REFERENCES member_level (level_id)
      ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_member_mobile  CHECK (mobile REGEXP '^1[0-9]{10}$'),
  CONSTRAINT ck_member_total   CHECK (total_amount >= 0),
  CONSTRAINT ck_member_status  CHECK (status IN ('正常', '冻结', '注销')),
  CONSTRAINT ck_member_channel CHECK (register_channel IN ('小程序', '门店', '线上广告', '朋友推荐'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='会员表';


-- =============================================================================
-- 表 5:coupon_template  券模板
-- 用途:营销策略的配置载体。模板一经启用,条款不可修改,变更须新建模板,
--       以保证历史券的条款可回溯。
-- 主键:template_id   候选键:仅 template_id(模板名称允许重复,不构成候选键)
-- 对应业务规则:BR-20(面额大于 0)、BR-21(门槛不低于面额)、BR-22(有效天数为正)、
--              BR-24(状态取值受限)
-- =============================================================================
CREATE TABLE coupon_template (
  template_id   INT UNSIGNED      NOT NULL AUTO_INCREMENT COMMENT '模板编号,代理主键',
  template_name VARCHAR(40)       NOT NULL                COMMENT '模板名称(允许同名不同批次)',
  face_value    DECIMAL(8,2)      NOT NULL                COMMENT '券面额(优惠金额)',
  min_amount    DECIMAL(10,2)     NOT NULL DEFAULT 0.00   COMMENT '使用门槛:订单明细合计金额下限',
  valid_days    SMALLINT UNSIGNED NOT NULL                COMMENT '有效天数,自领取之日起算',
  category_id   SMALLINT UNSIGNED NULL                    COMMENT '适用品类编号,为空表示不限品类',
  status        VARCHAR(6)        NOT NULL DEFAULT '停用'  COMMENT '模板状态:启用/停用',
  created_by    VARCHAR(30)       NOT NULL                COMMENT '创建人',
  created_at    DATETIME          NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  PRIMARY KEY (template_id),
  KEY idx_template_category (category_id),
  CONSTRAINT fk_template_category FOREIGN KEY (category_id) REFERENCES category (category_id)
      ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_template_face   CHECK (face_value > 0),
  CONSTRAINT ck_template_min    CHECK (min_amount >= 0),
  CONSTRAINT ck_template_days   CHECK (valid_days > 0),
  CONSTRAINT ck_template_status CHECK (status IN ('启用', '停用')),
  CONSTRAINT ck_template_threshold CHECK (min_amount >= face_value)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='券模板表';


-- =============================================================================
-- 表 6:sales_order  订单
-- 用途:交易主记录。items_amount 与 pay_amount 为派生属性,保留以满足对账与
--       约束落地(BR-16)的需要,其一致性由 ck_order_amount 强制保证。
-- 主键:order_id      候选键:order_no
-- 对应业务规则:BR-16(实付=明细合计−券优惠且非负)、BR-17(金额字段非负)、
--              BR-18(状态取值与支付时间一致性)、BR-19(必须属于一个会员)
-- =============================================================================
CREATE TABLE sales_order (
  order_id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '订单编号,代理主键',
  order_no        VARCHAR(24)     NOT NULL                COMMENT '订单号,业务唯一标识',
  member_id       BIGINT UNSIGNED NOT NULL                COMMENT '所属会员编号',
  order_time      DATETIME        NOT NULL                COMMENT '下单时间',
  items_amount    DECIMAL(12,2)   NOT NULL DEFAULT 0.00   COMMENT '明细合计金额(派生属性)',
  coupon_discount DECIMAL(10,2)   NOT NULL DEFAULT 0.00   COMMENT '券优惠金额',
  pay_amount      DECIMAL(12,2)   NOT NULL DEFAULT 0.00   COMMENT '实付金额(派生属性)',
  order_status    VARCHAR(6)      NOT NULL DEFAULT '待支付' COMMENT '订单状态:待支付/已支付/已完成/已取消/已退款',
  pay_time        DATETIME        NULL                    COMMENT '支付时间,未支付为空',
  PRIMARY KEY (order_id),
  UNIQUE KEY uk_order_no (order_no),
  KEY idx_order_member_time (member_id, order_time),
  KEY idx_order_status (order_status),
  CONSTRAINT fk_order_member FOREIGN KEY (member_id) REFERENCES member (member_id)
      ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_order_items    CHECK (items_amount >= 0),
  CONSTRAINT ck_order_discount CHECK (coupon_discount >= 0),
  CONSTRAINT ck_order_pay      CHECK (pay_amount >= 0),
  CONSTRAINT ck_order_status   CHECK (order_status IN ('待支付', '已支付', '已完成', '已取消', '已退款')),
  CONSTRAINT ck_order_amount   CHECK (pay_amount = items_amount - coupon_discount),
  CONSTRAINT ck_order_pay_time CHECK (
        (order_status IN ('已支付', '已完成', '已退款') AND pay_time IS NOT NULL)
     OR (order_status IN ('待支付', '已取消')            AND pay_time IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单表';


-- =============================================================================
-- 表 7:order_item  订单明细
-- 用途:由"订单↔商品"M:N 联系提升而来。(order_id, product_id) 是复合候选键。
-- 主键:item_id       候选键:(order_id, product_id)
-- 对应业务规则:BR-12(同单同商品不重复)、BR-13(数量为正)、BR-14(成交单价为正)
-- 说明:unit_price 是下单当时商品售价的快照;amount 为派生属性,由
--       ck_item_amount_calc 强制与"数量×成交单价"保持一致,以消除更新异常风险。
--       商品名称、品类名称不冗余到本表(否则构成部分函数依赖,违反 2NF)。
-- =============================================================================
CREATE TABLE order_item (
  item_id    BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT COMMENT '明细编号,代理主键',
  order_id   BIGINT UNSIGNED   NOT NULL                COMMENT '所属订单编号',
  product_id INT UNSIGNED      NOT NULL                COMMENT '商品编号',
  quantity   SMALLINT UNSIGNED NOT NULL                COMMENT '数量,正整数',
  unit_price DECIMAL(10,2)     NOT NULL                COMMENT '成交单价(下单当时售价的快照)',
  amount     DECIMAL(12,2)     NOT NULL                COMMENT '金额(派生属性:数量×成交单价)',
  PRIMARY KEY (item_id),
  UNIQUE KEY uk_item_order_product (order_id, product_id),
  KEY idx_item_product (product_id),
  CONSTRAINT fk_item_order   FOREIGN KEY (order_id)   REFERENCES sales_order (order_id)
      ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_item_product FOREIGN KEY (product_id) REFERENCES product (product_id)
      ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_item_qty    CHECK (quantity > 0),
  CONSTRAINT ck_item_price  CHECK (unit_price > 0),
  CONSTRAINT ck_item_amount CHECK (amount > 0),
  CONSTRAINT ck_item_amount_calc CHECK (amount = quantity * unit_price)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='订单明细表(由订单↔商品 M:N 联系提升)';


-- =============================================================================
-- 表 8:coupon_instance  券实例
-- 用途:由"会员↔券模板"M:N 联系提升而来。既记录券的生命周期,也记录智能体
--       的发放依据(策略版本、推荐得分、发放时等级)与发放时的条款快照。
-- 主键:instance_id   候选键:coupon_code、used_order_id(可空唯一)
-- 对应业务规则:BR-25(券码唯一)、BR-26(状态取值)、BR-27(同模板不得重复持有)、
--              BR-30/BR-31(一券一单、一单最多一券)、BR-34(状态与核销字段一致)、
--              BR-35(过期时间晚于领取时间)、BR-36(发放依据必填)
-- 说明:active_key 为生成列——仅当券处于"未使用/已锁定"时取非空值,配合唯一约束
--       实现"同一会员对同一模板在券未失效前不得重复持有"。已核销/已过期的券
--       active_key 为 NULL,而 MySQL 唯一索引允许多个 NULL,因此不会互相冲突。
--       used_order_id 上的唯一约束同时实现"一单最多一券";未核销的券该列为 NULL,
--       多行 NULL 同样允许。
-- =============================================================================
CREATE TABLE coupon_instance (
  instance_id      BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT '券实例编号,代理主键',
  coupon_code      CHAR(16)         NOT NULL                COMMENT '券码,业务唯一标识',
  template_id      INT UNSIGNED     NOT NULL                COMMENT '所属券模板编号',
  member_id        BIGINT UNSIGNED  NOT NULL                COMMENT '所属会员编号',
  issue_time       DATETIME         NOT NULL                COMMENT '领取时间',
  expire_time      DATETIME         NOT NULL                COMMENT '过期时间 = 领取时间 + 模板有效天数',
  coupon_status    VARCHAR(6)       NOT NULL DEFAULT '未使用' COMMENT '券状态:未使用/已锁定/已核销/已过期',
  used_order_id    BIGINT UNSIGNED  NULL                    COMMENT '核销订单编号,未核销为空',
  used_time        DATETIME         NULL                    COMMENT '核销时间,未核销为空',
  issue_channel    VARCHAR(20)      NOT NULL                COMMENT '发放渠道:智能体推荐/运营活动/新客注册',
  strategy_version VARCHAR(20)      NOT NULL                COMMENT '发放依据:策略版本号',
  reco_score       DECIMAL(5,4)     NOT NULL                COMMENT '发放依据:推荐得分(0~1)',
  issue_level_id   TINYINT UNSIGNED NOT NULL                COMMENT '发放依据:发放时会员所属等级编号',
  face_value_snap  DECIMAL(8,2)     NOT NULL                COMMENT '快照:发券时的券面额',
  min_amount_snap  DECIMAL(10,2)    NOT NULL DEFAULT 0.00   COMMENT '快照:发券时的使用门槛',
  active_key       VARCHAR(40)      GENERATED ALWAYS AS (
        IF(coupon_status IN ('未使用', '已锁定'), CONCAT(member_id, '-', template_id), NULL)
      ) STORED                                            COMMENT '活跃持有键,用于唯一约束',
  PRIMARY KEY (instance_id),
  UNIQUE KEY uk_coupon_code       (coupon_code),
  UNIQUE KEY uk_coupon_used_order (used_order_id),
  UNIQUE KEY uk_coupon_active_hold (active_key),
  KEY idx_coupon_member   (member_id, coupon_status),
  KEY idx_coupon_template (template_id),
  KEY idx_coupon_expire   (coupon_status, expire_time),
  CONSTRAINT fk_coupon_template FOREIGN KEY (template_id)    REFERENCES coupon_template (template_id)
      ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_coupon_member   FOREIGN KEY (member_id)      REFERENCES member (member_id)
      ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_coupon_order    FOREIGN KEY (used_order_id)  REFERENCES sales_order (order_id)
      ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT fk_coupon_level    FOREIGN KEY (issue_level_id) REFERENCES member_level (level_id)
      ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_coupon_status  CHECK (coupon_status IN ('未使用', '已锁定', '已核销', '已过期')),
  CONSTRAINT ck_coupon_channel CHECK (issue_channel IN ('智能体推荐', '运营活动', '新客注册')),
  CONSTRAINT ck_coupon_score   CHECK (reco_score >= 0 AND reco_score <= 1),
  CONSTRAINT ck_coupon_face    CHECK (face_value_snap > 0),
  CONSTRAINT ck_coupon_min     CHECK (min_amount_snap >= 0),
  CONSTRAINT ck_coupon_expire  CHECK (expire_time > issue_time),
  CONSTRAINT ck_coupon_used_consistency CHECK (
        (coupon_status = '已核销' AND used_order_id IS NOT NULL AND used_time IS NOT NULL)
     OR (coupon_status <> '已核销' AND used_order_id IS NULL     AND used_time IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='券实例表(由会员↔券模板 M:N 联系提升)';


-- =============================================================================
-- 执行提示(供在本机执行脚本的同学参考)
-- -----------------------------------------------------------------------------
-- 1. 版本:必须 MySQL 8.0.16 及以上,否则 CHECK 约束只被解析、不被执行。
--    可用 SELECT VERSION(); 确认。若为 5.7,需按下述方案改写:
--      · 单表取值范围类检查 → BEFORE INSERT/UPDATE 触发器,不满足则 SIGNAL SQLSTATE '45000';
--      · "门槛不低于面额"等跨列检查 → 同上;
--      · 生成列(active_key / parent_key)→ 5.7 不支持,需改为普通列 + 触发器维护。
-- 2. 执行顺序:本脚本内部已按外键依赖排好顺序(先父表后子表),可整体执行。
-- 3. 生成列注意:active_key、parent_key 由数据库自动计算,INSERT 时不得显式赋值,
--    否则报错 "The value specified for generated column ... is not allowed"。
--    使用 LOAD DATA 或 mysqldump 导入数据时,须把这两列从字段列表中排除。
-- 4. 订单金额写入:若先插入订单行、再逐条插入明细、最后回写金额,回写时必须把
--    items_amount 与 pay_amount 放在同一条 UPDATE 中,否则会瞬时违反 ck_order_amount。
-- 5. 手机号校验:ck_member_mobile 使用 REGEXP。若所用版本在 CHECK 中不接受
--    REGEXP,可退化为 CHECK (CHAR_LENGTH(mobile) = 11),并在应用层保留正则校验。
-- 6. 时区:如需固定按北京时间存储,执行前先 SET time_zone = '+08:00';
--    本设计统一使用 DATETIME(不带时区),避免 TIMESTAMP 的隐式时区转换。
-- 7. 若需重建:本脚本可直接重复执行,会先删除 8 张表再重建(数据将丢失)。
-- =============================================================================
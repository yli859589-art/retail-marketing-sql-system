-- 增量扩展：仅创建网站账户表；绝不修改八张既有业务表与业务数据。
CREATE TABLE IF NOT EXISTS user_account (
  user_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  username VARCHAR(40) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  role ENUM('CUSTOMER','ADMIN') NOT NULL,
  member_id BIGINT UNSIGNED NULL,
  status ENUM('ACTIVE','DISABLED') NOT NULL DEFAULT 'ACTIVE',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id),
  UNIQUE KEY uk_user_account_username (username),
  UNIQUE KEY uk_user_account_member (member_id),
  CONSTRAINT fk_user_account_member FOREIGN KEY (member_id) REFERENCES member(member_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  CONSTRAINT ck_user_account_role_member CHECK ((role='ADMIN' AND member_id IS NULL) OR (role='CUSTOMER' AND member_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Web 应用账号；密码仅保存哈希';

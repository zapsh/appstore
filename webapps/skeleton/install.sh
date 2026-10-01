#!/bin/bash
# webapps 应用骨架安装脚本（zap appstore 调用）
#
# 依赖环境变量（由 zapexec 注入）：
#   建站编排：SITE_ID SITE_DOMAIN SITE_ROOT SITE_OWNER SITE_LINUX_USER PHP_INSTANCE PHP_FPM_SOCK
#   建库编排：DB_NAME DB_USER DB_PASS DB_HOST DB_PORT DB_CHARSET DB_USER_HOST
# 本脚本以站点 Linux 账号（run_as: user）身份运行，没有 root 权限，
# 只负责把程序文件写进 SITE_ROOT 并初始化数据库表。
set -euo pipefail

source "${ZAP_PATH}/scripts/zap/bash_utils.sh"

APP_TITLE="Web 应用骨架"
: "${SITE_ROOT:?缺少 SITE_ROOT，建站编排未生效}"

log_info "准备安装 ${APP_TITLE} 到 ${SITE_ROOT}"

# ── 1) 初始化数据库表（连接信息由面板注入，密码不落盘）──────────
if [ -n "${DB_NAME:-}" ] && [ -n "${DB_USER:-}" ]; then
  mysql --default-character-set=utf8mb4 \
    -h "${DB_HOST:-127.0.0.1}" -P "${DB_PORT:-3306}" \
    -u "${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" <<'SQL' 2>/dev/null || \
    log_warn "建表失败（可忽略：index.php 首次访问会自动建表）"
CREATE TABLE IF NOT EXISTS skeleton_guestbook (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(64) NOT NULL,
  message TEXT NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
SQL
fi

# ── 2) 生成配置文件（含数据库凭据，标准 webapps 做法，请勿提交版本库）──
cat >"${SITE_ROOT}/config.php" <<EOF
<?php
// 由面板安装脚本生成，含数据库凭据；请勿提交到版本库（参考 .gitignore）
define('DB_HOST', '${DB_HOST:-127.0.0.1}');
define('DB_PORT', '${DB_PORT:-3306}');
define('DB_NAME', '${DB_NAME}');
define('DB_USER', '${DB_USER}');
define('DB_PASS', '${DB_PASS}');
EOF
chmod 0640 "${SITE_ROOT}/config.php"

# ── 3) 写入应用（前端表单 + 后端处理）──────────────────────────
# 注意：下面用 quoted heredoc（'PHP'）防止 bash 展开 PHP 里的 \$ 变量
cat >"${SITE_ROOT}/index.php" <<'PHP'
<?php
/**
 * Web 应用骨架 —— 演示 PHP 前端表单 + 后端处理 + 数据库读写。
 * 复制本目录即可作为你自己的 webapps 应用起点。
 */
require_once __DIR__ . '/config.php';

$pdo = new PDO(
    "mysql:host=" . DB_HOST . ";port=" . DB_PORT . ";dbname=" . DB_NAME . ";charset=utf8mb4",
    DB_USER, DB_PASS,
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);

// 首次访问确保表存在
$pdo->exec("CREATE TABLE IF NOT EXISTS skeleton_guestbook (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(64) NOT NULL,
    message TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4");

// ── 后端处理：接收表单 → 入库 ───────────────────────────────
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $name = trim($_POST['name'] ?? '');
    $message = trim($_POST['message'] ?? '');
    if ($name !== '' && $message !== '') {
        $stmt = $pdo->prepare("INSERT INTO skeleton_guestbook (name, message) VALUES (?, ?)");
        $stmt->execute([$name, $message]);
    }
    // POST 后重定向，避免刷新重复提交
    header('Location: ' . $_SERVER['REQUEST_URI']);
    exit;
}

// ── 读取已有留言 ────────────────────────────────────────────
$rows = $pdo
    ->query("SELECT name, message, created_at FROM skeleton_guestbook ORDER BY id DESC LIMIT 50")
    ->fetchAll(PDO::FETCH_ASSOC);
?>
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Web 应用骨架</title>
  <style>
    body { font: 14px/1.6 system-ui, sans-serif; max-width: 640px; margin: 32px auto; padding: 0 16px; color: #1f2329; }
    h1 { font-size: 20px; }
    .card { border: 1px solid #e5e6eb; border-radius: 8px; padding: 16px; margin-bottom: 16px; }
    input, textarea { width: 100%; box-sizing: border-box; padding: 8px; margin: 6px 0; border: 1px solid #e5e6eb; border-radius: 6px; }
    button { background: #165dff; color: #fff; border: 0; padding: 8px 16px; border-radius: 6px; cursor: pointer; }
    .msg { border-top: 1px dashed #eee; padding-top: 8px; margin-top: 8px; }
    .meta { color: #86909c; font-size: 12px; }
  </style>
</head>
<body>
  <h1>Web 应用骨架 Demo</h1>
  <div class="card">
    <p>这是 <b>webapps</b> 应用骨架：面板自动建站 + 建库，下面是 PHP 表单提交 → 后端入库 → 列表展示的完整闭环。</p>
    <form method="post">
      <input name="name" placeholder="你的名字" required>
      <textarea name="message" placeholder="说点什么…" rows="3" required></textarea>
      <button type="submit">提交</button>
    </form>
  </div>
  <div class="card">
    <strong>留言板（<?= count($rows) ?> 条）</strong>
    <?php if (empty($rows)): ?>
      <p class="meta">还没有留言，来当第一个。</p>
    <?php endif; ?>
    <?php foreach ($rows as $r): ?>
      <div class="msg">
        <div><b><?= htmlspecialchars($r['name'], ENT_QUOTES) ?></b>
          <span class="meta"><?= $r['created_at'] ?></span></div>
        <div><?= htmlspecialchars($r['message'], ENT_QUOTES) ?></div>
      </div>
    <?php endforeach; ?>
  </div>
</body>
</html>
PHP

log_ok "${APP_TITLE} 安装完成：${SITE_ROOT}"
log_info "访问站点域名 ${SITE_DOMAIN} 即可看到交互界面"

-- composer-create 插件：在站点根（或指定子目录）下执行 composer create-project。
-- 以站点 Linux 账号身份运行（scope=site → zap.exec_as_user 走 drop_privileges）。

function on_run(ctx)
  local pkg = zap.option("PACKAGE")
  if pkg == "" then
    zap.log("错误：未提供包名（PACKAGE）")
    error("缺少 PACKAGE")
  end

  -- 运行前校验 composer 可用：本插件依赖系统上的 composer（安装钩子会尽量自动补装）。
  -- try_run 失败不抛错、返回 (ok, output)，因此这里能给出明确的中文报错。
  local ok, ver = zap.try_run("composer", { "--version" })
  if not ok then
    zap.log("错误：未找到 composer（或无法执行）。请确认：")
    zap.log("  1) 系统已安装 PHP 8.1+；")
    zap.log("  2) composer 在站点账号 PATH 上（/usr/local/bin/composer 即可被所有账号访问）；")
    zap.log("  3) 或重新安装本插件以触发自动补装 composer。")
    error("composer 不可用")
  end
  zap.log("composer 就绪：" .. (ver or ""):gsub("\n.*", ""))

  local target = zap.option("TARGET")
  -- dir 控件回传绝对路径，直接当目标目录用；留空则落到站点根（不要再和 site_root 拼接，否则会重复）
  local dest = target
  if dest == "" then dest = zap.site_root() end

  zap.log("在 " .. dest .. " 创建 Composer 项目：" .. pkg)
  zap.log("运行身份：" .. zap.site_linux_user())

  -- 以站点账号执行；--no-interaction 避免联网下载依赖时卡在交互提示
  local out = zap.exec_as_user("composer", {
    "create-project",
    "--prefer-dist",
    "--no-interaction",
    pkg,
    dest,
  })
  zap.log(out)

  if target == "" then
    zap.log("完成。已将项目创建到站点根 " .. dest .. "。")
  else
    zap.log("完成。已将项目创建到 " .. dest .. "。")
  end
  zap.log("可把站点根切换到 " .. dest .. "/public 并加 Laravel 伪静态（try_files）。")
end

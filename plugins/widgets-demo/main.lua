-- widgets-demo 插件：把 manifest 里声明的所有控件类型都读出来并打印，方便对照前端回传值。
-- 以站点 Linux 账号身份运行（scope=site → zap.exec_as_user 走 drop_privileges）。

function on_run(ctx)
  zap.log("=== 控件示例插件 ===")
  zap.log("scope       = " .. (ctx.scope or ""))
  zap.log("action      = " .. (ctx.action or ""))
  zap.log("site_root   = " .. zap.site_root())
  zap.log("site_linux  = " .. zap.site_linux_user())
  zap.log("home_dir    = " .. zap.home_dir())
  zap.log("--------------------------------------------------")
  zap.log("TEXT   (string)      = [" .. zap.opt("TEXT") .. "]")
  zap.log("NUM    (number)      = [" .. zap.opt("NUM") .. "]")
  zap.log("FLAG   (bool)        = [" .. zap.opt("FLAG") .. "]")
  zap.log("SINGLE (select)      = [" .. zap.opt("SINGLE") .. "]")
  zap.log("MULTI  (multiselect) = [" .. zap.opt("MULTI") .. "]")
  zap.log("TARGET (dir)         = [" .. zap.opt("TARGET") .. "]")
  zap.log("SRC    (file)        = [" .. zap.opt("SRC") .. "]")
  zap.log("SRCS   (files)       = [" .. zap.opt("SRCS") .. "]")
  zap.log("--------------------------------------------------")

  -- 目录选择器回传的是相对站点根的路径（空则落到站点根）
  local target = zap.opt("TARGET")
  if target == "" then target = zap.site_root() end
  zap.log("TARGET 最终路径        = " .. target)

  -- 多文件：把空格连接的串拆开，逐个打印
  local raw = zap.opt("SRCS")
  if raw ~= "" then
    local i = 1
    for p in raw:gmatch("%S+") do
      zap.log("SRCS[" .. i .. "] = " .. p)
      i = i + 1
    end
  end

  zap.log("完成：以上即各控件回传到 main.lua 的值。")
end

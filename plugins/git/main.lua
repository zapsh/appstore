-- Git 管理插件：在文件管理器「当前目录」里执行 git 命令。
--
-- 工作目录由前端（文件管理器编辑器工具栏）通过 options.cwd 传入；
-- 本插件只做目录校验与子命令分发，真正的 git 由 zap.try_run 以「当前面板用户」身份跑。
--
-- 入口：ui.html 用 zap.call('<action>', {...}) 调用，action 即 git 子命令
-- （status / log / diff / add / commit / branch / pull / push / fetch / init ...）。
-- 后端把 action 映射到 on_<action>，找不到则回落到 on_run，由 ctx.action 自行分发。

--- 以「当前面板用户」身份在 cwd 里跑 git，失败不抛错，返回 (ok, output)。
local function git(args, cwd)
  return zap.try_run('git', args, { cwd = cwd })
end

--- 取并校验工作目录：必须非空、且真实存在且为目录。
local function safe_cwd()
  local cwd = zap.opt('cwd', '')
  if cwd == '' then
    zap.fail('未提供工作目录（cwd）。请通过文件管理器打开某目录后再用 Git 插件。')
  end
  -- 该目录必须存在且为目录（extract_cwd 已在 root 侧做规范化与越界校验，这里再确认用户可访问）
  local ok = zap.try_run('test', { '-d', cwd })
  if not ok then
    zap.fail('工作目录不存在或不是目录: ' .. cwd)
  end
  return cwd
end

--- 设置 Git 身份（user.name / user.email），支持全局(--global)或仅当前仓库。
local function set_identity(cwd)
  local name = zap.opt('name', '')
  local email = zap.opt('email', '')
  if name == '' and email == '' then
    zap.fail('请至少填写 user.name 或 user.email')
  end
  local global = zap.opt('global', '0') == '1'
  local flag = global and '--global' or nil

  if name ~= '' then
    local a = { 'config' }
    if flag then a[#a + 1] = flag end
    a[#a + 1] = 'user.name'
    a[#a + 1] = name
    local ok, out = git(a, cwd)
    if not ok then zap.fail(out ~= '' and out or '设置 user.name 失败') end
  end

  if email ~= '' then
    local a = { 'config' }
    if flag then a[#a + 1] = flag end
    a[#a + 1] = 'user.email'
    a[#a + 1] = email
    local ok, out = git(a, cwd)
    if not ok then zap.fail(out ~= '' and out or '设置 user.email 失败') end
  end

  zap.log('已保存 Git 身份' .. (global and '（全局 ~/.gitconfig）' or '（仅当前仓库 .git/config）') .. '。')
end

--- 设置当前仓库的远程地址：已存在则 set-url，不存在则 add。
local function set_remote(cwd)
  local remote = zap.opt('remote', 'origin')
  if remote == '' then remote = 'origin' end
  local url = zap.opt('url', '')
  if url == '' then zap.fail('请填写远程仓库地址（url）') end

  local exists = zap.try_run('git', { 'remote', 'get-url', remote }, { cwd = cwd })
  local args
  if exists then
    args = { 'remote', 'set-url', remote, url }
  else
    args = { 'remote', 'add', remote, url }
  end
  local ok, out = git(args, cwd)
  if not ok then
    zap.fail(out ~= '' and out or ('设置远程地址失败：' .. remote))
  end
  zap.log((exists and '已更新远程「' or '已新增远程「') .. remote .. '」→ ' .. url)
end

--- 默认入口：按 ctx.action 把请求分发到对应的 git 子命令。
function on_run(ctx)
  local action = ctx.action or 'status'
  local cwd = safe_cwd()

  -- 本插件扩展动作：身份配置 / 远程地址配置
  if action == 'config' then
    return set_identity(cwd)
  elseif action == 'remote' then
    return set_remote(cwd)
  end

  local args = { action }

  if action == 'commit' then
    local message = zap.opt('message', 'update')
    table.insert(args, '-m')
    table.insert(args, message)

  elseif action == 'add' or action == 'stage' then
    -- files 留空表示暂存全部
    local files = zap.opt('files', '')
    if files == '' then
      table.insert(args, '.')
    else
      for f in string.gmatch(files, '%S+') do table.insert(args, f) end
    end

  elseif action == 'checkout' or action == 'switch' then
    local br = zap.opt('branch', '')
    if br ~= '' then table.insert(args, br) end

  elseif action == 'log' then
    table.insert(args, '--oneline')
    table.insert(args, '-n')
    table.insert(args, zap.opt('n', '30'))

  elseif action == 'reset' then
    local mode = zap.opt('mode', '')
    if mode ~= '' then table.insert(args, mode) end
    table.insert(args, zap.opt('target', 'HEAD'))

  elseif action == 'init' then
    -- 可选参数（如 --bare）通过 files 字段透传
    for f in string.gmatch(zap.opt('files', ''), '%S+') do table.insert(args, f) end

  elseif action == 'clone' then
    local url = zap.opt('url', '')
    if url == '' then zap.fail('clone 需要 url') end
    table.insert(args, url)
    local dest = zap.opt('dest', '')
    if dest ~= '' then table.insert(args, dest) end
  end

  local ok, out = git(args, cwd)
  if not ok then
    -- git 在「不是仓库」等情况下会以非零退出码返回，把报错原样展示给用户
    zap.fail(out ~= '' and out or ('git ' .. action .. ' 执行失败'))
  end
  zap.log(out)
end

--- 回显当前工作目录，供 UI 初始填充（UI 也可在此基础上改成其它目录）。
function on_info(ctx)
  zap.log(zap.opt('cwd', ''))
end

-- Git 管理插件：在文件管理器「当前目录」里管理 Git 仓库（状态 / 暂存 / 提交 / 推送 / 设置）。
--
-- 工作目录由前端（文件管理器编辑器工具栏）通过 options.cwd 传入；本插件只做目录与
-- 参数校验、子命令分发和结果整形，真正的 git 由 zap.try_run 以「当前面板用户」身份跑。
--
-- 前后端协议（ui.html ↔ 本文件）：
--   ui.html 用 zap.call('<action>', {...}) 调用，action 映射到 on_<action>，找不到则回落到 on_run。
--   返回值只有一种形态：单行文本。因此分成两类动作：
--     · 读状态类（repo / log / branch / config_get）→ 返回**单行 JSON**，前端 JSON.parse 后渲染；
--     · 其余（status / diff / show 与各写操作）→ 返回可直读的文本。
--   写操作一律返回一行人话摘要，前端据此刷新 `repo` 状态。
--
-- 文件列表用 JSON 数组字符串传（options 到后端会被压成字符串，直接拼串会拆坏带空格的文件名）。

-- ── 基础工具 ────────────────────────────────────────────────

local function trim(s)
  return zap.str.trim(s or '')
end

--- 只允许仓库内的相对路径：挡掉绝对路径与 `..`，避免 git add 打到目录外面去。
local function safe_rel_path(p)
  p = trim(p)
  if p == '' then return nil end
  if p:sub(1, 1) == '/' then zap.fail('不接受绝对路径：' .. p) end
  if p:find('%.%.') then zap.fail('路径不允许包含 ..：' .. p) end
  return p
end

--- 挡掉长得像命令行参数的名称（remote / branch / url），避免被当成选项解析。
local function safe_name(p, what)
  p = trim(p)
  if p == '' then zap.fail('请填写' .. (what or '名称')) end
  if p:sub(1, 1) == '-' then zap.fail((what or '名称') .. '不能以 - 开头：' .. p) end
  if p:find('[%s\'"`]') then zap.fail((what or '名称') .. '含有非法字符：' .. p) end
  return p
end

--- porcelain 里带特殊字符的路径会被加引号并转义，这里还原成真实路径。
local function unquote_path(p)
  if p:sub(1, 1) ~= '"' then return p end
  p = p:sub(2, -2)
  p = p:gsub('\\(%d%d%d)', function(o) return string.char(tonumber(o, 8) or 63) end)
  p = p:gsub('\\(.)', '%1')
  return p
end

--- 前端用 JSON 数组字符串传来的文件列表；拿不到表的场合退化成按行拆。
local function opt_files()
  local raw = zap.opt('files', '')
  if raw == '' then return {} end
  local out = {}
  local ok, list = pcall(zap.from_json, raw)
  if ok and type(list) == 'table' then
    for _, v in ipairs(list) do
      local p = safe_rel_path(tostring(v or ''))
      if p then out[#out + 1] = p end
    end
    return out
  end
  for _, line in ipairs(zap.str.lines(raw)) do
    local p = safe_rel_path(line)
    if p then out[#out + 1] = p end
  end
  return out
end

local function opt_bool(name, default)
  local v = trim(zap.opt(name, '')):lower()
  if v == '' then return default == true end
  return v == 'true' or v == '1' or v == 'yes' or v == 'on'
end

-- ── git 调用封装 ────────────────────────────────────────────

--- 以「当前面板用户」身份在 cwd 里跑 git，失败不抛错，返回 (ok, output)。
local function git(args, cwd)
  return zap.try_run('git', args, { cwd = cwd })
end

--- 同上，但把输出端空白去掉；命令非零退出时一律回空串（读取类场景不想看到
--- “命令退出码 1:” 这种前缀，失败与否由调用方看第一个返回值）。
local function git_out(args, cwd)
  local ok, out = git(args, cwd)
  if not ok then return false, '' end
  return true, trim(out)
end

--- 失败即抛错：把 git 的非零退出输出原样交给前端展示。
local function git_or_fail(args, cwd, what)
  local ok, out = git(args, cwd)
  out = trim(out)
  if not ok then
    zap.fail(out ~= '' and out or ((what or 'git') .. ' 执行失败'))
  end
  return out
end

--- 取并校验工作目录：必须非空、且真实存在且为目录。
local function safe_cwd()
  local cwd = zap.opt('cwd', '')
  if cwd == '' then
    zap.fail('未提供工作目录（cwd）。请通过文件管理器打开某目录后再用 Git 插件。')
  end
  local ok = zap.try_run('test', { '-d', cwd })
  if not ok then zap.fail('工作目录不存在或不是目录: ' .. cwd) end
  return cwd
end

--- 是否为 Git 仓库（含子目录场景：`rev-parse --is-inside-work-tree` 会向上找）。
local function repo_root(cwd)
  local ok, out = git_out({ 'rev-parse', '--is-inside-work-tree' }, cwd)
  if not ok or out ~= 'true' then return nil end
  local _, root = git_out({ 'rev-parse', '--show-toplevel' }, cwd)
  if root == '' then root = cwd end
  return root
end

-- ── 状态采集 ────────────────────────────────────────────────

local STATUS_LABEL = {
  M = '修改',
  A = '新增',
  D = '删除',
  R = '重命名',
  C = '复制',
  T = '类型变更',
  U = '冲突',
  ['?'] = '未跟踪',
}

--- 解析 `git status --porcelain`：分出「已暂存 / 未暂存 / 未跟踪 / 冲突」四组。
local function collect_entries(cwd)
  local staged, unstaged, untracked, conflicted = {}, {}, {}, {}
  local _, out = git_out({ 'status', '--porcelain=v1', '--untracked-files=all' }, cwd)
  for _, line in ipairs(zap.str.lines(out)) do
    if #line >= 4 then
      local x, y = line:sub(1, 1), line:sub(2, 2)
      local path = line:sub(4)
      -- 重命名 / 复制写成 `R  old -> new`，展示与操作都取「新路径」
      local arrow = path:find(' -> ', 1, true)
      if arrow then path = path:sub(arrow + 4) end
      path = unquote_path(path)
      if x == '?' and y == '?' then
        untracked[#untracked + 1] = { path = path, status = '?', label = STATUS_LABEL['?'] }
      else
        local conflict = x == 'U' or y == 'U' or (x == 'A' and y == 'A') or (x == 'D' and y == 'D')
        if x ~= ' ' and x ~= '?' then
          staged[#staged + 1] = { path = path, status = x, label = STATUS_LABEL[x] or x }
        end
        if y ~= ' ' and y ~= '?' then
          unstaged[#unstaged + 1] = { path = path, status = y, label = STATUS_LABEL[y] or y }
        end
        if conflict then
          conflicted[#conflicted + 1] = { path = path, status = 'U', label = STATUS_LABEL.U }
        end
      end
    end
  end
  return staged, unstaged, untracked, conflicted
end

--- 分支信息：当前分支（detached 时给短 sha）、上游、领先 / 落后提交数。
--- 用 `symbolic-ref` 取分支名：空仓库（还没有第一次提交）也拿得到，`rev-parse --abbrev-ref HEAD`
--- 那种写法在空仓库里会同时输出 `HEAD` 和 fatal 报错。
local function collect_branch(cwd)
  local detached = false
  local sym_ok, branch = git_out({ 'symbolic-ref', '--short', '-q', 'HEAD' }, cwd)
  if not sym_ok or branch == '' then
    detached = true
    local _, sha = git_out({ 'rev-parse', '--short', 'HEAD' }, cwd)
    branch = sha
  end
  local _, upstream = git_out({ 'rev-parse', '--abbrev-ref', '@{u}' }, cwd)
  local ahead, behind = 0, 0
  if upstream ~= '' then
    local _, counts = git_out({ 'rev-list', '--left-right', '--count', 'HEAD...@{u}' }, cwd)
    local a, b = counts:match('^(%d+)%s+(%d+)$')
    ahead = tonumber(a) or 0
    behind = tonumber(b) or 0
  end
  return branch, detached, upstream, ahead, behind
end

local function collect_remotes(cwd)
  local list = {}
  local ok, names = git_out({ 'remote' }, cwd)
  if ok then
    for _, n in ipairs(zap.str.lines(names)) do
      local _, url = git_out({ 'remote', 'get-url', n }, cwd)
      local _, push = git_out({ 'remote', 'get-url', '--push', n }, cwd)
      list[#list + 1] = { name = n, url = url, push_url = push ~= url and push or '' }
    end
  end
  return list
end

--- Git 身份：仓库级生效值 + 全局值（UI 据此回显与提示「当前实际用的是哪个」）。
local function collect_identity(cwd)
  local _, name = git_out({ 'config', '--get', 'user.name' }, cwd)
  local _, email = git_out({ 'config', '--get', 'user.email' }, cwd)
  local _, gname = git_out({ 'config', '--global', '--get', 'user.name' }, cwd)
  local _, gemail = git_out({ 'config', '--global', '--get', 'user.email' }, cwd)
  return { name = name, email = email, global_name = gname, global_email = gemail }
end

local function collect_branches(cwd)
  local list = {}
  local ok, out = git_out({ 'branch', '--format=%(refname:short)%09%(objectname:short)' }, cwd)
  if ok then
    for _, line in ipairs(zap.str.lines(out)) do
      local name, sha = line:match('^(.-)\t(.*)$')
      if name then list[#list + 1] = { name = name, sha = sha } end
    end
  end
  return list
end

-- ── 动作实现 ────────────────────────────────────────────────

--- repo：一次性把面板需要的东西全部取回（进入 / 刷新「状态」页签时调用，避免逐按钮问后端）。
local function action_repo(cwd)
  local root = repo_root(cwd)
  if not root then
    zap.log(zap.json_encode({ ok = true, is_repo = false, cwd = cwd, message = '该目录不在 Git 仓库里' }))
    return
  end
  local branch, detached, upstream, ahead, behind = collect_branch(cwd)
  local staged, unstaged, untracked, conflicted = collect_entries(cwd)
  zap.log(zap.json_encode({
    ok = true,
    is_repo = true,
    cwd = cwd,
    root = root,
    branch = branch,
    detached = detached,
    upstream = upstream,
    ahead = ahead,
    behind = behind,
    clean = (#staged + #unstaged + #untracked + #conflicted) == 0,
    identity = collect_identity(cwd),
    remotes = collect_remotes(cwd),
    branches = collect_branches(cwd),
    staged = staged,
    unstaged = unstaged,
    untracked = untracked,
    conflicted = conflicted,
  }))
end

--- 暂存：不给 files 表示「全部」（含未跟踪文件）。
local function action_add(cwd)
  local files = opt_files()
  local args = { 'add' }
  if #files == 0 then
    args[#args + 1] = '-A'
  else
    for _, f in ipairs(files) do args[#args + 1] = f end
  end
  git_or_fail(args, cwd, '暂存')
  zap.log(#files == 0 and '已暂存全部变更' or ('已暂存 ' .. #files .. ' 个文件'))
end

--- 取消暂存：files 为空表示全部退回工作区。
--- 还没有第一次提交时 `git reset HEAD` 会退化不起来，改用 `git rm --cached`。
local function action_unstage(cwd)
  local files = opt_files()
  local has_head = (zap.try_run('git', { 'rev-parse', '--verify', 'HEAD' }, { cwd = cwd }))
  local args
  if has_head then
    args = { 'reset', '-q', 'HEAD' }
    if #files > 0 then
      args[#args + 1] = '--'
      for _, f in ipairs(files) do args[#args + 1] = f end
    end
  else
    args = { 'rm', '-r', '--cached' }
    if #files > 0 then
      args[#args + 1] = '--'
      for _, f in ipairs(files) do args[#args + 1] = f end
    else
      args[#args + 1] = '.'
    end
  end
  git_or_fail(args, cwd, '取消暂存')
  zap.log(#files == 0 and '已取消全部暂存' or ('已取消暂存 ' .. #files .. ' 个文件'))
end

--- 放弃工作区修改（危险操作，必须显式给文件；不支持「全部」）。
local function action_restore(cwd)
  local files = opt_files()
  if #files == 0 then zap.fail('请选择要放弃修改的文件') end
  local args = { 'checkout', '--' }
  for _, f in ipairs(files) do args[#args + 1] = f end
  git_or_fail(args, cwd, '放弃修改')
  zap.log('已放弃 ' .. #files .. ' 个文件的本地修改')
end

local function action_commit(cwd)
  local message = trim(zap.opt('message', ''))
  if message == '' then zap.fail('请填写提交信息') end
  local files = opt_files()
  local args = { 'commit', '-m', message }
  if opt_bool('amend', false) then args[#args + 1] = '--amend' end
  if #files > 0 then
    args[#args + 1] = '--'
    for _, f in ipairs(files) do args[#args + 1] = f end
  elseif opt_bool('all', false) then
    args[#args + 1] = '-a'
  end
  local out = git_or_fail(args, cwd, '提交')
  zap.log(out ~= '' and out or '已提交')
end

local function action_push(cwd)
  local remote = trim(zap.opt('remote', ''))
  local branch = trim(zap.opt('branch', ''))
  local args = { 'push' }
  if remote ~= '' then
    args[#args + 1] = remote
    if branch ~= '' then args[#args + 1] = branch end
  end
  if opt_bool('set_upstream', false) then
    if remote == '' then zap.fail('勾选「设为上游」时需要先指定远程') end
    table.insert(args, 2, '-u')
  end
  local out = git_or_fail(args, cwd, '推送')
  zap.log(out ~= '' and out or '推送完成')
end

local function action_pull(cwd)
  local args = { 'pull' }
  if opt_bool('rebase', false) then args[#args + 1] = '--rebase' end
  local remote = trim(zap.opt('remote', ''))
  local branch = trim(zap.opt('branch', ''))
  if remote ~= '' then
    args[#args + 1] = remote
    if branch ~= '' then args[#args + 1] = branch end
  end
  local out = git_or_fail(args, cwd, '拉取')
  zap.log(out ~= '' and out or '已是最新')
end

local function action_fetch(cwd)
  local out = git_or_fail({ 'fetch', '--all', '--prune' }, cwd, '获取')
  zap.log(out ~= '' and out or '已同步远端引用')
end

local function action_init(cwd)
  local root = repo_root(cwd)
  if root then zap.fail('该目录已在 Git 仓库内：' .. root) end
  local args = { 'init' }
  local branch = trim(zap.opt('branch', ''))
  if branch ~= '' then
    args[#args + 1] = '-b'
    args[#args + 1] = safe_name(branch, '初始分支名')
  end
  local out = git_or_fail(args, cwd, '初始化仓库')
  zap.log(out ~= '' and out or '已在当前目录初始化 Git 仓库')
end

--- 切换分支。
local function action_checkout(cwd)
  local branch = safe_name(zap.opt('branch', ''), '分支名')
  local out = git_or_fail({ 'checkout', branch }, cwd, '切换分支')
  zap.log(out ~= '' and out or ('已切换到 ' .. branch))
end

--- 创建并切换分支。
local function action_branch_create(cwd)
  local branch = safe_name(zap.opt('branch', ''), '分支名')
  local out = git_or_fail({ 'switch', '-c', branch }, cwd, '创建分支')
  zap.log(out ~= '' and out or ('已创建并切换到 ' .. branch))
end

--- 分支列表（JSON）。
local function action_branch(cwd)
  local _, current = git_out({ 'symbolic-ref', '--short', '-q', 'HEAD' }, cwd)
  zap.log(zap.json_encode({ ok = true, current = current, branches = collect_branches(cwd) }))
end

--- 提交历史（JSON）：hash / 作者 / 日期 / 主题，用 \x1f 分隔避免被空格拆坏。
local function action_log(cwd)
  local n = trim(zap.opt('n', '30'))
  if not n:match('^%d+$') then n = '30' end
  local ok, out = git_out(
    { 'log', '-n', n, '--date=short', '--pretty=format:%H' .. string.char(31) .. '%an' .. string.char(31) .. '%ad' .. string.char(31) .. '%s' },
    cwd
  )
  local list = {}
  if ok then
    for _, line in ipairs(zap.str.lines(out)) do
      local parts = zap.str.split(line, string.char(31), true)
      if #parts >= 4 then
        list[#list + 1] = { hash = parts[1], author = parts[2], date = parts[3], subject = parts[4] }
      end
    end
  end
  zap.log(zap.json_encode({ ok = true, commits = list }))
end

--- 差异：默认工作区 diff；staged=1 看已暂存；传 commit 则看某次提交。
local function action_diff(cwd)
  local commit = trim(zap.opt('commit', ''))
  if commit ~= '' then
    local out = git_or_fail({ 'show', '--color=never', safe_name(commit, '提交号') }, cwd, '查看提交')
    zap.log(out ~= '' and out or '（无差异）')
    return
  end
  local args = { 'diff', '--color=never' }
  local files = opt_files()
  if opt_bool('staged', false) then args[#args + 1] = '--cached' end
  if #files > 0 then
    args[#args + 1] = '--'
    for _, f in ipairs(files) do args[#args + 1] = f end
  end
  local out = git_or_fail(args, cwd, '查看差异')
  zap.log(out ~= '' and out or '（无差异）')
end

--- Git 身份：读 = JSON；写 = 走 action_config。
local function action_config_get(cwd)
  local identity = collect_identity(cwd)
  local ok, root = git_out({ 'rev-parse', '--show-toplevel' }, cwd)
  zap.log(zap.json_encode({ ok = true, root = ok and root or '', identity = identity }))
end

--- 设置 Git 身份（user.name / user.email），支持全局(--global)或仅当前仓库。
local function action_config(cwd)
  local name = trim(zap.opt('name', ''))
  local email = trim(zap.opt('email', ''))
  if name == '' and email == '' then zap.fail('请至少填写 user.name 或 user.email') end
  local global = opt_bool('global', false)
  local flag = global and '--global' or nil

  if name ~= '' then
    local a = { 'config' }
    if flag then a[#a + 1] = flag end
    a[#a + 1] = 'user.name'
    a[#a + 1] = name
    local ok, out = git(a, cwd)
    if not ok then zap.fail(trim(out) ~= '' and trim(out) or '设置 user.name 失败') end
  end
  if email ~= '' then
    local a = { 'config' }
    if flag then a[#a + 1] = flag end
    a[#a + 1] = 'user.email'
    a[#a + 1] = email
    local ok, out = git(a, cwd)
    if not ok then zap.fail(trim(out) ~= '' and trim(out) or '设置 user.email 失败') end
  end
  zap.log('已保存 Git 身份' .. (global and '（全局 ~/.gitconfig）' or '（仅当前仓库 .git/config）') .. '。')
end

--- 设置当前仓库的远程地址：已存在则 set-url，不存在则 add。
local function action_remote(cwd)
  local remote = trim(zap.opt('remote', ''))
  if remote == '' then remote = 'origin' end
  remote = safe_name(remote, '远程名')
  local url = trim(zap.opt('url', ''))
  if url == '' then zap.fail('请填写远程仓库地址（url）') end
  local exists = zap.try_run('git', { 'remote', 'get-url', remote }, { cwd = cwd })
  local args
  if exists then
    args = { 'remote', 'set-url', remote, url }
  else
    args = { 'remote', 'add', remote, url }
  end
  git_or_fail(args, cwd, '设置远程地址')
  zap.log((exists and '已更新远程「' or '已新增远程「') .. remote .. '」→ ' .. url)
end

local function action_remote_remove(cwd)
  local remote = safe_name(zap.opt('remote', ''), '远程名')
  git_or_fail({ 'remote', 'remove', remote }, cwd, '删除远程')
  zap.log('已删除远程「' .. remote .. '」')
end

--- 默认入口：按 ctx.action 分发。
function on_run(ctx)
  local action = ctx.action or 'status'
  local cwd = safe_cwd()

  if action == 'info' then
    zap.log(cwd)
    return
  elseif action == 'repo' then
    return action_repo(cwd)
  elseif action == 'status' then
    local out = git_or_fail({ 'status', '-sb' }, cwd, '查看状态')
    zap.log(out ~= '' and out or '（无输出）')
    return
  elseif action == 'diff' then
    return action_diff(cwd)
  elseif action == 'log' then
    return action_log(cwd)
  elseif action == 'branch' then
    return action_branch(cwd)
  elseif action == 'checkout' then
    return action_checkout(cwd)
  elseif action == 'branch_create' then
    return action_branch_create(cwd)
  elseif action == 'add' or action == 'stage' then
    return action_add(cwd)
  elseif action == 'unstage' then
    return action_unstage(cwd)
  elseif action == 'restore' then
    return action_restore(cwd)
  elseif action == 'commit' then
    return action_commit(cwd)
  elseif action == 'push' then
    return action_push(cwd)
  elseif action == 'pull' then
    return action_pull(cwd)
  elseif action == 'fetch' then
    return action_fetch(cwd)
  elseif action == 'init' then
    return action_init(cwd)
  elseif action == 'config' then
    return action_config(cwd)
  elseif action == 'config_get' then
    return action_config_get(cwd)
  elseif action == 'remote' then
    return action_remote(cwd)
  elseif action == 'remote_remove' then
    return action_remote_remove(cwd)
  elseif action == 'clone' then
    local url = trim(zap.opt('url', ''))
    if url == '' then zap.fail('clone 需要 url') end
    if url:sub(1, 1) == '-' then zap.fail('仓库地址不能以 - 开头') end
    local args = { 'clone', url }
    local dest = trim(zap.opt('dest', ''))
    if dest ~= '' then args[#args + 1] = dest end
    zap.log(git_or_fail(args, cwd, 'clone'))
    return
  end

  -- 兜底：只放行「无参数也只读」的子命令，其余一律拒绝 ——
  -- 不把未知 action 直接当 git 子命令拼上去，否则形如 `--output=xxx` 的 action 会变成选项注入。
  local READ_ONLY = { tag = true, describe = true }
  if READ_ONLY[action] then
    local out = git_or_fail({ action }, cwd, 'git ' .. action)
    zap.log(out ~= '' and out or '（无输出）')
    return
  end
  zap.fail('不支持的动作: ' .. tostring(action))
end

--- 回显当前工作目录，供 UI 初始填充。
function on_info(ctx)
  zap.log(zap.opt('cwd', ''))
end

vim9script

var repo_root = ''
var temp_root = ''
var session_cwd = ''
var base_sha = ''
var range_label = ''
var changes: list<dict<any>> = []
var files_bufnr = -1
var current_index = -1
var cleaning = false
var had_diff_base = false
var saved_diff_base: any = v:none
var had_relative_to = false
var saved_relative_to: any = v:none
var origin_rooter_state: dict<any> = {}
var origin_restore_pending = false

def Git(cwd: string, args: list<string>): list<string>
  const out = systemlist(['git', '-C', cwd] + args)
  if v:shell_error != 0
    throw $'git {join(args, " ")} failed'
  endif
  return out
enddef

def GitZero(cwd: string, args: list<string>): list<string>
  const out = system(['git', '-C', cwd] + args)
  if v:shell_error != 0
    throw $'git {join(args, " ")} failed'
  endif
  return split(out, "\x01", true)
enddef

def Resolve(ref: string): string
  if ref == '' || ref[0] ==# '-'
    throw 'invalid Git revision: ' .. ref
  endif
  return Git(repo_root, ['rev-parse', '--verify', ref .. '^{commit}'])[0]
enddef

def ResolveRange(spec: string): list<string>
  if spec == '' || spec =~# '\s' || spec[0] ==# '-'
    throw 'GitDiff requires one Git revision or range'
  endif

  if stridx(spec, '...') >= 0
    const refs = split(spec, '\.\.\.', true)
    if len(refs) != 2
      throw 'invalid Git range: ' .. spec
    endif
    const left = Resolve(refs[0] == '' ? 'HEAD' : refs[0])
    const right = Resolve(refs[1] == '' ? 'HEAD' : refs[1])
    return [Git(repo_root, ['merge-base', left, right])[0], right]
  endif

  if stridx(spec, '..') >= 0
    const refs = split(spec, '\.\.', true)
    if len(refs) != 2
      throw 'invalid Git range: ' .. spec
    endif
    return [
      Resolve(refs[0] == '' ? 'HEAD' : refs[0]),
      Resolve(refs[1] == '' ? 'HEAD' : refs[1]),
    ]
  endif

  return [Resolve(spec), Resolve('HEAD')]
enddef

def WorktreePath(cwd: string): string
  const configured: any = get(g:, 'gitdiff_worktree_dir', $'.tmp/gitdiff-{getpid()}')
  if type(configured) != v:t_string || configured == ''
    throw 'g:gitdiff_worktree_dir must be a non-empty string'
  endif
  return fnamemodify(isabsolutepath(configured) ? configured : cwd .. '/' .. configured, ':p')
enddef

def KeepCwd(): void
  if session_cwd != '' && getcwd() !=# session_cwd
    execute 'noautocmd cd ' .. fnameescape(session_cwd)
  endif
enddef

def DisableRooter(): dict<any>
  const state = {
    had: exists('g:rooter_disabled'),
    value: get(g:, 'rooter_disabled', v:none),
  }
  g:rooter_disabled = true
  return state
enddef

def RestoreRooter(state: dict<any>): void
  if state.had
    g:rooter_disabled = state.value
  else
    unlet! g:rooter_disabled
  endif
enddef

def ProtectOriginFromRooter(): void
  origin_rooter_state = {
    bufnr: bufnr(),
    had: exists('b:rooter_disabled'),
    value: get(b:, 'rooter_disabled', v:none),
  }
  b:rooter_disabled = true
enddef

def RestoreOriginRooter(): void
  origin_restore_pending = false
  if empty(origin_rooter_state) || !bufexists(origin_rooter_state.bufnr)
    origin_rooter_state = {}
    return
  endif
  if origin_rooter_state.had
    setbufvar(origin_rooter_state.bufnr, 'rooter_disabled', origin_rooter_state.value)
  else
    var variables: dict<any> = getbufvar(origin_rooter_state.bufnr, '')
    if has_key(variables, 'rooter_disabled')
      remove(variables, 'rooter_disabled')
    endif
  endif
  origin_rooter_state = {}
enddef

def RestoreOriginAfterEnter(): void
  if origin_restore_pending
    RestoreOriginRooter()
  endif
enddef

def ReadChanges(left: string, right: string): list<dict<any>>
  const names = GitZero(repo_root, ['diff', '--name-status', '-z', left, right])
  const nums = GitZero(repo_root, ['diff', '--numstat', '-z', left, right])
  var stats: dict<list<string>> = {}
  var i = 0
  while i < len(nums) && nums[i] != ''
    const fields = split(nums[i], "\t", true)
    if len(fields) != 3
      throw 'invalid git diff --numstat output'
    endif
    if fields[2] == ''
      if i + 2 >= len(nums)
        throw 'invalid renamed file stats'
      endif
      stats[nums[i + 2]] = [fields[0], fields[1]]
      i += 3
    else
      stats[fields[2]] = [fields[0], fields[1]]
      i += 1
    endif
  endwhile

  var result: list<dict<any>> = []
  i = 0
  while i < len(names) && names[i] != ''
    const status = strpart(names[i], 0, 1)
    if status ==# 'R' || status ==# 'C'
      if i + 2 >= len(names)
        throw 'invalid renamed file status'
      endif
      const path = names[i + 2]
      const count = get(stats, path, ['0', '0'])
      add(result, {
        status: status,
        old_path: names[i + 1],
        path: path,
        additions: count[0],
        deletions: count[1],
      })
      i += 3
    else
      if i + 1 >= len(names)
        throw 'invalid file status'
      endif
      const path = names[i + 1]
      const count = get(stats, path, ['0', '0'])
      add(result, {
        status: status,
        old_path: '',
        path: path,
        additions: count[0],
        deletions: count[1],
      })
      i += 2
    endif
  endwhile
  return result
enddef

def RestoreGitGutter(): void
  if had_diff_base
    g:gitgutter_diff_base = saved_diff_base
  else
    unlet! g:gitgutter_diff_base
  endif
  if had_relative_to
    g:gitgutter_diff_relative_to = saved_relative_to
  else
    unlet! g:gitgutter_diff_relative_to
  endif
enddef

def UseGitGutterBase(): void
  g:gitgutter_diff_base = base_sha
  g:gitgutter_diff_relative_to = 'index'
enddef

def DisplayPath(change: dict<any>): string
  if change.status ==# 'R' || change.status ==# 'C'
    return change.old_path .. ' → ' .. change.path
  endif
  return change.path
enddef

def RenderFiles(): void
  if files_bufnr <= 0 || !bufexists(files_bufnr)
    return
  endif
  var lines = [$'Git diff {range_label}', $'Files changed ({len(changes)})', '']
  for i in range(len(changes))
    const change = changes[i]
    const marker = i == current_index ? '> ' : '  '
    add(lines, printf(
      '%s+%-5s -%-5s %s  %s',
      marker,
      change.additions,
      change.deletions,
      change.status,
      DisplayPath(change)
    ))
  endfor
  setbufvar(files_bufnr, '&modifiable', true)
  setbufline(files_bufnr, 1, lines)
  if line('$', files_bufnr) > len(lines)
    deletebufline(files_bufnr, len(lines) + 1, '$')
  endif
  setbufvar(files_bufnr, '&modifiable', false)
enddef

def ConfigureCodeBuffer(): void
  if temp_root == ''
    return
  endif
  KeepCwd()
  const path = expand('%:p')
  if &buftype != '' || stridx(path, temp_root .. '/') != 0
    RestoreGitGutter()
    if &buftype == '' && path != ''
      silent! execute 'GitGutter'
    endif
    return
  endif

  b:rooter_disabled = true
  setlocal readonly nomodifiable
  nnoremap <buffer> <silent> q <ScriptCmd>Close()<CR>
  nnoremap <buffer> <silent> gf <ScriptCmd>ToggleFiles()<CR>
  nnoremap <buffer> <silent> ]f <ScriptCmd>MoveFile(1)<CR>
  nnoremap <buffer> <silent> [f <ScriptCmd>MoveFile(-1)<CR>
  nnoremap <buffer> ghs <Nop>
  nnoremap <buffer> ghr <Nop>

  const relative = strpart(path, strlen(temp_root) + 1)
  for i in range(len(changes))
    if changes[i].path ==# relative
      current_index = i
      RenderFiles()
      break
    endif
  endfor
  UseGitGutterBase()
  silent! execute 'GitGutter'
enddef

def PinFiles(): void
  if files_bufnr <= 0 || winnr('$') <= 1
    return
  endif
  const winid = bufwinid(files_bufnr)
  if winid > 0
    win_execute(winid, 'wincmd J | resize 12 | setlocal winfixheight')
  endif
enddef

def OpenPath(index: number): void
  if index < 0 || index >= len(changes) || changes[index].status ==# 'D'
    echo 'Deleted file has no target version'
    return
  endif
  const rooter_state = DisableRooter()
  try
    if bufnr('%') == files_bufnr
      if winnr('$') == 1
        aboveleft new
      else
        wincmd p
      endif
    endif
    execute 'edit ' .. fnameescape(temp_root .. '/' .. changes[index].path)
  finally
    KeepCwd()
    RestoreRooter(rooter_state)
  endtry
  current_index = index
  ConfigureCodeBuffer()
  PinFiles()
enddef

def OpenUnderCursor(): void
  OpenPath(line('.') - 4)
enddef

def MoveFile(direction: number): void
  if empty(changes)
    return
  endif
  var index = current_index
  for _ in range(len(changes))
    index = (index + direction + len(changes)) % len(changes)
    if changes[index].status !=# 'D'
      OpenPath(index)
      return
    endif
  endfor
enddef

def ToggleFiles(): void
  if files_bufnr <= 0 || !bufexists(files_bufnr)
    return
  endif
  if bufwinnr(files_bufnr) != -1
    if winnr('$') > 1
      win_execute(bufwinid(files_bufnr), 'close')
    endif
    return
  endif
  execute 'botright :12split'
  execute 'buffer ' .. files_bufnr
  PinFiles()
  wincmd p
enddef

def ShowFiles(): void
  enew
  execute 'file gitdiff://files'
  files_bufnr = bufnr('%')
  b:rooter_disabled = true
  setlocal buftype=nofile bufhidden=hide noswapfile nomodifiable
  setlocal nowrap nonumber norelativenumber signcolumn=no nolist
  setfiletype gitdiff
  nnoremap <buffer> <silent> <CR> <ScriptCmd>OpenUnderCursor()<CR>
  nnoremap <buffer> <silent> q <ScriptCmd>Close()<CR>
  nnoremap <buffer> <silent> gf <ScriptCmd>ToggleFiles()<CR>
  RenderFiles()
enddef

def ResetState(): void
  repo_root = ''
  temp_root = ''
  session_cwd = ''
  base_sha = ''
  range_label = ''
  changes = []
  files_bufnr = -1
  current_index = -1
  had_diff_base = false
  saved_diff_base = v:none
  had_relative_to = false
  saved_relative_to = v:none
enddef

def Cleanup(close_tab: bool): void
  if temp_root == '' || cleaning
    return
  endif
  cleaning = true
  const root = repo_root
  const worktree = temp_root
  const rooter_state = DisableRooter()
  try
    RestoreGitGutter()

    if close_tab
      for tab in range(1, tabpagenr('$'))
        if gettabvar(tab, 'gitdiff_session', false)
          if tabpagenr('$') > 1
            execute $'tabclose! {tab}'
          elseif tab == tabpagenr()
            enew
          endif
          break
        endif
      endfor
    endif

    for info in getbufinfo()
      const name = fnamemodify(info.name, ':p')
      if info.name ==# 'gitdiff://files' || stridx(name, worktree .. '/') == 0
        execute 'silent! bwipeout! ' .. info.bufnr
      endif
    endfor

    systemlist(['git', '-C', root, 'worktree', 'remove', '--force', worktree])
    if v:shell_error != 0
      echohl WarningMsg
      echom 'Could not remove Git diff worktree: ' .. worktree
      echohl None
    endif
  finally
    if !close_tab
      ProtectOriginFromRooter()
      origin_restore_pending = true
    endif
    KeepCwd()
    RestoreRooter(rooter_state)
    ResetState()
    cleaning = false
  endtry
enddef

export def Close(): void
  Cleanup(true)
enddef

def CleanupClosedTab(): void
  if temp_root == '' || cleaning
    return
  endif
  for tab in range(1, tabpagenr('$'))
    if gettabvar(tab, 'gitdiff_session', false)
      return
    endif
  endfor
  Cleanup(false)
enddef

export def Open(spec: string): void
  Close()
  try
    const invocation_cwd = getcwd()
    session_cwd = invocation_cwd
    const worktree = WorktreePath(invocation_cwd)
    repo_root = Git(invocation_cwd, ['rev-parse', '--show-toplevel'])[0]
    range_label = spec
    const resolved = ResolveRange(spec)
    base_sha = resolved[0]
    changes = ReadChanges(base_sha, resolved[1])
    if empty(changes)
      echo 'No changes'
      ResetState()
      return
    endif

    had_diff_base = exists('g:gitgutter_diff_base')
    saved_diff_base = get(g:, 'gitgutter_diff_base', v:none)
    had_relative_to = exists('g:gitgutter_diff_relative_to')
    saved_relative_to = get(g:, 'gitgutter_diff_relative_to', v:none)
    Git(repo_root, ['worktree', 'add', '--quiet', '--detach', worktree, resolved[1]])
    temp_root = resolve(worktree)
    UseGitGutterBase()

    const rooter_state = DisableRooter()
    try
      tabnew
      t:gitdiff_session = true
      ShowFiles()
    finally
      KeepCwd()
      RestoreRooter(rooter_state)
    endtry
  catch
    const message = v:exception
    if temp_root != ''
      Cleanup(true)
    else
      ResetState()
    endif
    echohl ErrorMsg
    echom message
    echohl None
  endtry
enddef

augroup UserGitDiff
  autocmd!
  autocmd BufReadPost,BufEnter * ConfigureCodeBuffer()
  autocmd BufEnter * RestoreOriginAfterEnter()
  autocmd WinNew * PinFiles()
  autocmd TabClosed * CleanupClosedTab()
  autocmd VimLeavePre * Cleanup(false)
augroup END

defcompile

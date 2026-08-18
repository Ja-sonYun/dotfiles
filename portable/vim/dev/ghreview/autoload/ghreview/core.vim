vim9script

import autoload 'dock/core.vim' as dock
import autoload 'gitdiff/core.vim' as gitdiff
import autoload 'utils/job.vim' as job
import autoload 'utils/signcol.vim' as signcol

class DraftSpec extends signcol.Spec
  def new()
    this.kind = 'draft'
    this.text = 'D'
    this.texthl = 'GhReviewDraftSign'
  enddef
endclass

class DraftItem extends signcol.Item
  def new(lnum: number, key: string)
    this.kind = 'draft'
    this.lnum = lnum
    this.key = key
  enddef
endclass

const draft_signs = signcol.SignCol.new('GhReview', [DraftSpec.new()], 20)
const drafts_query = join([
  'query($id: ID!) {',
  '  viewer { login }',
  '  node(id: $id) {',
  '    ... on PullRequest {',
  '      headRefOid',
  '      reviews(last: 20, states: [PENDING]) {',
  '        nodes { id author { login } }',
  '      }',
  '      reviewThreads(last: 100) {',
  '        nodes {',
  '          id path diffSide line originalLine',
  '          comments(last: 100) {',
  '            nodes {',
  '              id body createdAt state author { login }',
  '              pullRequestReview { id }',
  '            }',
  '          }',
  '        }',
  '      }',
  '    }',
  '  }',
  '}',
], "\n")
const create_review_mutation = join([
  'mutation($input: AddPullRequestReviewInput!) {',
  '  addPullRequestReview(input: $input) {',
  '    pullRequestReview { id }',
  '  }',
  '}',
], "\n")
const add_thread_mutation = join([
  'mutation($input: AddPullRequestReviewThreadInput!) {',
  '  addPullRequestReviewThread(input: $input) {',
  '    thread { id }',
  '  }',
  '}',
], "\n")

var repo_root = ''
var pr: dict<any> = {}
var session_head = ''
var pending_review_id = ''
var drafts: list<dict<any>> = []
var open_request = 0
var session_token = 0
var panel_sequence = 0
var review_mutating = false
var running_jobs: list<any> = []

def Error(message: string): void
  echohl ErrorMsg
  echom message
  echohl None
enddef

def JobError(stderr: list<string>, code: number): string
  const lines = copy(stderr)->filter((_, line) => line !=# '')
  return !empty(lines) ? join(lines, "\n") : $'command failed with exit code {code}'
enddef

def RegisterJob(jb: any): void
  add(running_jobs, jb)
enddef

def UnregisterJob(jb: any): void
  const index = index(running_jobs, jb)
  if index >= 0
    remove(running_jobs, index)
  endif
enddef

def Run(cwd: string, argv: list<string>, input: string, Done: any): void
  var jb: any
  jb = job.Job.new(argv, {
    cwd: cwd,
    done_cb: (stdout, stderr, code) => {
      UnregisterJob(jb)
      if code == 0
        call(Done, [join(stdout, "\n"), ''])
      else
        call(Done, ['', JobError(stderr, code)])
      endif
    },
  })
  RegisterJob(jb)
  try
    jb.Start()
    if input !=# ''
      jb.Stdin(input)
    endif
    jb.CloseIn()
  catch
    UnregisterJob(jb)
    call(Done, ['', v:exception])
  endtry
enddef

def GraphQL(cwd: string, query: string, variables: dict<any>, Done: any): void
  const input = json_encode({ query: query, variables: variables })
  Run(cwd, ['gh', 'api', 'graphql', '--input', '-'], input, (text, error) => {
    if error !=# ''
      call(Done, [{}, error])
      return
    endif
    try
      const response: any = json_decode(text)
      if type(response) != v:t_dict
        throw 'GitHub returned invalid JSON'
      endif
      const api_errors = get(response, 'errors', [])
      if !empty(api_errors)
        var messages: list<string> = []
        for item in api_errors
          add(messages, get(item, 'message', string(item)))
        endfor
        throw join(messages, "\n")
      endif
      const data = get(response, 'data', {})
      if type(data) != v:t_dict
        throw 'GitHub returned no data'
      endif
      call(Done, [data, ''])
    catch
      call(Done, [{}, v:exception])
    endtry
  })
enddef

def Git(cwd: string, args: list<string>): list<string>
  const output = systemlist(['git', '-C', cwd] + args)
  if v:shell_error != 0
    throw $'git {join(args, " ")} failed'
  endif
  return output
enddef

def RepositoryFromPrUrl(url: string): string
  const match = matchlist(url, '^https://github\.com/\([^/]\+\)/\([^/]\+\)/pull/[0-9]\+')
  return empty(match) ? '' : match[1] .. '/' .. match[2]
enddef

def Number(value: any, fallback: number = 0): number
  return type(value) == v:t_number ? value : fallback
enddef

def Hunks(buf: number): list<any>
  try
    const result: any = call('gitgutter#hunk#hunks', [buf])
    return type(result) == v:t_list ? result : []
  catch
    return []
  endtry
enddef

def DraftAnchor(draft: dict<any>, hunks: list<any>): number
  if get(draft, 'side', '') ==# 'RIGHT'
    return Number(get(draft, 'line', 0))
  endif
  const old_line = Number(get(draft, 'line', 0))
  for hunk in hunks
    if type(hunk) != v:t_list || len(hunk) < 4
      continue
    endif
    const old_start = Number(hunk[0])
    const old_count = Number(hunk[1])
    const new_start = Number(hunk[2])
    const new_count = Number(hunk[3])
    if new_count == 0 && old_line >= old_start && old_line < old_start + old_count
      return max([new_start, 1])
    endif
  endfor
  return 0
enddef

def Context(buf: number): dict<any>
  const context = getbufvar(buf, 'gitdiff_context', {})
  return type(context) == v:t_dict ? context : {}
enddef

def IsReviewBuffer(buf: number): bool
  const context = Context(buf)
  return !empty(pr)
    && get(context, 'repo_root', '') ==# repo_root
    && get(context, 'head_sha', '') ==# session_head
enddef

def UpdateBufferSigns(buf: number): void
  if !bufexists(buf) || !IsReviewBuffer(buf)
    draft_signs.Clear(buf)
    return
  endif
  const context = Context(buf)
  const path = get(context, 'path', '')
  const hunks = Hunks(buf)
  var seen: dict<bool> = {}
  var items: list<signcol.Item> = []
  for draft in drafts
    if get(draft, 'path', '') !=# path
      continue
    endif
    const anchor = DraftAnchor(draft, hunks)
    const key = string(anchor)
    if anchor > 0 && !has_key(seen, key)
      seen[key] = true
      add(items, DraftItem.new(anchor, path .. '@' .. key))
    endif
  endfor
  draft_signs.Update(buf, items)
enddef

def UpdateSigns(): void
  for info in getbufinfo()
    if has_key(getbufvar(info.bufnr, ''), 'gitdiff_context')
      UpdateBufferSigns(info.bufnr)
    endif
  endfor
enddef

def ApplyDrafts(data: dict<any>): void
  const viewer = get(get(data, 'viewer', {}), 'login', '')
  const node = get(data, 'node', {})
  if type(node) != v:t_dict || empty(node)
    throw 'GitHub pull request no longer exists'
  endif
  const current_head = get(node, 'headRefOid', '')
  if type(current_head) != v:t_string || current_head ==# ''
    throw 'GitHub returned no pull request head'
  endif

  pending_review_id = ''
  const reviews = get(get(node, 'reviews', {}), 'nodes', [])
  for review in reviews
    if get(get(review, 'author', {}), 'login', '') ==# viewer
      pending_review_id = get(review, 'id', '')
      break
    endif
  endfor

  var next_drafts: list<dict<any>> = []
  if pending_review_id !=# ''
    const threads = get(get(node, 'reviewThreads', {}), 'nodes', [])
    for thread in threads
      const comments = get(get(thread, 'comments', {}), 'nodes', [])
      for comment in comments
        if get(comment, 'state', '') !=# 'PENDING'
          continue
        endif
        if get(get(comment, 'pullRequestReview', {}), 'id', '') !=# pending_review_id
          continue
        endif
        const side = get(thread, 'diffSide', '')
        var line = Number(get(thread, 'line', 0))
        if line <= 0
          line = Number(get(thread, 'originalLine', 0))
        endif
        add(next_drafts, {
          id: get(comment, 'id', ''),
          thread_id: get(thread, 'id', ''),
          path: get(thread, 'path', ''),
          side: side,
          line: line,
          author: get(get(comment, 'author', {}), 'login', ''),
          created_at: get(comment, 'createdAt', ''),
          body: get(comment, 'body', ''),
        })
      endfor
    endfor
  endif
  session_head = current_head
  drafts = next_drafts
  UpdateSigns()
enddef

def Finish(done: any, ok: bool, error: string): void
  if type(done) != v:t_none
    call(done, [ok, error])
  endif
enddef

def FetchDrafts(expected_token: number, done: any): void
  GraphQL(repo_root, drafts_query, { id: get(pr, 'id', '') }, (data, error) => {
    if expected_token != session_token
      return
    endif
    if error !=# ''
      if type(done) == v:t_none
        Error(error)
      endif
      Finish(done, false, error)
      return
    endif
    try
      ApplyDrafts(data)
      Finish(done, true, '')
    catch
      if type(done) == v:t_none
        Error(v:exception)
      endif
      Finish(done, false, v:exception)
    endtry
  })
enddef

export def Refresh(): void
  if empty(pr)
    Error('No active GitHub review')
    return
  endif
  FetchDrafts(session_token, v:none)
enddef

def HandleFetch(request: number, root: string, info: dict<any>, error: string): void
  if request != open_request
    return
  endif
  if error !=# ''
    Error(error)
    return
  endif
  try
    if Git(getcwd(), ['rev-parse', '--show-toplevel'])[0] !=# root
      throw 'working directory changed while opening the review'
    endif
    gitdiff.Open($'{info.baseRefOid}...{info.headRefOid}')
    if !gettabvar(tabpagenr(), 'gitdiff_session', false)
      throw 'Git diff did not open'
    endif
    session_token += 1
    repo_root = root
    pr = info
    session_head = info.headRefOid
    pending_review_id = ''
    drafts = []
    FetchDrafts(session_token, v:none)
  catch
    Error(v:exception)
  endtry
enddef

def HandlePr(request: number, root: string, repository: string, text: string, error: string): void
  if request != open_request
    return
  endif
  if error !=# ''
    Error(error)
    return
  endif
  try
    const info: any = json_decode(text)
    if type(info) != v:t_dict
      throw 'GitHub returned invalid pull request data'
    endif
    const pr_repository = RepositoryFromPrUrl(get(info, 'url', ''))
    if pr_repository ==# '' || tolower(pr_repository) !=# tolower(repository)
      throw 'GitHub review only supports the current repository'
    endif
    const number = Number(get(info, 'number', 0))
    if number <= 0
      throw 'GitHub returned an invalid pull request number'
    endif
    Run(root, [
      'git', '-C', root, 'fetch', '--quiet', 'origin',
      'refs/heads/' .. info.baseRefName,
      $'refs/pull/{number}/head',
    ], '', (_, fetch_error) =>
      HandleFetch(request, root, info, fetch_error))
  catch
    Error(v:exception)
  endtry
enddef

def HandleRepository(request: number, root: string, target: string, text: string, error: string): void
  if request != open_request
    return
  endif
  if error !=# ''
    Error(error)
    return
  endif
  const repository = trim(text)
  if repository ==# ''
    Error('GitHub returned no repository name')
    return
  endif
  var argv = ['gh', 'pr', 'view']
  if target !=# ''
    add(argv, target)
  endif
  extend(argv, ['--json', 'id,number,url,title,baseRefName,baseRefOid,headRefOid'])
  Run(root, argv, '', (pr_text, pr_error) =>
    HandlePr(request, root, repository, pr_text, pr_error))
enddef

export def Open(target: string): void
  try
    const root = Git(getcwd(), ['rev-parse', '--show-toplevel'])[0]
    open_request += 1
    const request = open_request
    Run(root, ['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'], '',
      (text, error) => HandleRepository(request, root, target, text, error))
  catch
    Error(v:exception)
  endtry
enddef

def TargetAtCursor(): dict<any>
  const buf = bufnr()
  if !IsReviewBuffer(buf)
    throw 'Not a GitHub review diff buffer'
  endif
  const context = Context(buf)
  const cursor_line = line('.')
  for hunk in Hunks(buf)
    if type(hunk) != v:t_list || len(hunk) < 4
      continue
    endif
    const old_start = Number(hunk[0])
    const old_count = Number(hunk[1])
    const new_start = Number(hunk[2])
    const new_count = Number(hunk[3])
    if new_count == 0 && cursor_line == max([new_start, 1])
      return {
        path: context.path,
        line: old_start,
        side: 'LEFT',
        anchor: cursor_line,
        head: session_head,
      }
    endif
    if new_count > 0 && cursor_line >= new_start && cursor_line < new_start + new_count
      return {
        path: context.path,
        line: cursor_line,
        side: 'RIGHT',
        anchor: cursor_line,
        head: session_head,
      }
    endif
  endfor
  throw 'Review comments can only be added on changed lines'
enddef

def ReviewDock(): dict<any>
  return get(g:, 'ghreview_dock', { edge: 'bottom', size: 10, min_width: 50 })
enddef

def NewScratch(name: string, lines: list<string>, writable: bool): number
  const buf = bufadd(name)
  setbufvar(buf, '&buftype', writable ? 'acwrite' : 'nofile')
  setbufvar(buf, '&bufhidden', 'wipe')
  setbufvar(buf, '&swapfile', false)
  setbufvar(buf, '&filetype', 'markdown')
  bufload(buf)
  setbufvar(buf, '&modifiable', true)
  setbufline(buf, 1, empty(lines) ? [''] : lines)
  if !writable
    setbufvar(buf, '&modifiable', false)
  endif
  setbufvar(buf, '&modified', false)
  return buf
enddef

def AddComment(): void
  try
    const target = TargetAtCursor()
    panel_sequence += 1
    const name = $'ghreview://comment/{panel_sequence}/{target.path}:{target.line}'
    const buf = NewScratch(name, [''], true)
    setbufvar(buf, 'ghreview_target', target)
    setbufvar(buf, 'ghreview_saving', false)
    dock.Open(buf, ReviewDock())
    execute $'autocmd GhReviewComments BufWriteCmd <buffer={buf}> call ghreview#core#SaveComment({buf})'
  catch
    Error(v:exception)
  endtry
enddef

def CommentBody(buf: number): string
  var lines = getbufline(buf, 1, '$')
  while !empty(lines) && lines[-1] ==# ''
    remove(lines, -1)
  endwhile
  return join(lines, "\n")
enddef

def SaveFailed(buf: number, message: string): void
  review_mutating = false
  if bufexists(buf)
    setbufvar(buf, 'ghreview_saving', false)
  endif
  Error(message)
enddef

def SaveSucceeded(buf: number, expected_token: number): void
  review_mutating = false
  if bufexists(buf)
    setbufvar(buf, '&modified', false)
    execute $'silent! bwipeout! {buf}'
  endif
  if expected_token == session_token
    FetchDrafts(expected_token, v:none)
  endif
enddef

def AddThread(buf: number, expected_token: number, target: dict<any>, body: string): void
  const input = {
    pullRequestId: get(pr, 'id', ''),
    pullRequestReviewId: pending_review_id,
    path: target.path,
    line: target.line,
    side: target.side,
    body: body,
  }
  GraphQL(repo_root, add_thread_mutation, { input: input }, (data, error) => {
    if expected_token != session_token
      return
    endif
    if error !=# ''
      SaveFailed(buf, error)
      return
    endif
    if empty(get(get(data, 'addPullRequestReviewThread', {}), 'thread', {}))
      SaveFailed(buf, 'GitHub did not create the draft thread')
      return
    endif
    SaveSucceeded(buf, expected_token)
  })
enddef

def EnsurePendingReview(buf: number, expected_token: number, target: dict<any>, body: string): void
  if pending_review_id !=# ''
    AddThread(buf, expected_token, target, body)
    return
  endif
  const input = {
    pullRequestId: get(pr, 'id', ''),
    threads: [{
      path: target.path,
      line: target.line,
      side: target.side,
      body: body,
    }],
  }
  GraphQL(repo_root, create_review_mutation, { input: input }, (data, error) => {
    if expected_token != session_token
      return
    endif
    if error !=# ''
      SaveFailed(buf, error)
      return
    endif
    pending_review_id = get(get(get(data, 'addPullRequestReview', {}), 'pullRequestReview', {}), 'id', '')
    if pending_review_id ==# ''
      SaveFailed(buf, 'GitHub did not create a pending review')
      return
    endif
    SaveSucceeded(buf, expected_token)
  })
enddef

export def SaveComment(buf: number): void
  if !bufexists(buf) || getbufvar(buf, 'ghreview_saving', false)
    return
  endif
  if review_mutating
    Error('Another draft comment is being saved')
    return
  endif
  const body = CommentBody(buf)
  if body !~# '\S'
    Error('Draft comment is empty')
    return
  endif
  const target = getbufvar(buf, 'ghreview_target', {})
  if empty(pr) || type(target) != v:t_dict
    Error('No active GitHub review')
    return
  endif

  const expected_token = session_token
  review_mutating = true
  setbufvar(buf, 'ghreview_saving', true)
  FetchDrafts(expected_token, (ok, error) => {
    if !ok
      SaveFailed(buf, error)
      return
    endif
    if get(target, 'head', '') !=# session_head
      SaveFailed(buf, 'Pull request changed; run :GhReview again')
      return
    endif
    EnsurePendingReview(buf, expected_token, target, body)
  })
enddef

def FormatTime(value: string): string
  const timestamp = strptime('%Y-%m-%dT%H:%M:%SZ', value)
  return timestamp > 0 ? strftime('%Y-%m-%d %H:%M', timestamp) : value
enddef

def ShowThread(): void
  try
    const buf = bufnr()
    if !IsReviewBuffer(buf)
      throw 'Not a GitHub review diff buffer'
    endif
    const context = Context(buf)
    const cursor_line = line('.')
    const hunks = Hunks(buf)
    var matches: list<dict<any>> = []
    for draft in drafts
      if get(draft, 'path', '') ==# context.path
          && DraftAnchor(draft, hunks) == cursor_line
        add(matches, draft)
      endif
    endfor
    if empty(matches)
      throw 'No pending draft at this line'
    endif

    var lines = [$'{context.path}:{matches[0].line} | DRAFT', '']
    for draft in matches
      add(lines, $'{FormatTime(draft.created_at)} | @{draft.author}')
      extend(lines, split(draft.body, "\n", true))
      add(lines, '')
    endfor
    panel_sequence += 1
    const thread_buf = NewScratch($'ghreview://thread/{panel_sequence}', lines, false)
    dock.Open(thread_buf, ReviewDock())
  catch
    Error(v:exception)
  endtry
enddef

def OnGitDiffBuffer(): void
  const buf = bufnr()
  if !IsReviewBuffer(buf)
    return
  endif
  if !get(b:, 'ghreview_mapped', false)
    b:ghreview_mapped = true
    nnoremap <buffer> <silent> gc <ScriptCmd>AddComment()<CR>
    nnoremap <buffer> <silent> gt <ScriptCmd>ShowThread()<CR>
  endif
  UpdateBufferSigns(buf)
enddef

def CloseSession(): void
  session_token += 1
  draft_signs.ClearAll()
  repo_root = ''
  pr = {}
  session_head = ''
  pending_review_id = ''
  drafts = []
  review_mutating = false
enddef

highlight default link GhReviewDraftSign Todo

augroup GhReviewComments
  autocmd!
augroup END

augroup GhReviewEvents
  autocmd!
  autocmd User GitDiffBuffer OnGitDiffBuffer()
  autocmd User GitDiffClosed CloseSession()
augroup END

silent defcompile

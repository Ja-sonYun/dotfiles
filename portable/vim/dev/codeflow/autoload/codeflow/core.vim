vim9script

const HIGHLIGHTS = {
  CodeflowTitle: 'Title',
  CodeflowNote: 'Comment',
}
const TRACK_TYPE = 'CodeflowPosition'

var session: dict<any> = {}
var records: dict<dict<any>> = {}
var documents: dict<dict<any>> = {}
var listeners: dict<number> = {}
var marker_id = 0
var shown: dict<any> = {}
var watch_timer = -1
var poll_pending = false
var refreshing = false

def Git(root: string, args: list<string>): list<string>
  const command = 'git --no-optional-locks -C ' .. shellescape(root) .. ' '
    .. join(mapnew(args, (_, arg) => shellescape(arg)), ' ') .. ' 2>&1'
  const output = systemlist(command)
  if v:shell_error != 0
    throw 'FlowLoad: Git query failed for ' .. root .. ': ' .. join(output, ' ')
  endif
  return output
enddef

def ReadMetadata(root: string, expected: dict<any>): list<string>
  const branch = join(Git(root, ['rev-parse', '--abbrev-ref', 'HEAD']), '')
  const commit = join(Git(root, ['rev-parse', '--verify', 'HEAD']), '')
  const status = Git(root, ['status', '--porcelain=v1', '--untracked-files=all'])
  var lines: list<string> = []
  if branch !=# expected.branch
    extend(lines, [
      'WARNING: Branch mismatch',
      'Expected: ' .. expected.branch,
      'Current:  ' .. branch,
      '',
    ])
  endif
  if commit !=? expected.commit
    extend(lines, [
      'WARNING: Commit mismatch',
      'Expected: ' .. expected.commit,
      'Current:  ' .. commit,
      '',
    ])
  endif
  extend(lines, [
    'Project: ' .. root,
    'Branch: ' .. (branch ==# 'HEAD' ? 'HEAD (detached)' : branch),
    'Commit: ' .. strpart(commit, 0, 12),
    'Worktree (at load): ' .. (empty(status) ? 'clean' : 'changed'),
  ])
  if !empty(status)
    extend(lines, ['Status: index / worktree; ?? = untracked'] + status)
  endif
  return lines
enddef

def ReadFlow(path: string, content: string): dict<any>
  const json_path = fnamemodify(path, ':p')
  final flow = json_decode(content)
  if type(flow) != v:t_dict
      || type(get(flow, 'title', 0)) != v:t_string || empty(flow.title)
      || type(get(flow, 'steps', 0)) != v:t_list
    throw 'FlowLoad: expected a title and a steps array'
  endif

  if type(get(flow, 'root', 0)) != v:t_string || empty(flow.root)
      || type(get(flow, 'git', 0)) != v:t_dict
      || type(get(flow.git, 'branch', 0)) != v:t_string || empty(flow.git.branch)
      || type(get(flow.git, 'commit', 0)) != v:t_string || empty(flow.git.commit)
    throw 'FlowLoad: expected root, git.branch and git.commit strings'
  endif
  const root = simplify(flow.root =~# '^/'
    ? flow.root : fnamemodify(json_path, ':h') .. '/' .. flow.root)
  if !isdirectory(root)
    throw 'FlowLoad: project root is not a directory: ' .. root
  endif
  var entries: list<dict<any>> = []
  var ids: dict<bool> = {}
  for step in flow.steps
    const label = $'FlowLoad: step {len(entries) + 1}'
    if type(step) != v:t_dict
        || type(get(step, 'id', 0)) != v:t_string || empty(step.id)
        || type(get(step, 'file', 0)) != v:t_string || empty(step.file)
        || type(get(step, 'line', 0)) != v:t_number || step.line < 1
        || type(get(step, 'title', 0)) != v:t_string || empty(step.title)
        || type(get(step, 'description', 0)) != v:t_string
      throw label .. ' requires id, file, a positive line, title and description'
    endif
    if has_key(ids, step.id)
      throw label .. ': duplicate id: ' .. step.id
    endif
    ids[step.id] = true
    if step.file =~# '^/'
      throw label .. ': file must be relative to the project root'
    endif
    const file = simplify(root .. '/' .. step.file)
    add(entries, {
      bufnr: bufadd(file), lnum: step.line, col: 1, valid: 1,
      text: $'{len(entries) + 1}. {step.title}',
      user_data: extend(deepcopy(step), {order: len(entries) + 1}),
    })
  endfor
  return {
    json: flow,
    root: root,
    title: flow.title,
    items: entries,
    metadata: ReadMetadata(root, flow.git),
  }
enddef

def Forget(buf: number): void
  if bufloaded(buf)
    const types = filter(keys(HIGHLIGHTS), (_, name) =>
      !empty(prop_type_get(name, {bufnr: buf})))
    if !empty(types)
      prop_remove({bufnr: buf, types: types, all: true})
    endif
  endif
  for key in keys(shown)
    if shown[key].state.buf == buf
      remove(shown, key)
    endif
  endfor
enddef

def Wrap(text: string, width: number): list<string>
  const prefix = '> '
  const body_width = max([1, width - strdisplaywidth(prefix)])
  var remaining = substitute(text, '\t', '    ', 'g')
  var lines: list<string> = []
  while strdisplaywidth(remaining) > body_width
    var count = 0
    while count < strchars(remaining)
        && strdisplaywidth(strcharpart(remaining, 0, count + 1)) <= body_width
      count += 1
    endwhile
    const head = strcharpart(remaining, 0, max([1, count]))
    const space = strridx(head, ' ')
    if space > 0
      add(lines, strpart(head, 0, space))
      remaining = strpart(remaining, space + 1)
    else
      add(lines, head)
      remaining = strpart(remaining, strlen(head))
    endif
  endwhile
  add(lines, remaining)
  return map(lines, (_, line) => prefix .. line)
enddef

def RemoveNotes(key: string): void
  final note = remove(shown, key)
  if bufloaded(note.state.buf)
    for id in note.ids
      prop_remove({bufnr: note.state.buf, id: id, all: true})
    endfor
  endif
enddef

def ReconcileNotes(): void
  for buffer in getbufinfo({bufloaded: 1})
    const types = filter(keys(HIGHLIGHTS), (_, name) =>
      !empty(prop_type_get(name, {bufnr: buffer.bufnr})))
    if empty(types)
      continue
    endif
    final expected: list<string> = []
    final ids: list<number> = []
    for note in values(shown)
      if note.state.buf == buffer.bufnr
        extend(ids, note.ids)
        for row in note.state.lines
          for text in Wrap(row.text, note.state.width)
            const normalized = substitute(text, "[\x01-\x1f]", ' ', 'g')
            add(expected, json_encode([row.type, note.state.line, normalized]))
          endfor
        endfor
      endif
    endfor
    final actual: list<string> = mapnew(prop_list(1, {
      bufnr: buffer.bufnr, types: types, end_lnum: -1,
    }), (_, prop) => json_encode([prop.type, prop.lnum, prop.text]))
    if sort(actual) !=# sort(expected)
      Forget(buffer.bufnr)
    elseif !empty(ids) && len(prop_list(1, {
        bufnr: buffer.bufnr, types: types, ids: ids, end_lnum: -1,
      })) != len(actual)
      Forget(buffer.bufnr)
    endif
  endfor
enddef

def StepTitle(document: dict<any>, entry: dict<any>): string
  const deleted = get(get(document.tracks, entry.user_data.id, {}), 'deleted', false)
  return (deleted ? '[deleted] ' : '') .. entry.user_data.title
enddef

def ShowNotes(): void
  ReconcileNotes()
  var widths: dict<number> = {}
  for window in getwininfo()
    const key = string(window.bufnr)
    const width = max([1, window.width - window.textoff - 1])
    widths[key] = min([get(widths, key, width), width])
  endfor
  var groups: dict<any> = {}
  for entry in session.document.items
    final data = entry.user_data
    if entry.bufnr <= 0 || !bufloaded(entry.bufnr)
        || entry.lnum < 1 || entry.lnum > getbufinfo(entry.bufnr)[0].linecount
      continue
    endif
    const key = $'{entry.bufnr}:{entry.lnum}'
    if !has_key(groups, key)
      groups[key] = {
        buf: entry.bufnr, line: entry.lnum,
        width: get(widths, string(entry.bufnr), max([1, &columns - 1])),
        lines: [],
      }
    endif
    final group = groups[key]
    const title = StepTitle(session.document, entry)
    const lines = [$'CodeFlow {data.order}/{len(session.document.items)}: {title}', '']
      + split(data.description, "\n", true)
    for idx in range(len(lines))
      const name = idx == 0 ? 'CodeflowTitle' : 'CodeflowNote'
      add(group.lines, {type: name, text: lines[idx]})
    endfor
  endfor
  for key in keys(shown)
    if !has_key(groups, key) || shown[key].state !=# groups[key]
      RemoveNotes(key)
    endif
  endfor
  for [key, group] in items(groups)
    if has_key(shown, key)
      continue
    endif
    for [name, highlight] in items(HIGHLIGHTS)
      if empty(prop_type_get(name, {bufnr: group.buf}))
        prop_type_add(name, {bufnr: group.buf, highlight: highlight, priority: 0})
      endif
    endfor
    final note: dict<any> = {state: group, ids: []}
    shown[key] = note
    for row in group.lines
      for text in Wrap(row.text, group.width)
        add(note.ids, prop_add(group.line, 0, {
          bufnr: group.buf, type: row.type, text: text, text_align: 'above',
        }))
      endfor
    endfor
  endfor
enddef

def Warn(message: string): void
  echohl WarningMsg
  echomsg 'CodeFlow: ' .. message
  echohl None
enddef

def WarnOnce(message: string): void
  if empty(session)
    Warn(message)
    return
  endif
  if session.document.warning !=# message
    session.document.warning = message
    Warn(message)
  endif
enddef

def ReadContent(path: string): string
  if !filereadable(path)
    throw 'JSON file is not readable: ' .. path
  endif
  return join(readfile(path, 'b'), "\n")
enddef

def RemoveMarker(buf: number, id: number): void
  if bufloaded(buf)
    prop_remove({bufnr: buf, type: TRACK_TYPE, id: id, both: true, all: true})
  endif
enddef

def ClearTracks(document: dict<any>): void
  for track in values(document.tracks)
    RemoveMarker(track.entry.bufnr, track.origin)
    RemoveMarker(track.entry.bufnr, track.site)
  endfor
  document.tracks = {}
enddef

def SetPosition(entry: dict<any>, line: number): void
  entry.lnum = line
  entry.user_data.line = line
enddef

def Changed(buf: number, _start: number, _end: number, _added: number,
    changes: list<dict<number>>): void
  const emptied = getbufinfo(buf)[0].linecount == 1 && getbufline(buf, 1) ==# ['']
  for document in values(documents)
    for track in values(document.tracks)
      if track.entry.bufnr != buf
        continue
      endif
      for change in changes
        if change.added < 0 && track.line >= change.lnum
          document.dirty = true
          if track.line < change.lnum - change.added
            track.line = change.lnum
            track.deleted = true
            if emptied
              # Vim preserves properties when the last line becomes an empty placeholder.
              RemoveMarker(buf, track.origin)
            endif
          else
            track.line += change.added
          endif
        elseif change.added > 0
            && track.line >= (change.end == change.lnum ? change.lnum : change.end)
          track.line += change.added
          document.dirty = true
        endif
      endfor
    endfor
  endfor
  final positions: dict<number> = {}
  for prop in prop_list(1, {bufnr: buf, types: [TRACK_TYPE], end_lnum: -1})
    positions[string(prop.id)] = prop.lnum
  endfor
  for document in values(documents)
    for track in values(document.tracks)
      if track.entry.bufnr != buf
        continue
      endif
      const previous_line = track.line
      const was_deleted = track.deleted
      const origin = string(track.origin)
      const site = string(track.site)
      if has_key(positions, origin)
        track.line = positions[origin]
        track.deleted = false
      elseif track.deleted && has_key(positions, site)
        track.line = positions[site]
      endif
      if track.line != previous_line || track.deleted != was_deleted
        document.dirty = true
      endif
    endfor
  endfor
enddef

def AddMarker(buf: number, line: number, id: number): void
  if empty(prop_type_get(TRACK_TYPE, {bufnr: buf}))
    prop_type_add(TRACK_TYPE, {bufnr: buf})
  endif
  prop_add(line, 1, {bufnr: buf, type: TRACK_TYPE, id: id, length: 0})
enddef

def TrackBuffers(): void
  for key in keys(listeners)
    listener_flush(str2nr(key))
  endfor
  for document in values(documents)
    for entry in document.items
      if !bufloaded(entry.bufnr) || has_key(document.tracks, entry.user_data.id)
          || entry.lnum > getbufinfo(entry.bufnr)[0].linecount
        continue
      endif
      const key = string(entry.bufnr)
      if !has_key(listeners, key)
        listeners[key] = listener_add(Changed, entry.bufnr)
      endif
      marker_id += 2
      final track = {
        entry: entry, line: entry.lnum, deleted: false,
        origin: marker_id - 1, site: marker_id,
      }
      document.tracks[entry.user_data.id] = track
      AddMarker(entry.bufnr, track.line, track.origin)
    endfor
  endfor
enddef

def Publish(document: dict<any>): void
  for entry in document.items
    entry.text = $'{entry.user_data.order}. ' .. StepTitle(document, entry)
  endfor
  for record in values(records)
    if record.document.path !=# document.path
      continue
    endif
    const entries = getqflist({id: record.listid, items: 0}).items
    var changed = document.dirty || len(entries) != len(document.items)
    if !changed
      for idx in range(len(entries))
        if entries[idx].lnum != document.items[idx].lnum
            || entries[idx].bufnr != document.items[idx].bufnr
            || entries[idx].valid != document.items[idx].valid
            || entries[idx].text !=# document.items[idx].text
            || entries[idx].user_data !=# document.items[idx].user_data
          changed = true
          break
        endif
      endfor
    endif
    if changed
      WriteList(record, document)
    endif
  endfor
  document.dirty = false
enddef

def UpdateTracking(): void
  TrackBuffers()
  for key in keys(listeners)
    const buf = str2nr(key)
    if !bufloaded(buf) || empty(prop_type_get(TRACK_TYPE, {bufnr: buf}))
      continue
    endif
    final positions: dict<number> = {}
    for prop in prop_list(1, {bufnr: buf, types: [TRACK_TYPE], end_lnum: -1})
      positions[string(prop.id)] = prop.lnum
    endfor
    final owned: dict<bool> = {}
    for document in values(documents)
      for track in values(document.tracks)
        if track.entry.bufnr != buf
          continue
        endif
        const origin = string(track.origin)
        const site = string(track.site)
        owned[origin] = true
        owned[site] = true
        if has_key(positions, origin)
          track.line = positions[origin]
          track.deleted = false
          RemoveMarker(buf, track.site)
        else
          if track.deleted && has_key(positions, site)
            track.line = positions[site]
          endif
          track.line = min([max([1, track.line]), getbufinfo(buf)[0].linecount])
          const id = track.deleted ? track.site : track.origin
          if !has_key(positions, string(id))
            AddMarker(buf, track.line, id)
          endif
        endif
        SetPosition(track.entry, track.line)
      endfor
    endfor
    for id in keys(positions)
      if !has_key(owned, id)
        RemoveMarker(buf, str2nr(id))
      endif
    endfor
  endfor
  for document in values(documents)
    Publish(document)
  endfor
enddef

export def BufferLoaded(): void
  TrackBuffers()
enddef

export def Unload(buf: number): void
  Forget(buf)
  const key = string(buf)
  if has_key(listeners, key)
    listener_remove(remove(listeners, key))
  endif
  for document in values(documents)
    for idx in range(len(document.items))
      final entry = document.items[idx]
      if entry.bufnr != buf
        continue
      endif
      if has_key(document.tracks, entry.user_data.id)
        final track = remove(document.tracks, entry.user_data.id)
        RemoveMarker(buf, track.origin)
        RemoveMarker(buf, track.site)
      endif
      final saved = document.json.steps[idx]
      SetPosition(entry, saved.line)
    endfor
  endfor
enddef

def IsFlowList(record: dict<any>): bool
  const info = getqflist({id: record.listid, context: 0, items: 0})
  if info.id != record.listid || type(info.context) != v:t_dict
      || type(get(info.context, 'codeflow', 0)) != v:t_bool
      || !info.context.codeflow
      || len(info.items) != len(record.document.items)
    return false
  endif
  for idx in range(len(info.items))
    const data = get(info.items[idx], 'user_data', {})
    if type(data) != v:t_dict
        || type(get(data, 'id', 0)) != v:t_string
        || data.id !=# record.document.items[idx].user_data.id
      return false
    endif
  endfor
  return true
enddef

def PruneRecords(): void
  for [key, flow] in items(records)
    if !IsFlowList(flow)
      remove(records, key)
    endif
  endfor
  for [path, document] in items(documents)
    if empty(filter(values(records), (_, record) => record.document.path ==# path))
      ClearTracks(document)
      remove(documents, path)
    endif
  endfor
  for key in keys(listeners)
    var used = false
    for document in values(documents)
      if !empty(filter(copy(document.items), (_, entry) => entry.bufnr == str2nr(key)))
        used = true
        break
      endif
    endfor
    if !used
      listener_remove(remove(listeners, key))
    endif
  endfor
enddef

def FlowWindows(): list<dict<any>>
  const buf = getqflist({qfbufnr: 0}).qfbufnr
  return filter(getwininfo(), (_, window) =>
    window.quickfix && !window.loclist && window.bufnr == buf)
enddef

def Pause(): void
  if watch_timer >= 0
    timer_stop(watch_timer)
  endif
  watch_timer = -1
  poll_pending = false
  session = {}
  for buffer in getbufinfo({bufloaded: 1})
    Forget(buffer.bufnr)
  endfor
  shown = {}
enddef

def SyncFlow(): bool
  PruneRecords()
  UpdateTracking()
  const key = string(getqflist({id: 0}).id)
  if !has_key(records, key) || empty(FlowWindows())
    Pause()
    return false
  endif
  if empty(session) || session.listid != records[key].listid
    Pause()
    session = records[key]
    Reload()
  endif
  if watch_timer < 0
    watch_timer = timer_start(1000, Poll, {repeat: -1})
  endif
  return true
enddef

def WriteList(record: dict<any>, flow: dict<any>): void
  const info = getqflist({id: record.listid, idx: 0, items: 0})
  if get(info, 'id', 0) != record.listid
    return
  endif
  final positions: dict<number> = {}
  for idx in range(len(flow.items))
    positions[flow.items[idx].user_data.id] = idx + 1
  endfor
  var selected = empty(flow.items) ? 0 : 1
  if info.idx > 0 && info.idx <= len(info.items)
    selected = get(positions, info.items[info.idx - 1].user_data.id,
      min([info.idx, len(flow.items)]))
  endif
  final views: list<dict<any>> = []
  for window in (getqflist({id: 0}).id == record.listid ? FlowWindows() : [])
    final view: dict<any> = json_decode(win_execute(window.winid,
      'echo json_encode(winsaveview())'))
    if view.lnum > 0 && view.lnum <= len(info.items)
      const row = get(positions, info.items[view.lnum - 1].user_data.id, max([1, selected]))
      view.topline = max([1, row - (view.lnum - view.topline)])
      view.lnum = row
    endif
    add(views, {winid: window.winid, view: view})
  endfor
  if setqflist([], 'r', {
      id: record.listid, items: deepcopy(flow.items), idx: selected, title: flow.title,
      context: {codeflow: true, metadata: flow.metadata},
    }) != 0
    throw 'Could not update the quickfix list'
  endif
  for saved in views
    if !empty(getwininfo(saved.winid))
      win_execute(saved.winid, 'call winrestview(' .. string(saved.view) .. ')')
    endif
  endfor
enddef

export def PrepareJump(from_list: bool = false): void
  if refreshing
    return
  endif
  if from_list && getwininfo(win_getid())[0].loclist
    return
  endif
  refreshing = true
  try
    SyncFlow()
  catch
    WarnOnce(v:exception)
  finally
    refreshing = false
  endtry
enddef

export def PrepareCommand(): void
  if refreshing || (v:char !=# "\r" && v:char !=# "\n")
    return
  endif
  const command = fullcommand(getcmdline(), false)
  if index([
    'cc', 'cnext', 'cprevious', 'cNext', 'cfirst', 'clast', 'crewind',
  ], command) >= 0
    PrepareJump()
  endif
enddef

def Pending(document: dict<any>): bool
  for idx in range(len(document.items))
    final current = document.items[idx].user_data
    final saved = document.json.steps[idx]
    if current.line != saved.line
        || get(get(document.tracks, current.id, {}), 'deleted', false)
      return true
    endif
  endfor
  return false
enddef

def DocumentWarning(document: dict<any>, message: string): void
  if document.warning !=# message
    document.warning = message
    Warn(document.path .. ': ' .. message)
  endif
enddef

def Conflict(document: dict<any>): void
  document.blocked = true
  throw 'JSON changed while source positions were pending; use :FlowLoad to reload it'
enddef

def ReplaceLists(document: dict<any>): void
  for record in values(records)
    if record.document.path ==# document.path
      WriteList(record, document)
    endif
  endfor
enddef

def ApplyDocument(document: dict<any>, flow: dict<any>, content: string): void
  ClearTracks(document)
  extend(document, flow)
  document.seen = content
  document.blocked = false
  document.warning = ''
  ReplaceLists(document)
  UpdateTracking()
enddef

def Reload(): void
  final document = session.document
  if document.blocked
    return
  endif
  try
    const content = ReadContent(document.path)
    if content !=# document.seen
      if Pending(document)
        Conflict(document)
      endif
      ApplyDocument(document, ReadFlow(document.path, content), content)
    endif
    document.warning = ''
  catch
    DocumentWarning(document, v:exception)
  endtry
enddef

def CheckWritable(document: dict<any>): void
  if ReadContent(document.path) !=# document.seen
    Conflict(document)
  endif
  for buffer in getbufinfo()
    if buffer.changed && !empty(buffer.name)
        && resolve(fnamemodify(buffer.name, ':p')) ==# document.path
      document.blocked = true
      throw 'JSON buffer has unsaved changes; save or discard them, then use :FlowLoad'
    endif
  endfor
enddef

def SaveDocument(document: dict<any>, buf: number): void
  if document.blocked
    return
  endif
  final updated = deepcopy(document.json)
  updated.steps = []
  final deleted: dict<bool> = {}
  var changed = false
  for idx in range(len(document.items))
    final entry = document.items[idx]
    final step = deepcopy(document.json.steps[idx])
    if entry.bufnr == buf
        && resolve(fnamemodify(bufname(buf), ':p')) ==# resolve(simplify(document.root .. '/' .. step.file))
      if get(get(document.tracks, step.id, {}), 'deleted', false)
        deleted[step.id] = true
        changed = true
        continue
      endif
      if step.line != entry.lnum
        changed = true
        step.line = entry.lnum
      endif
    endif
    add(updated.steps, step)
  endfor
  if !changed
    return
  endif
  CheckWritable(document)
  const content = json_encode(updated)
  const temporary = document.path .. '.' .. fnamemodify(tempname(), ':t')
  try
    if writefile([content], temporary) != 0
      throw 'Could not write updated JSON'
    endif
    if setfperm(temporary, getfperm(document.path)) == 0
      throw 'Could not preserve JSON file permissions'
    endif
    CheckWritable(document)
    if rename(temporary, document.path) != 0
      throw 'Could not replace updated JSON'
    endif
  finally
    if filereadable(temporary)
      delete(temporary)
    endif
  endtry
  document.json = updated
  document.seen = content .. "\n"
  document.warning = ''
  if !empty(deleted)
    for id in keys(deleted)
      final track = remove(document.tracks, id)
      RemoveMarker(buf, track.origin)
      RemoveMarker(buf, track.site)
    endfor
    filter(document.items, (_, entry) => !has_key(deleted, entry.user_data.id))
    for idx in range(len(document.items))
      final entry = document.items[idx]
      entry.user_data.order = idx + 1
      entry.text = $'{idx + 1}. ' .. StepTitle(document, entry)
    endfor
    ReplaceLists(document)
  endif
enddef

export def Saved(buf: number): void
  if refreshing
    return
  endif
  refreshing = true
  try
    PruneRecords()
    UpdateTracking()
    for document in values(documents)
      try
        SaveDocument(document, buf)
      catch
        DocumentWarning(document, v:exception)
      endtry
    endfor
  catch
    WarnOnce(v:exception)
  finally
    refreshing = false
  endtry
enddef

export def Refresh(): void
  if refreshing
    return
  endif
  refreshing = true
  try
    if !SyncFlow()
      return
    endif
    if poll_pending
      poll_pending = false
      Reload()
    endif
    ShowNotes()
  catch
    WarnOnce(v:exception)
  finally
    refreshing = false
  endtry
enddef

def Poll(timer: number): void
  if timer == watch_timer && !empty(session)
    poll_pending = true
  endif
enddef

export def Load(path: string): void
  refreshing = true
  try
    PruneRecords()
    const json_path = resolve(fnamemodify(path, ':p'))
    const content = ReadContent(json_path)
    if !has_key(documents, json_path)
      documents[json_path] = extend(ReadFlow(json_path, content), {
        path: json_path, seen: content, tracks: {}, blocked: false, warning: '', dirty: false,
      })
    elseif documents[json_path].blocked || documents[json_path].seen !=# content
      ApplyDocument(documents[json_path], ReadFlow(json_path, content), content)
    endif
    UpdateTracking()
    final flow = documents[json_path]
    if setqflist([], ' ', {
        title: flow.title, items: deepcopy(flow.items), nr: '$',
        context: {codeflow: true, metadata: flow.metadata},
      }) != 0
      throw 'FlowLoad: could not create the quickfix list'
    endif
    const listid = getqflist({id: 0}).id
    Pause()
    session = {listid: listid, document: flow}
    records[string(listid)] = session
    if !empty(flow.items)
      try
        silent cfirst
      catch
        Warn('Flow loaded; could not jump: ' .. v:exception)
      endtry
    endif
    copen
  catch
    Warn(v:exception)
  finally
    refreshing = false
  endtry
  Refresh()
enddef

defcompile

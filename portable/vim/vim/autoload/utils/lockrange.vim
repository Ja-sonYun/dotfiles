vim9script

export class LockRangeContext
  var id: string
  var manager: any

  def new(this.id, this.manager)
  enddef

  def Replace(lines: list<string>): void
    this.manager.ReplaceRange(this.id, lines)
  enddef

  def Unlock(): void
    this.manager.UnlockRange(this.id)
  enddef

  def SetStatus(text: string): void
    this.manager.SetStatus(this.id, text)
  enddef

  def Range(): list<number>
    return this.manager.GetRange(this.id)
  enddef

  def Lines(): list<string>
    return this.manager.GetLines(this.id)
  enddef
endclass

class LockRangeManager
  var ranges: dict<dict<any>> = {}
  var suppress: bool = false
  var last_linecount: number = 0
  var last_cursor: list<number> = []

  def new()
  enddef

  def EnsureHighlight(): void
    if hlexists('GptLockRange') == 0
      execute 'highlight default GptLockRange ctermbg=238 guibg=#3a3a3a'
    endif
  enddef

  def EnsureStatusHighlight(): void
    if hlexists('GptLockRangeStatus') == 0
      execute 'highlight default GptLockRangeStatus ctermfg=245 guifg=#8a8a8a'
    endif
  enddef

  def EnsureStatusType(buf: number): void
    this.EnsureStatusHighlight()
    if empty(prop_type_get('GptLockRangeStatus', {'bufnr': buf}))
      prop_type_add('GptLockRangeStatus', {
        bufnr: buf,
        highlight: 'GptLockRangeStatus',
        priority: 90,
      })
    endif
  enddef

  def ClearStatusType(buf: number): void
    if empty(prop_type_get('GptLockRangeStatus', {'bufnr': buf}))
      return
    endif
    prop_type_delete('GptLockRangeStatus', { bufnr: buf })
  enddef

  def StatusText(status: string): string
    if status ==# ''
      return '  [locked]'
    endif
    return '  [locked] ' .. status
  enddef

  def ClearStatusAll(buf: number): void
    prop_remove({
      bufnr: buf,
      type: 'GptLockRangeStatus',
      all: v:true,
    })
  enddef

  def ClearStatusAt(buf: number, lnum: number): void
    if lnum <= 0
      return
    endif
    prop_remove({
      bufnr: buf,
      type: 'GptLockRangeStatus',
      lnum: lnum,
      end_lnum: lnum,
      all: v:true,
    })
  enddef

  def UpdateStatusForLock(id: string): void
    if !has_key(this.ranges, id)
      return
    endif
    var info = this.ranges[id]
    var start = get(info, 'start', 0)
    var end = get(info, 'end', 0)
    if end < start
      var tmp = start
      start = end
      end = tmp
    endif
    var old_lnum = get(info, 'status_lnum', 0)
    var status = get(info, 'status', '')
    var buf = bufnr('%')
    if old_lnum > 0 && old_lnum != start
      this.ClearStatusAt(buf, old_lnum)
      info['status_lnum'] = 0
    endif
    if start > 0
      this.EnsureStatusType(buf)
      this.ClearStatusAt(buf, start)
      prop_add(start, 0, {
        bufnr: buf,
        type: 'GptLockRangeStatus',
        text: this.StatusText(status),
      })
      info['status_lnum'] = start
    endif
    this.ranges[id] = info
  enddef

  def UpdateAllStatuses(): void
    for lock_id in keys(this.ranges)
      this.UpdateStatusForLock(lock_id)
    endfor
  enddef


  def BuildLockPositions(start: number, end: number): list<list<number>>
    var positions: list<list<number>> = []
    for lnum in range(start, end)
      add(positions, [lnum])
    endfor
    return positions
  enddef

  def NewLockId(): string
    return sha256(reltimestr(reltime()) .. string(rand()))
  enddef

  def UpdateHighlight(start: number, end: number, match_id: number): number
    if match_id != 0
      matchdelete(match_id)
    endif
    if start <= 0 || end < start
      return 0
    endif
    return matchaddpos('GptLockRange', this.BuildLockPositions(start, end))
  enddef

  def LastChangeLnum(): number
    const changes = getchangelist(bufnr('%'))
    if len(changes) == 0
      return 0
    endif
    const list = changes[0]
    if empty(list)
      return 0
    endif
    const last = list[-1]
    return get(last, 'lnum', 0)
  enddef

  def HasOverlap(start: number, end: number): bool
    for info in values(this.ranges)
      var range_start = get(info, 'start', 0)
      var range_end = get(info, 'end', 0)
      if range_start <= 0 || range_end <= 0
        continue
      endif
      if range_end < range_start
        var tmp = range_start
        range_start = range_end
        range_end = tmp
      endif
      if start <= range_end && end >= range_start
        return true
      endif
    endfor
    return false
  enddef

  def RegisterAutocmd(): void
    augroup GptSoftLock
      autocmd! * <buffer>
      autocmd InsertCharPre <buffer> Manager().HandleInsertCharPre()
      autocmd TextChanged,TextChangedI <buffer> Manager().SoftLockCheck()
    augroup END
  enddef

  def ClearAutocmd(): void
    augroup GptSoftLock
      autocmd! * <buffer>
    augroup END
  enddef

  def Cleanup(): void
    this.ranges = {}
    this.suppress = false
    this.last_linecount = 0
    this.last_cursor = []
    var buf = bufnr('%')
    this.ClearStatusAll(buf)
    this.ClearStatusType(buf)
    this.ClearAutocmd()
  enddef

  def HandleInsertCharPre(): void
    if empty(this.ranges)
      return
    endif
    const pos = getpos('.')
    const lnum = pos[1]
    for info in values(this.ranges)
      var range_start = get(info, 'start', 0)
      var range_end = get(info, 'end', 0)
      if range_start <= 0 || range_end <= 0
        continue
      endif
      if range_end < range_start
        var tmp = range_start
        range_start = range_end
        range_end = tmp
      endif
      if lnum >= range_start && lnum <= range_end
        this.last_cursor = pos
        v:char = ''
        return
      endif
    endfor
  enddef

  def SoftLockCheck(): void
    if this.suppress
      return
    endif
    if empty(this.ranges)
      this.ClearStatusAll(bufnr('%'))
      return
    endif
    const change_lnum = this.LastChangeLnum()
    const current_linecount = line('$')
    const last_linecount = this.last_linecount == 0 ? current_linecount : this.last_linecount
    const delta = current_linecount - last_linecount
    var restored = false
    var lock_changed = false
    var next_ranges: dict<dict<any>> = {}
    for [lock_id, info] in items(this.ranges)
      var start = get(info, 'start', 0)
      var end = get(info, 'end', 0)
      if start <= 0 || end <= 0
        next_ranges[lock_id] = info
        continue
      endif
      if end < start
        var tmp = start
        start = end
        end = tmp
      endif
      if delta != 0 && change_lnum > 0 && change_lnum < start
        start += delta
        end += delta
      endif
      if start <= 0 || end < start || start > current_linecount
        lock_changed = true
        break
      endif
      var read_end = end
      if read_end > current_linecount
        read_end = current_linecount
      endif
      const original = get(info, 'lines', [])
      const current = getline(start, read_end)
      if current !=# original || len(current) != len(original)
        lock_changed = true
        break
      endif
      info['start'] = start
      info['end'] = end
      info['match_id'] = this.UpdateHighlight(start, end, get(info, 'match_id', 0))
      next_ranges[lock_id] = info
    endfor
    if lock_changed
      if empty(this.last_cursor)
        this.last_cursor = getpos('.')
      endif
      this.suppress = true
      silent! undo
      this.suppress = false
      restored = true
    else
      for [lock_id, info] in items(next_ranges)
        this.ranges[lock_id] = info
      endfor
    endif
    this.UpdateAllStatuses()
    this.last_linecount = line('$')
    if restored
      if !empty(this.last_cursor)
        setpos('.', this.last_cursor)
        this.last_cursor = []
      endif
      echohl WarningMsg
      echom 'Locked range cannot be modified.'
      echohl None
    endif
  enddef

  def LockRange(start: number, end: number): any
    if start <= 0 || end <= 0
      return v:none
    endif
    var s = start
    var e = end
    if e < s
      var tmp = s
      s = e
      e = tmp
    endif
    this.EnsureHighlight()
    if this.HasOverlap(s, e)
      echohl ErrorMsg
      echom 'Relock is not possible.'
      echohl None
      return v:none
    endif
    const lock_id = this.NewLockId()
    const lines = getline(s, e)
    const match_id = this.UpdateHighlight(s, e, 0)
    this.ranges[lock_id] = {
      start: s,
      end: e,
      lines: lines,
      match_id: match_id,
      status: '',
      status_lnum: 0,
    }
    this.suppress = false
    this.last_linecount = line('$')
    this.RegisterAutocmd()
    this.UpdateStatusForLock(lock_id)
    return LockRangeContext.new(lock_id, this)
  enddef

  def UnlockRange(id: string): void
    if empty(this.ranges) || !has_key(this.ranges, id)
      return
    endif
    var info = this.ranges[id]
    var buf = bufnr('%')
    this.ClearStatusAt(buf, get(info, 'status_lnum', 0))
    const match_id = get(info, 'match_id', 0)
    if match_id != 0
      matchdelete(match_id)
    endif
    remove(this.ranges, id)
    if empty(this.ranges)
      this.Cleanup()
      return
    endif
    this.ClearStatusType(buf)
    this.last_linecount = line('$')
  enddef

  def UnlockAll(): void
    if empty(this.ranges)
      return
    endif
    for info in values(this.ranges)
      const match_id = get(info, 'match_id', 0)
      if match_id != 0
        matchdelete(match_id)
      endif
    endfor
    this.Cleanup()
  enddef

  def GetRange(id: string): list<number>
    if has_key(this.ranges, id)
      const info = this.ranges[id]
      return [get(info, 'start', 0), get(info, 'end', 0)]
    endif
    return [0, 0]
  enddef

  def GetLines(id: string): list<string>
    if has_key(this.ranges, id)
      const info = this.ranges[id]
      return get(info, 'lines', [])
    endif
    return []
  enddef

  def ReplaceRange(id: string, lines: list<string>): void
    if empty(this.ranges) || !has_key(this.ranges, id)
      return
    endif
    var info = this.ranges[id]
    const start = get(info, 'start', 0)
    const end = get(info, 'end', 0)
    if start <= 0 || end < start
      return
    endif
    const old_end = end
    this.suppress = true
    deletebufline('%', start, end)
    if len(lines) > 0
      append(start - 1, lines)
    endif
    this.suppress = false
    const new_end = start + len(lines) - 1
    const delta = new_end - old_end
    info['end'] = new_end
    info['lines'] = lines
    info['match_id'] = this.UpdateHighlight(start, new_end, get(info, 'match_id', 0))
    this.ranges[id] = info
    if delta != 0
      for [other_id, other] in items(this.ranges)
        if other_id ==# id
          continue
        endif
        var other_start = get(other, 'start', 0)
        var other_end = get(other, 'end', 0)
        if other_start > old_end
          other['start'] = other_start + delta
          other['end'] = other_end + delta
          other['match_id'] = this.UpdateHighlight(other['start'], other['end'], get(other, 'match_id', 0))
          this.ranges[other_id] = other
        endif
      endfor
    endif
    this.UpdateAllStatuses()
    this.last_linecount = line('$')
  enddef

  def SetStatus(id: string, text: string): void
    if empty(this.ranges) || !has_key(this.ranges, id)
      return
    endif
    var info = this.ranges[id]
    info['status'] = text
    this.ranges[id] = info
    this.UpdateStatusForLock(id)
  enddef
endclass

def Manager(): LockRangeManager
  if !exists('b:gpt_lock_manager')
    b:gpt_lock_manager = LockRangeManager.new()
  endif
  return b:gpt_lock_manager
enddef

export def LockRange(start: number, end: number): any
  return Manager().LockRange(start, end)
enddef

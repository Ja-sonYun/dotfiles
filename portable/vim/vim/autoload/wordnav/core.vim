vim9script

import autoload 'utils/dict.vim' as d

const DEFAULT_CONFIG = {
  map: true,
  mappings: {
    next_end: {keys: 'E', modes: ['n', 'x', 'o']},
    next_start: {keys: 'W', modes: ['n', 'x', 'o']},
    prev_start: {keys: 'B', modes: ['n', 'x', 'o']},
    next_uscore: {keys: 'gE', modes: ['n', 'x', 'o']},
    op_till_uscore: {keys: 'E', modes: ['o']},
  },
}

var Config = deepcopy(DEFAULT_CONFIG)

def SetupMappings()
  var m = Config.mappings

  var ekey = get(m.next_end, 'keys')
  execute 'nnoremap <silent> ' .. ekey .. ' <ScriptCmd>NextSubwordEnd(v:count1, false)<CR>'
  execute 'xnoremap <silent> ' .. ekey .. ' <ScriptCmd>NextSubwordEnd(v:count1, true)<CR>'
  execute 'onoremap <silent> ' .. ekey .. ' <ScriptCmd>NextSubwordEnd(v:count1, true)<CR>'

  var wkey = get(m.next_start, 'keys')
  execute 'nnoremap <silent> ' .. wkey .. ' <ScriptCmd>NextSubwordStart(v:count1, false)<CR>'
  execute 'xnoremap <silent> ' .. wkey .. ' <ScriptCmd>NextSubwordStart(v:count1, true)<CR>'
  execute 'onoremap <silent> ' .. wkey .. ' <ScriptCmd>NextSubwordStart(v:count1, true)<CR>'

  var bkey = get(m.prev_start, 'keys')
  execute 'nnoremap <silent> ' .. bkey .. ' <ScriptCmd>PrevSubwordStart(v:count1, false)<CR>'
  execute 'xnoremap <silent> ' .. bkey .. ' <ScriptCmd>PrevSubwordStart(v:count1, true)<CR>'
  execute 'onoremap <silent> ' .. bkey .. ' <ScriptCmd>PrevSubwordStart(v:count1, true)<CR>'

  var gkey = get(m.next_uscore, 'keys')
  execute 'nnoremap <silent> ' .. gkey .. ' <ScriptCmd>NextUnderscoreInIdentifier(v:count1, false)<CR>'
  execute 'xnoremap <silent> ' .. gkey .. ' <ScriptCmd>NextUnderscoreInIdentifier(v:count1, true)<CR>'
  execute 'onoremap <silent> ' .. gkey .. ' <ScriptCmd>NextUnderscoreInIdentifier(v:count1, true)<CR>'

  var okey = get(m.op_till_uscore, 'keys')
  execute 'onoremap <silent> ' .. okey .. ' <ScriptCmd>NextUnderscoreInIdentifier(1, true)<CR>'
enddef

def GetLine0(row0: number): string
  return get(getline(row0 + 1, row0 + 1), 0, '')
enddef

def Ch(s: string, idx0: number): string
  return idx0 < 0 || idx0 >= strlen(s) ? '' : strpart(s, idx0, 1)
enddef

def Classify(line: string, idx0: number): string
  if idx0 < 0 | return 'bos' | endif
  var len = strlen(line)
  if idx0 >= len | return 'eol' | endif
  var c = Ch(line, idx0)
  if c ==# '_' | return 'underscore' | endif
  if c =~# '\s' | return 'ws' | endif
  if c =~# '\d' | return 'digit' | endif
  if c =~# '\l' | return 'lower' | endif
  if c =~# '\u' | return 'upper' | endif
  return 'other'
enddef

def IsWord(tp: string): bool
  return tp ==# 'lower' || tp ==# 'upper' || tp ==# 'digit'
enddef

def IsIdentChar(tp: string): bool
  return tp ==# 'underscore' || IsWord(tp)
enddef

def TrimNonWordBackward(row0: number, col0: number, stop_row0: number, stop_col0: number): list<number>
  var r = row0
  var c = col0
  while r > stop_row0 || (r == stop_row0 && c >= stop_col0)
    var tp = Classify(GetLine0(r), c)
    if IsWord(tp) || tp ==# 'underscore'
      return [r, c]
    endif
    if r == stop_row0 && c == stop_col0
      break
    endif
    c -= 1
    if c < 0
      r -= 1
      if r < stop_row0
        break
      endif
      c = strlen(GetLine0(r)) - 1
      if c < 0
        c = 0
      endif
    endif
  endwhile
  return [stop_row0, stop_col0]
enddef

def SetMotion(start_row0: number, start_col0: number, dest_row0: number, dest_col0: number, trim_delim: bool): void
  var start = [0, start_row0 + 1, start_col0 + 1, 0]
  var dest = [0, dest_row0 + 1, dest_col0 + 1, 0]
  var endmark = dest
  if trim_delim
    var trimmed = TrimNonWordBackward(dest_row0, dest_col0, start_row0, start_col0)
    if trimmed[0] < start_row0 || (trimmed[0] == start_row0 && trimmed[1] < start_col0)
      trimmed = [start_row0, start_col0]
    endif
    endmark = [0, trimmed[0] + 1, trimmed[1] + 1, 0]
  endif
  setpos("'[", start)
  setpos("']", endmark)
  setpos('.', dest)
enddef

def IsStart(line: string, idx0: number): bool
  var cur = Classify(line, idx0)
  if !IsWord(cur) | return false | endif
  var prev = Classify(line, idx0 - 1)
  if prev ==# 'bos' || prev ==# 'ws' || prev ==# 'underscore' || prev ==# 'other' | return true | endif
  if !IsWord(prev) | return true | endif
  if prev ==# 'lower' && cur ==# 'upper' | return true | endif
  if prev ==# 'digit' && cur !=# 'digit' | return true | endif
  if prev !=# 'digit' && cur ==# 'digit' | return true | endif
  if prev ==# 'upper' && cur ==# 'upper'
    var nxt = Classify(line, idx0 + 1)
    if nxt ==# 'lower' || nxt ==# 'digit' | return true | endif
  endif
  return false
enddef

def IsEnd(line: string, idx0: number): bool
  var cur = Classify(line, idx0)
  if !IsWord(cur) | return false | endif
  var nxt = Classify(line, idx0 + 1)
  if nxt ==# 'eol' || nxt ==# 'ws' || nxt ==# 'underscore' || nxt ==# 'other' | return true | endif
  if !IsWord(nxt) | return true | endif
  if cur ==# 'lower' && nxt ==# 'upper' | return true | endif
  if cur ==# 'digit' && nxt !=# 'digit' | return true | endif
  if cur !=# 'digit' && nxt ==# 'digit' | return true | endif
  if cur ==# 'upper' && nxt ==# 'upper'
    var foll = Classify(line, idx0 + 2)
    if foll ==# 'lower' || foll ==# 'digit' | return true | endif
  endif
  return false
enddef

def SkipDelims(total: number, row0: number, col0: number): list<any>
  var r = row0
  var c = col0
  while r < total
    var line = GetLine0(r)
    var len = strlen(line)
    while c < len
      if IsWord(Classify(line, c)) | return [r, c, line, len] | endif
      c += 1
    endwhile
    r += 1
    c = 0
  endwhile
  return []
enddef

def FindNextEnd(total: number, row0: number, col0: number, skip_current: bool): list<any>
  var r = row0
  var c = col0
  var skip = skip_current
  while r < total
    var line = GetLine0(r)
    var len = strlen(line)
    if len == 0 || c >= len
      r += 1
      c = 0
      skip = false
      continue
    endif
    if !IsWord(Classify(line, c))
      var s = SkipDelims(total, r, c)
      if empty(s) | return [] | endif
      r = s[0]
      c = s[1]
      line = s[2]
      len = s[3]
      skip = false
    endif
    var i = c
    while i < len
      if IsEnd(line, i)
        if skip && r == row0 && i == col0
          skip = false
        else
          return [r, i]
        endif
      endif
      i += 1
    endwhile
    r += 1
    c = 0
    skip = false
  endwhile
  return []
enddef

def NextSubwordEndImpl(count: number, trim_delim: bool): void
  var total = line('$')
  var p = getcurpos()
  var row0 = p[1] - 1
  var col0 = p[2] > 0 ? p[2] - 1 : 0
  var start_row = row0
  var start_col = col0
  var n = count
  var fr = row0
  var fc = col0
  var in_end = row0 >= 0 && row0 < total && IsEnd(GetLine0(row0), col0)
  while n > 0
    var res = FindNextEnd(total, row0, col0, in_end)
    if empty(res)
      var last = max([total - 1, 0])
      var ll = GetLine0(last)
      fr = last
      fc = strlen(ll) > 0 ? strlen(ll) - 1 : 0
      break
    endif
    fr = res[0]
    fc = res[1]
    n -= 1
    row0 = res[0]
    col0 = res[1] + 1
    in_end = false
  endwhile
  if trim_delim
    var line_after = GetLine0(fr)
    var len_after = strlen(line_after)
    var idx = fc + 1
    while idx < len_after && Classify(line_after, idx) ==# 'underscore'
      fc = idx
      idx += 1
    endwhile
  endif
  SetMotion(start_row, start_col, fr, fc, trim_delim)
enddef

def NextSubwordStartImpl(count: number, trim_delim: bool): void
  var total = line('$')
  var p = getcurpos()
  var row0 = p[1] - 1
  var col0 = p[2] > 0 ? p[2] - 1 : 0
  var n = count
  var fr = row0
  var fc = col0
  while n > 0
    col0 += 1
    var found = false
    while row0 < total
      const text = GetLine0(row0)
      while col0 < strlen(text)
        if IsStart(text, col0)
          found = true
          break
        endif
        col0 += 1
      endwhile
      if found
        break
      endif
      row0 += 1
      col0 = 0
    endwhile
    if !found
      break
    endif
    fr = row0
    fc = col0
    n -= 1
  endwhile
  if trim_delim
    var scan_line = GetLine0(fr)
    while fc > 0 && Classify(scan_line, fc - 1) ==# 'underscore'
      fc -= 1
    endwhile
  endif
  SetMotion(p[1] - 1, p[2] > 0 ? p[2] - 1 : 0, fr, fc, trim_delim)
enddef

def FindPrevStart(row0: number, col0: number): list<number>
  var r = row0
  var c = col0
  while r >= 0
    var line = GetLine0(r)
    var len = strlen(line)
    if len == 0
      r -= 1
      if r < 0
        break
      endif
      c = strlen(GetLine0(r))
      continue
    endif
    if c > len
      c = len
    endif
    if c <= 0
      r -= 1
      if r < 0
        break
      endif
      c = strlen(GetLine0(r))
      continue
    endif
    for idx in range(c - 1, 0, -1)
      if !IsWord(Classify(line, idx - 1)) && IsWord(Classify(line, idx))
        return [r, idx]
      endif
      if Classify(line, idx - 1) ==# 'lower' && Classify(line, idx) ==# 'upper'
        return [r, idx]
      endif
      if Classify(line, idx - 1) ==# 'upper' && Classify(line, idx) ==# 'upper' && Classify(line, idx + 1) ==# 'lower'
        return [r, idx]
      endif
    endfor
    if IsWord(Classify(line, 0))
      return [r, 0]
    endif
    r -= 1
    if r >= 0
      c = strlen(GetLine0(r))
    endif
  endwhile
  return [0, 0]
enddef

def PrevSubwordStartImpl(count: number, trim_delim: bool): void
  var p = getcurpos()
  var row0 = p[1] - 1
  var col0 = p[2] > 0 ? p[2] - 1 : 0
  var result = [0, 0]
  var n = count
  var cur_row = row0
  var cur_col = col0
  while n > 0
    result = FindPrevStart(cur_row, cur_col)
    cur_row = result[0]
    cur_col = result[1]
    n -= 1
  endwhile
  var start_row = p[1] - 1
  var start_col = max([p[2] - 1, 0])
  var target = result
  if trim_delim
    var trimmed = TrimNonWordBackward(target[0], target[1], target[0], 0)
    target = [trimmed[0], trimmed[1]]
  endif
  SetMotion(start_row, start_col, target[0], target[1], trim_delim)
enddef

def NextUnderscoreImpl(count: number, trim_delim: bool): void
  var n = count
  var total = line('$')
  var p = getcurpos()
  var row0 = p[1] - 1
  var col0 = p[2] > 0 ? p[2] - 1 : 0
  var line = GetLine0(row0)
  var len = strlen(line)
  if !IsIdentChar(Classify(line, col0))
    var s = SkipDelims(total, row0, col0)
    if empty(s) | return | endif
    row0 = s[0]
    col0 = s[1]
    line = s[2]
    len = s[3]
  endif
  var left = col0
  while left > 0 && IsIdentChar(Classify(line, left - 1)) | left -= 1 | endwhile
  var right = col0
  while right < len && IsIdentChar(Classify(line, right)) | right += 1 | endwhile
  var target = col0
  while n > 0
    var f = match(line, '_', target + 1)
    if f < 0 || f >= right
      target = max([right - 1, left])
      break
    endif
    target = f
    n -= 1
  endwhile
  SetMotion(p[1] - 1, max([p[2] - 1, 0]), row0, target, trim_delim)
enddef

export def NextSubwordEnd(count: number = 1, trim: bool = false): void
  NextSubwordEndImpl(count, trim)
enddef

export def NextSubwordStart(count: number = 1, trim: bool = false): void
  NextSubwordStartImpl(count, trim)
enddef

export def PrevSubwordStart(count: number = 1, trim: bool = false): void
  PrevSubwordStartImpl(count, trim)
enddef

export def NextUnderscoreInIdentifier(count: number = 1, trim: bool = false): void
  NextUnderscoreImpl(count, trim)
enddef

export def Setup(cfg: dict<any> = {}): void
  Config = d.DeepMerge(deepcopy(Config), cfg)
  SetupMappings()
enddef

defcompile

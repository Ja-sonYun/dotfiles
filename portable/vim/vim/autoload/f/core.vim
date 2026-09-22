vim9script

g:last_pat = ''
g:last_dir = 1

def DrainCharNonBlocking(): string
  var t = getchar(0)
  if t == 0
    return ''
  endif
  if type(t) == v:t_number
    return nr2char(t)
  endif
  return string(t)
enddef

def IsAsciiAlnum(ch: string): bool
  if ch ==# ''
    return false
  endif
  if char2nr(ch) > 127
    return false
  endif
  return ch =~# '^[A-Za-z0-9]$'
enddef

def DoMove(forward: bool): void
  var pat = g:last_pat
  var lnum = line('.')
  var pos = col('.')
  var found: bool = false
  var idx: number = -1

  if forward
    while lnum <= line('$')
      var txt = getline(lnum)
      var start = (lnum == line('.')) ? pos : 0
      if start < 0
        start = 0
      endif
      idx = stridx(txt, pat, start)
      if idx >= 0
        found = true
        break
      endif
      lnum += 1
    endwhile
  else
    while lnum >= 1
      var txt = getline(lnum)
      var stopcol = (lnum == line('.')) ? pos - 2 : strlen(txt) - 1
      if stopcol < 0
        lnum -= 1
        continue
      endif
      var slice = (stopcol >= 0) ? txt[0 : stopcol] : ''
      idx = strridx(slice, pat)
      if idx >= 0
        found = true
        break
      endif
      lnum -= 1
    endwhile
  endif

  if !found
    echom 'not found: ' .. pat
    return
  endif

  cursor(lnum, idx + 1)
enddef

def BuildPattern(initial: string): string
  if IsAsciiAlnum(initial)
    var c2 = nr2char(getchar())
    if c2 ==# "\<Esc>"
      return ''
    endif
    return initial .. c2
  endif
  return initial
enddef

def StartMove(forward: bool): void
  var c = nr2char(getchar())
  if c ==# "\<Esc>"
    return
  endif
  var pat = BuildPattern(c)
  if pat ==# ''
    return
  endif
  g:last_pat = pat
  g:last_dir = forward ? 1 : -1
  DoMove(forward)
enddef

def RepeatMove(reverse: bool): void
  if g:last_pat ==# ''
    echom 'no previous f/F search'
    return
  endif
  var dir = reverse ? -g:last_dir : g:last_dir
  DoMove(dir == 1)
enddef

export def Setup(): void
  nnoremap <silent> f <ScriptCmd>StartMove(1)<CR>
  nnoremap <silent> F <ScriptCmd>StartMove(0)<CR>
  nnoremap <silent> ; <ScriptCmd>RepeatMove(0)<CR>
  nnoremap <silent> <leader>, <ScriptCmd>RepeatMove(1)<CR>

  xnoremap <silent> f <ScriptCmd>StartMove(1)<CR>
  xnoremap <silent> F <ScriptCmd>StartMove(0)<CR>
  xnoremap <silent> ; <ScriptCmd>RepeatMove(0)<CR>
  xnoremap <silent> <leader>, <ScriptCmd>RepeatMove(1)<CR>
enddef

defcompile

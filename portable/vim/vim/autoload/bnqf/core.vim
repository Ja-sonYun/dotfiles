vim9script

const COLUMN_SEP = ' | '
const CODE_TRUNC_COL = 120
const PROP_TYPES: list<dict<string>> = [
  {name: 'bnqf_dir', highlight: 'Directory'},
  {name: 'bnqf_lnum', highlight: 'LineNr'},
  {name: 'bnqf_code', highlight: 'NormalNC'},
  {name: 'bnqf_msg', highlight: 'DiagnosticWarn'},
]

def PadRight(text: string, width: number): string
  var pad = width - strdisplaywidth(text)
  return pad > 0 ? text .. repeat(' ', pad) : text
enddef

def Truncate(text: string, maxlen: number): string
  return strchars(text) <= maxlen ? text : strcharpart(text, 0, maxlen)
enddef

def NormalizeWhitespace(text: string): string
  var s = substitute(text, '\s\+', ' ', 'g')
  return trim(s)
enddef

def ReadBufferLine(bufnr: number, lnum: number): string
  if bufnr > 0 && bufloaded(bufnr)
    try
      return get(getbufline(bufnr, lnum, lnum), 0, '')
    catch
    endtry
  endif
  const path = bufname(bufnr)
  if path !=# '' && filereadable(path)
    try
      const lines = readfile(path, '', lnum)
      return get(lines, lnum - 1, '')
    catch
    endtry
  endif
  return ''
enddef

def CollectItems(info: dict<any>): list<dict<any>>
  const query = {id: info.id, items: 1}
  if get(info, 'quickfix', 0) == 1
    return getqflist(query).items
  endif
  return getloclist(info.winid, query).items
enddef

def BuildRows(info: dict<any>): list<dict<any>>
  var rows: list<dict<any>> = []
  const items = CollectItems(info)
  for idx in range(info.start_idx, info.end_idx)
    const it = get(items, idx - 1, null_dict)
    if type(it) != v:t_dict
      break
    endif

    const bufn  = <number>get(it, 'bufnr', 0)
    const file  = fnamemodify(bufname(bufn), ':~:.')
    const lnum  = <number>get(it, 'lnum', 0)
    const col   = <number>get(it, 'col', 0)
    const ecol  = <number>get(it, 'end_col', 0)
    const pos   = ecol > 0 ? printf('%d:%d-%d', lnum, col, ecol) : printf('%d:%d', lnum, col)

    const raw_code = substitute(ReadBufferLine(bufn, lnum), '\t', '  ', 'g')
    const code     = Truncate(raw_code, CODE_TRUNC_COL)
    const normcode = NormalizeWhitespace(code)

    const message  = NormalizeWhitespace(<string>get(it, 'text', ''))
    const show_msg = message !=# '' && message !=# normcode

    add(rows, {
      file: file,
      pos: pos,
      code: code,
      msg: show_msg ? message : '',
    })
  endfor
  return rows
enddef

def ComputeColumnWidths(rows: list<dict<any>>): dict<number>
  var w = {file: 0, pos: 0}
  for r in rows
    w.file = max([w.file, strdisplaywidth(r.file)])
    w.pos  = max([w.pos,  strdisplaywidth(r.pos)])
  endfor
  return w
enddef

def RenderLine(row: dict<any>, widths: dict<number>): string
  const file = PadRight(row.file, widths.file)
  const pos  = PadRight(row.pos,  widths.pos)
  var segs: list<string> = [file, pos, ' ' .. row.code]
  if row.msg !=# ''
    add(segs, ' ' .. row.msg)
  endif
  return join(segs, COLUMN_SEP)
enddef

export def Text(info: dict<any>): list<string>
  const rows = BuildRows(info)
  if empty(rows)
    return []
  endif
  const widths = ComputeColumnWidths(rows)
  var out: list<string> = []
  for r in rows
    add(out, RenderLine(r, widths))
  endfor
  return out
enddef

def EnsurePropTypes(): void
  for defn in PROP_TYPES
    try
      prop_type_add(defn.name, {highlight: defn.highlight, priority: 100})
    catch
    endtry
  endfor
enddef

def ClearPropsCurrent(): void
  try
    prop_clear(1, line('$'), {})
  catch
  endtry
enddef

def ColumnRanges(line: string): list<list<number>>
  var ranges: list<list<number>> = []
  const parts = split(line, COLUMN_SEP, 1)
  var start = 0
  for part in parts
    const finish = start + strlen(part)
    add(ranges, [start, finish])
    start = finish + strlen(COLUMN_SEP)
  endfor
  return ranges
enddef

def HighlightSegment(row: number, start: number, finish: number, type: string): void
  if finish <= start
    return
  endif
  prop_add(row + 1, start + 1, {type: type, length: finish - start})
enddef

export def ApplyHlCurrent(): void
  if &filetype !=# 'qf'
    return
  endif
  EnsurePropTypes()
  ClearPropsCurrent()

  const lines = getline(1, '$')
  for i in range(0, len(lines) - 1)
    const rs = ColumnRanges(lines[i])
    const n = len(rs)
    if n >= 3
      HighlightSegment(i, rs[0][0], rs[0][1], 'bnqf_dir')
      HighlightSegment(i, rs[1][0], rs[1][1], 'bnqf_lnum')
      HighlightSegment(i, rs[2][0], rs[2][1], 'bnqf_code')
      if n >= 4
        HighlightSegment(i, rs[3][0], rs[3][1], 'bnqf_msg')
      endif
    endif
  endfor
enddef

def SetWinoptsForBuf(buf: number): void
  for winid in win_findbuf(buf)
    const wn = win_id2win(winid)
    if wn > 0
      setwinvar(wn, '&wrap', false)
      setwinvar(wn, '&number', false)
      setwinvar(wn, '&relativenumber', false)
      setwinvar(wn, '&signcolumn', 'no')
      setwinvar(wn, '&foldcolumn', '0')
    endif
  endfor
enddef

export def RefreshAllQfWindows(): void
  for id in range(1, winnr('$'))
    const buf = winbufnr(id)
    if getbufvar(buf, '&filetype', '') ==# 'qf'
      SetWinoptsForBuf(buf)
      win_execute(win_getid(id), 'call bnqf#core#ApplyHlCurrent()')
    endif
  endfor
enddef

export def History(): void
  const total = getqflist({nr: '$'}).nr
  if total == 0
    echo 'No quickfix history'
    return
  endif

  const current = getqflist({nr: 0}).nr
  var entries: list<string> = ['Quickfix history (0 to cancel):']
  for nr in range(1, total)
    const info = getqflist({
      nr: nr,
      title: 1,
      size: 1,
    })
    add(entries, printf('%s %d: %s (%d items)',
      nr == current ? '>' : ' ', nr, info.title, info.size))
  endfor

  const selected = inputlist(entries)
  if selected < 1 || selected > total
    return
  endif

  const offset = selected - current
  if offset < 0
    execute 'colder ' .. -offset
  elseif offset > 0
    execute 'cnewer ' .. offset
  endif
  copen
enddef

export def Setup(): void
  &quickfixtextfunc = 'bnqf#core#Text'

  augroup BnQfInit
    autocmd!
    autocmd FileType qf setlocal nomodifiable noswapfile
    autocmd FileType qf SetWinoptsForBuf(bufnr())
    autocmd FileType qf ApplyHlCurrent()
    autocmd QuickFixCmdPost * RefreshAllQfWindows()
    autocmd BufWinEnter * if &filetype ==# 'qf' | ApplyHlCurrent() | endif
  augroup END
enddef

defcompile

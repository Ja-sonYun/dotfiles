vim9script

var configured = false
var reflowing = false
var pending_timer = -1

def Spec(options: dict<any>): dict<any>
  const edge = get(options, 'edge', '')
  const size = get(options, 'size', 0)
  const min_width = edge ==# 'bottom' ? get(options, 'min_width', 40) : 0
  if index(['left', 'right', 'bottom'], edge) < 0
    throw 'dock: edge must be left, right, or bottom'
  endif
  if type(size) != v:t_number || size <= 0
    throw 'dock: size must be a positive number'
  endif
  if edge ==# 'bottom' && (type(min_width) != v:t_number || min_width <= 0)
    throw 'dock: min_width must be a positive number'
  endif
  return { edge: edge, size: size, min_width: min_width }
enddef

def DockWindows(): list<dict<any>>
  return getwininfo()->filter((_, info) =>
    info.tabnr == tabpagenr() && !empty(getwinvar(info.winid, 'dock', {})))
enddef

def Move(winid: number, edge: string): void
  if winnr('$') <= 1
    return
  endif
  if edge ==# 'bottom'
    win_execute(winid, 'wincmd J')
  elseif edge ==# 'left'
    win_execute(winid, 'wincmd H')
  else
    win_execute(winid, 'wincmd L')
  endif
enddef

def Resize(winid: number, spec: dict<any>): void
  if spec.edge ==# 'bottom'
    win_execute(winid, $'resize {spec.size} | setlocal winfixheight nowinfixwidth')
  else
    win_execute(winid, $'vertical resize {spec.size} | setlocal winfixwidth nowinfixheight')
  endif
enddef

def OnEdge(windows: list<dict<any>>, edge: string): list<dict<any>>
  return copy(windows)->filter((_, info) =>
    get(getwinvar(info.winid, 'dock', {}), 'edge', '') ==# edge)
enddef

def BottomsFit(bottoms: list<dict<any>>): bool
  if len(bottoms) < 2
    return false
  endif
  var required = len(bottoms) - 1
  for info in bottoms
    required += getwinvar(info.winid, 'dock', {}).min_width
  endfor
  return getwininfo(bottoms[0].winid)[0].width >= required
enddef

def ArrangeBottomRow(bottoms: list<dict<any>>): void
  const available = getwininfo(bottoms[0].winid)[0].width - len(bottoms) + 1
  var min_total = 0
  var height = 0
  for info in bottoms
    const spec = getwinvar(info.winid, 'dock', {})
    min_total += spec.min_width
    height = max([height, spec.size])
  endfor

  var target = bottoms[0].winid
  for info in bottoms[1 :]
    win_splitmove(info.winid, target, { vertical: true, rightbelow: true })
    target = info.winid
  endfor

  const extra = available - min_total
  for i in range(len(bottoms) - 1)
    const spec = getwinvar(bottoms[i].winid, 'dock', {})
    const width = spec.min_width + extra / len(bottoms)
    win_execute(bottoms[i].winid, $'vertical resize {width}')
  endfor
  win_execute(bottoms[0].winid, $'resize {height}')
  for info in bottoms
    win_execute(info.winid, 'setlocal winfixheight nowinfixwidth')
  endfor
enddef

def Reflow(): void
  pending_timer = -1
  if reflowing
    return
  endif
  reflowing = true
  try
    const windows = DockWindows()
    const bottoms = OnEdge(windows, 'bottom')
    const lefts = OnEdge(windows, 'left')
    const rights = OnEdge(windows, 'right')

    for info in windows
      win_execute(info.winid, 'setlocal nowinfixheight nowinfixwidth')
    endfor
    for info in bottoms
      Move(info.winid, 'bottom')
    endfor
    for info in lefts
      Move(info.winid, 'left')
    endfor
    for info in rights
      Move(info.winid, 'right')
    endfor

    if winnr('$') > 1
      for info in lefts + rights
        const spec = getwinvar(info.winid, 'dock', {})
        Resize(info.winid, spec)
      endfor
      if BottomsFit(bottoms)
        ArrangeBottomRow(bottoms)
      else
        for info in bottoms
          Resize(info.winid, getwinvar(info.winid, 'dock', {}))
        endfor
      endif
    endif
  finally
    reflowing = false
  endtry
enddef

def ReflowLater(_: number = 0): void
  if reflowing || pending_timer >= 0
    return
  endif
  pending_timer = timer_start(0, (_) => Reflow())
enddef

export def Setup(): void
  if configured
    return
  endif
  configured = true
  augroup UserDock
    autocmd!
    autocmd WinNew,WinClosed,WinResized,VimResized,TabEnter * ReflowLater()
  augroup END
enddef

export def Attach(options: dict<any>): void
  Setup()
  w:dock = Spec(options)
  ReflowLater()
enddef

export def Open(buf: number, options: dict<any>): void
  Setup()
  if !bufexists(buf)
    throw $'dock: buffer {buf} does not exist'
  endif

  const existing = bufwinid(buf)
  if existing > 0
    win_gotoid(existing)
    Attach(options)
    return
  endif

  const spec = Spec(options)
  if spec.edge ==# 'bottom'
    execute $'botright :{spec.size}split'
  elseif spec.edge ==# 'left'
    execute $'topleft vertical :{spec.size}split'
  else
    execute $'botright vertical :{spec.size}split'
  endif
  execute $'buffer {buf}'
  Attach(spec)
enddef

defcompile

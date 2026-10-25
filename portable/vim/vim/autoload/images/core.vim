vim9script

var popups: list<number> = []
var last_state = ''
var refreshing = false
const image_extension = '\c\.\%(png\|jpe\?g\|gif\|webp\)$'

export def Close()
  var closing = popups
  popups = []
  last_state = ''
  for popup in closing
    if !empty(popup_getpos(popup))
      popup_close(popup)
    endif
  endfor
enddef

export def Highlights()
  for id in range(1, 255)
    var name = 'VimImageID' .. id
    execute printf('highlight %s ctermfg=%d guifg=#%06x', name, id, id)
    if empty(prop_type_get(name))
      prop_type_add(name, {
        highlight: name,
      })
    endif
  endfor
enddef

def LocalPath(link: string): string
  var path = trim(link)
  if path =~# '^<.*>$'
    path = path[1 : -2]
  endif
  if path =~# '^\a[[:alnum:]+.-]*:' || path =~# '^//'
    return ''
  endif
  if path !~# '^/'
    path = fnamemodify(bufname(), ':p:h') .. '/' .. path
  endif
  path = simplify(path)
  return path =~# image_extension && filereadable(path) ? path : ''
enddef

def Targets(): list<dict<any>>
  var file = fnamemodify(bufname(), ':p')
  if file =~# image_extension && filereadable(file)
    return [{
      path: file,
      line: line('w0'),
      whole: true,
    }]
  endif
  if &filetype !=# 'markdown' || empty(bufname())
    return []
  endif

  var targets: list<dict<any>> = []
  const pattern = '!\[[^]]*\](\s*\(<[^>]\+>\|[^[:space:]()]\+\)'
  for lnum in range(line('w0'), line('w$'))
    if foldclosed(lnum) >= 0
      continue
    endif
    var text = getline(lnum)
    var offset = 0
    while len(targets) < 16
      var found = matchstrpos(text, pattern, offset)
      if found[1] < 0
        break
      endif
      offset = found[2]
      var path = LocalPath(matchlist(found[0], pattern)[1])
      if !empty(path)
        add(targets, {
          path: path,
          line: lnum,
          whole: false,
        })
      endif
    endwhile
  endfor
  return targets
enddef

def Run(arguments: list<string>): string
  var command = join(mapnew(['vim-image-upload'] + arguments,
    (_, value) => shellescape(value)), ' ')
  var result = system(command)
  if v:shell_error != 0
    throw empty(trim(result)) ? 'Image uploader failed' : trim(result)
  endif
  return result
enddef

def Dimensions(path: string, width: number, height: number): list<number>
  var result = split(Run([
    '--only-dump-dims',
    '--max-cols', string(width),
    '--max-rows', string(height),
    path,
  ]))
  if len(result) != 2 || result[0] !~# '^\d\+$' || result[1] !~# '^\d\+$'
    throw 'Invalid image dimensions: ' .. path
  endif
  return [max([1, str2nr(result[0])]), max([1, str2nr(result[1])])]
enddef

def Upload(path: string, width: number, height: number): list<dict<any>>
  var text_file = tempname()
  var info_file = tempname()
  try
    Run([
      '-c', string(width),
      '-r', string(height),
      '-o', text_file,
      '--save-info', info_file,
      '--noesc',
      '--256',
      path,
    ])
    var id = 0
    for entry in readfile(info_file)
      if entry =~# '^id\s\+\d\+$'
        id = str2nr(split(entry)[1])
      endif
    endfor
    if id < 1 || id > 255
      throw 'Invalid image ID: ' .. path
    endif
    var rows: list<dict<any>> = []
    for text in readfile(text_file)
      add(rows, {
        text: text,
        props: [{
          col: 1,
          length: strlen(text),
          type: 'VimImageID' .. id,
        }],
      })
    endfor
    return rows
  finally
    delete(text_file)
    delete(info_file)
  endtry
enddef

def TextEdges(window: dict<any>): list<number>
  var edges = repeat([window.wincol + window.textoff - 1], window.height)
  var bottom = window.winrow + window.height - 1
  var right = window.wincol + window.width - 1
  for lnum in range(line('w0'), line('w$'))
    var start = screenpos(window.winid, lnum, 1)
    if start.row > 0 && foldclosed(lnum) >= 0
      edges[start.row - window.winrow] = right
      continue
    endif
    var end = screenpos(window.winid, lnum, strlen(getline(lnum)) + 1)
    # A wrapped line can begin above the visible part of the window.
    var first_row = start.row == 0 ? window.winrow : max([window.winrow, start.row])
    var last_row = end.row == 0 ? bottom : min([bottom, end.row])
    for row in range(first_row, last_row)
      edges[row - window.winrow] = row < last_row || end.col == 0
        ? right : max([edges[row - window.winrow], end.col - 1])
    endfor
  endfor
  return edges
enddef

def Placement(window: dict<any>, edges: list<number>, anchor: number,
    width: number, height: number): list<number>
  var bottom = window.winrow + window.height - 1
  var right = window.wincol + window.width - 1
  for row in range(max([window.winrow, anchor]), bottom)
    for rows in reverse(range(1, min([height, bottom - row + 1])))
      var cols = max([1, width * rows / height])
      var occupied = max(edges[row - window.winrow : row - window.winrow + rows - 1])
      var col = right - cols + 1
      if cols >= min([width, 5]) && rows >= min([height, 3]) && occupied + 1 < col
        for used in range(row - window.winrow, row - window.winrow + rows - 1)
          edges[used] = right
        endfor
        return [row, col, cols, rows]
      endif
    endfor
  endfor
  return []
enddef

export def Refresh(force: bool = false)
  if refreshing || &buftype !=# '' || mode() =~# '^[iR]'
    return
  endif
  var targets = Targets()
  var window = getwininfo(win_getid())[0]
  var state = string([
    window.winid, window.bufnr, window.winrow, window.wincol,
    window.width, window.height, window.textoff,
    b:changedtick, line('w0'), line('w$'), g:vim_images_tmux_layers,
    mapnew(targets, (_, target) => [target.path, getftime(target.path), getfsize(target.path)]),
  ])
  if !force && state ==# last_state
    return
  endif
  Close()
  last_state = state
  if empty(targets)
    return
  endif

  refreshing = true
  try
    $VIM_IMAGES_TMUX_LAYERS = string(g:vim_images_tmux_layers)
    Highlights()
    redraw
    var edges = TextEdges(window)
    for target in targets
      var dims = Dimensions(target.path,
        min([100, max([1, window.width - window.textoff - 2])]),
        min([30, max([1, window.height - 2])]))
      var position: list<number>
      if target.whole
        position = [window.winrow, window.wincol + window.textoff, dims[0], dims[1]]
      else
        var anchor = screenpos(window.winid, target.line, 1).row
        if anchor == 0
          continue
        endif
        position = Placement(window, edges, anchor, dims[0], dims[1])
      endif
      if empty(position)
        continue
      endif
      var rows = Upload(target.path, position[2], position[3])
      add(popups, popup_create(rows, {
        line: position[0],
        col: position[1],
        pos: 'topleft',
        minwidth: position[2],
        maxwidth: position[2],
        minheight: position[3],
        maxheight: position[3],
        wrap: false,
        scrollbar: false,
        mapping: false,
        zindex: 10,
      }))
    endfor
  catch
    echohl ErrorMsg
    echomsg 'Image preview: ' .. v:exception
    echohl None
  finally
    refreshing = false
    last_state = state
  endtry
enddef

export def SetDepth(value: string)
  if value !~# '^[012]$' || (empty($TMUX) != (value ==# '0'))
    echoerr 'Use depth 0 outside tmux, or depth 1 or 2 inside tmux'
    return
  endif
  g:vim_images_tmux_layers = str2nr(value)
  Refresh(true)
enddef

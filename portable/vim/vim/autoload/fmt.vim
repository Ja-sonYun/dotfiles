function! fmt#Formatter(name) abort
  execute 'runtime! formatter/' . a:name . '.vim'
  let b:current_formatter = a:name
endfunction

function! fmt#RunFmt(ext, cmds) abort
  let s = getpos("'<")[1]
  let e = getpos("'>")[1]
  let before = getline(s, e)
  let prev_change = changenr()

  let dir = expand('%:p:h')
  if empty(dir)
    let dir = getcwd()
  endif

  let fmt_ext = empty(a:ext) ? 'tmp' : a:ext
  let bufname = expand('%:t:r')
  let tmp_dir = trim(system('mktemp -d ' . shellescape(dir . '/.vim-fmt.XXXXXXXXXX')))
  if v:shell_error != 0
    echohl ErrorMsg
    echomsg '[fmt] could not create temporary directory'
    echohl None
    return 0
  endif
  let tmp = tmp_dir . '/' . bufname . '.' . fmt_ext
  let err = tmp_dir . '/stderr'

  " Build the shell command
  let sc = ['cd ' . shellescape(dir), 'status=0', 'cat >' . shellescape(tmp) . ' || status=$?']

  " Run each formatter command
  for cmd in a:cmds
    call add(sc, '[ $status -ne 0 ] && exit $status')
    let full = substitute(cmd, '{file}', shellescape(tmp), 'g')
    call add(sc, full . ' >/dev/null 2>>' . shellescape(err) . ' || status=$?')
  endfor
  call add(sc, '[ $status -ne 0 ] && exit $status')

  " Output formatted file
  call add(sc, 'cat ' . shellescape(tmp) . ' || status=$?')
  call add(sc, 'exit $status')
  let shcmd = 'sh -c ' . shellescape(join(sc, ' ; '))

  " Execute formatter over the selection
  let shell_error = 0
  try
    execute "'<,'>!" . shcmd
    let shell_error = v:shell_error
  catch /^Vim\%((\a\+)\)\=:E/
    " Handle Vim errors (e.g., command execution failure)
    let shell_error = 1
  endtry

  " Compare with produced tmp file
  let after = filereadable(tmp) ? readfile(tmp) : []
  let nochange = join(before, "\n") ==# join(after, "\n")

  " Report errors
  let has_error = 0
  if filereadable(err)
    let msgs = readfile(err)
    if !empty(msgs)
      let has_error = 1
      echohl ErrorMsg
      for m in msgs
        echomsg '[fmt error] ' . m
      endfor
      echohl None
    endif
  endif

  call delete(tmp_dir, 'rf')

  " Failure -> revert and exit
  if shell_error !=# 0 || has_error
    if changenr() !=# prev_change
      silent! undo
    endif
    echohl ErrorMsg
    echomsg '[fmt] failed'
    echohl None
    return 0
  endif

  " No change -> revert filter effect and exit
  if nochange
    if changenr() !=# prev_change
      silent! undo
    endif
    echomsg '[fmt] no change'
    return 0
  endif

  echomsg '[fmt] done'
  return 0
endfunction

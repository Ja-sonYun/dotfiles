function! utils#Preserve(cmd) abort
  let view = winsaveview()
  execute a:cmd
  call winrestview(view)
endfunction

function! utils#GetGitRoot(...) abort
  if !executable('git')
    return ''
  endif

  let l:start = getcwd()
  if a:0 > 0 && type(a:1) == type('') && a:1 !=# ''
    let l:start = a:1
  endif

  let l:cmd = 'git -C ' .. shellescape(l:start) .. ' rev-parse --show-toplevel'
  let l:out = systemlist(l:cmd)
  if v:shell_error != 0 || empty(l:out)
    return ''
  endif

  return l:out[0]
endfunction

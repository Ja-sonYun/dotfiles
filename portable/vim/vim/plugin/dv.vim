if exists("g:loaded_user_dv")
  finish
endif
let g:loaded_user_dv = 1

let s:last_dir = ''
let s:dir_var_store = {}

function! s:LoadGlobalVarsJson(file) abort
  if !filereadable(a:file)
    return
  endif
  try
    let l:data = json_decode(join(readfile(a:file), "\n"))
  catch /^Vim\%((\a\+)\)\=:E/
    echoerr 'Invalid JSON in ' . a:file
    return
  endtry
  if !has_key(l:data, 'g')
    return
  endif

  let l:dir = getcwd()
  let s:dir_var_store[l:dir] = {}

  for [l:k, l:v] in items(l:data.g)
    if exists('g:' . l:k)
      let s:dir_var_store[l:dir][l:k] = deepcopy(g:[l:k])
    else
      let s:dir_var_store[l:dir][l:k] = v:none
    endif
    let g:[l:k] = l:v
  endfor
  echo 'Loaded global vars from ' . a:file
endfunction

function! s:RestoreGlobalVars(dir) abort
  if !has_key(s:dir_var_store, a:dir)
    return
  endif
  for [l:k, l:oldval] in items(s:dir_var_store[a:dir])
    if l:oldval is v:none
      if exists('g:' . l:k)
        unlet g:[l:k]
      endif
    else
      let g:[l:k] = l:oldval
    endif
  endfor
  unlet s:dir_var_store[a:dir]
endfunction

function! s:MaybeReloadVars() abort
  let l:dir = getcwd()
  if l:dir ==# s:last_dir
    return
  endif
  if s:last_dir !=# ''
    call s:RestoreGlobalVars(s:last_dir)
  endif
  let s:last_dir = l:dir
  call s:LoadGlobalVarsJson(l:dir . '/.vim_vars.json')
endfunction

augroup LoadGlobalVars
  autocmd!
  autocmd BufEnter,VimEnter,DirChanged * call s:MaybeReloadVars()
augroup END

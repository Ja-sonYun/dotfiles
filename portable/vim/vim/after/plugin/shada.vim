if exists("g:loaded_after_shada")
  finish
endif
let g:loaded_after_shada = 1

let s:per_root_ready = 0

function! s:state_dir_and_ext() abort
  let state = empty($XDG_STATE_HOME) ? expand('~/.local/state') : $XDG_STATE_HOME
  let root  = state . '/vim/viminfo/workspaces'
  let ext   = '.viminfo'
  return [root, ext]
endfunction

function! s:per_root_path() abort
  let [root, ext] = s:state_dir_and_ext()
  let ws   = getcwd()
  let base = fnamemodify(ws, ':t')
  let hash = strpart(sha256(ws), 0, 8)
  call mkdir(root, 'p')
  return root . '/' . base . '_' . hash . ext
endfunction

function! s:clear_histories() abort
  for t in [':', '/', '=', '@']
    call histdel(t)
  endfor
endfunction

function! s:apply_per_root() abort
  if s:per_root_ready
    silent! wviminfo!
  endif

  let file = s:per_root_path()
  let &viminfofile = file

  call s:clear_histories()
  if filereadable(file)
    silent! rviminfo!
  endif

  let s:per_root_ready = 1
endfunction

augroup PerRootViminfo
  autocmd!
  autocmd VimEnter   * call s:apply_per_root()
  autocmd DirChanged * call s:apply_per_root()
  autocmd VimLeavePre * silent! wviminfo!
augroup END

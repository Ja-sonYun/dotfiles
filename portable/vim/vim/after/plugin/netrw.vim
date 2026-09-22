if exists("g:loaded_after_netrw")
  finish
endif
let g:loaded_after_netrw = 1

if !has('mac') && !has('win32') && !has('win64')
  if executable('xdg-open')
    let g:Openprg = 'xdg-open'
  elseif executable('gio')
    let g:Openprg = 'gio open'
  endif
endif

let s:header_lines = 8

augroup OverrideExplore
  autocmd!
  autocmd VimEnter * call s:OverrideExplore()
augroup END

function! s:OverrideExplore() abort
  silent! delcommand Explore
  command! -nargs=* -complete=dir Explore call s:Explore(<q-args>)
endfunction

function! s:Explore(args) abort
  if &buftype == '' && &filetype !=# 'netrw'
    let l:file = expand('%:t')
    let l:dir  = expand('%:p:h')
  else
    let l:file = ''
    let l:dir  = getcwd()
  endif

  if a:args ==# ''
    call netrw#Explore(0, 0, 0, fnameescape(l:dir))
  else
    call netrw#Explore(0, 0, 0, a:args)
  endif

  if l:file !=# '' && search('\V' . escape(l:file, '\'), 'w') == 0
    call cursor(s:header_lines + 1, 1)
  endif
endfunction

nnoremap <silent> <leader>f <Cmd>Explore<CR>

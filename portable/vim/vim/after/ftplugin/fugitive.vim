nmap <buffer> l <CR>
nnoremap <buffer><nowait> q <Cmd>q<CR>
nnoremap <buffer><nowait> <C-c> <Cmd>q<CR>
nnoremap <buffer><nowait> r <Cmd>e<CR>
nnoremap <buffer> <leader>f <Nop>

setlocal signcolumn=no
setlocal bufhidden=wipe
setlocal nonumber norelativenumber
setlocal cursorline

let &l:listchars = join([
      \ 'tab:. ',
      \ 'extends:❯',
      \ 'precedes:❮',
      \ 'nbsp: ',
      \ 'trail: ',
      \ 'leadmultispace:| '
      \ ], ',')

setlocal winfixheight winfixwidth

augroup FugitiveLocal
  autocmd! * <buffer>
  autocmd BufWinEnter <buffer> if &filetype ==# 'fugitive' | wincmd L | wincmd L | vertical resize 50 | endif
augroup END

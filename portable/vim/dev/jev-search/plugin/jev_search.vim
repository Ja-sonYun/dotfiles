vim9script

if exists('g:loaded_jev_search')
  finish
endif
g:loaded_jev_search = true

import autoload 'jev_search.vim' as search

command! -range JevSearch search.Start(<line1>, <line2>)
xnoremap <silent> <Plug>(JevSearch) :JevSearch<CR>

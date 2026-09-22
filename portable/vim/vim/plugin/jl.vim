if exists("g:loaded_user_jl")
  finish
endif
let g:loaded_user_jl = 1

function! s:NextFileJump(forward) abort
  let start = expand('%:p')
  let max = 100

  for _ in range(max)
    if a:forward
      execute "normal! \<C-i>"
    else
      execute "normal! \<C-o>"
    endif
    redraw

    if expand('%:p') !=# start && &buftype ==# '' && &modifiable && !&readonly
      return
    endif
  endfor
endfunction

nnoremap <silent> <Space>i <Cmd>call <SID>NextFileJump(1)<CR>
nnoremap <silent> <Space>o <Cmd>call <SID>NextFileJump(0)<CR>

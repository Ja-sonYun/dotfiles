setlocal nonumber
setlocal cursorline
setlocal statusline=%n\ %f%=%L\ lines

nnoremap <buffer><silent><nowait> q <Cmd>q<CR>
nnoremap <buffer><silent><nowait> <C-c> <Cmd>q<CR>
nnoremap <buffer><silent><nowait> l <CR><Cmd>wincmd p<CR>
nnoremap <buffer> <leader>f <Nop>

nnoremap <buffer><nowait> f :Cfilter 
nnoremap <buffer><nowait> F :Cfilter! 
nnoremap <buffer><silent><nowait> <Space>s <Cmd>call bnqf#search#Start()<CR>

function s:TabCC(line)
  let is_location = getwininfo(win_getid())[0].loclist
  if is_location
    let location = getloclist(0, {'items': 1, 'title': 1, 'context': 1})
  endif
  execute 'tabnew'
  if is_location
    call setloclist(0, [], ' ', location)
    execute 'll' a:line
  else
    execute 'cc' a:line
  endif
endfunction

nnoremap <silent><buffer><nowait> t <Cmd>call <SID>TabCC(line('.'))<CR>

call dock#core#Attach(get(g:, 'quickfix_dock', {'edge': 'bottom', 'size': 10, 'min_width': 40}))

setlocal nonumber
setlocal cursorline
setlocal statusline=%n\ %f%=%L\ lines

nnoremap <buffer><silent><nowait> q <Cmd>q<CR>
nnoremap <buffer><silent><nowait> <C-c> <Cmd>q<CR>
nnoremap <buffer><silent><nowait> l <CR><Cmd>wincmd p<CR>
nnoremap <buffer> <leader>f <Nop>

nnoremap <buffer><nowait> f :Cfilter 
nnoremap <buffer><nowait> F :Cfilter! 

function s:TabCC(line)
  execute 'tabnew'
  execute 'cc' a:line
endfunction

nnoremap <silent><buffer><nowait> t <Cmd>call <SID>TabCC(line('.'))<CR>

call dock#core#Attach(get(g:, 'quickfix_dock', {'edge': 'bottom', 'size': 10, 'min_width': 40}))

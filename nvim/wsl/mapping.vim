
" NMAP:
nmap ,a :noh <bar> :call EchoMessage('no highlight')<CR>
nmap ,c :TagbarToggle<CR>
nmap ,C :Tags<CR>
nmap Qm :Marks<CR>
nmap QN :tabnew<CR>
nmap QM :tabclose<CR>
nmap ,e :e<bar>call EchoMessage('Reloaded!')<CR>
" nmap ,s :setlocal spell! spelllang=en_us<bar> call EchoMessage('SpellCheck')<CR>
nmap <C-Right> <ESC>:call EchoMessage('tab next') <bar> tabnext<CR>
nmap <C-Left> <ESC>:call EchoMessage('tab prev') <bar> tabprev<CR>
nmap ,g :Buffers<CR>
nmap ,h :Commit<CR>
nmap ,H :BCommit<CR>
nmap ,t :NvimTreeToggle<CR>
nmap ,T :TagbarToggle<CR>
nmap ,f :Files<CR>
nmap ,r :Rg<CR>
nmap ,q <ESC>:bd <bar> :call EchoMessage('buffer closed!')<CR>
nmap ,w <ESC>:w <bar> :call EchoMessage('file saved!')<CR>
nmap ,z <ESC>:q<CR>
nmap ,l <ESC>:ls<CR>
" do noh -> why?
nmap ,R <ESC>:source % <bar> :call EchoMessage('init.vim reloaded!') <bar> :noh<CR>

" for normal mode - the word under the cursor
nmap <leader>db <Plug>VimspectorBalloonEval
" for visual mode, the visually selected text
" xmap di <Plug>VimspectorBalloonEval

nmap <leader>dt <Plug>VimspectorToggleBreakpoint
nmap <leader>dc <Plug>VimspectorContinue
nmap <leader>df <Plug>VimspectorAddFunctionBreakpoint
nmap <leader>dT <Plug>VimspectorToggleConditionalBreakpoint
nmap <leader>dr <Plug>VimspectorRestart
nmap <leader>dp <Plug>VimspectorPause
nmap <leader>dq :VimspectorReset<CR>
nmap <leader>dW :VimspectorWatch 

nmap Qh <ESC>:checkhealth<CR>
nmap Qb <ESC>:BufOnly <bar> :call EchoMessage('buf only')<CR>
nmap Qq <ESC>:wq<CR>
nmap QQ <ESC>:wq!<CR>

" Yankround:
nmap p <Plug>(yankround-p)
xmap p <Plug>(yankround-p)
nmap P <Plug>(yankround-P)
nmap gp <Plug>(yankround-gp)

xmap gp <Plug>(yankround-gp)
nmap gP <Plug>(yankround-gP)
" nmap <C-p> <Plug>(yankround-prev)
" nmap <C-n> <Plug>(yankround-next)
"
" Find files using Telescope command-line sugar.
nnoremap <leader>ff <cmd>Telescope find_files<cr>
nnoremap <leader>fg <cmd>Telescope live_grep<cr>
nnoremap <leader>fb <cmd>Telescope buffers<cr>
nnoremap <leader>fh <cmd>Telescope help_tags<cr>

" Using Lua functions
nnoremap <leader>ff <cmd>lua require('telescope.builtin').find_files()<cr>
nnoremap <leader>fg <cmd>lua require('telescope.builtin').live_grep()<cr>
nnoremap <leader>fb <cmd>lua require('telescope.builtin').buffers()<cr>
nnoremap <leader>fh <cmd>lua require('telescope.builtin').help_tags()<cr>


" These commands will navigate through buffers in order regardless of which mode you are using
" e.g. if you change the order of buffers :bnext and :bprevious will not respect the custom ordering
nnoremap <silent><Right> :BufferLineCycleNext<CR>
nnoremap <silent><Left> :BufferLineCyclePrev<CR>

nnoremap gp :silent %!prettier --stdin-filepath %<CR>

nnoremap ,,,,t <ESC>:setlocal ts=4 sw=4 expandtab<CR>
nnoremap ,,t <ESC>:setlocal ts=2 sw=2 expandtab<CR>

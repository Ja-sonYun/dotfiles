vim9script

if exists('g:loaded_user_codeflow')
  finish
endif
g:loaded_user_codeflow = true

import autoload 'codeflow/core.vim' as codeflow

command! -nargs=1 -complete=file FlowLoad codeflow.Load(<f-args>)

nnoremap <silent> qn <Cmd>call codeflow#core#PrepareJump()<CR><Cmd>cnext<CR>
nnoremap <silent> qp <Cmd>call codeflow#core#PrepareJump()<CR><Cmd>cprev<CR>

def TabCC(): void
  codeflow.PrepareJump(true)
  const row = line('.')
  tabnew
  execute 'cc' row
enddef

def ConfigureQuickfix(): void
  nnoremap <buffer><silent><nowait> <CR> <Cmd>call codeflow#core#PrepareJump(v:true)<CR><CR>
  nnoremap <buffer><silent><nowait> l <Cmd>call codeflow#core#PrepareJump(v:true)<CR><CR><Cmd>wincmd p<CR>
  nnoremap <silent><buffer><nowait> t <ScriptCmd>TabCC()<CR>
enddef

augroup CodeFlow
  autocmd!
  autocmd FileType qf ConfigureQuickfix()
  autocmd SafeState,SafeStateAgain * codeflow.Refresh()
  autocmd CmdlineLeave : codeflow.PrepareCommand()
  autocmd BufReadPost * codeflow.BufferLoaded()
  autocmd BufWritePost * codeflow.Saved(str2nr(expand('<abuf>')))
  autocmd BufUnload * codeflow.Unload(str2nr(expand('<abuf>')))
augroup END

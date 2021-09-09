" custom.vim

" don't display number if window is one of below types
let blacklist = ['nerdtree', 'taglist', 'tagbar', 'VimspectorPrompt', 'NvimTree']
augroup numbertoggle
  autocmd!
  autocmd BufEnter,FocusGained,InsertLeave * if index(blacklist, &ft) < 0 | set relativenumber
  autocmd BufLeave,FocusLost,InsertEnter   * if index(blacklist, &ft) < 0 | set norelativenumber number
augroup END


" echoing message
function! EchoMessage(msg)
  echohl WarningMsg
  echo "Message"
  echohl None
  echon ': ' a:msg
endfunction

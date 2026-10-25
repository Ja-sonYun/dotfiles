vim9script

if exists('g:loaded_user_images')
  finish
endif
g:loaded_user_images = true

import autoload 'images/core.vim'

g:vim_images_tmux_layers = get(g:, 'vim_images_tmux_layers', empty($TMUX) ? 0 : 1)

command! ImagePreview core.Refresh(true)
command! ImageClear core.Close()
command! -nargs=1 ImageTmuxLayers core.SetDepth(<q-args>)

augroup UserImages
  autocmd!
  autocmd VimEnter,BufWinEnter,CursorHold,BufWritePost,InsertLeave * core.Refresh()
  autocmd FocusGained * core.Refresh(true)
  autocmd BufWinLeave,WinLeave,TabLeave,WinScrolled,VimResized,VimLeavePre,InsertEnter * core.Close()
  autocmd ColorScheme * core.Highlights()
augroup END

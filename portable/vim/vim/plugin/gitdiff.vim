vim9script

if exists('g:loaded_user_gitdiff')
  finish
endif
g:loaded_user_gitdiff = true

import autoload 'gitdiff/core.vim' as gitdiff

command! -nargs=1 -bar GitDiff gitdiff.Open(<q-args>)
command! -nargs=0 -bar GitDiffClose gitdiff.Close()

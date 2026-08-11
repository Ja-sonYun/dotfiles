vim9script

if exists('g:loaded_user_dock')
  finish
endif
g:loaded_user_dock = true

import autoload 'dock/core.vim' as dock

dock.Setup()

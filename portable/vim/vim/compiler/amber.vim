if exists('current_compiler')
  finish
endif

let amber = 'amber'

let &l:makeprg = amber . ' check '
      \ ..get(b:, 'amber_makeprg_params', get(g:, 'amber_makeprg_params', ''))
exe 'CompilerSet makeprg='..escape(&l:makeprg, ' \|"')

CompilerSet errorformat=
      \%E%f:%l:%c:\ %m,
      \%E%f:%l:\ %m,
      \%E%\\s%#-->%\\s%#%f:%l:%c,
      \%E%\\s%#-->%\\s%#%f:%l,
      \%-G%.%#

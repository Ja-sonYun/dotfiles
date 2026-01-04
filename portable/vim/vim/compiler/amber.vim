if exists('current_compiler')
  finish
endif

let &l:makeprg = 'amber check %:p '
      \ ..get(b:, 'amber_makeprg_params', get(g:, 'amber_makeprg_params', ''))
exe 'CompilerSet makeprg='..escape(&l:makeprg, ' \|"')

CompilerSet errorformat=
      \%E%\\s%#ERROR%\\s%#%m,
      \%Z%\\s%#at\\s%#%f:%l:%c,
      \%-G%\\s%#%\\d%#\|%.%#,
      \%-G%.%#

if exists('current_compiler')
  finish
endif

let current_compiler = 'typescript'

let local_tsc = getcwd() . '/node_modules/.bin/tsc'

if executable(local_tsc)
  let tsc = shellescape(local_tsc)
elseif executable('pnpx')
  let tsc = 'pnpm tsc'
elseif executable('yarn')
  let tsc = 'yarn tsc'
elseif executable('npx')
  let tsc = 'npx tsc'
else
  let tsc = 'tsc'
endif

let &l:makeprg = tsc . ' '
      \ ..get(b:, 'tsc_makeprg_params', get(g:, 'tsc_makeprg_params', '')) . ' '
exe 'CompilerSet makeprg='..escape(&l:makeprg, ' \|"')

CompilerSet errorformat=
      \%E%f(%l\\,%c):\ error\ %m,
      \%W%f(%l\\,%c):\ warning\ %m,
      \%C%\s%#%m,
      \%-G%.%#

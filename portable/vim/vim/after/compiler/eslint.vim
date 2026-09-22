if !exists("current_compiler") || current_compiler !=# "eslint"
  finish
endif

" Find eslint in order: local node_modules, global npx, global pnpm, global yarn, global eslint
let local_eslint = getcwd() . '/node_modules/.bin/eslint'

if executable(local_eslint)
  let eslint = shellescape(local_eslint)
elseif executable('pnpx')
  let eslint = 'pnpm eslint'
elseif executable('yarn')
  let eslint = 'yarn eslint'
elseif executable('npx')
  let eslint = 'npx eslint'
else
  let eslint = 'eslint'
endif

let &l:makeprg = eslint . ' --format stylish '
      \ ..get(b:, 'eslint_makeprg_params', get(g:, 'eslint_makeprg_params', ''))
exe 'CompilerSet makeprg='..escape(&l:makeprg, ' \|"')
CompilerSet errorformat=%-P%f,\%\\s%#%l:%c\ %#\ %trror\ \ %m,\%\\s%#%l:%c\ %#\ %tarning\ \ %m,\%-Q,\%-G%.%#,

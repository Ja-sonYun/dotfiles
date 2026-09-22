if !exists("current_compiler") || current_compiler !=# "mypy"
  finish
endif

let venv_mypy = getcwd() . '/.venv/bin/mypy'

if executable(venv_mypy)
  let mypy = shellescape(venv_mypy) . ' %:S'
else
  let mypy = 'mypy %:S'
endif

let &l:makeprg = mypy . ' --show-column-numbers '
	    \ ..get(b:, 'mypy_makeprg_params', get(g:, 'mypy_makeprg_params', '--strict --ignore-missing-imports'))
exe 'CompilerSet makeprg='..escape(&l:makeprg, ' \|"')
CompilerSet errorformat=%f:%l:%c:\ %t%*[^:]:\ %m

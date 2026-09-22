if !exists("current_compiler") || current_compiler !=# "ruff"
  finish
endif

let venv_ruff = getcwd() . '/.venv/bin/ruff'
if executable(venv_ruff)
  let ruff = shellescape(venv_ruff)
else
  let ruff = 'ruff'
endif

let &l:makeprg= ruff . ' check --output-format=concise '
        \ ..get(b:, 'ruff_makeprg_params', get(g:, 'ruff_makeprg_params', '--preview'))
exe 'CompilerSet makeprg='..escape(&l:makeprg, ' \|"')

CompilerSet errorformat=%f:%l:%c:\ %m,%f:%l:\ %m,%f:%l:%c\ -\ %m,%f:

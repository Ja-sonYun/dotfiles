if exists("g:loaded_user_core")
  finish
endif
let g:loaded_user_core = 1

set shellpipe=>%s\ 2>&1
set shellredir=>%s\ 2>&1

autocmd QuickFixCmdPost lgrep,lvimgrep lopen
autocmd QuickFixCmdPost grep,grepadd,make copen

if executable('rg')
  set grepprg=rg\ --vimgrep\ --no-heading\ --color=never\ --fixed-strings\ --smart-case\ --glob\ '!**/.git/*'\ --
  set grepformat=%f:%l:%c:%m
endif

if executable('rg') && executable('fzf')
  function FindWithRg(cmdarg, cmdcomplete) abort
    let l:rg_findcmd = 'rg --files --hidden --color=never --glob "!**/.git/*"'
    if a:cmdarg ==# ''
      return systemlist(l:rg_findcmd)
    endif
    return systemlist(l:rg_findcmd .. ' | fzf --filter=' .. shellescape(a:cmdarg))
  endfunction

  set findfunc=FindWithRg
endif

nnoremap <space>f :find 
nnoremap <space>r :grep 
nnoremap <space>l :lgrep  %<left><left>
nnoremap <space>c :compiler 
nnoremap <space>m :make! 
nnoremap <space>e :!
nnoremap <space>g :vimgrep // **/*.*<left><left><left><left><left><left><left><left>

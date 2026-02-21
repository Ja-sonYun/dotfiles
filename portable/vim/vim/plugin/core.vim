if exists("g:loaded_user_core")
  finish
endif
let g:loaded_user_core = 1

set shellpipe=>%s\ 2>&1
set shellredir=>%s\ 2>&1

let s:grep_prev_cwd = ''
let s:grep_switched = 0

function! s:GetSearchRoot() abort
  let l:start = expand('%:p:h', 1)
  if l:start ==# ''
    let l:start = getcwd()
  endif

  let l:root = utils#GetGitRoot(l:start)
  if l:root ==# ''
    let l:root = getcwd()
  endif
  return l:root
endfunction

function! s:GrepCdPre() abort
  let s:grep_prev_cwd = getcwd()
  let s:grep_switched = 0

  let l:root = s:GetSearchRoot()
  if l:root !=# s:grep_prev_cwd
    execute 'noautocmd lcd' fnameescape(l:root)
    let s:grep_switched = 1
  endif
endfunction

function! s:GrepCdPost() abort
  if s:grep_switched
    execute 'noautocmd lcd' fnameescape(s:grep_prev_cwd)
    let s:grep_switched = 0
  endif
endfunction

autocmd QuickFixCmdPre grep,grepadd,lgrep call <SID>GrepCdPre()
autocmd QuickFixCmdPost grep,grepadd,lgrep call <SID>GrepCdPost()
autocmd QuickFixCmdPost lgrep,lvimgrep lopen
autocmd QuickFixCmdPost grep,grepadd,make copen

if executable('rg')
  set grepprg=rg\ --vimgrep\ --no-heading\ --color=never\ --fixed-strings\ --smart-case\ --glob\ '!**/.git/*'\ --
  set grepformat=%f:%l:%c:%m
endif

if executable('rg') && executable('fzf')
  function FindWithRg(cmdarg, cmdcomplete) abort
    let l:root = s:GetSearchRoot()

    let l:rg_findcmd = 'rg --files --hidden --color=never --glob "!**/.git/*" ' .. shellescape(l:root)
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

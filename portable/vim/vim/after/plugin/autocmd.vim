if exists("g:loaded_after_autocmd")
  finish
endif
let g:loaded_after_autocmd = 1

let g:noncode_buftypes = ['terminal', 'nofile', 'prompt', 'quickfix', 'help']


" --- Don't auto-comment new lines ---
augroup NoAutoComment
  autocmd!
  autocmd BufEnter * setlocal formatoptions-=c formatoptions-=r formatoptions-=o
augroup END


" --- Remove trailing whitespace on save ---
function! s:TrimTrailingWhitespace() abort
  if !get(b:, 'trimtrail', 0)
    return
  endif
  let view = winsaveview()
  try
    keepjumps keeppatterns silent! %s/\s\+$//e
  finally
    call winrestview(view)
  endtry
endfunction

augroup TrimTrailingWS
  autocmd!
  autocmd BufWritePre * call <SID>TrimTrailingWhitespace()
augroup END


" --- Always switch Rel/Abs number automatically ---
augroup ModifyRelativeNumber
  autocmd!
  autocmd BufLeave,FocusLost,InsertEnter,WinLeave,CmdlineEnter *
        \ if index(g:noncode_buftypes, &buftype) < 0 |
        \   if &number && &relativenumber | setlocal norelativenumber | endif |
        \ endif
  autocmd BufEnter,FocusGained,InsertLeave,WinEnter,CmdlineLeave *
        \ if index(g:noncode_buftypes, &buftype) < 0 |
        \   if &number && !&relativenumber | setlocal relativenumber | endif |
        \ endif
augroup END


" --- Open file at last edit position ---
augroup OpenFileAtLastPosition
  autocmd!
  autocmd BufReadPost * silent! normal! g`"zv
augroup END


" --- Dynamic on-save hook via environment variables ---
augroup OnSaveHook
  autocmd!
  autocmd BufWritePost * call <SID>MaybeRunOnSaveHook()
augroup END

function! s:FileMatchesGlobs(globs, fname) abort
  for pat in split(a:globs, ',')
    if a:fname =~ glob2regpat(pat)
      return 1
    endif
  endfor
  return 0
endfunction

function! s:MaybeRunOnSaveHook() abort
  if empty($VIM_ON_SAVE_HOOK)
    return
  endif
  let l:f = expand('%:t')
  if empty($VIM_ON_SAVE_HOOK_TRIGGER_RULES)
    call system($VIM_ON_SAVE_HOOK)
  elseif s:FileMatchesGlobs($VIM_ON_SAVE_HOOK_TRIGGER_RULES, l:f)
    call system($VIM_ON_SAVE_HOOK)
  endif
endfunction

" --- Dynamic indentation settings per buffer via b:indent and b:usetab ---
augroup Indent
  autocmd!
  autocmd BufWinEnter * if index(g:noncode_buftypes, &buftype) < 0 |
    \ let width = getbufvar(bufnr(), 'indent', 2) |
    \ let usetab = getbufvar(bufnr(), 'usetab', 0) |
    \ let trailspace = repeat(' ', width - 1) |
    \ if usetab |
    \   setlocal noexpandtab |
    \ else |
    \   setlocal expandtab |
    \ endif |
    \ setlocal list |
    \ let &l:tabstop = width |
    \ let &l:shiftwidth = width |
    \ let &l:softtabstop = width |
    \ let &l:listchars = join([
    \   'tab:> ',
    \   'extends:>',
    \   'precedes:<',
    \   'nbsp:&',
    \   'trail:~',
    \   'leadmultispace:.' .. trailspace
    \ ], ',') |
    \ endif
  autocmd TerminalWinOpen * setlocal nolist
augroup END

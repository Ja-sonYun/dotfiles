if exists("g:loaded_user_args")
  finish
endif
let g:loaded_user_args = 1

nnoremap <silent> ]a <Cmd>next<CR>
nnoremap <silent> [a <Cmd>prev<CR>
nnoremap <silent> <leader>AA <Cmd>argadd \| argdedupe \| args<CR>
nnoremap <silent> <leader>Ad <Cmd>%argdel \| args<CR>

function! ArgOpenFuzzyComplete(A, L, P)
    let candidates = argv()
    let pat = tolower(a:A)
    if empty(pat)
        return candidates
    endif
    let filtered = filter(candidates, {_, v -> ArgFuzzyMatch(v, pat)})
    return filtered
endfunction

function! ArgFuzzyMatch(target, pattern)
    let t = tolower(a:target)
    let idx = 0
    for ch in split(a:pattern, '\zs')
        let pos = stridx(t, ch, idx)
        if pos == -1
            return 0
        endif
        let idx = pos + 1
    endfor
    return 1
endfunction
function! ArgOpen(arg)
    execute 'edit' fnameescape(a:arg)
endfunction

command! -nargs=1 -complete=customlist,ArgOpenFuzzyComplete ArgOpen call ArgOpen(<f-args>)
nnoremap <Space>a :ArgOpen 

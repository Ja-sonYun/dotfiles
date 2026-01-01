if exists("b:did_indent")
  finish
endif
let b:did_indent = 1

setlocal indentexpr=GetAmberIndent(v:lnum)
setlocal indentkeys=0{,0},0],0),:,0#,!^F,o,O,e

function! s:StripComment(line)
  return substitute(a:line, '//.*$', '', '')
endfunction

function! s:LineOpensBlock(line)
  let stripped = s:StripComment(a:line)
  return stripped =~ '{\s*$' || stripped =~ ':\s*$'
endfunction

function! s:LineOpensList(line)
  let stripped = s:StripComment(a:line)
  return stripped =~ '\[\s*$'
endfunction

function! s:LineOpensParen(line)
  let stripped = s:StripComment(a:line)
  return stripped =~ '(\s*$'
endfunction

function! s:LineEndsWithAssignment(line)
  let stripped = s:StripComment(a:line)
  return stripped =~ '=\s*$'
endfunction

function! s:LineEndsWithComma(line)
  let stripped = s:StripComment(a:line)
  return stripped =~ ',\s*$'
endfunction

function! s:LineContinues(line)
  let stripped = s:StripComment(a:line)
  return stripped =~ '\v([+\-*/%]|\&\&|\|\|)\s*$'
endfunction

function! s:FindAssignmentIndent(lnum)
  let lnum = a:lnum
  while lnum > 0
    let line = s:StripComment(getline(lnum))
    if line =~ '=\s*$'
      return indent(lnum)
    endif
    let lnum = prevnonblank(lnum - 1)
  endwhile
  return -1
endfunction

function! s:FindMatchingBraceIndent(lnum)
  let save_pos = getpos('.')
  call cursor(a:lnum, 1)
  let match_lnum = searchpair('{', '', '}', 'bnW')
  call setpos('.', save_pos)
  if match_lnum > 0
    return indent(match_lnum)
  endif
  return max([indent(a:lnum) - &shiftwidth, 0])
endfunction

function! s:FindMatchingBracketIndent(lnum)
  let save_pos = getpos('.')
  call cursor(a:lnum, 1)
  let match_lnum = searchpair('\[', '', '\]', 'bnW')
  call setpos('.', save_pos)
  if match_lnum > 0
    return indent(match_lnum)
  endif
  return max([indent(a:lnum) - &shiftwidth, 0])
endfunction

function! s:FindMatchingParenIndent(lnum)
  let save_pos = getpos('.')
  call cursor(a:lnum, 1)
  let match_lnum = searchpair('(', '', ')', 'bnW')
  call setpos('.', save_pos)
  if match_lnum > 0
    return indent(match_lnum)
  endif
  return max([indent(a:lnum) - &shiftwidth, 0])
endfunction

function! s:FindMatchingIfLine(lnum)
  let pending = {}
  let lnum = a:lnum
  while lnum > 0
    let line = getline(lnum)
    if line =~ '^\s*//'
      let lnum = prevnonblank(lnum - 1)
      continue
    endif
    let ind = indent(lnum)
    if line =~ '^\s*\(else\|elif\)\>'
      let pending[ind] = get(pending, ind, 0) + 1
    elseif line =~ '^\s*if\>'
      let count = get(pending, ind, 0)
      if count == 0
        return lnum
      endif
      let pending[ind] = count - 1
    endif
    let lnum = prevnonblank(lnum - 1)
  endwhile
  return 0
endfunction

function! s:FindNearestColonIndent(lnum, max_indent)
  let lnum = a:lnum
  while lnum > 0
    let line = s:StripComment(getline(lnum))
    let ind = indent(lnum)
    if ind < a:max_indent && line =~ ':\s*$'
      return ind
    endif
    let lnum = prevnonblank(lnum - 1)
  endwhile
  return -1
endfunction

function! GetAmberIndent(lnum)
  if a:lnum == 1
    return 0
  endif

  let line = getline(a:lnum)
  let prev_lnum = prevnonblank(a:lnum - 1)
  if prev_lnum == 0
    return 0
  endif
  let prev_line = getline(prev_lnum)
  let prev_indent = indent(prev_lnum)

  if line =~ '^\s*}'
    return s:FindMatchingBraceIndent(a:lnum)
  endif

  if line =~ '^\s*\]'
    return s:FindMatchingBracketIndent(a:lnum)
  endif

  if line =~ '^\s*)'
    return s:FindMatchingParenIndent(a:lnum)
  endif

  if line =~ '^\s*\(else\|elif\)\>'
    if prev_line =~ '^\s*}\s*$'
      return indent(prev_lnum)
    endif

    let if_lnum = s:FindMatchingIfLine(prev_lnum)
    if if_lnum > 0
      let if_line = s:StripComment(getline(if_lnum))
      if if_line !~ '{\s*$' || prev_indent <= indent(if_lnum)
        return indent(if_lnum)
      endif
    endif

    let colon_indent = s:FindNearestColonIndent(prev_lnum, prev_indent)
    if colon_indent >= 0
      return colon_indent
    endif
  endif

  if s:LineEndsWithAssignment(prev_line)
    return prev_indent + &shiftwidth
  endif

  if s:LineOpensList(prev_line)
    return prev_indent + &shiftwidth
  endif

  if s:LineOpensParen(prev_line)
    return prev_indent + &shiftwidth
  endif

  if s:LineOpensBlock(prev_line)
    return prev_indent + &shiftwidth
  endif

  let assign_indent = s:FindAssignmentIndent(prev_lnum)
  if assign_indent >= 0 && prev_indent == assign_indent + &shiftwidth
    if !s:LineContinues(prev_line) && !s:LineEndsWithComma(prev_line)
      return assign_indent
    endif
  endif

  return prev_indent
endfunction

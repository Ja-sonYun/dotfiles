if exists('b:did_indent')
  finish
endif
let b:did_indent = 1

setlocal indentexpr=GetAmberIndent(v:lnum)
setlocal indentkeys=0{,0},0],0),o,O,e

" ============================================================================
" Configuration
" ============================================================================

let s:operators = {
      \ 'chars': ['+', '-', '*', '/', '%', '<', '>'],
      \ 'tokens2': ['==', '!=', '<=', '>=', '&&', '||', '..'],
      \ 'words': ['and', 'or'],
      \ }

let s:keywords = {
      \ 'then': 'then',
      \ 'else': 'else',
      \ }

let s:pairs = [
      \ {'open': '[', 'close': ']'},
      \ {'open': '(', 'close': ')'},
      \ {'open': '{', 'close': '}'},
      \ ]

let s:op_tail_re = '\v(\.\.=?|&&|\|\||==|!=|<=|>=|<|>|[+\-*/%]|\<and\>|\<or\>)\s*$'

" ============================================================================
" Low-level helpers
" ============================================================================

function! s:IsEscaped(str, pos) abort
  let i = a:pos - 1
  let bs = 0
  while i >= 0 && strpart(a:str, i, 1) ==# '\'
    let bs += 1
    let i -= 1
  endwhile
  return (bs % 2) == 1
endfunction

function! s:LTrim(s) abort
  return substitute(a:s, '^\s\+', '', '')
endfunction

function! s:RTrim(s) abort
  return substitute(a:s, '\s\+$', '', '')
endfunction

" ============================================================================
" Line scanning
" ============================================================================

function! s:InitPairCounts() abort
  let counts = {}
  for pair in s:pairs
    let counts[pair.open] = 0
    let counts[pair.close] = 0
  endfor
  return counts
endfunction

function! s:ScanLine(line) abort
  let s = a:line
  let n = strlen(s)
  let in_str = 0
  let in_cmd = 0
  let positions = []
  let counts = s:InitPairCounts()
  let last_sig = ''

  let i = 0
  while i < n
    let ch = strpart(s, i, 1)
    let nx = (i + 1 < n) ? strpart(s, i + 1, 1) : ''

    if !in_cmd && ch ==# '"' && !s:IsEscaped(s, i)
      let in_str = !in_str
    elseif !in_str && ch ==# '$' && !s:IsEscaped(s, i)
      let in_cmd = !in_cmd
      call add(positions, i)
    elseif !in_str && !in_cmd && ch ==# '/' && nx ==# '/'
      return {
            \ 'stripped': strpart(s, 0, i),
            \ 'dollar_positions': positions,
            \ 'counts': counts,
            \ 'last_sig': last_sig,
            \ }
    endif

    if !in_str && !in_cmd && ch !~# '\s'
      let last_sig = ch
    endif

    if !in_str && !in_cmd && has_key(counts, ch)
      let counts[ch] += 1
    endif

    let i += 1
  endwhile

  return {
        \ 'stripped': s,
        \ 'dollar_positions': positions,
        \ 'counts': counts,
        \ 'last_sig': last_sig,
        \ }
endfunction

function! s:StripComment(line) abort
  if a:line !~# '//'
    return a:line
  endif
  return s:ScanLine(a:line).stripped
endfunction

" ============================================================================
" Token detection
" ============================================================================

function! s:IsThen(code) abort
  return a:code =~# '^' . s:keywords.then . '\>'
endfunction

function! s:IsElse(code) abort
  return a:code =~# '^' . s:keywords.else . '\>'
endfunction

function! s:IsTernaryElse(code) abort
  if !s:IsElse(a:code)
    return 0
  endif
  let rest = substitute(a:code, '^' . s:keywords.else . '\>\s*', '', '')
  if rest ==# ''
    return 0
  endif
  return strpart(rest, 0, 1) !=# '{'
endfunction

function! s:IsOpHead(code) abort
  if a:code ==# ''
    return 0
  endif

  let c0 = strpart(a:code, 0, 1)
  if index(s:operators.chars, c0) >= 0
    return 1
  endif

  let c2 = strpart(a:code, 0, 2)
  if index(s:operators.tokens2, c2) >= 0
    return 1
  endif

  for w in s:operators.words
    if a:code =~# '^' . w . '\>'
      return 1
    endif
  endfor

  return 0
endfunction

function! s:IsOpTail(code_r) abort
  return a:code_r !=# '' && a:code_r =~# s:op_tail_re
endfunction


" ============================================================================
" Line ending detection
" ============================================================================

function! s:EndsWithCmdDollar(code_r) abort
  let code = s:RTrim(a:code_r)
  if code ==# ''
    return 0
  endif

  let last_idx = strlen(code) - 1
  if strpart(code, last_idx, 1) ==# '?'
    let last_idx -= 1
    while last_idx >= 0 && strpart(code, last_idx, 1) =~# '\s'
      let last_idx -= 1
    endwhile
  endif

  if last_idx < 0 || strpart(code, last_idx, 1) !=# '$'
    return 0
  endif

  return !s:IsEscaped(code, last_idx)
endfunction

function! s:EndsWithComma(code_r) abort
  return a:code_r =~# ',\s*$'
endfunction

function! s:EndsWithBackslash(code_r) abort
  return a:code_r =~# '\\$'
endfunction

function! s:EndsWithAssign(code_r) abort
  if a:code_r !~# '=\s*$'
    return 0
  endif
  return a:code_r !~# '\v(\.\.=|==|!=|<=|>=)\s*$'
endfunction

" ============================================================================
" Indent matching
" ============================================================================

function! s:FindMatchingOpenerIndent(lnum, open_char, close_char) abort
  let depth = 1
  let cur_lnum = a:lnum

  while cur_lnum > 0
    let line = getline(cur_lnum)
    let res = s:ScanLine(line)
    let open_count = get(res.counts, a:open_char, 0)
    let close_count = get(res.counts, a:close_char, 0)

    if cur_lnum == a:lnum
      let depth = close_count - open_count
    else
      let depth = depth + close_count - open_count
    endif

    if depth <= 0
      return indent(cur_lnum)
    endif

    let cur_lnum = prevnonblank(cur_lnum - 1)
  endwhile

  return 0
endfunction

function! s:CmdDollarPositions(line) abort
  return s:ScanLine(a:line).dollar_positions
endfunction

function! s:FindCmdStartIndent(from_lnum) abort
  let lnum = a:from_lnum
  let first = 1

  while lnum > 0
    let raw = getline(lnum)
    let positions = s:CmdDollarPositions(raw)

    if !empty(positions)
      if first
        let stripped = s:StripComment(raw)
        let r = s:RTrim(stripped)
        if s:EndsWithCmdDollar(r)
          call remove(positions, len(positions) - 1)
        endif
        let first = 0
      endif

      if !empty(positions)
        return indent(lnum)
      endif
    endif

    let lnum = prevnonblank(lnum - 1)
  endwhile

  return -1
endfunction

function! s:FindPrevThenIndent(from_lnum) abort
  let lnum = a:from_lnum
  let depth = 0

  while lnum > 0
    let stripped = s:StripComment(getline(lnum))
    let code = s:LTrim(stripped)

    if s:IsTernaryElse(code)
      let depth += 1
    endif

    if s:IsThen(code)
      if depth == 0
        return indent(lnum)
      endif
      let depth -= 1
    endif

    let lnum = prevnonblank(lnum - 1)
  endwhile

  return -1
endfunction

function! s:FindTernaryChainStartIndent(from_lnum) abort
  let lnum = a:from_lnum
  let then_depth = 0
  let else_depth = 0
  let last_matched_then_lnum = -1

  while lnum > 0
    let stripped = s:StripComment(getline(lnum))
    let code = s:LTrim(stripped)

    if s:IsTernaryElse(code)
      let else_depth += 1
    endif

    if s:IsThen(code)
      let then_depth += 1
      if then_depth > else_depth
        let prev = prevnonblank(lnum - 1)
        if prev > 0
          return indent(prev)
        endif
        return 0
      endif
      let last_matched_then_lnum = lnum
    endif

    let lnum = prevnonblank(lnum - 1)
  endwhile

  if last_matched_then_lnum > 0
    let prev = prevnonblank(last_matched_then_lnum - 1)
    if prev > 0
      return indent(prev)
    endif
  endif

  return -1
endfunction

" ============================================================================
" Context builder
" ============================================================================

function! s:BuildContext(lnum) abort
  let ctx = {'lnum': a:lnum, 'sw': &l:shiftwidth}

  let ctx.cur_raw = getline(a:lnum)
  let ctx.cur_stripped = s:StripComment(ctx.cur_raw)
  let ctx.cur = s:LTrim(ctx.cur_stripped)

  let ctx.prev_lnum = prevnonblank(a:lnum - 1)
  if ctx.prev_lnum > 0
    let ctx.prev_raw = getline(ctx.prev_lnum)
    let ctx.prev_stripped = s:StripComment(ctx.prev_raw)
    let ctx.prev = s:LTrim(ctx.prev_stripped)
    let ctx.prev_r = s:RTrim(ctx.prev_stripped)
    let ctx.prev_ind = indent(ctx.prev_lnum)
    let ctx.prev_scan = s:ScanLine(ctx.prev_r)
  else
    let ctx.prev_raw = ''
    let ctx.prev_stripped = ''
    let ctx.prev = ''
    let ctx.prev_r = ''
    let ctx.prev_ind = 0
    let ctx.prev_scan = {'counts': s:InitPairCounts(), 'last_sig': ''}
  endif

  let ctx.cur_op_head = s:IsOpHead(ctx.cur)
  let ctx.prev_op_head = s:IsOpHead(ctx.prev)
  let ctx.prev_op_tail = s:IsOpTail(ctx.prev_r)

  let ctx.cur_is_then = s:IsThen(ctx.cur)
  let ctx.cur_is_else = s:IsElse(ctx.cur)
  let ctx.cur_is_ternary_else = s:IsTernaryElse(ctx.cur)
  let ctx.prev_is_ternary_else = s:IsTernaryElse(ctx.prev)

  let ctx.prev_ends_bs = s:EndsWithBackslash(ctx.prev_r)

  let ctx.prevprev_lnum = prevnonblank(ctx.prev_lnum - 1)
  let ctx.prevprev_ends_bs = 0
  if ctx.prevprev_lnum > 0
    let pp_stripped = s:StripComment(getline(ctx.prevprev_lnum))
    let pp_r = s:RTrim(pp_stripped)
    let ctx.prevprev_ends_bs = s:EndsWithBackslash(pp_r)
  endif

  return ctx
endfunction

" ============================================================================
" Indent rules: check functions
" ============================================================================

function! s:CheckFirstLine(ctx) abort
  return a:ctx.lnum == 1
endfunction

function! s:CheckNoPrevLine(ctx) abort
  return a:ctx.prev_lnum == 0
endfunction

function! s:CheckCloserBrace(ctx) abort
  return a:ctx.cur =~# '^}' && a:ctx.cur !~# '{'
endfunction

function! s:CheckBraceElseBrace(ctx) abort
  return a:ctx.cur =~# '^}\s*else\s*{'
endfunction

function! s:CheckCloserBracket(ctx) abort
  return a:ctx.cur =~# '^\]'
endfunction

function! s:CheckCloserParen(ctx) abort
  return a:ctx.cur =~# '^\)'
endfunction

function! s:CheckCmdEnd(ctx) abort
  return s:EndsWithCmdDollar(a:ctx.prev_r)
endfunction

function! s:CheckOpLeadingDedent(ctx) abort
  return a:ctx.prev_op_head
        \ && !a:ctx.cur_op_head
        \ && !a:ctx.cur_is_then
        \ && !a:ctx.cur_is_else
        \ && !a:ctx.prev_op_tail
        \ && !s:EndsWithComma(a:ctx.prev_r)
        \ && !a:ctx.prev_ends_bs
endfunction

function! s:CheckTernaryElseDedent(ctx) abort
  return a:ctx.prev_is_ternary_else
        \ && !a:ctx.cur_op_head
        \ && !a:ctx.cur_is_then
        \ && !a:ctx.cur_is_else
        \ && !a:ctx.prev_op_tail
        \ && !s:EndsWithComma(a:ctx.prev_r)
endfunction

function! s:CheckBackslashFinalDedent(ctx) abort
  return a:ctx.prevprev_ends_bs
        \ && !a:ctx.prev_ends_bs
        \ && !a:ctx.prev_op_head
        \ && !a:ctx.cur_op_head
        \ && !a:ctx.cur_is_then
        \ && !a:ctx.cur_is_else
        \ && !a:ctx.prev_op_tail
        \ && !s:EndsWithComma(a:ctx.prev_r)
endfunction

function! s:CheckBackslashContinue(ctx) abort
  return a:ctx.prev_ends_bs
        \ && !a:ctx.cur_op_head
        \ && !a:ctx.cur_is_then
        \ && !a:ctx.cur_is_else
endfunction

function! s:CheckCurIsThen(ctx) abort
  return a:ctx.cur_is_then
endfunction

function! s:CheckCurIsTernaryElse(ctx) abort
  return a:ctx.cur_is_ternary_else
endfunction

function! s:CheckCurOpHead(ctx) abort
  return a:ctx.cur_op_head
endfunction

function! s:CheckTrailingCloser(ctx) abort
  let res = a:ctx.prev_scan
  if res.last_sig ==# ''
    return 0
  endif
  for pair in s:pairs
    if res.last_sig ==# pair.close
      return res.counts[pair.close] > res.counts[pair.open]
    endif
  endfor
  return 0
endfunction

function! s:CheckOpenersOrTails(ctx) abort
  let res = a:ctx.prev_scan
  for pair in s:pairs
    if res.counts[pair.open] > res.counts[pair.close]
      return 1
    endif
    if res.last_sig ==# pair.open
      return 1
    endif
  endfor
  return s:EndsWithAssign(a:ctx.prev_r) || a:ctx.prev_op_tail
endfunction

" ============================================================================
" Indent rules: calc functions
" ============================================================================

function! s:CalcZero(ctx) abort
  return 0
endfunction

function! s:CalcCloserBrace(ctx) abort
  return s:FindMatchingOpenerIndent(a:ctx.lnum, '{', '}')
endfunction

function! s:CalcBraceElseBrace(ctx) abort
  return s:FindMatchingOpenerIndent(a:ctx.lnum, '{', '}')
endfunction

function! s:CalcCloserBracket(ctx) abort
  return s:FindMatchingOpenerIndent(a:ctx.lnum, '[', ']')
endfunction

function! s:CalcCloserParen(ctx) abort
  return s:FindMatchingOpenerIndent(a:ctx.lnum, '(', ')')
endfunction

function! s:CalcCmdEnd(ctx) abort
  let cmd_ind = s:FindCmdStartIndent(a:ctx.prev_lnum)
  return (cmd_ind >= 0) ? cmd_ind : a:ctx.prev_ind
endfunction

function! s:CalcDedent(ctx) abort
  return max([a:ctx.prev_ind - a:ctx.sw, 0])
endfunction

function! s:CalcTernaryChainEnd(ctx) abort
  let start_ind = s:FindTernaryChainStartIndent(a:ctx.prev_lnum)
  return (start_ind >= 0) ? start_ind : a:ctx.prev_ind
endfunction

function! s:CalcBackslashContinue(ctx) abort
  if a:ctx.prev_op_head || a:ctx.prevprev_ends_bs
    return a:ctx.prev_ind
  endif
  return a:ctx.prev_ind + a:ctx.sw
endfunction

function! s:CalcThen(ctx) abort
  if a:ctx.prev_op_head || a:ctx.prev_op_tail
    return a:ctx.prev_ind
  endif
  return a:ctx.prev_ind + a:ctx.sw
endfunction

function! s:CalcTernaryElse(ctx) abort
  let then_ind = s:FindPrevThenIndent(a:ctx.prev_lnum)
  return (then_ind >= 0) ? then_ind : a:ctx.prev_ind
endfunction

function! s:CalcOpHead(ctx) abort
  if a:ctx.prev_op_head || a:ctx.prev_op_tail
    return a:ctx.prev_ind
  endif
  return a:ctx.prev_ind + a:ctx.sw
endfunction

function! s:CalcTrailingCloser(ctx) abort
  let res = a:ctx.prev_scan
  for pair in s:pairs
    if res.last_sig ==# pair.close
      return s:FindMatchingOpenerIndent(a:ctx.prev_lnum, pair.open, pair.close)
    endif
  endfor
  return a:ctx.prev_ind
endfunction

function! s:CalcIndent(ctx) abort
  return a:ctx.prev_ind + a:ctx.sw
endfunction

" ============================================================================
" Indent rules list
" ============================================================================

let s:indent_rules = [
      \ {'check': 's:CheckFirstLine',           'calc': 's:CalcZero'},
      \ {'check': 's:CheckNoPrevLine',          'calc': 's:CalcZero'},
      \ {'check': 's:CheckBraceElseBrace',      'calc': 's:CalcBraceElseBrace'},
      \ {'check': 's:CheckCloserBrace',         'calc': 's:CalcCloserBrace'},
      \ {'check': 's:CheckCloserBracket',       'calc': 's:CalcCloserBracket'},
      \ {'check': 's:CheckCloserParen',         'calc': 's:CalcCloserParen'},
      \ {'check': 's:CheckCmdEnd',              'calc': 's:CalcCmdEnd'},
      \ {'check': 's:CheckOpLeadingDedent',     'calc': 's:CalcDedent'},
      \ {'check': 's:CheckTernaryElseDedent',   'calc': 's:CalcTernaryChainEnd'},
      \ {'check': 's:CheckBackslashFinalDedent','calc': 's:CalcDedent'},
      \ {'check': 's:CheckBackslashContinue',   'calc': 's:CalcBackslashContinue'},
      \ {'check': 's:CheckCurIsThen',           'calc': 's:CalcThen'},
      \ {'check': 's:CheckCurIsTernaryElse',    'calc': 's:CalcTernaryElse'},
      \ {'check': 's:CheckCurOpHead',           'calc': 's:CalcOpHead'},
      \ {'check': 's:CheckTrailingCloser',      'calc': 's:CalcTrailingCloser'},
      \ {'check': 's:CheckOpenersOrTails',      'calc': 's:CalcIndent'},
      \ ]

" ============================================================================
" Main indent function
" ============================================================================

function! GetAmberIndent(lnum) abort
  let ctx = s:BuildContext(a:lnum)

  for rule in s:indent_rules
    if call(rule.check, [ctx])
      return call(rule.calc, [ctx])
    endif
  endfor

  return ctx.prev_ind
endfunction

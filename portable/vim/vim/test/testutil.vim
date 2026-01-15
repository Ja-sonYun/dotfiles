vim9script

export def ExpectError(Fn: func, expect_patterns: list<string>): void
  var got = ''
  try
    Fn()
  catch
    got = v:exception
  endtry
  if got ==# ''
    add(v:errors, 'Expected error: ' .. join(expect_patterns, ' | '))
    return
  endif
  var matched = false
  for pat in expect_patterns
    if got =~# pat
      matched = true
      break
    endif
  endfor
  if !matched
    add(v:errors, 'Unexpected error: ' .. got)
  endif
enddef

export def QuitWithCheck(name: string): void
  if !empty(v:errors)
    for err in v:errors
      echo err
    endfor
    cquit 1
  endif
  echo 'OK: ' .. name
  quitall
enddef

vim9script

const stdout_path = '/dev/stdout'
const color_green = "\x1b[32m"
const color_red = "\x1b[31m"
const color_reset = "\x1b[0m"


def Emit(msg: string): void
  try
    writefile([msg], stdout_path, 'a')
  catch
    echo msg
  endtry
enddef


def Colorize(msg: string, color: string): string
  return color .. msg .. color_reset
enddef


def Format(value: any): string
  var s = string(value)
  s = substitute(s, "\n", '\\n', 'g')
  s = substitute(s, "\r", '\\r', 'g')
  return s
enddef

export def Log(msg: string): void
  Emit(msg)
enddef

export def AssertEqual(name: string, expected: any, actual: any): void
  var msg = printf('PASS: %s expected=%s got=%s', name, Format(expected), Format(actual))
  if expected ==# actual
    Emit(Colorize(msg, color_green))
  else
    add(v:errors, Colorize(printf('FAIL: %s expected=%s got=%s', name, Format(expected), Format(actual)), color_red))
  endif
enddef

export def AssertTrue(name: string, value: bool): void
  if value
    Emit(Colorize(printf('PASS: %s got=%s', name, Format(value)), color_green))
  else
    add(v:errors, Colorize(printf('FAIL: %s got=%s', name, Format(value)), color_red))
  endif
enddef

export def ExpectError(name: string, Fn: func, expect_patterns: list<string>): void
  var got = ''
  try
    Fn()
  catch
    got = v:exception
  endtry
  if got ==# ''
    add(v:errors, Colorize('FAIL: ' .. name .. ' expected error: ' .. join(expect_patterns, ' | '), color_red))
    return
  endif
  for pat in expect_patterns
    if got =~# pat
      Emit(Colorize(printf('PASS: %s matched=%s error=%s', name, pat, Format(got)), color_green))
      return
    endif
  endfor
  add(v:errors, Colorize('FAIL: ' .. name .. ' unexpected error: ' .. Format(got), color_red))
enddef

export def QuitWithCheck(name: string): void
  if !empty(v:errors)
    for err in v:errors
      Emit(err)
    endfor
    cquit 1
  endif
  Emit(Colorize('OK: ' .. name, color_green))
  quitall
enddef

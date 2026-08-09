vim9script

import autoload 'utils/path.vim' as p
import autoload 'utils/dict.vim' as d

g:rooter_busy = false

const DEFAULT = {
  buftypes: ['', 'nofile', 'nowrite', 'acwrite'],
  patterns: ['.git', 'Makefile', 'package.json'],
}

var Config = copy(DEFAULT)

def FindRoot(): p.Path
  var dir = p.Path.new(expand('%:p:h', 1))
  if dir.String() ==# ''
    dir = p.Path.Cwd()
  endif
  while true
    for p in Config.patterns
      if !empty(dir.Glob(p))
        return dir
      endif
    endfor
    const cur = dir.String()
    dir = dir.Parent()
    if cur ==# dir.String()
      break
    endif
  endwhile
  return p.Path.new('')
enddef

def Activate(): bool
  if get(g:, 'rooter_disabled', false) || get(b:, 'rooter_disabled', false)
    return false
  endif
  if index(Config.buftypes, &buftype) == -1
    return false
  endif
  const fp = p.Path.new(expand('%:p', 1))
  return empty(fp.String()) || fp.IsFile() || fp.IsDir()
enddef

def Rooter(): void
  if g:rooter_busy
    return
  endif
  g:rooter_busy = true

  if !Activate()
    g:rooter_busy = false
    return
  endif
  const root = FindRoot()
  if root.String() !=# ''
    execute 'cd' fnameescape(root.String())
  endif

  g:rooter_busy = false
enddef

export def Setup(opt: dict<any> = {}): void
  Config = d.DeepMerge(copy(DEFAULT), opt)
  augroup Rooter
    autocmd!
    autocmd VimEnter,BufEnter,BufWritePost,DirChanged * Rooter()
  augroup END
enddef

defcompile

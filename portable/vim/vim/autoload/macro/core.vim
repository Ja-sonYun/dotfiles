vim9script

import autoload 'utils/dict.vim' as d

const DEFAULT_CONFIG = {
  editor_height: 4,
  keybinding: 'Q',
}

var Config: dict<any> = deepcopy(DEFAULT_CONFIG)

def IsValidRegister(reg: string): bool
  return reg =~# '^[a-zA-Z0-9"*\+_\-/%#]$'
enddef

def OpenMacroEditorWindow(reg: string = ''): void
  var register_name = reg
  if empty(register_name)
    echo 'Register to edit: '
    register_name = getcharstr()
  endif
  if !IsValidRegister(register_name)
    echohl ErrorMsg | echomsg 'Invalid register: ' .. register_name | echohl None
    return
  endif

  register_name = tolower(register_name)
  var bufname = 'MacroEditor[' .. register_name .. ']'
  if bufexists(bufname)
    var winid = bufwinid(bufname)
    if winid != -1
      win_gotoid(winid)
      return
    endif
  endif

  execute 'botright new ' .. fnameescape(bufname)
  execute 'resize ' .. Config.editor_height
  b:register_name = register_name

  &l:buftype = 'acwrite'
  &l:bufhidden = 'wipe'
  &l:filetype = 'nocode'
  &l:number = false
  &l:relativenumber = false
  &l:wrap = false
  &l:modifiable = true
  &l:winfixwidth = true
  &l:winfixheight = true

  var macro_content = getreg(b:register_name)
  if !empty(macro_content)
    setline(1, split(macro_content, "\n", 1))
    if line('$') > 1 && getline('$') ==# ''
      deletebufline(bufnr('%'), line('$'))
    endif
    normal! gg
    setlocal nomodified
  else
    setline(1, [''])
    setlocal nomodified
  endif

  &l:statusline = 'MacroEditor [' .. b:register_name .. '] %m'

  var au = 'MacroEditor_' .. string(bufnr('%'))
  execute 'augroup ' .. au
    autocmd!
    autocmd BufWriteCmd <buffer> call SaveMacro()
    autocmd BufWipeout  <buffer> call CleanupMacro()
    autocmd BufWinLeave <buffer> call CleanupMacro()
  execute 'augroup END'
enddef

def SaveMacro(): void
  var raw = join(getline(1, '$'), "\n")
  setreg(b:register_name, raw, 'v')
  setlocal nomodified
  echomsg 'Macro saved to register ' .. b:register_name
enddef

def CleanupMacro(): void
  var au = 'MacroEditor_' .. string(bufnr('%'))
  if exists('#' .. au)
    execute 'augroup ' .. au
    autocmd!
    execute 'augroup END'
  endif
enddef

def ListMacros(): void
  var regs = split('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"*_+-%#/', '\zs')
  echomsg 'Registered macros:'
  echomsg '=================='
  for r in regs
    var content = getreg(r)
    if type(content) == v:t_string && !empty(content)
      var preview = substitute(content, '\s\+', ' ', 'g')
      if strchars(preview) > 80
        preview = strcharpart(preview, 0, 80) .. '...'
      endif
      echomsg printf('%s: %s', r, preview)
    endif
  endfor
enddef

export def Setup(cfg: dict<any> = {}): void
  Config = d.DeepMerge(deepcopy(Config), cfg)

  command! -nargs=? MacroEdit call OpenMacroEditorWindow(<f-args>)
  command!          MacroList call ListMacros()

  execute 'nnoremap <silent> ' .. Config.keybinding .. ' <Cmd>MacroEdit<CR>'
enddef

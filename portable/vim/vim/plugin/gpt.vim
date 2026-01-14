vim9script

if exists('g:loaded_user_gpt')
  finish
endif
g:loaded_user_gpt = true

import autoload 'utils/gpt.vim' as gpt

def EnsureLockHighlight(): void
  if hlexists('GptLockRange') == 0
    execute 'highlight default GptLockRange ctermbg=238 guibg=#3a3a3a'
  endif
enddef

def BuildLockPositions(start: number, end: number): list<list<number>>
  var positions: list<list<number>> = []
  for lnum in range(start, end)
    add(positions, [lnum])
  endfor
  return positions
enddef

def UpdateLockHighlight(start: number, end: number): void
  if get(b:, 'gpt_lock_match', 0) != 0
    matchdelete(b:gpt_lock_match)
  endif
  if start <= 0 || end < start
    return
  endif
  b:gpt_lock_match = matchaddpos('GptLockRange', BuildLockPositions(start, end))
enddef

def UnlockGptRange(): void
  if !get(b:, 'gpt_lock_active', false)
    return
  endif
  b:gpt_lock_active = false
  if get(b:, 'gpt_lock_match', 0) != 0
    matchdelete(b:gpt_lock_match)
  endif
  if exists('b:gpt_lock_match')
    unlet b:gpt_lock_match
  endif
  if exists('b:gpt_lock_lines')
    unlet b:gpt_lock_lines
  endif
  if exists('b:gpt_lock_suppress')
    unlet b:gpt_lock_suppress
  endif
  augroup GptSoftLock
    autocmd! * <buffer>
  augroup END
enddef

def SoftLockCheck(): void
  if !get(b:, 'gpt_lock_active', false)
    return
  endif
  if get(b:, 'gpt_lock_suppress', false)
    return
  endif
  var start = line("'g")
  var end = line("'h")
  if start <= 0 || end <= 0
    return
  endif
  if end < start
    var tmp = start
    start = end
    end = tmp
  endif
  const original = get(b:, 'gpt_lock_lines', [])
  const current = getline(start, end)
  if current ==# original
    UpdateLockHighlight(start, end)
    return
  endif
  b:gpt_lock_suppress = true
  deletebufline('%', start, end)
  if len(original) > 0
    append(start - 1, original)
  endif
  b:gpt_lock_suppress = false
  setpos("'g", [bufnr('%'), start, 1, 0])
  setpos("'h", [bufnr('%'), start + len(original) - 1, 1, 0])
  UpdateLockHighlight(start, start + len(original) - 1)
  echohl WarningMsg
  echom 'Locked range cannot be modified.'
  echohl None
enddef

def LockGptRange(start: number, end: number): bool
  if get(b:, 'gpt_lock_active', false)
    echohl WarningMsg
    echom 'GPT request already in progress.'
    echohl None
    return false
  endif
  EnsureLockHighlight()
  b:gpt_lock_active = true
  b:gpt_lock_lines = getline(start, end)
  b:gpt_lock_suppress = false
  setpos("'g", [bufnr('%'), start, 1, 0])
  setpos("'h", [bufnr('%'), end, 1, 0])
  UpdateLockHighlight(start, end)
  augroup GptSoftLock
    autocmd! * <buffer>
    autocmd TextChanged,TextChangedI <buffer> SoftLockCheck()
  augroup END
  return true
enddef

def GenerateReplacer(prompt: string, system_prompt: string): func<void>
  def InnerFunc(start: number, end: number): void
    echom 'Calling GPT to process text...'
    const text = join(getline(start, end), "\n")
    const full_prompt = prompt .. '\n' .. text

    if !LockGptRange(start, end)
      return
    endif

    try
      gpt.CallAsync(
        'gpt-5.2-codex',
        full_prompt,
        (result) => {
          var lock_start = line("'g")
          var lock_end = line("'h")
          if lock_start <= 0 || lock_end <= 0
            lock_start = start
            lock_end = end
          endif
          if lock_end < lock_start
            var tmp = lock_start
            lock_start = lock_end
            lock_end = tmp
          endif
          UnlockGptRange()
          const lines = split(result, "\n")
          deletebufline('%', lock_start, lock_end)
          append(lock_start - 1, lines)
          echohl MoreMsg
          echom 'Text replacement completed.'
          echohl None
        },
        {
          system_prompt: system_prompt,
          err_cb: (error_message) => {
            UnlockGptRange()
            echohl ErrorMsg
            echom 'GPT request failed: ' .. string(error_message)
            echohl None
          },
        }
      )
    catch
      UnlockGptRange()
      echohl ErrorMsg
      echom v:exception
      echohl None
    endtry
  enddef

  return InnerFunc
enddef

const GrammarFix = GenerateReplacer(
  'Fix the grammar of the following text without changing meaning:',
  'You are a precise grammar correction model. Output only corrected text.'
)
const AddComment = GenerateReplacer(
  'Add insightful comments to the following code to improve its readability:',
  'You are an expert programmer who writes clear and concise comments. Output only the code with added comments. Do not change the original code functionality.'
)
const RefactorCode = GenerateReplacer(
  'Refactor the following code to improve its structure and readability without changing its functionality:',
  'You are an expert programmer who refactors code for better structure and readability. Output only the refactored code.'
)

command! -range Fix      call GrammarFix(<line1>, <line2>)
command! -range Com      call AddComment(<line1>, <line2>)
command! -range Refactor call RefactorCode(<line1>, <line2>)

defcompile

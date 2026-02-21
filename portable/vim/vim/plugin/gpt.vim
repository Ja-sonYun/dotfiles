vim9script

if exists('g:loaded_user_gpt')
  finish
endif
g:loaded_user_gpt = true

import autoload 'utils/opencode.vim' as opencode
import autoload 'utils/lockrange.vim' as lock

const MSG_CALLING = 'Calling GPT to process text...'
const MSG_STATUS = 'refining...'
const MSG_REPLACE_DONE = 'Text replacement completed.'
const MSG_ASK_DONE = 'Ask completed.'
const MSG_NO_RESPONSE = 'No response returned.'
const MSG_FAIL_PREFIX = 'GPT request failed: '

def CurrentFilePath(): string
  const path = expand('%:p')
  return path == '' ? '[No Name]' : path
enddef

def BuildFileHeader(): string
  return 'File: ' .. CurrentFilePath() .. "\n\n"
enddef

def EchoWith(hl: string, msg: string): void
  if hl != ''
    execute 'echohl ' .. hl
  endif
  echom msg
  if hl != ''
    echohl None
  endif
enddef

def CallAiAsync(
  prompt: string,
  system_prompt: string,
  OnSuccess: func,
  OnError: func
): void
  try
    const model = get(g:, 'opencode_model', 'openai/gpt-5.2-codex')
    opencode.CallAsync(
      model,
      prompt,
      (result) => {
        call(OnSuccess, [result])
      },
      {
        system_prompt: system_prompt,
        err_cb: (error_message) => {
          call(OnError, [string(error_message)])
        },
      }
    )
  catch
    call(OnError, [v:exception])
  endtry
enddef

def GenerateReplacer(prompt: string, system_prompt: string): func<void>
  def InnerFunc(start: number, end: number): void
    EchoWith('', MSG_CALLING)
    const text = join(getline(start, end), "\n")
    const full_prompt = BuildFileHeader() .. prompt .. '\n' .. text

    const ctx = lock.LockRange(start, end)
    if type(ctx) == v:t_none
      return
    endif
    ctx.SetStatus(MSG_STATUS)

    def OnSuccess(result: string): void
      const lines = split(result, "\n")
      ctx.Replace(lines)
      ApplyIndent(ctx)
      ctx.Unlock()
      EchoWith('MoreMsg', MSG_REPLACE_DONE)
    enddef

    def OnError(message: string): void
      ctx.Unlock()
      EchoWith('ErrorMsg', MSG_FAIL_PREFIX .. message)
    enddef

    CallAiAsync(full_prompt, system_prompt, OnSuccess, OnError)
  enddef

  return InnerFunc
enddef

def BuildAskPrompt(instruction: string, lines: list<string>): string
  return BuildFileHeader() .. 'Instruction: ' .. instruction .. "\n\nCode:\n" .. join(lines, "\n")
enddef

def ApplyIndent(ctx: any): void
  if &l:indentexpr == ''
    return
  endif

  const r = ctx.Range()
  const start = r[0]
  const end_ = r[1]
  if start <= 0 || end_ <= 0 || end_ < start
    return
  endif

  const save_pos = getpos('.')
  try
    for lnum in range(start, end_)
      keepjumps call cursor(lnum, 1)
      silent! normal! ==
    endfor
  finally
    keepjumps call setpos('.', save_pos)
  endtry
enddef

def AskAction(start: number, end: number, instruction: string): void
  EchoWith('', MSG_CALLING)
  const ctx = lock.LockRange(start, end)
  if type(ctx) == v:t_none
    return
  endif
  ctx.SetStatus(MSG_STATUS)
  const original_lines = ctx.Lines()
  const full_prompt = BuildAskPrompt(instruction, original_lines)
  const system_prompt = 'You are a concise code assistant. Apply the user instruction to the provided code. Return only the updated source code. Do not use markdown or code fences. Do not include explanations or prose. If the request cannot be satisfied, return a single comment line explaining why.'

  def OnSuccess(result: string): void
    if trim(result) == ''
      ctx.Unlock()
      EchoWith('WarningMsg', MSG_NO_RESPONSE)
      return
    endif
    const new_lines = split(result, "\n", 1)
    ctx.Replace(new_lines)
    ApplyIndent(ctx)
    ctx.Unlock()
    EchoWith('MoreMsg', MSG_ASK_DONE)
  enddef

  def OnError(message: string): void
    ctx.Unlock()
    EchoWith('ErrorMsg', MSG_FAIL_PREFIX .. message)
  enddef

  CallAiAsync(full_prompt, system_prompt, OnSuccess, OnError)
enddef

const GrammarFix = GenerateReplacer(
  'Fix the grammar of the following text without changing meaning:',
  'You are a precise grammar correction model. Output only corrected text. Do not use markdown or code fences. Output raw text only.'
)
const AddComment = GenerateReplacer(
  'Add insightful comments to the following code to improve its readability:',
  'You are an expert programmer who writes clear and concise comments. Output only the code with added comments. Do not change the original code functionality. Do not use markdown or code fences. Output raw text only.'
)
const RefactorCode = GenerateReplacer(
  'Refactor the following code to improve its structure and readability without changing its functionality:',
  'You are an expert programmer who refactors code for better structure and readability. Output only the refactored code. Do not use markdown or code fences. Output raw text only.'
)

command! -range Fix          call GrammarFix(<line1>, <line2>)
command! -range Comment      call AddComment(<line1>, <line2>)
command! -range Refactor     call RefactorCode(<line1>, <line2>)
command! -range -nargs=+ Ask call AskAction(<line1>, <line2>, <q-args>)

defcompile

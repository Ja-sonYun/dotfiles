vim9script

import autoload 'utils/job.vim' as job

const DEFAULT_MODEL = 'openai/gpt-5.2-codex'
const DEFAULT_FORMAT = 'json'
const DEFAULT_AGENT = 'chat'

var running_jobs: list<any> = []

def BuildPrompt(prompt: string, opts: dict<any>): string
  const system_prompt = get(opts, 'system_prompt', '')
  if system_prompt == ''
    return prompt
  endif
  return system_prompt .. "\n\n" .. prompt
enddef

def BuildArgs(model: string, prompt: string, opts: dict<any>): list<string>
  var args = ['opencode', 'run']
  const resolved_model = model != '' ? model : get(g:, 'opencode_model', DEFAULT_MODEL)
  if resolved_model != ''
    add(args, '--model')
    add(args, resolved_model)
  endif
  const format = get(g:, 'opencode_format', DEFAULT_FORMAT)
  if format != ''
    add(args, '--format')
    add(args, format)
  endif
  const agent = get(g:, 'opencode_agent', DEFAULT_AGENT)
  if agent != ''
    add(args, '--agent')
    add(args, agent)
  endif
  const variant = get(g:, 'opencode_variant', '')
  if variant != ''
    add(args, '--variant')
    add(args, variant)
  endif
  const extra = get(g:, 'opencode_extra_args', [])
  if type(extra) == v:t_list
    extend(args, extra)
  endif
  add(args, BuildPrompt(prompt, opts))
  return args
enddef

def ExtractText(stdout: list<string>): string
  var out = ''
  for line in stdout
    if trim(line) == ''
      continue
    endif
    var obj: dict<any>
    try
      obj = json_decode(line)
    catch
      throw 'Failed to parse opencode JSON output.'
    endtry
    if get(obj, 'type', '') ==# 'text'
      const part = get(obj, 'part', {})
      if type(part) == v:t_dict && has_key(part, 'text')
        out ..= part.text
      endif
    endif
  endfor
  return out
enddef

def ParseResult(stdout: list<string>, stderr: list<string>, code: number): string
  if len(stderr) > 0
    throw join(stderr, "\n")
  endif
  if code != 0
    throw 'opencode failed with exit code ' .. string(code)
  endif
  const text = ExtractText(stdout)
  if text == ''
    throw 'No response returned.'
  endif
  return text
enddef

def RegisterJob(jb: any): void
  add(running_jobs, jb)
enddef

def UnregisterJob(jb: any): void
  const idx = index(running_jobs, jb)
  if idx >= 0
    remove(running_jobs, idx)
  endif
enddef

export def Call(
  model: string,
  prompt: string,
  opts: dict<any> = {}
): string
  const argv = BuildArgs(model, prompt, opts)
  const jb = job.Job.new(argv)
  jb.Start()
  jb.CloseIn()
  const res = jb.Join()
  return ParseResult(res.out, res.err, res.code)
enddef

export def CallAsync(
  model: string,
  prompt: string,
  cb: any,
  opts: dict<any> = {}
): void
  const argv = BuildArgs(model, prompt, opts)
  const err_cb = get(opts, 'err_cb', v:none)
  var jb: any
  jb = job.Job.new(argv, {
    done_cb: (stdout, stderr, code) => {
      try
        const text = ParseResult(stdout, stderr, code)
        call(cb, [text])
      catch
        const error_message = v:exception
        if type(err_cb) != v:t_none
          call(err_cb, [error_message])
        else
          echohl ErrorMsg
          echom error_message
          echohl None
        endif
      endtry
      UnregisterJob(jb)
    },
  })
  RegisterJob(jb)
  jb.Start()
  jb.CloseIn()
enddef

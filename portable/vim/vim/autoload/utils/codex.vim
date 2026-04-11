vim9script

import autoload 'utils/job.vim' as job

const DEFAULT_MODEL = 'gpt-5.4'

var running_jobs: list<any> = []

def BuildPrompt(prompt: string, opts: dict<any>): string
  const system_prompt = get(opts, 'system_prompt', '')
  if system_prompt == ''
    return prompt
  endif
  return system_prompt .. "\n\n" .. prompt
enddef

def BuildArgs(model: string, prompt: string, opts: dict<any>): list<string>
  var args = ['codex', 'exec', '--json']
  const resolved_model = model != '' ? model : get(g:, 'codex_model', DEFAULT_MODEL)
  if resolved_model != ''
    add(args, '--model')
    add(args, resolved_model)
  endif
  const extra = get(g:, 'codex_extra_args', [])
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
      throw 'Failed to parse codex JSON output.'
    endtry
    if get(obj, 'type', '') ==# 'item.completed'
      const item = get(obj, 'item', {})
      if type(item) == v:t_dict && has_key(item, 'text')
        out ..= item.text
      endif
    endif
  endfor
  return out
enddef

def ParseResult(stdout: list<string>, stderr: list<string>, code: number): string
  if code != 0
    # check JSONL for error events first
    for line in stdout
      if trim(line) == ''
        continue
      endif
      try
        const obj = json_decode(line)
        if get(obj, 'type', '') ==# 'error'
          throw get(obj, 'message', 'codex error')
        endif
      catch /Failed to parse/
        continue
      endtry
    endfor
    if len(stderr) > 0
      throw join(stderr, "\n")
    endif
    throw 'codex failed with exit code ' .. string(code)
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

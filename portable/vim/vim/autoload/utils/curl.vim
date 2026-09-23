vim9script

import autoload 'utils/job.vim' as job

export class Response
  var status: number = -1
  var headers: dict<string> = {}
  var body: string = ''
  var raw: list<string> = []
  var jobcode: number = -1

  def new(out: list<string>, err: list<string>, jobcode: number)
    this.raw = out
    this.jobcode = jobcode
    if empty(out)
      return
    endif

    var lines = copy(out)
    var i = 0
    while i < len(lines)
      if lines[i] =~# '^HTTP/'
        var parts = split(lines[i])
        if len(parts) >= 2
          this.status = str2nr(parts[1])
        endif
        this.headers = {}
        var has_location = false
        i += 1
        while i < len(lines) && lines[i] !~# '^\r\?$'
          var h = matchlist(lines[i], '^\([^:]\+\):\(.*\)$')
          if len(h) >= 3
            this.headers[trim(h[1])] = trim(h[2])
            if tolower(trim(h[1])) ==# 'location' && trim(h[2]) !=# ''
              has_location = true
            endif
          endif
          i += 1
        endwhile
        if i < len(lines) && lines[i] =~# '^\r\?$'
          i += 1
        endif
        var intermediate = (this.status >= 100 && this.status < 200 && this.status != 101)
          || (this.status >= 300 && this.status < 400 && has_location)
        if intermediate && i < len(lines) && lines[i] =~# '^HTTP/'
          continue
        endif
        this.body = join(lines[i :], "\n")
        break
      endif
      i += 1
    endwhile
  enddef

  def Body(): dict<any>
    try
      return json_decode(this.body)
    catch
      return {}
    endtry
  enddef
endclass


export class Request
  var job: any
  var url: string = ''
  var method: string = 'GET'
  var headers: dict<string> = {}
  var data: string = ''
  var jobopts: dict<any> = {}
  var done_cb: any = v:none
  var err_cb: any = v:none

  var _is_started: bool = false

  def new(url: string, opts: dict<any> = {})
    this.url = url
    this.method = get(opts, 'method', 'GET')
    this.headers = get(opts, 'headers', {})
    this.data = get(opts, 'data', '')
    this.jobopts = get(opts, 'jobopts', {})
    this.done_cb = get(opts, 'done_cb', v:none)
    this.err_cb = get(opts, 'err_cb', v:none)

    var argv: list<string> = [
      'curl', '-i', '-sSL', '--suppress-connect-headers', '-X', this.method, this.url,
    ]

    for [k, v] in items(this.headers)
      add(argv, '-H')
      add(argv, printf('%s: %s', k, v))
    endfor

    if this.data !=# ''
      add(argv, '-d')
      add(argv, this.data)
    endif

    var job_opts = copy(this.jobopts)
    job_opts.stream_cb = (ch: channel, msg: any, is_err: bool) => {
      if is_err && type(this.err_cb) != v:t_none
        call(this.err_cb, [msg])
      endif
    }
    job_opts.done_cb = (stdout: list<string>, stderr: list<string>, code: number) => {
      var resp = Response.new(stdout, stderr, code)
      if type(this.done_cb) != v:t_none
        call(this.done_cb, [resp])
      endif
    }

    this.job = job.Job.new(argv, job_opts)
  enddef

  def Start(): void
    if this._is_started
      throw 'Curl already started'
    endif
    this.job.Start()
    this._is_started = true
  enddef

  def Join(timeout_ms: number = -1): Response
    var res = this.job.Join(timeout_ms)
    return Response.new(res.out, res.err, res.code)
  enddef

  def WaitAsync(interval_ms: number = 50, cb: any = v:none): void
    this.job.WaitAsync(interval_ms, (stdout: list<string>, stderr: list<string>, code: number) => {
      timer_start(0, (_) => {
        const resp = this.Result()
        if type(cb) != v:t_none
          call(cb, [resp])
        endif
      })
    })
  enddef

  def Result(): Response
    var r = this.job.Result()
    return Response.new(r.out, r.err, r.code)
  enddef

  def IsRunning(): bool
    return this.job.IsRunning()
  enddef

  def Kill(): void
    this.job.Kill()
  enddef
endclass

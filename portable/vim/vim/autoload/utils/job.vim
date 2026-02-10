vim9script

export enum OutMode
  nl, raw, raw_esc
endenum

export enum Status
  none, run, fail, dead
endenum

export class Result
  var out: list<string> = []
  var err: list<string> = []
  var code: number = -1
endclass


export class Job
  var job: job

  var argv: list<string> = []
  var opt: dict<any> = {}

  var stdout: list<string> = []
  var stderr: list<string> = []
  var exit_code: number = -1

  var _is_started: bool = false
  var _stream_cb: any = v:none
  var _done_cb: any = v:none

  def new(argv: list<string>, opts: dict<any> = {})
    var buf = get(opts, 'buf', 0)
    var out_mode = get(opts, 'out_mode', OutMode.nl).name
    var env = get(opts, 'env', {})
    var cwd = get(opts, 'cwd', '')
    var timeout = get(opts, 'timeout', 0)

    this._stream_cb = get(opts, 'stream_cb', v:none)
    this._done_cb = get(opts, 'done_cb', v:none)

    var OutCb = (ch: channel, msg: any) => this._OnStream(ch, msg, false)
    var ErrCb = (ch: channel, msg: any) => this._OnStream(ch, msg, true)
    var opt: dict<any> = {
      in_io: 'pipe',
      err_io: 'pipe',
      err_mode: out_mode,
      err_cb: ErrCb,
      exit_cb: this._OnExit,
      noblock: 1,
      env: env,
    }
    if cwd !=# ''
      opt.cwd = cwd
    endif
    if timeout > 0
      opt.timeout = timeout
    endif
    if buf > 0
      opt.out_io = 'buffer'
      opt.out_buf = buf
      if out_mode !=# 'nl'
        opt.out_mode = out_mode
      endif
    else
      opt.out_io = 'pipe'
      opt.out_mode = out_mode
      opt.out_cb = OutCb
    endif

    this.argv = argv
    this.opt = opt
  enddef

  def Start(): void
    if this._is_started
      throw 'Job already started'
    endif
    this.job = job_start(this.argv, this.opt)
    this._is_started = true
  enddef

  def Status(): Status
    if !this._is_started
      return Status.none
    endif
    var s = job_status(this.job)
    if s ==# 'run'
      return Status.run
    elseif s ==# 'fail'
      return Status.fail
    else
      return Status.dead
    endif
  enddef

  # Method that need the job to be started

  def Kill(): void
    this._GuardStarted()
    if this.IsRunning()
      job_stop(this.job)
    endif
  enddef

  def IsRunning(): bool
    this._GuardStarted()
    return this.Status() ==# Status.run
  enddef

  def Stdin(data: string): void
    this._GuardStarted()
    ch_sendraw(job_getchannel(this.job), data)
  enddef

  def Clear(): void
    this._GuardStarted()
    this.stdout = []
    this.stderr = []
    this.exit_code = -1
  enddef

  def Result(): Result
    this._GuardStarted()
    return Result.new(this.stdout, this.stderr, this.exit_code)
  enddef

  def Join(timeout_ms: number = -1): Result
    this._GuardStarted()
    var t0 = reltime()
    while this.IsRunning()
      if timeout_ms >= 0 && reltimefloat(reltime(t0)) * 1000.0 > timeout_ms
        throw 'Join timeout'
      endif
      sleep 10m
    endwhile
    return this.Result()
  enddef

  def WaitAsync(interval_ms: number = 50, cb: any = v:none): void
    this._GuardStarted()
    var self = this
    var timer_id = timer_start(interval_ms, (_) => {
      if self.IsRunning()
        timer_start(interval_ms, (_) => self.WaitAsync(interval_ms, cb))
      else
        if type(cb) != v:t_none
          call(cb, [self.stdout, self.stderr, self.exit_code])
        endif
      endif
    })
  enddef

  def CloseIn(): void
    this._GuardStarted()
    ch_close_in(job_getchannel(this.job))
  enddef

  # Private methods

  def _GuardStarted(): bool
    if !this._is_started
      throw 'Job not started'
    endif
    return true
  enddef

  def _OnStream(ch: channel, msg: any, is_err: bool): void
    var lines: list<string>
    if type(msg) == v:t_list
      lines = msg
    else
      lines = [msg]
    endif
    if is_err
      extend(this.stderr, lines)
    else
      extend(this.stdout, lines)
    endif
    if type(this._stream_cb) != v:t_none
      try
        call(this._stream_cb, [ch, lines, is_err])
      catch
      endtry
    endif
  enddef

  def _OnExit(jb: job, code: number): void
    this.exit_code = code
    if type(this._done_cb) != v:t_none
      timer_start(0, (_) => call(this._done_cb, [this.stdout, this.stderr, code]))
    endif
  enddef

  def _CallIfFunc(F: any, args: list<any>): void
    if type(F) != v:t_none
      try
        call(F, args)
      catch
      endtry
    endif
  enddef
endclass

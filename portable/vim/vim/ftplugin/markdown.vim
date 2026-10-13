if exists("b:did_user_ftplugin")
  finish
endif
let b:did_user_ftplugin = 1

let b:indent = 2
let b:autorel = 1
let b:trimtrail = v:false

if has('mac')
  function! MarkdownPreviewOpenBrowser(url) abort
    call timer_start(1000, { _ -> job_start(['/usr/bin/open', a:url]) })
  endfunction

  let g:mkdp_browserfunc = 'MarkdownPreviewOpenBrowser'
endif

Formatter prettier

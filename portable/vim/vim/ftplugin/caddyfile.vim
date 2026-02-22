if exists("b:did_user_ftplugin")
  finish
endif
let b:did_user_ftplugin = 1

setlocal commentstring=#\ %s

let b:indent = 2
let b:autorel = 1
let b:trimtrail = v:true

if exists("b:did_user_ftplugin")
  finish
endif
let b:did_user_ftplugin = 1

let b:indent = 4
let b:usetab = v:true
let b:autorel = 1
let b:trimtrail = v:true

Formatter gofmt

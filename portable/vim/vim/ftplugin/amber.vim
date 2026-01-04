" Modified from: https://github.com/amber-lang/amber-vim/blob/main/ftplugin/amber.vim

if exists("b:did_user_ftplugin")
    finish
endif
let b:did_user_ftplugin = 1

let b:indent = 4
let b:autorel = 1
let b:trimtrail = v:true

" Enable smart indentation, so we indent on line after "{".
setlocal smartindent

" Continue inline or documentation comments on next line.
setlocal formatoptions+=ro
setlocal comments=:///,://

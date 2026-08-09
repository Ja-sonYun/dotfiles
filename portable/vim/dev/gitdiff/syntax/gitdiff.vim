if exists('b:current_syntax')
  finish
endif

syntax match GitDiffHeader /^Git diff .*/
syntax match GitDiffCount /^Files changed (\d\+)$/
syntax match GitDiffCurrent /^>/
syntax match GitDiffAdded /+\(\d\+\|-\)/
syntax match GitDiffDeleted /-\(\d\+\|-\)/
syntax match GitDiffStatusAdded /\sA\s\s/
syntax match GitDiffStatusDeleted /\sD\s\s/
syntax match GitDiffStatusChanged /\sM\s\s/
syntax match GitDiffStatusRenamed /\s[RC]\s\s/

highlight default link GitDiffHeader Title
highlight default link GitDiffCount Comment
highlight default link GitDiffCurrent CursorLineNr
highlight default link GitDiffAdded GitGutterAdd
highlight default link GitDiffDeleted GitGutterDelete
highlight default link GitDiffStatusAdded GitGutterAdd
highlight default link GitDiffStatusDeleted GitGutterDelete
highlight default link GitDiffStatusChanged GitGutterChange
highlight default link GitDiffStatusRenamed Identifier

let b:current_syntax = 'gitdiff'

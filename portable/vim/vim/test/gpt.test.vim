vim9script
# Run: vim -Nu NONE -n -i NONE -es -S portable/vim/vim/test/gpt.test.vim

set nocompatible
set nomore
const root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. fnameescape(root)

import autoload 'utils/gpt.vim' as gpt
import autoload 'test/testutil.vim' as testutil

def CallSyncNoKey(): void
  gpt.Call('gpt-5', 'hello')
enddef

def CallToolNoKey(): void
  gpt.CallTool('gpt-5', 'tool', 'prompt', {'type': 'object'})
enddef

var patterns = ['OpenAI API key', 'Job not started']
testutil.ExpectError('call sync no key', CallSyncNoKey, patterns)
testutil.ExpectError('call tool no key', CallToolNoKey, patterns)
testutil.AssertTrue('CallAsync exported', type(gpt.CallAsync) == v:t_func)
testutil.AssertTrue('CallToolAsync exported', type(gpt.CallToolAsync) == v:t_func)

testutil.QuitWithCheck('gpt.test')

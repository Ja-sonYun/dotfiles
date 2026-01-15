vim9script
# Run: vim -Nu NONE -n -i NONE -es -S portable/vim/vim/test/timeit.test.vim

set nocompatible
set nomore
const root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. fnameescape(root)

import autoload 'utils/timeit.vim' as timeit
import autoload 'test/testutil.vim' as testutil

var total = 0

def Add(n: number): void
  total += n
enddef

timeit.TimeIt(Add, 2)
testutil.AssertEqual('add value', 2, total)

testutil.QuitWithCheck('timeit.test')

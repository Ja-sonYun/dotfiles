vim9script
# Run: vim -Nu NONE -n -i NONE -es -S portable/vim/vim/test/dict.test.vim

set nocompatible
set nomore
const root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. fnameescape(root)

import autoload 'utils/dict.vim' as dict
import autoload 'test/testutil.vim' as testutil

var base = {a: 1, b: {c: 2}}
var next = {b: {d: 3}, e: 4}
var res = dict.DeepMerge(base, next)

testutil.AssertEqual('merge a', 1, res.a)
testutil.AssertEqual('merge b.c', 2, res.b.c)
testutil.AssertEqual('merge b.d', 3, res.b.d)
testutil.AssertEqual('merge e', 4, res.e)

next.b.d = 9
testutil.AssertEqual('deepcopy', 3, res.b.d)

testutil.QuitWithCheck('dict.test')

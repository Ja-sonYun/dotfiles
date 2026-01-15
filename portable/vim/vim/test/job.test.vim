vim9script
# Run: vim -Nu NONE -n -i NONE -es -S portable/vim/vim/test/job.test.vim

set nocompatible
set nomore
const root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. fnameescape(root)

import autoload 'utils/job.vim' as job
import autoload 'test/testutil.vim' as testutil

var j = job.Job.new(['/bin/sh', '-c', 'printf "hello\n"'])
j.Start()
var res = j.Join(1000)
testutil.AssertEqual('exit code', 0, res.code)
testutil.AssertTrue('stdout has line', len(res.out) >= 1)
testutil.AssertEqual('stdout first line', 'hello', res.out[0])
testutil.AssertEqual('status dead', job.Status.dead, j.Status())

testutil.QuitWithCheck('job.test')

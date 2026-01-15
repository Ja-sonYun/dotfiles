vim9script
# Run: vim -Nu NONE -n -i NONE -es -S portable/vim/vim/test/path.test.vim

set nocompatible
set nomore
const root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. fnameescape(root)

import autoload 'utils/path.vim' as path
import autoload 'test/testutil.vim' as testutil

var quoted = path.Path.new('"foo"')
testutil.AssertEqual('strip quotes', 'foo', quoted.String())

var base = path.Path.Temp('dir')
base.Mkdir(true)
testutil.AssertTrue('mkdir', base.IsDir())

var file = base.Join('sample.txt')
file.WriteText("hello\nworld")
testutil.AssertTrue('write file', file.IsFile())
testutil.AssertEqual('read text', "hello\nworld", file.ReadText())

var renamed = file.WithName('renamed.txt')
file.Rename(renamed)
testutil.AssertTrue('rename exists', file.Exists())
testutil.AssertEqual('name', 'renamed.txt', file.Name())
testutil.AssertEqual('suffix', 'txt', file.Suffix())
testutil.AssertEqual('stem', 'renamed', file.Stem())

var rel = file.RelativeTo(base)
testutil.AssertEqual('relative', 'renamed.txt', rel.String())

var joined = base.Join([1, 2])
testutil.AssertEqual('join list', base.String() .. '/1/2', joined.String())

var posix = path.Path.new('C:\tmp\file').AsPosix()
testutil.AssertEqual('posix', 'C:/tmp/file', posix)


file.Remove()
base.Rmdir()

testutil.QuitWithCheck('path.test')

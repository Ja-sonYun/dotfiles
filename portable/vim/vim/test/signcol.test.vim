vim9script
# Run: vim -Nu NONE -n -i NONE -es -S portable/vim/vim/test/signcol.test.vim
# Visual: vim -Nu NONE -n -i NONE -S portable/vim/vim/test/signcol.test.vim -c 'let g:signcol_visual=1'

set nocompatible
set nomore
set number
set cursorline
set signcolumn=yes
const root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. fnameescape(root)

import autoload 'utils/signcol.vim' as signcol
import autoload 'test/testutil.vim' as testutil

class TestSpec extends signcol.Spec
  def new(kind: string, text: string, texthl: string)
    this.kind = kind
    this.text = text
    this.texthl = texthl
  enddef
endclass

class TestItem extends signcol.Item
  def new(kind: string, lnum: number)
    this.kind = kind
    this.lnum = lnum
  enddef
endclass

def SignCount(buf: number, group: string): number
  var res = sign_getplaced(buf, { group: group })
  if empty(res)
    return 0
  endif
  return len(get(res[0], 'signs', []))
enddef

var sc: signcol.SignCol

def Stage2(): void
  var item3 = TestItem.new('err', 999)
  sc.Update(bufnr('%'), [item3])
  testutil.AssertEqual('stage2 count', 1, SignCount(bufnr('%'), 'TestGroup'))
  var placed = sign_getplaced(bufnr('%'), { group: 'TestGroup' })
  testutil.AssertEqual('stage2 clamp', 4, get(placed[0].signs[0], 'lnum', 0))
  testutil.Log('Stage2: moved to line 4')
enddef

def Stage3(): void
  sc.Clear(bufnr('%'))
  testutil.AssertEqual('stage3 cleared', 0, SignCount(bufnr('%'), 'TestGroup'))
  testutil.Log('Stage3: cleared')
enddef


new
setlocal buftype=nofile bufhidden=wipe noswapfile
setline(1, ['one', 'two', 'three', 'four'])

var specErr = TestSpec.new('err', 'E', 'ErrorMsg')
var specWarn = TestSpec.new('warn', 'W', 'WarningMsg')

sc = signcol.SignCol.new('TestGroup', [specErr, specWarn])

var item1 = TestItem.new('err', 2)
var item2 = TestItem.new('warn', 4)

sc.Update(bufnr('%'), [item1, item2])
testutil.AssertEqual('stage1 count', 2, SignCount(bufnr('%'), 'TestGroup'))

var st1 = sc.Status(bufnr('%'))
testutil.AssertEqual('stage1 status', 2, st1.placed)

if exists('g:signcol_visual')
  nnoremap <buffer> n <ScriptCmd>Stage2()<CR>
  nnoremap <buffer> c <ScriptCmd>Stage3()<CR>
  nnoremap <buffer> q <ScriptCmd>testutil.QuitWithCheck('signcol.test')<CR>
  echo 'Stage1: n=update, c=clear, q=quit'
  finish
endif

Stage2()
Stage3()
testutil.QuitWithCheck('signcol.test')

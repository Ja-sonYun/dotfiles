vim9script
# Run: vim -Nu NONE -n -i NONE -es -S portable/vim/vim/test/curl.test.vim

set nocompatible
set nomore
const root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. fnameescape(root)

import autoload 'utils/curl.vim' as curl
import autoload 'test/testutil.vim' as testutil

var lines = [
  'HTTP/1.1 200 OK',
  'Content-Type: application/json',
  'X-Test: ok',
  '',
  '{"ok":true}',
]
var resp = curl.Response.new(lines, [], 0)
testutil.AssertEqual('status', 200, resp.status)
testutil.AssertEqual('content-type', 'application/json', resp.headers['Content-Type'])
testutil.AssertEqual('x-test', 'ok', resp.headers['X-Test'])
testutil.AssertEqual('json ok', v:true, resp.Body().ok)

var bad = curl.Response.new(['HTTP/1.1 204 No Content', '', ''], [], 0)
testutil.AssertEqual('empty body', {}, bad.Body())

testutil.QuitWithCheck('curl.test')

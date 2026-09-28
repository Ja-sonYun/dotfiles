" Vim syntax file
" Language:     Python (Enhanced with Type Annotations)
" Maintainer:   Aaron Carlisle
" Based on:     Vim's syntax/python.vim by Zvezdan Petkovic, Neil Schemenauer
"               and Dmitry Vasiliev
" Last Change:  2026 Sep 26
" Version:      1.1.0
"
" Description:
"   Enhanced Python syntax highlighting with type expressions colored only
"   inside real annotation contexts (parameters, returns, assignments, bases,
"   PEP 695 type parameters / type aliases).
"
" Configuration Options:
"   let g:python_enhanced_highlight_all = 1
"   let g:python_highlight_type_annotations = 1
"   let g:python_highlight_operators = 1
"   let g:python_highlight_func_calls = 0
"   let g:python_highlight_class_vars = 1
"   let g:python_highlight_builtins = 1
"   let g:python_highlight_exceptions = 1
"   let g:python_highlight_string_formatting = 1
"   let g:python_highlight_doctests = 1
"   let g:python_highlight_space_errors = 0
"   let g:python_slow_sync = 0
"   let g:python_enhanced_colors = 0   " 1 = built-in palette

if exists("b:current_syntax")
  finish
endif

let s:cpo_save = &cpo
set cpo&vim

" ============================================================================
" Configuration
" ============================================================================

" highlight_all turns on every option except space errors
let s:all = get(g:, 'python_enhanced_highlight_all', 0) || get(g:, 'python_highlight_all', 0)

let s:type_annotations = s:all || get(g:, 'python_highlight_type_annotations', 1)
let s:operators = s:all || get(g:, 'python_highlight_operators', 1)
let s:func_calls = s:all || get(g:, 'python_highlight_func_calls', 0)
let s:class_vars = s:all || get(g:, 'python_highlight_class_vars', 1)
let s:builtins = s:all || get(g:, 'python_highlight_builtins', 1)
let s:exceptions = s:all || get(g:, 'python_highlight_exceptions', 1)
let s:string_fmt = s:all || get(g:, 'python_highlight_string_formatting', 1)
let s:doctests = s:all || get(g:, 'python_highlight_doctests', 1)
let s:space_errors = get(g:, 'python_highlight_space_errors', 0)
let s:slow_sync = get(g:, 'python_slow_sync', 0)

" ============================================================================
" Keywords and Statements
" ============================================================================

syn keyword pythonStatement     False None True
syn keyword pythonStatement     as assert break continue del global
syn keyword pythonStatement     lambda nonlocal pass return with yield
syn keyword pythonStatement     class nextgroup=pythonClass skipwhite
syn keyword pythonStatement     def nextgroup=pythonFunction skipwhite
syn keyword pythonConditional   elif else if
syn keyword pythonRepeat        for while
syn keyword pythonOperator      and in is not or
syn keyword pythonException     finally raise try
" except and except* as one exception item (Python 3.11+)
" (\> cannot follow *, so the star is its own alternative)
syn match   pythonException     "\<except\%(\*\|\>\)" display
syn keyword pythonInclude       from import
syn keyword pythonAsync         async await

" Soft keywords (Python 3.10+ match/case)
syn match   pythonConditional   "^\s*\zscase\%(\s\+.*:.*$\)\@="
syn match   pythonConditional   "^\s*\zsmatch\%(\s\+.*:\s*\%(#.*\)\=$\)\@="

" PEP 695 type statement: type Name[...] = ...
" (builtin type() call is handled separately below)
syn match   pythonStatement     "\<type\ze\s\+\h\w*" nextgroup=pythonTypeAlias skipwhite

" Class, function, and type alias names
" No 'display': these start nextgroup chains (-> header colon -> docstring on
" the next line) that are lost when Vim skips display items off-screen.
syn match   pythonClass         "\h\w*" contained
      \ nextgroup=pythonTypeParamList,pythonClassBases,pythonDefColon skipwhite
syn match   pythonFunction      "\h\w*" contained
      \ nextgroup=pythonTypeParamList,pythonParamList skipwhite
syn match   pythonTypeAlias     "\h\w*" contained
      \ nextgroup=pythonTypeParamList,pythonTypeAliasEq skipwhite

" Header colon after def/class -> docstring via nextgroup (not lookbehind)
" skipnl: docstring is almost always on the following line after def/class :
syn match   pythonDefColon      ":" contained
      \ nextgroup=pythonDocstring,pythonDefComment skipwhite skipempty skipnl
" Comments between the header colon and the docstring keep the chain alive
syn match   pythonDefComment    "#.*$" contained contains=pythonTodo,@Spell
      \ nextgroup=pythonDocstring,pythonDefComment skipwhite skipempty skipnl

" ============================================================================
" Type expression cluster (only used inside annotation regions)
" ============================================================================

if s:type_annotations
  " Contained typing names (annotation contexts only)
  syn keyword pythonTypingType contained
        \ Any AnyStr
        \ Annotated
        \ Callable ClassVar Concatenate
        \ Final ForwardRef
        \ Generic
        \ Literal LiteralString
        \ Never NewType NoReturn NotRequired
        \ Optional
        \ ParamSpec ParamSpecArgs ParamSpecKwargs Protocol
        \ ReadOnly Required
        \ Self
        \ Tuple Type TypeAlias TypeGuard TypeIs TypeVar TypeVarTuple
        \ Union Unpack
        \ Awaitable Coroutine AsyncIterable AsyncIterator AsyncGenerator
        \ Iterable Iterator Generator
        \ Reversible Container Collection
        \ Hashable Sized
        \ Mapping MutableMapping
        \ Sequence MutableSequence
        \ AbstractSet MutableSet
        \ MappingView KeysView ItemsView ValuesView
        \ ContextManager AsyncContextManager
        \ Pattern Match
        \ IO TextIO BinaryIO
        \ NamedTuple TypedDict
        \ SupportsInt SupportsFloat SupportsComplex SupportsBytes
        \ SupportsAbs SupportsRound SupportsIndex
        \ List Dict Set FrozenSet
        \ Deque DefaultDict OrderedDict Counter ChainMap

  " Builtin primitives as types (only inside annotations)
  syn keyword pythonPrimitiveType contained
        \ str int float bool bytes bytearray
        \ list dict set frozenset tuple
        \ object type complex
        \ memoryview range slice

  " None and Ellipsis inside types
  syn keyword pythonTypeNone    None contained
  syn match   pythonTypeEllipsis "\.\.\." contained

  " Union pipe only inside type regions
  syn match   pythonTypeUnion   "|" contained

  " Commas inside type expressions (e.g. dict[str, int])
  syn match   pythonTypeComma   "," contained

  " Dotted type names: collections.abc.Sequence
  syn match   pythonTypeDotted  "\h\w*\%(\.\h\w*\)\+" contained
        \ contains=pythonTypingType,pythonPrimitiveType

  " CapWords / aliases / TypeVars / user types
  syn match   pythonTypeName    "\h\w*" contained

  " Quoted forward references
  syn region  pythonTypeString  start=+[uUrR]\=\z(['"]\)+ end="\z1" skip="\\\\\|\\\z1"
        \ contained contains=NONE

  " Nested brackets and parentheses inside type expressions
  syn region  pythonTypeBracket matchgroup=pythonTypeBracket
        \ start="\[" end="\]" contained
        \ contains=@pythonTypeExpr
  syn region  pythonTypeParen matchgroup=pythonTypeBracket
        \ start="(" end=")" contained
        \ contains=@pythonTypeExpr

  " Include pythonComment so trailing notes (# ...) stay comments, not type names
  syn cluster pythonTypeExpr contains=
        \ pythonPrimitiveType,pythonTypingType,pythonTypeName,pythonTypeDotted,
        \ pythonTypeUnion,pythonTypeBracket,pythonTypeParen,pythonTypeComma,
        \ pythonTypeEllipsis,pythonTypeNone,pythonTypeString,pythonComment

  " -------------------------------------------------------------------------
  " Brackets: continuation lines inside (...) [...] {...} are expressions, so
  " `key: value` in a multi-line dict/call is never a statement annotation.
  " Defined before the lookbehind regions below (param lists, class bases,
  " type params) so those still win when they start at the same bracket.
  " -------------------------------------------------------------------------
  syn region  pythonBracketBlock start="(" end=")" transparent
        \ contains=TOP,pythonAnnotatedAssign,pythonAnnotatedAttr
  syn region  pythonBracketBlock start="\[" end="\]" transparent
        \ contains=TOP,pythonAnnotatedAssign,pythonAnnotatedAttr
  syn region  pythonBracketBlock start="{" end="}" transparent
        \ contains=TOP,pythonAnnotatedAssign,pythonAnnotatedAttr

  " -------------------------------------------------------------------------
  " PEP 695 type parameter lists: def f[T], class C[T], type A[T]
  " -------------------------------------------------------------------------
  syn region  pythonTypeParamList matchgroup=pythonTypeBracket
        \ start="\%(\%(\%(async\s\+\)\=def\|class\|type\)\s\+\h\w*\s*\)\@<=\["
        \ end="\]"
        \ contains=@pythonTypeExpr,pythonTypeParamStar
        \ nextgroup=pythonParamList,pythonClassBases,pythonTypeAliasEq,pythonDefColon
        \ skipwhite skipnl

  syn match   pythonTypeParamStar "[*]\{1,2}" contained nextgroup=pythonTypeName skipwhite

  " -------------------------------------------------------------------------
  " Parameter lists after def / async def (lookbehind so sync cannot drop them)
  " Brackets in defaults (x=f(1, 2), x={"k": v}) are pythonBracketBlock, so
  " their ) , and : cannot end the list or start an annotation.
  " -------------------------------------------------------------------------
  syn region  pythonParamList matchgroup=pythonParams
        \ start="\%(\%(async\s\+\)\=def\s\+\h\w*\%(\s*\[[^[\]]*\]\)\=\s*\)\@<=("
        \ end=")"
        \ contains=pythonBracketBlock,pythonParamAnnotation,pythonParamLambda,
        \          pythonClassVar,pythonBuiltin,pythonNumber,pythonString,
        \          pythonRawString,pythonFString,pythonBytes,pythonOperatorSymbol,
        \          pythonComment,pythonEllipsis,@Spell
        \ nextgroup=pythonReturnType,pythonDefColon
        \ skipwhite skipnl

  " : annotation inside params — ends at top-level = , or )
  " Nested [...] / (...) are contained and consume internal commas.
  syn region  pythonParamAnnotation matchgroup=pythonTypeColon
        \ start=":" end="\ze\%(\s*\%(=\|,\|)\)\)" contained
        \ contains=@pythonTypeExpr

  " key=lambda x: ...  -- the lambda's colon is not an annotation
  syn region  pythonParamLambda matchgroup=pythonStatement
        \ start="\<lambda\>" matchgroup=NONE end=":" contained oneline
        \ contains=pythonBracketBlock,pythonNumber,pythonString,pythonOperatorSymbol

  " -------------------------------------------------------------------------
  " Return type: -> through header : (not contained — any -> … : is a return type)
  " -------------------------------------------------------------------------
  syn region  pythonReturnType matchgroup=pythonReturnArrow
        \ start="->" end="\ze\s*:"
        \ contains=@pythonTypeExpr
        \ nextgroup=pythonDefColon
        \ skipwhite skipnl

  " Always color -> as return arrow (never as operator)
  syn match   pythonReturnArrow "->" display

  " -------------------------------------------------------------------------
  " Class bases: class Foo(Bar, Generic[T])
  " -------------------------------------------------------------------------
  syn region  pythonClassBases matchgroup=pythonParams
        \ start="\%(class\s\+\h\w*\%(\s*\[[^[\]]*\]\)\=\s*\)\@<=("
        \ end=")"
        \ contains=@pythonTypeExpr,pythonClassBases,pythonComment
        \ nextgroup=pythonDefColon
        \ skipwhite skipnl

  " -------------------------------------------------------------------------
  " Statement annotations: name: Type [= ...]  (self.attr: Type is below,
  " after pythonAttribute)
  " Exclude control-flow keywords
  " -------------------------------------------------------------------------
  syn match   pythonAnnotatedAssign
        \ "^\s*\%(\%(\%(async\s\+\)\=def\|class\|if\|elif\|else\|while\|for\|with\|try\|except\|match\|case\|type\|return\|yield\|assert\|del\|global\|nonlocal\|import\|from\|raise\|pass\|break\|continue\|await\)\>\)\@!\zs\h\w*\%(\s*,\s*\h\w*\)*\s*\ze:"
        \ nextgroup=pythonStmtAnnotation
        \ skipwhite

  syn region  pythonStmtAnnotation matchgroup=pythonTypeColon
        \ start=":"
        \ end="\ze\%(\s*=\|\s*#\|$\)"
        \ contained
        \ contains=@pythonTypeExpr
        \ oneline

  " -------------------------------------------------------------------------
  " type Alias = ...  RHS is a type expression
  " -------------------------------------------------------------------------
  syn match   pythonTypeAliasEq "=" contained
        \ nextgroup=pythonTypeAliasValue skipwhite

  syn region  pythonTypeAliasValue
        \ start="\ze\S"
        \ end="$"
        \ contained
        \ contains=@pythonTypeExpr,pythonComment
        \ oneline

  " -------------------------------------------------------------------------
  " Type comments: # type: ...  (inside pythonComment; not "# type: ignore")
  " -------------------------------------------------------------------------
  syn match   pythonTypeComment "\%(#\s*type:\s*\)\@<=\%(ignore\>\)\@!\S.*$"
        \ contained contains=@pythonTypeExpr

endif

" Contained helpers that only make sense via nextgroup / annotation regions.
" Anything using contains=ALLBUT must exclude these, or e.g.
" pythonTypeAliasValue (start at any \S) swallows the rest of the line.
syn cluster pythonTypeInternal contains=
      \ pythonTypingType,pythonPrimitiveType,pythonTypeNone,pythonTypeEllipsis,
      \ pythonTypeUnion,pythonTypeComma,pythonTypeDotted,pythonTypeName,
      \ pythonTypeString,pythonTypeBracket,pythonTypeParen,pythonTypeParamStar,
      \ pythonParamAnnotation,pythonParamLambda,pythonStmtAnnotation,
      \ pythonTypeAliasEq,pythonTypeAliasValue,pythonTypeComment,
      \ pythonDefColon,pythonDefComment,pythonDocstring

" ============================================================================
" Class Variables (self, cls, mcs)
" ============================================================================

if s:class_vars
  syn keyword pythonClassVar    self cls mcs
endif

" ============================================================================
" Operators — | is bitwise here (union only inside type regions)
" ============================================================================

if s:operators
  " One character at a time: runs like **= or //= look the same as a single
  " match, and a character class is much cheaper than a long alternation.
  syn match pythonOperatorSymbol "[-+*/%@<>=~&|^]\|!=\|:=" display
endif

" ============================================================================
" Function Calls
" ============================================================================

if s:func_calls
  syn match   pythonFunctionCall "\h\w*\ze\s*(" display
        \ contains=pythonBuiltin
endif

" ============================================================================
" Decorators
" ============================================================================

syn match   pythonDecorator     "@" display contained
syn match   pythonDecoratorName "@\s*\h\%(\w\|\.\)*" display contains=pythonDecorator

" Lookbehind: consuming a ) or ] here would hide it from pythonBracketBlock's end
syn match   pythonMatrixMultiply
      \ "\%(\w\|[])]\)\@1<=\s*@"
      \ contains=TOP,pythonDecoratorName
      \ transparent

" ============================================================================
" Comments
" ============================================================================

syn match   pythonComment       "#.*$" contains=pythonTodo,pythonTypeComment,@Spell
syn keyword pythonTodo          FIXME NOTE NOTES TODO XXX HACK BUG OPTIMIZE REVIEW contained

" ============================================================================
" Expression cluster for f-string fields (narrow; not ALLBUT)
" ============================================================================

syn cluster pythonExpression contains=
      \ pythonStatement,pythonConditional,pythonRepeat,pythonAsync,
      \ pythonAttribute,pythonFunctionCall,
      \ pythonBuiltin,pythonNumber,pythonNone,pythonEllipsis,
      \ pythonString,pythonRawString,pythonFString,pythonBytes,
      \ pythonOperatorSymbol,pythonOperator,pythonClassVar,
      \ pythonComment,pythonDecoratorName,pythonExceptions,
      \ pythonFStringFieldSkip,pythonFStringDebug

" ============================================================================
" Strings
" ============================================================================

syn region  pythonString matchgroup=pythonQuotes
      \ start=+[uU]\=\z(['"]\)+ end="\z1" skip="\\\\\|\\\z1"
      \ contains=pythonEscape,pythonUnicodeEscape,@Spell

syn region  pythonString matchgroup=pythonTripleQuotes
      \ start=+[uU]\=\z('''\|"""\)+ end="\z1" keepend
      \ contains=pythonEscape,pythonUnicodeEscape,pythonSpaceError,pythonDoctest,@Spell

syn region  pythonRawString matchgroup=pythonQuotes
      \ start=+[rR]\z(['"]\)+ end="\z1" skip="\\\\\|\\\z1"
      \ contains=@Spell
syn region  pythonRawString matchgroup=pythonTripleQuotes
      \ start=+[rR]\z('''\|"""\)+ end="\z1" keepend
      \ contains=pythonSpaceError,pythonDoctest,@Spell

syn region  pythonFString matchgroup=pythonQuotes
      \ start=+\c[fF]\z(['"]\)+
      \ end="\z1"
      \ skip="\\\\\|\\\z1"
      \ contains=pythonFStringField,pythonFStringSkip,pythonEscape,pythonUnicodeEscape,@Spell

syn region  pythonFString matchgroup=pythonTripleQuotes
      \ start=+\c[fF]\z('''\|"""\)+
      \ end="\z1"
      \ keepend
      \ contains=pythonFStringField,pythonFStringSkip,pythonEscape,pythonUnicodeEscape,pythonSpaceError,pythonDoctest,@Spell

syn region  pythonRawFString matchgroup=pythonQuotes
      \ start=+\c\%(FR\|RF\)\z(['"]\)+
      \ end="\z1"
      \ skip="\\\\\|\\\z1"
      \ contains=pythonFStringField,pythonFStringSkip,@Spell

syn region  pythonRawFString matchgroup=pythonTripleQuotes
      \ start=+\c\%(FR\|RF\)\z('''\|"""\)+
      \ end="\z1"
      \ keepend
      \ contains=pythonFStringField,pythonFStringSkip,pythonSpaceError,pythonDoctest,@Spell

syn region  pythonBytes matchgroup=pythonQuotes
      \ start=+\c[bB]\z(['"]\)+
      \ end="\z1"
      \ skip="\\\\\|\\\z1"
      \ contains=pythonBytesEscape

syn region  pythonBytes matchgroup=pythonTripleQuotes
      \ start=+\c[bB]\z('''\|"""\)+
      \ end="\z1"
      \ keepend
      \ contains=pythonBytesEscape

syn region  pythonRawBytes matchgroup=pythonQuotes
      \ start=+\c\%(BR\|RB\)\z(['"]\)+
      \ end="\z1"
      \ skip="\\\\\|\\\z1"

syn region  pythonRawBytes matchgroup=pythonTripleQuotes
      \ start=+\c\%(BR\|RB\)\z('''\|"""\)+
      \ end="\z1"
      \ keepend

" F-string fields — explicit expression cluster (not ALLBUT)
syn region  pythonFStringField
      \ matchgroup=pythonFStringDelimiter
      \ start=/{/
      \ end=/\%(=\s*\)\=\%(!\a\s*\)\=\%(:\%({\_[^}]*}\|[^{}]*\)\+\)\=}/
      \ contained
      \ contains=@pythonExpression

syn match   pythonFStringFieldSkip  /(\_[^()]*)\|\[\_[^][]*]\|{\_[^{}]*}/
      \ contained
      \ contains=@pythonExpression

syn match   pythonFStringSkip       /{{/ transparent contained contains=NONE
syn match   pythonFStringSkip       /}}/ transparent contained contains=NONE

" F-string debug specifier: f"{expr=}"
syn match   pythonFStringDebug      /\h\w*=\ze[}:!]/ contained containedin=pythonFStringField

" ============================================================================
" Docstrings (nextgroup after header colon + module docstring)
" ============================================================================

" Function/class docstrings (triggered via nextgroup=pythonDocstring)
syn region  pythonDocstring
      \ start=+[rRuU]\=\z('''\|"""\)+ end="\z1" keepend contained
      \ contains=pythonEscape,pythonUnicodeEscape,pythonSpaceError,pythonDoctest,@Spell

" Module docstring at top of file
syn region  pythonDocstring
      \ start=+\%^\%(\s*#.*\n\|\s*\n\)*\s*\zs[rRuU]\=\z('''\|"""\)+
      \ end="\z1" keepend
      \ contains=pythonEscape,pythonUnicodeEscape,pythonSpaceError,pythonDoctest,@Spell

" ============================================================================
" String Escapes
" ============================================================================

syn match   pythonEscape            +\\[abfnrtv'"\\]+ contained
syn match   pythonEscape            "\\\o\{1,3}" contained
syn match   pythonEscape            "\\x\x\{2}" contained
syn match   pythonUnicodeEscape     "\%(\\u\x\{4}\|\\U\x\{8}\)" contained
syn match   pythonUnicodeEscape     "\\N{\a\+\%(\%(\s\a\+[[:alnum:]]*\)\|\%(-[[:alnum:]]\+\)\)*}" contained
syn match   pythonEscape            "\\$"

syn match   pythonBytesEscape       +\\[abfnrtv'"\\]+ contained
syn match   pythonBytesEscape       "\\\o\{1,3}" contained
syn match   pythonBytesEscape       "\\x\x\{2}" contained

" ============================================================================
" String Formatting
" ============================================================================

if s:string_fmt
  syn match   pythonStrFormatting   "%\%(([^)]\+)\)\=[#0\-+ ]*\%(\*\|\d\+\)\=\%(\.\%(\*\|\d\+\)\)\=[hlL]\=[diouxXeEfFgGcrsab%]" contained containedin=pythonString,pythonRawString
  syn match   pythonStrFormat       "{\%(\%(\d\+\|[[:alpha:]_][[:alnum:]_]*\)\%(\.[[:alpha:]_][[:alnum:]_]*\|\[\%(\d\+\|[^]]*\)\]\)*\)\=\%(![rsa]\)\=\%(:\%([^{}]\|{[^}]*}\)*\)\=}" contained containedin=pythonString,pythonRawString
  syn match   pythonStrTemplate     "\$\$\|\$\h\w*\|\${\h\w*}" contained containedin=pythonString,pythonRawString
endif

" ============================================================================
" Numbers
" ============================================================================

syn match   pythonNumber    "\<0[oO]\%(_\=\o\)\+\>"
syn match   pythonNumber    "\<0[xX]\%(_\=\x\)\+\>"
syn match   pythonNumber    "\<0[bB]\%(_\=[01]\)\+\>"
syn match   pythonNumber    "\<\%([1-9]\%(_\=\d\)*\|0\+\%(_\=0\)*\)\>"
syn match   pythonNumber    "\<\d\%(_\=\d\)*[jJ]\>"
syn match   pythonNumber    "\<\d\%(_\=\d\)*[eE][+-]\=\d\%(_\=\d\)*[jJ]\=\>"
syn match   pythonNumber
      \ "\<\d\%(_\=\d\)*\.\%([eE][+-]\=\d\%(_\=\d\)*\)\=[jJ]\=\%(\W\|$\)\@="
syn match   pythonNumber
      \ "\%(^\|\W\)\@1<=\%(\d\%(_\=\d\)*\)\=\.\d\%(_\=\d\)*\%([eE][+-]\=\d\%(_\=\d\)*\)\=[jJ]\=\>"

syn keyword pythonNone      None
syn match   pythonEllipsis  "\.\@1<!\.\.\.\ze\.\@!" display

" ============================================================================
" Builtins
" ============================================================================

if s:builtins
  syn keyword pythonBuiltin     False True None
  syn keyword pythonBuiltin     NotImplemented Ellipsis __debug__
  syn keyword pythonBuiltin     quit exit copyright credits license

  " Built-in functions — type is NOT a keyword here (see match below)
  syn keyword pythonBuiltin     abs all any ascii bin bool breakpoint bytearray
  syn keyword pythonBuiltin     bytes callable chr classmethod compile complex
  syn keyword pythonBuiltin     delattr dict dir divmod enumerate eval exec
  syn keyword pythonBuiltin     filter float format frozenset getattr globals
  syn keyword pythonBuiltin     hasattr hash help hex id input int isinstance
  syn keyword pythonBuiltin     issubclass iter len list locals map max
  syn keyword pythonBuiltin     memoryview min next object oct open ord pow
  syn keyword pythonBuiltin     print property range repr reversed round set
  syn keyword pythonBuiltin     setattr slice sorted staticmethod str sum super
  syn keyword pythonBuiltin     tuple vars zip __import__

  " type() call stays builtin; type Name is the statement (above)
  syn match   pythonBuiltin     "\<type\>\ze\s*(" display

  " TOP (not ALLBUT): contained regions would otherwise extend this match
  syn match   pythonAttribute   /\.\h\w*/hs=s+1
        \ contains=TOP,pythonBuiltin,pythonAsync
        \ transparent
endif

" Dotted annotation target: self.attr: Type [= ...]
" Starts at the last .attr (a leading self/cls keyword would outrank a match
" starting at column 0) and is defined after pythonAttribute so it wins there.
if s:type_annotations
  syn match   pythonAnnotatedAttr
        \ "\%(^\s*\h\w*\%(\.\h\w*\)*\)\@<=\.\h\w*\s*\ze:"
        \ transparent contains=NONE
        \ nextgroup=pythonStmtAnnotation
        \ skipwhite
endif

" ============================================================================
" Exceptions
" ============================================================================

if s:exceptions
  syn keyword pythonExceptions  BaseException Exception
  syn keyword pythonExceptions  ArithmeticError BufferError LookupError
  syn keyword pythonExceptions  AssertionError AttributeError EOFError
  syn keyword pythonExceptions  FloatingPointError GeneratorExit ImportError
  syn keyword pythonExceptions  IndentationError IndexError KeyError
  syn keyword pythonExceptions  KeyboardInterrupt MemoryError
  syn keyword pythonExceptions  ModuleNotFoundError NameError
  syn keyword pythonExceptions  NotImplementedError OSError OverflowError
  syn keyword pythonExceptions  RecursionError ReferenceError RuntimeError
  syn keyword pythonExceptions  StopAsyncIteration StopIteration SyntaxError
  syn keyword pythonExceptions  SystemError SystemExit TabError TypeError
  syn keyword pythonExceptions  UnboundLocalError UnicodeDecodeError
  syn keyword pythonExceptions  UnicodeEncodeError UnicodeError
  syn keyword pythonExceptions  UnicodeTranslateError ValueError
  syn keyword pythonExceptions  ZeroDivisionError
  syn keyword pythonExceptions  EnvironmentError IOError WindowsError
  syn keyword pythonExceptions  BlockingIOError BrokenPipeError
  syn keyword pythonExceptions  ChildProcessError ConnectionAbortedError
  syn keyword pythonExceptions  ConnectionError ConnectionRefusedError
  syn keyword pythonExceptions  ConnectionResetError FileExistsError
  syn keyword pythonExceptions  FileNotFoundError InterruptedError
  syn keyword pythonExceptions  IsADirectoryError NotADirectoryError
  syn keyword pythonExceptions  PermissionError ProcessLookupError TimeoutError
  syn keyword pythonExceptions  ExceptionGroup BaseExceptionGroup
  syn keyword pythonExceptions  BytesWarning DeprecationWarning EncodingWarning
  syn keyword pythonExceptions  FutureWarning ImportWarning
  syn keyword pythonExceptions  PendingDeprecationWarning ResourceWarning
  syn keyword pythonExceptions  RuntimeWarning SyntaxWarning UnicodeWarning
  syn keyword pythonExceptions  UserWarning Warning
endif

" ============================================================================
" Space Errors
" ============================================================================

if s:space_errors
  syn match   pythonSpaceError  display excludenl "\s\+$"
  syn match   pythonSpaceError  display " \+\t"
  syn match   pythonSpaceError  display "\t\+ "
endif

" ============================================================================
" Doctests
" ============================================================================

if s:doctests
  syn region  pythonDoctest
        \ start="^\s*>>>\s" end="^\s*$"
        \ contained contains=ALLBUT,pythonDoctest,pythonEllipsis,pythonClass,pythonFunction,pythonTypeAlias,
        \   pythonFStringField,pythonFStringFieldSkip,pythonFStringDebug,@pythonTypeInternal,@Spell

  syn region  pythonDoctestValue
        \ start=+^\s*\%(>>>\s\|\.\.\.\s\|"""\|'''\)\@!\S\++ end="$"
        \ contained contains=pythonEllipsis

  syn match   pythonDoctestEllipsis "\%(^\s*\)\@<!\.\@1<!\zs\.\.\.\ze\.\@!" display
        \ contained containedin=pythonDoctest
endif

" ============================================================================
" Shebang and Encoding
" ============================================================================

syn match   pythonShebang       "\%^#!.*$"
syn match   pythonEncoding      "^#.*\%(coding[:=]\s*\)\@<=\S\+" display

" ============================================================================
" Synchronization
" ============================================================================

if s:slow_sync
  syn sync fromstart
else
  " Param/return regions use lookbehind, so syncing at def/class is safe.
  " Require ( : or [ after the name so prose like "class Foo manages..." at
  " column 0 inside a long string is not taken as a top-level sync point.
  syn sync match pythonSync grouphere NONE "^\%(def\|class\|async\s\+def\)\s\+\h\w*\s*[(:\[]"
  syn sync minlines=100
endif

" ============================================================================
" Highlight Links (always; palette applied separately when colors enabled)
" ============================================================================

hi def link pythonStatement         Statement
hi def link pythonConditional       Conditional
hi def link pythonRepeat            Repeat
hi def link pythonOperator          Operator
hi def link pythonException         Exception
hi def link pythonInclude           Include
hi def link pythonAsync             Statement
hi def link pythonDecorator         Define
hi def link pythonDecoratorName     Function
hi def link pythonClass             Structure
hi def link pythonFunction          Function
hi def link pythonTypeAlias         Type
hi def link pythonComment           Comment
hi def link pythonTodo              Todo
hi def link pythonShebang           Comment
hi def link pythonEncoding          Comment
hi def link pythonDefComment        pythonComment

hi def link pythonString            String
hi def link pythonRawString         String
hi def link pythonFString           String
hi def link pythonRawFString        String
hi def link pythonBytes             String
hi def link pythonRawBytes          String
hi def link pythonQuotes            String
hi def link pythonTripleQuotes      pythonQuotes
hi def link pythonEscape            Special
hi def link pythonUnicodeEscape     pythonEscape
hi def link pythonBytesEscape       Special
hi def link pythonFStringDelimiter  Special
hi def link pythonFStringDebug      Special
hi def link pythonDocstring         String

if s:string_fmt
  hi def link pythonStrFormatting   Special
  hi def link pythonStrFormat       Special
  hi def link pythonStrTemplate     Special
endif

hi def link pythonNumber            Number
hi def link pythonNone              Constant
hi def link pythonEllipsis          Constant

if s:builtins
  hi def link pythonBuiltin         Function
endif

if s:exceptions
  hi def link pythonExceptions      Structure
endif

if s:class_vars
  hi def link pythonClassVar        Identifier
endif

if s:operators
  hi def link pythonOperatorSymbol  Operator
endif

if s:func_calls
  hi def link pythonFunctionCall    Function
endif

if s:type_annotations
  hi def link pythonReturnArrow     Operator
  hi def link pythonTypingType      Type
  hi def link pythonPrimitiveType   Type
  hi def link pythonTypeName        Type
  hi def link pythonTypeDotted      Type
  hi def link pythonTypeUnion       Operator
  hi def link pythonTypeNone        Constant
  hi def link pythonTypeEllipsis    Constant
  hi def link pythonTypeString      String
  hi def link pythonTypeComment     SpecialComment
  hi def link pythonTypeParamStar   Operator
  hi def link pythonReturnType      Type
  hi def link pythonParamAnnotation Type
  hi def link pythonStmtAnnotation  Type
  hi def link pythonTypeAliasValue  Type
endif

if s:doctests
  hi def link pythonDoctest         Special
  hi def link pythonDoctestValue    Define
  hi def link pythonDoctestEllipsis pythonBuiltin
endif

if s:space_errors
  hi def link pythonSpaceError      Error
endif

" Apply palette when the plugin function is available
if exists('*PythonSyntaxEnhancedApplyColors')
  call PythonSyntaxEnhancedApplyColors()
endif

let b:current_syntax = "python"

let &cpo = s:cpo_save
unlet s:cpo_save

" vim:set sw=2 sts=2 ts=8 noet:

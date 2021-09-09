source $MYDOTFILES/nvim/$OS_ENV/host.vim

let s:using_snippets = 0

source $MYDOTFILES/nvim/wsl/plugins.vim

source $MYDOTFILES/nvim/wsl/debugger.vim

" source $MYDOTFILES/nvim/$OS_ENV/clipboard.vim
source $MYDOTFILES/nvim/m1/clipboard.vim

source $MYDOTFILES/nvim/wsl/theme.vim

source $MYDOTFILES/nvim/wsl/indent.vim

source $MYDOTFILES/nvim/wsl/custom.vim

source $MYDOTFILES/nvim/wsl/lsp.vim

source $MYDOTFILES/nvim/wsl/mapping.vim

source $MYDOTFILES/nvim/wsl/treesitter.vim

set encoding=UTF-8
scriptencoding utf-8
set backspace=indent,eol,start
set expandtab
set shiftround
set shiftwidth=4
set softtabstop=-1
set tabstop=8
set title
set regexpengine=1
set noshowcmd
set nocursorline
set hidden
set nofixendofline
set nostartofline
set splitbelow
set splitright
set hlsearch
set incsearch
set laststatus=2
set showtabline=2

set completeopt=menuone,noinsert,noselect

set shortmess+=c

set noruler
set noshowmode
set updatetime=1000
set timeoutlen=1000
set ttimeoutlen=0
set tags=./.tags;,tags;

" open all fold
set foldlevel=99

" seperator styl
set fillchars+=vert:⠀

let g:fzf_tags_command = 'ctags -R -f .tags'

" if exists('+termguicolors')
let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
set termguicolors
" endif

" let g:airline#extensions#tabline#enabled = 1

" NerdCommenter:
let g:NERDSpaceDelims=1
let g:NERDDefaultAlign='left'

" NERDTree:
let g:NERDTreeShowBookmarks = 1
let NERDTreeHijackNetrw = 0
function! GotoTree()
    :NERDTree %:p:h
endfunction
let NERDTreeMapActivateNode=''
let NERDTreeHijackNetrw=1
nmap ,nerd :NERDTree



" Custom Key Mapping:
" nnoremap <C-p> :Files<CR>
" nnoremap <C-n> :Rg<CR>
let &t_SI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=1\x7\<Esc>\\"
let &t_SR = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=2\x7\<Esc>\\"
let &t_EI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=0\x7\<Esc>\\"

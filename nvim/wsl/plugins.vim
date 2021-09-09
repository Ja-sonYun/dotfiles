" Plugins by Vundle

set nocompatible
filetype off

set rtp+=$MYDOTFILES/nvim/bundle/Vundle.vim
call vundle#begin()            " required
Plugin 'VundleVim/Vundle.vim'  " required
" Vim FZF integration, used as OmniSharp selector
Plugin 'junegunn/fzf'
Plugin 'junegunn/fzf.vim'
Plugin 'chrisbra/csv.vim'
Plugin 'akinsho/nvim-bufferline.lua'

Plugin 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}
Plugin 'nvim-lua/popup.nvim'
Plugin 'nvim-lua/plenary.nvim'
Plugin 'nvim-telescope/telescope.nvim'

" Plugin 'prettier/vim-prettier', { 'do': 'yarn install' }
Plugin 'puremourning/vimspector'
Plugin 'glepnir/lspsaga.nvim'

" Colorscheme
" Plugin 'gruvbox-community/gruvbox'
Plugin 'lukas-reineke/indent-blankline.nvim'
Plugin 'folke/tokyonight.nvim', { 'branch': 'main' }
Plugin 'liuchengxu/space-vim-dark'
Plugin 'dracula/vim', { 'name': 'dracula' }
Plugin 'cocopon/iceberg.vim'
Plugin 'nanotech/jellybeans.vim'

" neovim 0.5
Plugin 'hrsh7th/nvim-compe'

" Syntax highlight
" Plugin 'leafgarland/typescript-vim'
" Plugin 'dart-lang/dart-vim-plugin'
" Plugin 'peitalin/vim-jsx-typescript'
" Plugin 'maxmellon/vim-jsx-pretty'
" Plugin 'stanangeloff/php.vim'
" Plugin 'posva/vim-vue'
" Plugin 'shime/vim-livedown'
" Plugin 'plasticboy/vim-markdown'
Plugin 'bad-whitespace'
" Plugin 'jwalton512/vim-blade'

" GIT
Plugin 'tpope/vim-fugitive'
Plugin 'airblade/vim-gitgutter'

" Statusline
" Plugin 'itchyny/lightline.vim'
" Plugin 'mengelbrecht/lightline-bufferline'
" Plugin 'shinchu/lightline-gruvbox.vim'
" Plugin 'maximbaz/lightline-ale'
" Plugin 'vim-airline/vim-airline'
" Plugin 'vim-airline/vim-airline-themes'
Plugin 'hoob3rt/lualine.nvim', {'commit': 'dc2c711'}
" If you want to have icons in your statusline choose one of these
Plugin 'kyazdani42/nvim-web-devicons'

" dash
Plugin 'rizzatti/dash.vim'

" Autocompletion
" Plugin 'pangloss/vim-javascript'
Plugin 'neovim/nvim-lspconfig'
Plugin 'nvim-lua/lsp_extensions.nvim'
Plugin 'nvim-lua/completion-nvim'

Plugin 'tommcdo/vim-lion'
" Plugin 'jeetsukumaran/vim-buffergator'
Plugin 'chrisbra/unicode.vim'
Plugin 'scrooloose/nerdcommenter'
Plugin 'schickling/vim-bufonly'
Plugin 'vim-scripts/DrawIt'
Plugin 'surround.vim'
Plugin 'mattn/emmet-vim'
Plugin 'LeafCage/yankround.vim'
Plugin 'jiangmiao/auto-pairs'

" Plugin 'prabirshrestha/vim-lsp'
" Plugin 'prabirshrestha/asyncomplete-lsp.vim'
" Plugin 'prabirshrestha/asyncomplete.vim'
" Plugin 'keremc/asyncomplete-clang.vim'
" Plugin 'prabirshrestha/async.vim'
" Plugin 'runoshun/tscompletejob'
" Plugin 'prabirshrestha/asyncomplete-tscompletejob.vim'

" tmux
Plugin 'christoomey/vim-tmux-navigator'

" php completion
" Plugin 'shawncplus/phpcomplete.vim'

" directory plugin
" Plugin 'preservim/nerdtree'
Plugin 'kyazdani42/nvim-tree.lua'
Plugin 'majutsushi/tagbar'
" Plugin 'ctrlpvim/ctrlp.vim'
" Plugin 'dyng/ctrlsf.vim'

" cursor
Plugin 'mg979/vim-visual-multi'

Plugin 'ryanoasis/vim-devicons'

call vundle#end()               " required
filetype plugin indent on       " required
syntax on

lua << EOF
-- require paq { 'rktjmp/lush.nvim' }
EOF

set hidden
set noswapfile

set rtp+=.
set rtp+=./plenary.nvim
runtime! plugin/plenary.vim

call plug#begin()

Plug 'nvim-lua/plenary.nvim'

call plug#end()

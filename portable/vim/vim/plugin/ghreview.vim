vim9script

if exists('g:loaded_user_ghreview')
  finish
endif
g:loaded_user_ghreview = true

import autoload 'ghreview/core.vim' as ghreview

command! -nargs=? -bar GhReview ghreview.Open(<q-args>)
command! -nargs=0 -bar GhReviewRefresh ghreview.Refresh()

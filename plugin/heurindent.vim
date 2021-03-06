" heurindent.vim - Heuristic indentation detection
" Copyright (c) 2017  Sven Karsten Greiner
"
" This program is free software: you can redistribute it and/or modify
" it under the terms of the GNU General Public License as published by
" the Free Software Foundation, either version 3 of the License, or
" (at your option) any later version.
"
" This program is distributed in the hope that it will be useful,
" but WITHOUT ANY WARRANTY; without even the implied warranty of
" MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
" GNU General Public License for more details.
"
" You should have received a copy of the GNU General Public License
" along with this program.  If not, see <https://www.gnu.org/licenses/>.

if exists('g:loaded_heurindent') || v:version < 700 || &cp
  finish
endif
let g:loaded_heurindent = 1


" Guess expandtab and shiftwidth.
"
" 'expandtab' is set depending on the ratio of soft/hard tabstops.
"
" 'shiftwidth' is detected based on weighted periods in the range of
" [g:heurindent_min_sw, g:heurindent_max_sw] (defaults to [2, &tabstop])
" with constraints 'min <= max' and 'min > 0'
" g:heurindent_weight_factor (default 0.8) can be used to tune weighting.
"
" In order to work correctly, 'tabstop' should be set to a sensible value
" (usually you want 'tabstop' to be 8, unless you know what you do).
function! s:guess(lines) abort
  let options = {}
  let linetype_histogram = {'hard': 0, 'soft': 0, 'spaces': 0, 'comment': 0}
  let indent_histogram = {}
  let softtab = repeat(' ', &tabstop)
  let max_indent = 0
  let comment = ''

  for line in a:lines
    " Skip empty or not indented lines
    if !len(line) || line =~# '^\s*$' || line =~# '^\S'
      continue
    endif

    if s:getPreference('skip_comments', 1)
      " Increment comment counter. Will be decremented again if no comment
      " encountered.
      let linetype_histogram.comment += 1

      let comment_multiline = 1

      " Skip comments
      " First check, if line starts a comment
      if !len(comment)
        let candidates = {}

        let candidates.c   = match(line, '\v/\*')
        let candidates.xml = match(line, '\v\<\!--')
        let candidates.pyd = match(line, '\v^\s*\zs""""@!')

        let min = len(line)
        for [type, position] in items(candidates)
          if position >= 0 && position < min
            let min = position
            let comment = type
            let comment_multiline = 0
          endif
        endfor
      endif

      " Now check if the comment ends
      if len(comment)
        if comment ==# 'c'
          if line =~# '\v\*/(.*/\*)@!'
            let comment = ''
          endif
        elseif comment ==# 'xml'
          if line =~# '\v--\>(.*\<\!--)@!'
            let comment = ''
          endif
        elseif comment ==# 'pyd'
          if (comment_multiline && line =~# '\v^\s*""""@!') || line =~# '\v^\s*""""@!.{-}"@1<!""""@!'
            let comment = ''
          endif
        endif

        " Skip if this is the end of a multi-line comment
        if comment_multiline
          continue
        endif
      endif

      let linetype_histogram.comment -= 1
    endif

    " Increment linetype histogram
    if line =~# '^\t'
      let linetype_histogram.hard += 1
    elseif line =~# '^' . softtab
      let linetype_histogram.soft += 1
    else
      let linetype_histogram.spaces += 1
    endif

    " Increment indentation histogram
    let indent = len(matchstr(substitute(line, '\t', softtab, 'g'), '^ *'))
    if has_key(indent_histogram, indent)
      let indent_histogram[indent] += 1
    else
      let indent_histogram[indent] = 1
    endif
    if indent > max_indent
      let max_indent = indent
    endif
  endfor

  let linetype_histogram.total = linetype_histogram.hard + linetype_histogram.soft + linetype_histogram.spaces

  " Abort if no lines were used in detection
  if !linetype_histogram.total
    if s:getPreference('debug', 0)
      echom 'No useful lines!'
    endif
    return options
  endif

  " Detect shiftwidth
  let space_heuristic = {}
  let min_sw = max([s:getPreference('min_sw', 2), 1])
  let max_sw = max([s:getPreference('max_sw', &tabstop), min_sw])

  for i in range(min_sw, max_sw)
    let sum = 0
    let weight = 1
    let n = i

    while n <= max_indent
      if has_key(indent_histogram, n)
        let sum += weight * indent_histogram[n]
      endif
      let weight = weight * s:getPreference('weight_factor', 0.8)
      let n += i
    endwhile

    let space_heuristic[i] = sum
  endfor

  for [width, score] in items(space_heuristic)
    if score > get(space_heuristic, get(options, 'shiftwidth', 0), 0)
      let options.shiftwidth = width
    endif
  endfor

  " Set expandtab depending on soft/hard ratio
  if linetype_histogram.hard || linetype_histogram.soft
    let ratio = 1.0 * linetype_histogram.soft / (linetype_histogram.hard + linetype_histogram.soft)
    let options.expandtab = ratio > s:getPreference('ratio_threshold', 0.5)
  endif

  if s:getPreference('debug', 0)
    echom 'Linetype histogram: '    . string(linetype_histogram)
    echom 'Indentation histogram: ' . string(indent_histogram)
    echom 'Space heuristics:   '    . string(space_heuristic)
    echom 'Determined options: '    . string(options)
  endif

  return options
endfunction


" Apply options.
function! s:applyOptions(options) abort
  if !len(a:options)
    return 0
  endif

  for [option, value] in items(a:options)
    call setbufvar('', '&'.option, value)
  endfor

  return 1
endfunction


" Detect indentation and set expandtab and shiftwidth.
" This function should be called to invoke heurindent.
function! s:detect() abort
  if &buftype ==# 'help'
    return
  endif

  if !exists('b:heurindent_option_backup')
    let b:heurindent_option_backup = {
          \ 'shiftwidth': &shiftwidth,
          \ 'expandtab': &expandtab }
  endif

  let maxlines = s:getPreference('maxlines', 1024)
  let options = s:guess(getline(1, maxlines))

  call s:applyOptions(options)
endfunction


" Reset shiftwidth and expandtab to the state before the first invocation
" of heurindent.
function! s:reset() abort
  let b:heurindent_automatic = 0
  call s:applyOptions(get(b:, 'heurindent_option_backup', {}))
endfunction


" Get preference. First try buffer local, then fall back to global.
function! s:getPreference(name, default) abort
  return get(b:, 'heurindent_' . a:name, get(g:, 'heurindent_' . a:name, a:default))
endfunction


" Get summary of expandtab, shiftwidth and tabstop.
function! HeurindentIndicator() abort
  let sw = &shiftwidth ? &shiftwidth : &tabstop
  if &expandtab
    return 'sw='.sw
  elseif &tabstop == sw
    return 'ts='.&tabstop
  else
    return 'sw='.sw.',ts='.&tabstop
  endif
endfunction


augroup heurindent
  autocmd!
  autocmd FileType * if s:getPreference('automatic', 1) | call s:detect() | endif
augroup END

command! -bar -bang Heurindent if <bang>0 | call s:reset() | else | call s:detect() | endif
command! -bar HeurindentReset call s:reset()

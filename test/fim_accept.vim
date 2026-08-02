let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')

let g:llama_config = {
    \ 'auto_fim': v:false,
    \ 'enable_at_startup': v:true,
    \ 'ring_n_chunks': 0,
    \ 'show_info': 0,
    \ 'keymap_fim_accept_full': '<C-g>f',
    \ 'keymap_fim_accept_line': '<Tab>',
    \ 'keymap_fim_accept_word': '<C-Right>',
    \ }

execute 'set runtimepath^=' . fnameescape(s:repo)
runtime plugin/llama.vim

let s:render_function = matchstr(execute('function /fim_render'), '<SNR>\d\+_fim_render')
call assert_notequal('', s:render_function, 'could not find llama.vim FIM renderer')

function! s:show_hint(line, column, content) abort
    enew!
    call setline(1, a:line)
    call cursor(1, max([1, a:column]))
    execute printf('call %s(%d, 1, [%s], 0)', s:render_function, a:column, string({'content': a:content}))
    call assert_true(llama#is_fim_hint_shown(), 'FIM hint was not shown')
endfunction

" Tab accepts exactly one line and advances when another suggested line exists.
call s:show_hint('prefix', 6, " first\nsecond")
call feedkeys("A\<Tab>", 'xt')
call assert_equal(['prefix first', ''], getline(1, '$'), 'Tab must accept one line only')
call assert_equal(2, line('.'), 'Tab must advance to the next suggested line')

" Tab also includes a line break when the suggestion ends on that line.
call s:show_hint('prefix', 6, ' only')
call feedkeys("A\<Tab>", 'xt')
call assert_equal(['prefix only', ''], getline(1, '$'), 'Tab must append a line break after a single-line suggestion')
call assert_equal(2, line('.'), 'single-line Tab acceptance must advance')

" Accepting the last word on a line advances when another line is suggested.
call s:show_hint('value =', 7, " first\nsecond")
call feedkeys("A\<C-Right>", 'xt')
call assert_equal(['value = first', ''], getline(1, '$'), 'last word must accept without the next line')
call assert_equal(2, line('.'), 'last word must advance to the next suggested line')

" Trailing whitespace after the last word does not prevent advancing.
call s:show_hint('value =', 7, " first  \nsecond")
call feedkeys("A\<C-Right>", 'xt')
call assert_equal(['value = first', ''], getline(1, '$'), 'last word must not insert trailing completion whitespace')
call assert_equal(2, line('.'), 'last word followed by whitespace must advance')

" A partial word acceptance must remain on the current line.
call s:show_hint('value =', 7, " first second\nthird")
call feedkeys("A\<C-Right>", 'xt')
call assert_equal(['value = first'], getline(1, '$'), 'word accept must stop at the first whitespace boundary')
call assert_equal(1, line('.'), 'partial word acceptance must stay on the current line')

" A final word without another suggested line must not create a new line.
call s:show_hint('value =', 7, ' done')
call feedkeys("A\<C-Right>", 'xt')
call assert_equal(['value = done'], getline(1, '$'), 'single-line word must be accepted')
call assert_equal(1, line('.'), 'single-line word acceptance must stay on the current line')

" Existing suffix text belongs after the multi-line completion and must not
" shorten the first suggested word.
call s:show_hint('call();', 5, "argument\nnext")
call feedkeys("6|i\<C-Right>", 'xt')
call assert_equal(['call(argument', ');'], getline(1, '$'), 'multi-line word acceptance must preserve the existing suffix')
call assert_equal(2, line('.'), 'word acceptance before a suffix must advance to the next suggested line')

call llama#disable()

if len(v:errors) > 0
    for s:error in v:errors
        echom s:error
    endfor
    cquit 1
endif

qa!

let s:repo = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:tmpdir = tempname()
let s:request_file = s:tmpdir . '/requests.jsonl'
let s:curl_dir = s:tmpdir . '/bin'
let s:curl = s:curl_dir . '/curl'
let s:old_path = $PATH

call mkdir(s:curl_dir, 'p')
call writefile([
    \ '#!/bin/sh',
    \ 'payload=$(cat)',
    \ 'printf "%s\\n" "$payload" >> "$LLAMA_TEST_REQUEST"',
    \ 'printf ''{"content":"TEST_HINT"}''',
    \ ], s:curl)
call setfperm(s:curl, 'rwx------')
let $LLAMA_TEST_REQUEST = s:request_file
let $PATH = s:curl_dir . ':' . s:old_path

let s:marker = 'one'
let s:last_ctx = {}
let s:provider_calls = 0
let s:cpp_provider_calls = 0
let s:markdown_provider_calls = 0
let s:skipped_provider_calls = 0

function! s:provider(ctx) abort
    let s:provider_calls += 1
    let s:last_ctx = a:ctx
    return [
        \ {'filename': 'provider.hpp', 'text': 'marker ' . s:marker},
        \ {'text': 'fallback filename'},
        \ {'filename': 'ignored.hpp'},
        \ ]
endfunction

function! s:broken_provider(ctx) abort
    throw 'provider failure'
endfunction

function! s:is_cpp(ctx) abort
    return a:ctx.filetype ==# 'cpp'
endfunction

function! s:is_markdown(ctx) abort
    return a:ctx.filetype ==# 'markdown'
endfunction

function! s:broken_condition(ctx) abort
    throw 'condition failure'
endfunction

function! s:cpp_provider(ctx) abort
    let s:cpp_provider_calls += 1
    return [{'filename': 'cpp.hpp', 'text': 'cpp-only context'}]
endfunction

function! s:markdown_provider(ctx) abort
    let s:markdown_provider_calls += 1
    return [{'filename': 'notes.md', 'text': 'markdown-only context'}]
endfunction

function! s:skipped_provider(ctx) abort
    let s:skipped_provider_calls += 1
    return [{'filename': 'unexpected.txt', 'text': 'must not be called'}]
endfunction

let g:llama_config = {
    \ 'auto_fim': v:false,
    \ 'enable_at_startup': v:true,
    \ 'ring_n_chunks': 0,
    \ 'show_info': 0,
    \ 'context_providers': [
    \   function('s:provider'),
    \   {'name': 'cpp', 'cond': function('s:is_cpp'), 'provider': function('s:cpp_provider')},
    \   {'name': 'markdown', 'cond': function('s:is_markdown'), 'provider': function('s:markdown_provider')},
    \   {'name': 'broken condition', 'cond': function('s:broken_condition'), 'provider': function('s:skipped_provider')},
    \   {'name': 'invalid condition', 'cond': 'not-a-function', 'provider': function('s:skipped_provider')},
    \   {'name': 'missing provider', 'cond': function('s:is_cpp')},
    \   function('s:broken_provider'),
    \   'not-a-function',
    \ ],
    \ }

execute 'set runtimepath^=' . fnameescape(s:repo)
runtime plugin/llama.vim

call setline(1, 'int main() {}')
call cursor(1, 5)
setlocal filetype=cpp

function! s:request_count() abort
    return filereadable(s:request_file) ? len(readfile(s:request_file)) : 0
endfunction

function! s:wait_for_requests(count) abort
    return wait(2000, {-> s:request_count() >= a:count}, 20)
endfunction

call llama#fim(-1, -1, v:false, [], v:false)
call assert_equal(0, s:wait_for_requests(1), 'initial FIM request was not captured')
sleep 100m

let s:requests = map(readfile(s:request_file), 'json_decode(v:val)')
let s:extra = s:requests[0].input_extra
call assert_equal(3, len(s:extra), 'multiple providers must contribute in configured order')
call assert_equal('provider.hpp', s:extra[0].filename, 'provider filename must be preserved')
call assert_equal('marker one', s:extra[0].text, 'provider text must be included')
call assert_equal('context-provider', s:extra[1].filename, 'missing filename must get a stable fallback')
call assert_equal('fallback filename', s:extra[1].text, 'valid text without filename must be included')
call assert_equal('cpp.hpp', s:extra[2].filename, 'conditional C++ provider chunk must be appended')
call assert_equal('cpp-only context', s:extra[2].text, 'conditional C++ provider text must be included')
call assert_equal(1, s:last_ctx.line, 'provider line must be 1-based')
call assert_equal(4, s:last_ctx.column, 'provider column must be a 0-based byte column')
call assert_equal('cpp', s:last_ctx.filetype, 'provider context must include the current filetype')
call assert_equal(1, s:cpp_provider_calls, 'matching conditional provider must be called')
call assert_equal(0, s:markdown_provider_calls, 'non-matching conditional provider must not be called')
call assert_equal(0, s:skipped_provider_calls, 'invalid and throwing conditions must skip providers')

call llama#fim(-1, -1, v:false, [], v:true)
sleep 200m
call assert_equal(1, s:request_count(), 'identical provider context must use the FIM cache')

let s:marker = 'two'
call llama#fim(-1, -1, v:false, [], v:true)
call assert_equal(0, s:wait_for_requests(2), 'changed provider context must bypass the FIM cache')
sleep 100m
let s:requests = map(readfile(s:request_file), 'json_decode(v:val)')
call assert_equal('marker two', s:requests[1].input_extra[0].text, 'updated provider text must reach the server')

let s:provider_calls_before_disable = s:provider_calls
let s:cpp_calls_before_disable = s:cpp_provider_calls
let g:llama_config.context_providers_enabled = v:false
call llama#fim(-1, -1, v:false, [], v:true)
call assert_equal(0, s:wait_for_requests(3), 'disabling providers must bypass a completion cached with provider context')
sleep 100m
let s:requests = map(readfile(s:request_file), 'json_decode(v:val)')
call assert_equal([], s:requests[2].input_extra, 'disabled providers must add no FIM context')
call assert_equal(s:provider_calls_before_disable, s:provider_calls, 'disabled providers must not be called')
call assert_equal(s:cpp_calls_before_disable, s:cpp_provider_calls, 'disabled conditional providers must not be called')

let g:llama_config.context_providers_enabled = v:true
call llama#fim(-1, -1, v:false, [], v:true)
sleep 200m
call assert_equal(3, s:request_count(), 're-enabled provider context should reuse its matching cached completion')

let s:cpp_calls_before_markdown = s:cpp_provider_calls
setlocal filetype=markdown
call llama#fim(-1, -1, v:false, [], v:true)
call assert_equal(0, s:wait_for_requests(4), 'changed provider conditions must bypass the C++ provider cache entry')
sleep 100m
let s:requests = map(readfile(s:request_file), 'json_decode(v:val)')
let s:markdown_extra = s:requests[3].input_extra
call assert_equal(3, len(s:markdown_extra), 'markdown provider must coexist with unconditional provider chunks')
call assert_equal('notes.md', s:markdown_extra[2].filename, 'markdown condition must select the markdown provider')
call assert_equal('markdown-only context', s:markdown_extra[2].text, 'markdown provider text must reach the server')
call assert_equal(s:cpp_calls_before_markdown, s:cpp_provider_calls, 'C++ provider must not run in a markdown buffer')
call assert_equal(1, s:markdown_provider_calls, 'markdown provider must run in a markdown buffer')
call assert_equal(0, s:skipped_provider_calls, 'invalid conditional descriptors must never call their providers')

call llama#toggle_context_providers()
call assert_equal(v:false, g:llama_config.context_providers_enabled, 'toggle command must disable providers')
call llama#toggle_context_providers()
call assert_equal(v:true, g:llama_config.context_providers_enabled, 'toggle command must re-enable providers')

call llama#disable()
let $PATH = s:old_path
call delete(s:tmpdir, 'rf')

if len(v:errors) > 0
    for s:error in v:errors
        echom s:error
    endfor
    cquit 1
endif

qa!

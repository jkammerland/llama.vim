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
    \ 'printf ''{"content":"TEST_HINT","tokens_cached":17}''',
    \ ], s:curl)
call setfperm(s:curl, 'rwx------')
let $LLAMA_TEST_REQUEST = s:request_file
let $PATH = s:curl_dir . ':' . s:old_path

let s:events = []
let s:snapshots = []
let s:string_callback_count = 0

function! s:on_event(event) abort
    call add(s:events, deepcopy(a:event))
    " Deliberately mutate the callback-owned value. Public state and the server
    " request must remain unchanged.
    let a:event.input_prefix = 'callback-mutated'
endfunction

function! s:on_snapshot(snapshot) abort
    call add(s:snapshots, deepcopy(a:snapshot))
endfunction

function! s:broken_callback(event) abort
    throw 'observer failure'
endfunction

function! LlamaTestStringCallback(event) abort
    let s:string_callback_count += 1
endfunction

function! s:provider(ctx) abort
    return [{'filename': 'provider.txt', 'text': 'åß'}]
endfunction

let g:llama_config = {
    \ 'auto_fim': v:false,
    \ 'enable_at_startup': v:true,
    \ 'ring_n_chunks': 0,
    \ 'show_info': 0,
    \ 'context_providers': [function('s:provider')],
    \ 'fim_event_callback': function('s:on_event'),
    \ 'debug_snapshot_callback': function('s:on_snapshot'),
    \ }

execute 'set runtimepath^=' . fnameescape(s:repo)
runtime plugin/llama.vim

execute 'file ' . fnameescape(s:tmpdir . '/sample.cpp')
call setline(1, ['alpha', 'value = 1;', 'omega'])
call cursor(2, 6)
setlocal filetype=cpp

function! s:request_count() abort
    return filereadable(s:request_file) ? len(readfile(s:request_file)) : 0
endfunction

function! s:event_count(kind) abort
    return len(filter(copy(s:events), 'get(v:val, "event", "") ==# a:kind'))
endfunction

function! s:last_event(kind) abort
    let l:matches = filter(copy(s:events), 'get(v:val, "event", "") ==# a:kind')
    return empty(l:matches) ? {} : l:matches[-1]
endfunction

call llama#fim(-1, -1, v:false, [], v:false)
call assert_equal(0, wait(2000, {-> s:request_count() >= 1}, 20), 'FIM request was not captured')
call assert_equal(0, wait(2000, {-> s:event_count('response') >= 1 && len(s:snapshots) >= 1}, 20), 'observer callbacks did not finish')

let s:server_request = json_decode(readfile(s:request_file)[0])
let s:request_event = s:last_event('request')
call assert_equal(1, s:request_event.schema_version)
call assert_equal('request', s:request_event.event)
call assert_equal(1, s:request_event.request_id)
call assert_equal(2, s:request_event.cursor_line)
call assert_equal(5, s:request_event.cursor_col)
call assert_equal(0, s:request_event.ring_chunks)
call assert_equal(0, s:request_event.ring_extra_chunks)
call assert_equal(1, s:request_event.provider_chunks)
call assert_equal(1, s:request_event.extra_chunks)
call assert_equal(2, s:request_event.extra_chars, 'extra_chars must count characters, not UTF-8 bytes')
call assert_equal(1, s:request_event.prefix_lines)
call assert_equal(2, s:request_event.suffix_lines)
call assert_equal(5, s:request_event.prompt_chars)
call assert_true(s:request_event.tokens_cached is v:null, 'request tokens_cached must be unknown')
call assert_equal(s:server_request, s:request_event.request, 'snapshot request must exactly match the server body')
call assert_equal(1, len(s:snapshots), 'snapshot callback must receive request events only')

let s:manual = llama#debug_snapshot()
call assert_equal(17, s:manual.tokens_cached, 'last snapshot must be enriched by the correlated response')
call assert_notequal('callback-mutated', s:manual.input_prefix, 'callback mutation escaped its deep copy')
let s:event_count_before_manual = len(s:events)
let s:snapshot_count_before_manual = len(s:snapshots)
call llama#debug_snapshot()
sleep 20m
call assert_equal(s:event_count_before_manual, len(s:events), 'manual snapshot must not emit lifecycle events')
call assert_equal(s:snapshot_count_before_manual, len(s:snapshots), 'manual snapshot must not invoke snapshot callback')

" A throwing observer must not prevent the next FIM request from starting.
let g:llama_config.fim_event_callback = function('s:broken_callback')
call setline(2, 'value = 2;')
call llama#fim(-1, -1, v:false, [], v:false)
call assert_equal(0, wait(2000, {-> s:request_count() >= 2}, 20), 'throwing callback blocked FIM')

" Function-name strings remain supported for Vim configuration files.
let g:llama_config.fim_event_callback = 'LlamaTestStringCallback'
call setline(2, 'value = 3;')
call llama#fim(-1, -1, v:false, [], v:false)
call assert_equal(0, wait(2000, {-> s:request_count() >= 3}, 20), 'string callback request was not sent')
call assert_equal(0, wait(2000, {-> s:string_callback_count >= 2}, 20), 'string callback did not receive request and response')

" Render/accept/dismiss events are correlated without exposing the internal
" response metadata added to cache entries.
let g:llama_config.fim_event_callback = function('s:on_event')
let s:render_function = matchstr(execute('function /fim_render'), '<SNR>\d\+_fim_render')
call assert_notequal('', s:render_function, 'could not find FIM renderer')

enew!
call setline(1, 'prefix')
call cursor(1, 6)
execute printf('call %s(6, 1, [%s], 0)', s:render_function, string({
    \ 'content': ' answer',
    \ 'tokens_cached': 9,
    \ '_llama_request_id': 77,
    \ }))
call llama#fim_accept('full')
call assert_equal(0, wait(1000, {-> s:event_count('accepted') >= 1}, 10), 'accepted event was not delivered')
let s:accepted = s:last_event('accepted')
call assert_equal(77, s:accepted.request_id)
call assert_equal('full', s:accepted.accept_type)
call assert_equal(' answer', s:accepted.accepted_text)
call assert_false(has_key(s:accepted.response, '_llama_request_id'), 'internal response metadata leaked')
call assert_equal(0, s:event_count('dismissed'), 'acceptance must not also emit dismissal')

execute printf('call %s(13, 1, [%s], 0)', s:render_function, string({
    \ 'content': ' later',
    \ '_llama_request_id': 78,
    \ }))
call llama#fim_hide('test-dismiss')
call assert_equal(0, wait(1000, {-> s:event_count('dismissed') >= 1}, 10), 'dismissed event was not delivered')
call assert_equal('test-dismiss', s:last_event('dismissed').reason)
call assert_equal(78, s:last_event('dismissed').request_id)

" With every observer disabled, request capture must be gated off rather than
" merely constructing a payload that nobody consumes.
let s:event_count_before_disabled = len(s:events)
let s:snapshot_count_before_disabled = len(s:snapshots)
let g:llama_config.fim_event_callback = ''
let g:llama_config.debug_snapshot_callback = ''
let g:llama_config.debug_snapshot_enabled = v:false
call setline(1, 'capture disabled')
call cursor(1, 8)
call llama#fim(-1, -1, v:false, [], v:false)
call assert_equal(0, wait(2000, {-> s:request_count() >= 4}, 20), 'disabled observer request was not sent')
call assert_equal({}, llama#debug_snapshot(), 'disabled capture retained a request snapshot')
sleep 20m
call assert_equal(s:event_count_before_disabled, len(s:events), 'disabled lifecycle callback received an event')
call assert_equal(s:snapshot_count_before_disabled, len(s:snapshots), 'disabled snapshot callback received an event')

" Explicit manual capture remains available without installing a callback.
let g:llama_config.debug_snapshot_enabled = v:true
call setline(1, 'manual capture')
call llama#fim(-1, -1, v:false, [], v:false)
call assert_equal(0, wait(2000, {-> s:request_count() >= 5}, 20), 'manual capture request was not sent')
call assert_equal(0, wait(2000, {-> get(llama#debug_snapshot(), 'tokens_cached', v:null) is 17}, 20), 'manual snapshot was not enriched')
call assert_equal('request', get(llama#debug_snapshot(), 'event', ''), 'manual capture did not retain the request')
call assert_equal(s:event_count_before_disabled, len(s:events), 'manual capture emitted a lifecycle event')
call assert_equal(s:snapshot_count_before_disabled, len(s:snapshots), 'manual capture invoked a snapshot callback')

call llama#disable()
let $PATH = s:old_path
call delete(s:tmpdir, 'rf')
delfunction LlamaTestStringCallback

if len(v:errors) > 0
    for s:error in v:errors
        echom s:error
    endfor
    cquit 1
endif

qa!

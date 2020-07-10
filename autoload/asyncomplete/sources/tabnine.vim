let s:line_limit = 1000
let s:max_num_result = 10
let s:binary_dir = expand('<sfile>:p:h:h:h:h') . '/binaries'
let s:job = v:none
let s:chan = v:none
let s:buffer = ''
let s:optname = 'tabnine'
let s:ctx = {}
let s:startcol = 0

function! asyncomplete#sources#tabnine#completor(opt, ctx)
    let l:col = a:ctx['col']
    let l:typed = a:ctx['typed']

    let l:kw = matchstr(l:typed, '\w\+$')
    let l:lwlen = len(l:kw)

    let l:startcol = l:col - l:lwlen

    let s:opt = a:opt['name']
    let s:ctx = a:ctx
    let s:startcol = l:startcol
    call s:get_response(a:ctx)
endfunction

function! asyncomplete#sources#tabnine#get_source_options(opts)
    call s:start_tabnine()
    return a:opts
endfunction

function! asyncomplete#sources#tabnine#get_chan()
    return s:chan
endfunction

function! s:start_tabnine() abort
    let l:tabnine_path = s:get_tabnine_path(s:binary_dir)
    let l:cmd = [
      \   l:tabnine_path,
      \   '--client',
      \   'sublime',
      \   '--log-file-path',
      \   s:binary_dir . '/tabnine.log',
      \ ]
    let l:jobopt = {
       \   "out_cb": function("s:out_cb"),
       \ }
    let s:job = job_start(l:cmd, l:jobopt)
    if job_status(s:job) == 'run'
        let s:chan = job_getchannel(s:job)
    endif
endfunction

function! s:get_response(ctx) abort
    let l:pos = getpos('.')
    let l:last_line = line('$')
    let l:before_line = max([1, l:pos[1] - s:line_limit])
    let l:before_lines = getline(l:before_line, l:pos[1])
    if !empty(l:before_lines)
        let l:before_lines[-1] = l:before_lines[-1][:l:pos[2]-1]
    endif
    let l:after_line = min([l:last_line, l:pos[1] + s:line_limit])
    let l:after_lines = getline(l:pos[1], l:after_line)
    if !empty(l:after_lines)
        let l:after_lines[0] = l:after_lines[0][l:pos[2]:]
    endif

    let l:region_includes_beginning = v:false
    if l:before_line == 1
        let l:region_includes_beginning = v:true
    endif

    let l:region_includes_end = v:false
    if l:after_line == l:last_line
        let l:region_includes_end = v:true
    endif

    let l:params = {
       \   'filename': a:ctx['filepath'],
       \   'before': join(l:before_lines, "\n"),
       \   'after': join(l:after_lines, "\n"),
       \   'region_includes_beginning': l:region_includes_beginning,
       \   'region_includes_end': l:region_includes_end,
       \   'max_num_result': s:max_num_result,
       \ }
    call s:request('Autocomplete', l:params)
endfunction

function! s:request(name, param) abort
    let l:req = {
      \ 'version': '1.0.14',
      \ 'request': {
      \     a:name: a:param,
      \   },
      \ }

    if s:chan == v:none
        return
    endif

    let s:buffer = json_encode(l:req) . "\n"
    call s:flush_vim_sendraw(v:null)
endfunction

function! s:out_cb(channel, msg) abort
    let l:response = json_decode(a:msg)
    let l:words = []
    for l:result in l:response['results']
        let l:word = []
        call add(l:word, l:result['new_prefix'])

        call add(l:words, [l:result['new_prefix']])
    endfor
    let l:matches = map(l:words,'{"word":v:val,"dup":1,"icase":1,"menu": "[tabnine]"}')
    echomsg l:matches
    call asyncomplete#complete(s:optname, s:ctx, s:startcol, l:matches)
endfunction

function! s:err_cb(channel, msg) abort
    echoerr a:msg
endfunction

function! s:exit_cb(channel, msg) abort
    echoerr "exit"
    let s:chan = v:none
endfunction

function! s:get_tabnine_path(binary_dir) abort
    let l:os = ''
    if has('macunix')
        let l:os = 'apple-darwin'
    elseif has('unix')
        let l:os = 'unknown-linux-gnu'
    elseif has('win32')
        let l:os = 'pc-windows-gpu'
    endif

    let l:versions = glob(fnameescape(a:binary_dir) . '/*', 1, 1)
    let l:versions = reverse(sort(l:versions))
    for l:version in l:versions
        let l:triple = s:parse_architecture('') . '-' . l:os
        let l:path = join([l:version, l:triple, s:executable_name('TabNine')], '/')
        if filereadable(l:path)
            return l:path
        endif
    endfor
endfunction

function! s:parse_architecture(arch) abort
    if system('file -L "' . exepath(v:progpath) . '"') =~ 'x86-64'
        return 'x86_64'
    endif
    return a:arch
endfunction

function! s:executable_name(name) abort
    if has('win32') || has('win64')
        return a:name . '.exe'
    endif
    return a:name
endfunction

function! s:flush_vim_sendraw(timer) abort
    if s:chan == v:null
        return
    endif

    sleep 1m
    if len(s:buffer) <= 4096
        call ch_sendraw(s:chan, s:buffer)
        let s:buffer = ''
    else
        let l:to_send = s:buffer[:4095]
        let s:buffer = s:buffer[4096:]
        call ch_sendraw(s:chan, l:to_send)
        call timer_start(1, function('s:flush_vim_sendraw'))
    endif
endfunction
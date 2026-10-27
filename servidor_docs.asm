bits 64
default rel
; ============ SATIRO-IA: SERVICO DE DOCUMENTOS 100% ASSEMBLY (porta 8766) ============
; Le os .txt de dados\documentos (extraidos pelo pipeline), divide em trechos,
; e atende em assembly puro:
;   GET  /api/saude       -> status
;   GET  /api/documentos  -> lista com nome/trechos (nomes vindos do indice.json)
;   POST /api/resumo      -> {"arquivo":"..."} resumo extrativo + principais termos
;   POST /api/busca       -> {"tema":"..."} passagens mais relevantes
; CORS liberado para o frontend da porta 8765 chamar direto.

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ReadFile
extern __imp_CreateFileA
extern __imp_CloseHandle
extern __imp_ExitProcess
extern __imp_LoadLibraryA
extern __imp_GetProcAddress
extern __imp_FindFirstFileA
extern __imp_FindNextFileA
extern __imp_FindClose
extern __imp_SetFilePointerEx
extern __imp_GetSystemInfo
extern __imp_GetModuleFileNameA
extern __imp_SetCurrentDirectoryA
extern __imp_VirtualAlloc
extern __imp_GetFileAttributesA

%include "tf_sistema.asm"

global main

section .data
align 8
caminho_docs:   db "dados\documentos", 0
padrao_txt:     db "dados\documentos\*.txt", 0
prefixo_doc:    db "dados\documentos\", 0
caminho_indice: db "dados\documentos\indice.json", 0
nome_dll:       db "ws2_32.dll", 0
n_WSAStartup:   db "WSAStartup", 0
n_socket:       db "socket", 0
n_htons:        db "htons", 0
n_bind:         db "bind", 0
n_listen:       db "listen", 0
n_accept:       db "accept", 0
n_recv:         db "recv", 0
n_send:         db "send", 0
n_closesocket:  db "closesocket", 0
n_setsockopt:   db "setsockopt", 0

msg_boot:       db "Satiro-IA: servico de documentos em assembly puro na porta 8766.", 13, 10
msg_boot_len    equ $ - msg_boot
resp_saude:     db '{"ok":true,"motor":"assembly"}'
resp_saude_len  equ $ - resp_saude
resp_404:       db '{"erro":"rota inexistente"}'
resp_404_len    equ $ - resp_404
chave_nome:     db '"nome":"'
chave_nome_len  equ $ - chave_nome
chave_id:       db '"id":"'
chave_id_len    equ $ - chave_id
hexdig:         db "0123456789abcdef"

stop_tab:
    db "de",0,"da",0,"do",0,"das",0,"dos",0,"as",0,"os",0,"em",0,"um",0,"uma",0
    db "uns",0,"umas",0,"nos",0,"nas",0,"para",0,"por",0,"com",0,"que",0,"qual",0
    db "quais",0,"como",0,"quando",0,"quem",0,"aos",0,"mais",0,"ser",0,"sao",0
    db "foi",0,"era",0,"isso",0,"esse",0,"essa",0,"ele",0,"ela",0,"the",0,"voce",0
    db "seu",0,"sua",0,"elas",0,"este",0,"esta",0,"ate",0,"sobre",0,"nao",0,"sim",0
    db "pelo",0,"pela",0,"sem",0,"sob",0,"dos",0,"e",0,"a",0,"o",0
stop_fim equ $ - stop_tab

section .bss
alignb 16
fn_WSAStartup: resq 1
fn_socket:     resq 1
fn_htons:      resq 1
fn_bind:       resq 1
fn_listen:     resq 1
fn_accept:     resq 1
fn_recv:       resq 1
fn_send:       resq 1
fn_closesocket: resq 1
fn_setsockopt: resq 1
hout:          resq 1
wrote:         resd 1
s_listen:      resq 1
s_cli:         resq 1
wsad:          resb 400
sa:            resb 16
tmpd:          resd 1
reqbuf:        resb 1048576
reqtot:        resq 1
corpooff:      resq 1
corpolen:      resq 1
outbuf:        resb 1048576
c3map:         resb 64
; ---- documentos carregados ----
ndocs:         resq 1
d_name:        resq 256
d_nlen:        resq 256
d_trechos:     resq 256
d_sbase:       resq 256                   ; indice da primeira frase do doc
d_txtbuf:      resb 8388608               ; textos crus (frases apontam para ca)
txttop:        resq 1
; ---- frases ----
nsent:         resq 1
s_ptr:         resq 16384
s_len:         resq 16384
s_doc:         resq 16384
s_words:       resq 16384
s_wcount:      resq 16384
normarena:     resb 8388608
normtop:       resq 1
wordbuf:       resb 16777216
wordtop:       resq 1
findbuf:       resb 600
idbuf:         resb 4096
idlen:         resq 1
nomebuf:       resb 4096
nomelen:       resq 1
reqname:       resb 4096
reqlen:        resq 1
temabuf:       resb 16384
qwords:        resq 64
qwlens:        resq 64
qwn:           resq 1
escbuf:        resb 524288
cand_idx:      resq 8
cand_score:    resq 8

section .text

; ---------- console: rsi = texto, rcx = bytes ------------------------------------------------
say:
    push rbx
    push r12
    sub rsp, 40
    mov r12, rsi
    mov rbx, rcx
    mov rcx, [hout]
    mov rdx, r12
    mov r8, rbx
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 40
    pop r12
    pop rbx
    ret

; ---------- le arquivo inteiro: rcx = caminho, rdx = buf, r8 = max -> rax = bytes ------------
le_arquivo:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r12, rdx
    mov r13, r8
    mov edx, 0x80000000
    mov r8d, 1
    xor r9d, r9d
    mov qword [rsp+32], 3
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .fim
    mov rbx, rax
    mov rcx, rbx
    mov rdx, r12
    mov r8, r13
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    mov rcx, rbx
    xor edx, edx
    call [__imp_CloseHandle]
    mov eax, [wrote]
.fim:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------- tabela de acentos ------------------------------------------------------------------
monta_c3map:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    lea rdi, [c3map]
    mov ecx, 64
    mov al, ' '
.z:
    mov [rdi], al
    inc rdi
    dec ecx
    jnz .z
    lea rdi, [c3map]
    mov byte [rdi+0x00], 'a'
    mov byte [rdi+0x01], 'a'
    mov byte [rdi+0x02], 'a'
    mov byte [rdi+0x03], 'a'
    mov byte [rdi+0x04], 'a'
    mov byte [rdi+0x05], 'a'
    mov byte [rdi+0x06], 'a'
    mov byte [rdi+0x07], 'c'
    mov byte [rdi+0x08], 'e'
    mov byte [rdi+0x09], 'e'
    mov byte [rdi+0x0A], 'e'
    mov byte [rdi+0x0B], 'e'
    mov byte [rdi+0x0C], 'i'
    mov byte [rdi+0x0D], 'i'
    mov byte [rdi+0x0E], 'i'
    mov byte [rdi+0x0F], 'i'
    mov byte [rdi+0x10], 'd'
    mov byte [rdi+0x11], 'n'
    mov byte [rdi+0x12], 'o'
    mov byte [rdi+0x13], 'o'
    mov byte [rdi+0x14], 'o'
    mov byte [rdi+0x15], 'o'
    mov byte [rdi+0x16], 'o'
    mov byte [rdi+0x18], 'o'
    mov byte [rdi+0x19], 'u'
    mov byte [rdi+0x1A], 'u'
    mov byte [rdi+0x1B], 'u'
    mov byte [rdi+0x1C], 'u'
    mov byte [rdi+0x1D], 'y'
    mov byte [rdi+0x1E], 't'
    mov byte [rdi+0x1F], 's'
    mov byte [rdi+0x20], 'a'
    mov byte [rdi+0x21], 'a'
    mov byte [rdi+0x22], 'a'
    mov byte [rdi+0x23], 'a'
    mov byte [rdi+0x24], 'a'
    mov byte [rdi+0x25], 'a'
    mov byte [rdi+0x26], 'a'
    mov byte [rdi+0x27], 'c'
    mov byte [rdi+0x28], 'e'
    mov byte [rdi+0x29], 'e'
    mov byte [rdi+0x2A], 'e'
    mov byte [rdi+0x2B], 'e'
    mov byte [rdi+0x2C], 'i'
    mov byte [rdi+0x2D], 'i'
    mov byte [rdi+0x2E], 'i'
    mov byte [rdi+0x2F], 'i'
    mov byte [rdi+0x30], 'd'
    mov byte [rdi+0x31], 'n'
    mov byte [rdi+0x32], 'o'
    mov byte [rdi+0x33], 'o'
    mov byte [rdi+0x34], 'o'
    mov byte [rdi+0x35], 'o'
    mov byte [rdi+0x36], 'o'
    mov byte [rdi+0x38], 'o'
    mov byte [rdi+0x39], 'u'
    mov byte [rdi+0x3A], 'u'
    mov byte [rdi+0x3B], 'u'
    mov byte [rdi+0x3C], 'u'
    mov byte [rdi+0x3D], 'y'
    mov byte [rdi+0x3E], 't'
    mov byte [rdi+0x3F], 'y'
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------- normaliza limitado: rdi = dst, rsi = src, rdx = len -> rax = len --------------------
normaliza_n:
    push rbx
    mov rbx, rdi
    test rdx, rdx
    jz .f
.n:
    movzx eax, byte [rsi]
    cmp eax, 0xC3
    je .c3
    cmp eax, 0x80
    jae .espaco
    cmp eax, 'A'
    jb .vd
    cmp eax, 'Z'
    ja .espaco
    add eax, 32
    jmp .guarda
.vd:
    cmp eax, 'a'
    jb .dig
    cmp eax, 'z'
    ja .espaco
    jmp .guarda
.dig:
    cmp eax, '0'
    jb .espaco
    cmp eax, '9'
    ja .espaco
.guarda:
    mov [rdi], al
    inc rdi
    inc rsi
    dec rdx
    jnz .n
    jmp .f
.c3:
    cmp rdx, 2
    jb .espaco
    movzx eax, byte [rsi+1]
    cmp eax, 0x80
    jb .espaco
    cmp eax, 0xBF
    ja .espaco
    lea r9, [c3map]
    movzx eax, byte [r9+rax-0x80]
    mov [rdi], al
    inc rdi
    add rsi, 2
    sub rdx, 2
    jnz .n
    jmp .f
.espaco:
    mov eax, ' '
    mov [rdi], al
    inc rdi
    inc rsi
    dec rdx
    jnz .n
.f:
    test rbx, rbx
    jz .ve
    cmp rdi, rbx
    jbe .sem
    cmp byte [rdi-1], ' '
    jne .sem
    dec rdi
.sem:
    mov byte [rdi], 0
.ve:
    mov rax, rdi
    sub rax, rbx
    pop rbx
    ret

; ---------- palavra serve? rsi = ptr, rcx = len -> rax = 1/0 ------------------------------------
palavra_ok:
    cmp rcx, 3
    jb .nao
    lea rdx, [stop_tab]
    lea rax, [rdx+stop_fim]
.loop:
    cmp rdx, rax
    jae .sim
    mov r8, rcx
    mov r9, rsi
.c:
    movzx eax, byte [rdx]
    movzx ecx, byte [r9]
    test eax, eax
    jz .nao
    cmp eax, ecx
    jne .prox
    inc rdx
    inc r9
    dec r8
    jnz .c
    movzx eax, byte [rdx]
    test eax, eax
    jz .nao
.prox:
    movzx eax, byte [rdx]
    test eax, eax
    jz .prox2
    inc rdx
    jmp .prox
.prox2:
    inc rdx
    jmp .loop
.sim:
    mov eax, 1
    ret
.nao:
    xor eax, eax
    ret

; ---------- esc_json: rdi = dst, rsi = src, rdx = len -> rax = bytes ----------------------------
esc_json:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, rdi
    xor rcx, rcx
.l:
    cmp rcx, rdx
    jae .f
    movzx eax, byte [rsi+rcx]
    cmp eax, '"'
    je .q
    cmp eax, 0x5C
    je .bs
    cmp eax, 10
    je .nl
    cmp eax, 13
    je .cr
    cmp eax, 9
    je .tab
    cmp eax, 32
    jae .raw
    mov byte [rdi], 0x5C
    mov byte [rdi+1], 'u'
    mov byte [rdi+2], '0'
    mov byte [rdi+3], '0'
    mov r8d, eax
    shr eax, 4
    and eax, 15
    lea r9, [hexdig]
    mov al, [r9+rax]
    mov [rdi+4], al
    mov eax, r8d
    and eax, 15
    mov al, [r9+rax]
    mov [rdi+5], al
    add rdi, 6
    inc rcx
    jmp .l
.q:
    mov byte [rdi], 0x5C
    mov byte [rdi+1], 0x22
    add rdi, 2
    inc rcx
    jmp .l
.bs:
    mov byte [rdi], 0x5C
    mov byte [rdi+1], 0x5C
    add rdi, 2
    inc rcx
    jmp .l
.nl:
    mov byte [rdi], 0x5C
    mov byte [rdi+1], 'n'
    add rdi, 2
    inc rcx
    jmp .l
.cr:
    mov byte [rdi], 0x5C
    mov byte [rdi+1], 'r'
    add rdi, 2
    inc rcx
    jmp .l
.tab:
    mov byte [rdi], 0x5C
    mov byte [rdi+1], 't'
    add rdi, 2
    inc rcx
    jmp .l
.raw:
    mov [rdi], al
    inc rdi
    inc rcx
    jmp .l
.f:
    mov rax, rdi
    sub rax, rbx
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .data
section .text

; ================================ carga dos documentos =====================================

; fraseia o texto: rsi = base, rdx = len, r13 = indice do doc
; frases terminam em . ! ? seguidos de espaco/fim, ou em quebra de linha; >= 20 chars
divide_doc:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    lea r10, [s_ptr]
    xor r8, r8                          ; inicio da frase
    xor r9, r9                          ; pos
.scan:
    cmp r9, rdx
    jae .ultima
    movzx eax, byte [rsi+r9]
    cmp eax, 10
    je .quebra
    cmp eax, '.'
    je .ponto
    cmp eax, '!'
    je .ponto
    cmp eax, '?'
    je .ponto
    inc r9
    jmp .scan
.ponto:
    inc r9
    cmp r9, rdx
    jae .ultima
    movzx eax, byte [rsi+r9]
    cmp eax, ' '
    je .corta
    cmp eax, 10
    je .corta
    jmp .scan
.quebra:
    mov r10, r9
    call .emite
    inc r9
    mov r8, r9
    jmp .scan
.corta:
    mov r10, r9
    call .emite
    mov r8, r9
    jmp .scan
.ultima:
    mov r10, rdx
    call .emite
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.emite:
    ; frase = [rsi+r8, rsi+r10)
    mov rax, r10
    sub rax, r8
    cmp rax, 20
    jb .e_fim
    ; corta espacos das pontas
.e_trim_esq:
    cmp byte [rsi+r8], ' '
    jne .e_trim_dir
    inc r8
    jmp .e_trim_esq
.e_trim_dir:
.e_t2:
    cmp r10, r8
    jbe .e_ok
    movzx eax, byte [rsi+r10-1]
    cmp eax, ' '
    je .e_t3
    cmp eax, 13
    je .e_t3
    cmp eax, 9
    jne .e_ok
.e_t3:
    dec r10
    jmp .e_t2
.e_ok:
    mov rax, r10
    sub rax, r8
    cmp rax, 20
    jb .e_fim
    cmp qword [nsent], 16384
    jae .e_fim
    ; registra
    mov rcx, [nsent]
    mov rax, r8
    add rax, rsi
    mov [r10+rcx*8], rax
    mov rax, r10
    sub rax, r8
    mov [r10+rcx*8+131072], rax
    mov [r10+rcx*8+262144], r13
    inc qword [nsent]
    mov rax, r13
    shl rax, 3
    inc qword [r10+rax+262144]
.e_fim:
    ret

; varre dados\documentos\*.txt, carrega e fraseia cada um
carrega_documentos:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    lea r11, [d_name]
    mov qword [ndocs], 0
    mov qword [nsent], 0
    mov qword [txttop], 0
    lea rcx, [padrao_txt]
    lea rdx, [findbuf]
    call [__imp_FindFirstFileA]
    cmp rax, -1
    je .fim
    mov [tmpd], eax
.l:
    ; nome do arquivo em findbuf+48
    lea rbx, [findbuf+48]
    ; tamanho do nome
    xor r12, r12
.nl:
    cmp byte [rbx+r12], 0
    je .nlf
    inc r12
    jmp .nl
.nlf:
    cmp r12, 4
    jb .next
    ; le o arquivo para a arena
    lea rsi, [prefixo_doc]
    lea rdi, [reqname]
    mov ecx, 18
    rep movsb
    mov rsi, rbx
    lea rdi, [reqname+18]
    mov rcx, r12
    rep movsb
    lea rcx, [reqname]
    lea r10, [txttop]
    mov rdx, r10
    mov r8d, 2097152
    call le_arquivo
    cmp rax, -1
    je .next
    ; nome para a lista
    mov rax, rbx
    mov rcx, [ndocs]
    mov [r11+rcx*8], rax
    mov [r11+rcx*8+2048], r12
    ; fraseia
    mov r13, rcx
    mov rsi, r10
    mov rdx, rax
    inc qword [ndocs]
    call divide_doc
.next:
    mov ecx, [tmpd]
    lea rdx, [findbuf]
    call [__imp_FindNextFileA]
    test eax, eax
    jnz .l
    mov ecx, [tmpd]
    call [__imp_FindClose]
.fim:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================ pontuacao e resumo ========================================

; df: quantas frases contem a palavra (r10 = ptr, r11 = len) -> rax
df_lookup:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    lea r10, [s_words]
    lea r11, [s_wcount]
    xor rcx, rcx
    xor rax, rax
.d:
    cmp rcx, [nsent]
    jae .fim
    ; a frase rcx contem a palavra?
    mov rdi, [r10+rcx*8]
    xor r8, r8
.dw:
    cmp r8, [r10+rcx*8+131072]
    jae .dn
    mov rax, r8
    shl rax, 4
    mov rsi, [rdi+rax]
    mov rdx, [rdi+rax+8]
    cmp rdx, r11
    jne .pwn
    push rcx
    push rsi
    push rdi
    xor r9, r9
.mc:
    cmp r9, rdx
    jae .meq
    movzx eax, byte [rsi+r9]
    movzx edx, byte [r10+r9]
    cmp eax, edx
    jne .mdif
    inc r9
    jmp .mc
.meq:
    pop rdi
    pop rsi
    pop rcx
    inc rax
    jmp .dn
.mdif:
    pop rdi
    pop rsi
    pop rcx
.pwn:
    inc r8
    jmp .dw
.dn:
    inc rcx
    jmp .d
.fim:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ================================ HTTP ======================================================

; envia tudo: rcx = buf, rdx = len
section .data
send_all:
hdr_ct:        db "Content-Type: application/json; charset=utf-8", 13, 10
hdr_ct_len     equ $ - hdr_ct
hdr_cl:        db "Content-Length: "
hdr_cl_len     equ $ - hdr_cl
hdr_tail:      db 13, 10, "Connection: close", 13, 10, "Access-Control-Allow-Origin: *", 13, 10, "Access-Control-Allow-Headers: Content-Type", 13, 10, "Access-Control-Allow-Methods: GET, POST, OPTIONS", 13, 10, 13, 10
hdr_tail_len   equ $ - hdr_tail
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov rbx, rcx
    mov r12, rdx
    xor r13, r13
.l:
    cmp r13, r12
    jae .fim
    mov rcx, [s_cli]
    mov rdx, rbx
    add rdx, r13
    mov r8, r12
    sub r8, r13
    xor r9d, r9d
    call [fn_send]
    test eax, eax
    jz .fim
    cmp eax, -1
    je .fim
    movsxd rax, eax
    add r13, rax
    jmp .l
.fim:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; monta resposta: rcx = status, rdx = ctype, r8 = corpo, r9 = len
envia_resp:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov r12, r8
    mov r13, r9
    lea rdi, [outbuf]
    mov rsi, rcx
.sh:
    movzx eax, byte [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    test eax, eax
    jnz .sh
    lea rsi, [hdr_ct]
    mov ecx, hdr_ct_len
.cp:
    movzx eax, byte [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    dec ecx
    jnz .cp
    lea rsi, [hdr_cl]
    mov ecx, hdr_cl_len
.cl:
    movzx eax, byte [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    dec ecx
    jnz .cl
    mov rax, r13
    mov rbx, 10
    xor rcx, rcx
.dv:
    xor edx, edx
    div rbx
    push rdx
    inc rcx
    test rax, rax
    jnz .dv
.dvd:
    pop rax
    add al, '0'
    mov [rdi], al
    inc rdi
    dec rcx
    jnz .dvd
    lea rsi, [hdr_tail]
    mov ecx, hdr_tail_len
.tl:
    movzx eax, byte [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    dec ecx
    jnz .tl
    mov rcx, r13
    mov rsi, r12
    rep movsb
    mov rax, rdi
    lea rdx, [outbuf]
    sub rax, rdx
    mov rdx, rax
    mov rcx, [s_cli]
    call send_all
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret


; ---------- recebe a requisicao -> rax = 1 ok, 0 falha ---------------------------------------
recv_request:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov qword [reqtot], 0
    mov qword [corpooff], 0
    mov qword [corpolen], 0
.l:
    mov rax, [reqtot]
    cmp rax, 1000000
    jae .falha
    mov rcx, [s_cli]
    lea rdx, [reqbuf]
    add rdx, rax
    mov r8, 1048576
    sub r8, rax
    xor r9d, r9d
    lea r11, [reqbuf]
    call [fn_recv]
    cmp rax, -1
    je .falha
    test eax, eax
    jz .falha
    movsxd rcx, eax
    add [reqtot], rcx
    xor r8, r8
.h:
    lea rax, [r8+4]
    cmp rax, [reqtot]
    ja .precisa
    lea r10, [reqbuf]
    cmp byte [r10+r8], 13
    jne .hn
    cmp byte [r10+r8+1], 10
    jne .hn
    cmp byte [r10+r8+2], 13
    jne .hn
    cmp byte [r10+r8+3], 10
    jne .hn
    mov [corpooff], r8
    add qword [corpooff], 4
    jmp .achou
.hn:
    inc r8
    jmp .h
.precisa:
    jmp .l
.achou:
    xor r8, r8
    mov qword [corpolen], 0
.clnext:
    inc r8
    jmp .clscan
.clscan:
    lea rax, [r8+15]
    cmp rax, [corpooff]
    jae .cldone
    cmp byte [r11+r8], 'C'
    jne .clnext
    cmp byte [r11+r8+1], 'o'
    jne .clnext
    cmp byte [r11+r8+2], 'n'
    jne .clnext
    cmp byte [r11+r8+3], 't'
    jne .clnext
    cmp byte [r11+r8+4], 'e'
    jne .clnext
    cmp byte [r11+r8+5], 'n'
    jne .clnext
    cmp byte [r11+r8+6], 't'
    jne .clnext
    cmp byte [r11+r8+7], '-'
    jne .clnext
    cmp byte [r11+r8+8], 'L'
    jne .clnext
    cmp byte [r11+r8+9], 'e'
    jne .clnext
    cmp byte [r11+r8+10], 'n'
    jne .clnext
    cmp byte [r11+r8+11], 'g'
    jne .clnext
    cmp byte [r11+r8+12], 't'
    jne .clnext
    cmp byte [r11+r8+13], 'h'
    jne .clnext

    lea rcx, [r8+15]
.dl:
    movzx eax, byte [r11+rcx]
    cmp eax, ' '
    jne .d1
    inc rcx
    jmp .dl
.d1:
    movzx eax, byte [r11+rcx]
    cmp eax, '0'
    jb .cldone
    cmp eax, '9'
    ja .cldone
    sub eax, '0'
    imul qword [corpolen], 10
    movzx edx, al
    add [corpolen], rdx
    inc rcx
    jmp .d1
.cldone:
    mov rax, [corpooff]
    add rax, [corpolen]
    cmp [reqtot], rax
    jb .l
    mov eax, 1
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.falha:
    xor eax, eax
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .text
; (clscan_next resolvido dentro do recv_request)
main:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    call sis_inicia
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout], rax
    call monta_c3map
    lea rcx, [nome_dll]
    call [__imp_LoadLibraryA]
    test rax, rax
    jz .erro
    mov r12, rax
    lea rdx, [n_WSAStartup]
    mov rcx, r12
    call [__imp_GetProcAddress]
    test rax, rax
    jz .erro
    mov [fn_WSAStartup], rax
    lea rdx, [n_socket]
    mov rcx, r12
    call [__imp_GetProcAddress]
    test rax, rax
    jz .erro
    mov [fn_socket], rax
    lea rdx, [n_htons]
    mov rcx, r12
    call [__imp_GetProcAddress]
    test rax, rax
    jz .erro
    mov [fn_htons], rax
    lea rdx, [n_bind]
    mov rcx, r12
    call [__imp_GetProcAddress]
    test rax, rax
    jz .erro
    mov [fn_bind], rax
    lea rdx, [n_listen]
    mov rcx, r12
    call [__imp_GetProcAddress]
    test rax, rax
    jz .erro
    mov [fn_listen], rax
    lea rdx, [n_accept]
    mov rcx, r12
    call [__imp_GetProcAddress]
    test rax, rax
    jz .erro
    mov [fn_accept], rax
    lea rdx, [n_recv]
    mov rcx, r12
    call [__imp_GetProcAddress]
    test rax, rax
    jz .erro
    mov [fn_recv], rax
    lea rdx, [n_send]
    mov rcx, r12
    call [__imp_GetProcAddress]
    test rax, rax
    jz .erro
    mov [fn_send], rax
    lea rdx, [n_closesocket]
    mov rcx, r12
    call [__imp_GetProcAddress]
    test rax, rax
    jz .erro
    mov [fn_closesocket], rax
    lea rdx, [n_setsockopt]
    mov rcx, r12
    call [__imp_GetProcAddress]
    test rax, rax
    jz .erro
    mov [fn_setsockopt], rax
    mov ecx, 0x202
    lea rdx, [wsad]
    call [fn_WSAStartup]
    test eax, eax
    jnz .erro
    mov ecx, 2
    mov edx, 1
    xor r8d, r8d
    call [fn_socket]
    cmp rax, -1
    je .erro
    mov [s_listen], rax
    mov rcx, [s_listen]
    mov edx, 0xFFFF
    mov r8d, 0x1006
    mov dword [tmpd], 60000
    lea r9, [tmpd]
    mov qword [rsp+32], 4
    call [fn_setsockopt]
    mov word [sa], 2
    mov ecx, 8766
    call [fn_htons]
    mov [sa+2], ax
    mov dword [sa+4], 0
    mov qword [sa+8], 0
    mov rcx, [s_listen]
    lea rdx, [sa]
    mov r8d, 16
    call [fn_bind]
    test eax, eax
    jnz .erro
    mov rcx, [s_listen]
    mov edx, 16
    call [fn_listen]
    call carrega_documentos
    lea rsi, [msg_boot]
    mov ecx, msg_boot_len
    call say
.loop:
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    call [fn_accept]
    cmp rax, -1
    je .loop
    mov [s_cli], rax
    call handle_conn
    mov rcx, [s_cli]
    call [fn_closesocket]
    jmp .loop
.erro:
    mov ecx, 1
    call [__imp_ExitProcess]
handle_conn:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    call recv_request
    test eax, eax
    jz .fim
    cmp qword [metodo], 0
    je .get
    ; ---- POST ----
    lea rdi, [reqbuf+5]
    lea rsi, [rota_resumo]
    mov rcx, 11
    call path_e
    test eax, eax
    jnz .post_resumo
    lea rdi, [reqbuf+5]
    lea rsi, [rota_busca]
    mov rcx, 10
    call path_e
    test eax, eax
    jnz .post_busca
    jmp .nao_migrado
.get:
    lea rdi, [reqbuf+4]
    lea rsi, [rota_saude]
    mov rcx, 10
    call path_e
    test eax, eax
    jnz .saude
    lea rdi, [reqbuf+4]
    lea rsi, [rota_documentos]
    mov rcx, 15
    call path_e
    test eax, eax
    jnz .documentos
    jmp .nao_migrado
.saude:
    lea rcx, [h200]
    lea rdx, [ctype_json]
    lea r8, [resp_saude]
    mov r9, resp_saude_len
    call envia_resp
    jmp .fim
.documentos:
    call lista_documentos
    jmp .fim
.post_resumo:
    mov rcx, [reqbuf]
    lea rcx, [reqbuf]
    add rcx, [corpooff]
    mov rdx, [corpolen]
    lea r8, [nm_arquivo]
    call json_campo
    cmp rax, 0
    jl .resumo_erro
    mov [reqlen], rax
    lea rdi, [reqname]
    mov ecx, 18
    rep movsb
    lea rdi, [reqname+18]
    lea rsi, [campobuf]
    mov rcx, [reqlen]
    rep movsb
    call responde_resumo
    jmp .fim
.resumo_erro:
    lea rcx, [h400]
    lea rdx, [ctype_json]
    lea r8, [resp_sem_nome]
    mov r9, resp_sem_nome_len
    call envia_resp
    jmp .fim
.post_busca:
    mov rcx, [reqbuf]
    lea rcx, [reqbuf]
    add rcx, [corpooff]
    mov rdx, [corpolen]
    lea r8, [nm_tema]
    call json_campo
    cmp rax, 0
    jl .busca_erro
    mov [reqlen], rax
    mov rdi, normmsg
    lea rsi, [campobuf]
    mov rdx, [reqlen]
    call normaliza_n
    call extrai_palavras
    call responde_busca
    jmp .fim
.busca_erro:
    lea rcx, [h400]
    lea rdx, [ctype_json]
    lea r8, [resp_sem_tema]
    mov r9, resp_sem_tema_len
    call envia_resp
    jmp .fim
.nao_migrado:
    lea rcx, [h404]
    lea rdx, [ctype_json]
    lea r8, [resp_404]
    mov r9, resp_404_len
    call envia_resp
.fim:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .data
rota_resumo:      db "/api/resumo"
rota_busca:       db "/api/busca"
rota_documentos:  db "/api/documentos"
rota_saude:       db "/api/saude"
h200:             db "HTTP/1.1 200 OK", 0
h400:             db "HTTP/1.1 400 Bad Request", 0
h404:             db "HTTP/1.1 404 Not Found", 0
ctype_json:       db "application/json; charset=utf-8", 0
nm_arquivo:       db "arquivo", 0
nm_tema:          db "tema", 0
resp_sem_nome:    db '{"erro":"diga o arquivo"}'
resp_sem_nome_len equ $ - resp_sem_nome
resp_sem_tema:    db '{"erro":"diga o tema"}'
resp_sem_tema_len equ $ - resp_sem_tema
section .text

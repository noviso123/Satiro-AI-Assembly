; ============ ASM: base comum (E/S, buffers, mensagens) ============
; Montador x86-64 em assembly para o formato COFF do pelink. Sintaxe: subconjunto
; do NASM usado pelo projeto. Este arquivo: constantes, buffers e E/S.

%define AS_FBUF_SIZE   4194304      ; buffer de leitura por nivel de %include
%define AS_FBUF_LEVELS 8
%define AS_EXBUF_SIZE  33554432     ; codigo fonte expandido (todos os includes)
%define AS_SEC_SIZE    16777216     ; .text e .data geradas (cada)
%define AS_OUT_SIZE    67108864     ; arquivo COFF de saida
%define AS_LINE_MAX    8192
%define AS_NAME_MAX    512

; Entrada/saida de rotinas que chamam o Windows: alinha a pilha em 16 bytes
; independentemente de quem chamou (rbp guarda o rsp original).
%macro AS_ENTER 0
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 64
%endmacro
%macro AS_LEAVE 0
    mov rsp, rbp
    pop rbp
%endmacro

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ReadFile
extern __imp_CreateFileA
extern __imp_CloseHandle
extern __imp_GetFileSize
extern __imp_GetCommandLineA
extern __imp_ExitProcess

section .bss
alignb 16
as_hout:     resq 1
as_hfile:    resq 1
as_bytes:    resd 1
as_wrote:    resd 1
as_srcpath:  resb 512
as_outpath:  resb 512
as_fbuf:     resb AS_FBUF_SIZE * AS_FBUF_LEVELS
as_exbuf:    resb AS_EXBUF_SIZE
as_exlen:    resq 1
as_outbuf:   resb AS_OUT_SIZE
as_tmp:      resq 8                 ; variaveis temporarias de uso geral
as_numbuf:   resb 32

section .data
align 8
as_s_usage:  db "uso: asm <entrada.asm> <saida.obj>", 13, 10, 0
as_s_open:   db "asm: nao foi possivel abrir ", 0
as_s_err:    db "asm: erro: ", 0
as_s_nl:     db 13, 10, 0
as_s_colon:  db ": ", 0
as_s_at:     db " (linha ", 0
as_s_close:  db ")", 13, 10, 0

section .text

; ---------- as_strlen: rsi -> rax ---------------------------------------------
as_strlen:
    xor eax, eax
.l:
    cmp byte [rsi+rax], 0
    je .d
    inc rax
    jmp .l
.d:
    ret

; ---------- as_say: rsi = texto zero-terminado -> stdout -----------------------
as_say:
    AS_ENTER
    mov [as_tmp], rsi
    call as_strlen
    mov r8, rax
    mov rcx, [as_hout]
    mov rdx, [as_tmp]
    lea r9, [as_wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    AS_LEAVE
    ret

; ---------- as_say_n: rsi = texto, rcx = tamanho -> stdout ---------------------
as_say_n:
    AS_ENTER
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [as_hout]
    lea r9, [as_wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    AS_LEAVE
    ret

; ---------- as_say_num: rax = valor sem sinal -> stdout ------------------------
as_say_num:
    AS_ENTER
    lea rdi, [as_numbuf+31]
    mov rcx, 10
.d:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .d
    lea rax, [as_numbuf+31]
    sub rax, rdi
    mov rcx, rax
    mov rsi, rdi
    call as_say_n
    AS_LEAVE
    ret

; ---------- as_fail: rsi = mensagem; imprime "asm: erro: <msg>" e sai com 1 ----
; Opcionalmente a linha em [as_tmp+8] (numero) e o texto em [as_tmp+16].
as_fail:
    AS_ENTER
    mov [as_tmp+24], rsi
    lea rsi, [as_s_err]
    call as_say
    mov rsi, [as_tmp+24]
    call as_say
    lea rsi, [as_s_nl]
    call as_say
    mov ecx, 1
    call [__imp_ExitProcess]

; ---------- as_read_file: rdi = caminho, rsi = destino -> rax = bytes ou -1 ----
as_read_file:
    AS_ENTER
    mov [as_tmp], rsi
    mov rcx, rdi
    mov edx, 0x80000000             ; GENERIC_READ
    mov r8d, 1
    xor r9d, r9d
    mov qword [rsp+32], 3           ; OPEN_EXISTING
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .erro
    mov [as_hfile], rax
    mov rcx, rax
    xor edx, edx
    call [__imp_GetFileSize]
    cmp eax, -1
    je .fecha
    cmp rax, AS_FBUF_SIZE
    ja .fecha
    mov [as_tmp+8], rax
    mov rcx, [as_hfile]
    mov rdx, [as_tmp]
    mov r8, [as_tmp+8]
    lea r9, [as_bytes]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    test eax, eax
    jz .fecha
    mov rcx, [as_hfile]
    call [__imp_CloseHandle]
    mov eax, [as_bytes]
    AS_LEAVE
    ret
.fecha:
    mov rcx, [as_hfile]
    call [__imp_CloseHandle]
.erro:
    mov rax, -1
    AS_LEAVE
    ret

; ---------- as_write_file: rdi = caminho, rsi = buffer, rdx = tamanho -> eax ----
as_write_file:
    AS_ENTER
    mov [as_tmp], rsi
    mov [as_tmp+8], rdx
    mov rcx, rdi
    mov edx, 0x40000000             ; GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 2           ; CREATE_ALWAYS
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .erro
    mov [as_hfile], rax
    mov rcx, rax
    mov rdx, [as_tmp]
    mov r8, [as_tmp+8]
    lea r9, [as_wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    mov rcx, [as_hfile]
    call [__imp_CloseHandle]
    mov eax, [as_wrote]
    cmp rax, [as_tmp+8]
    jne .erro
    mov eax, 1
    AS_LEAVE
    ret
.erro:
    xor eax, eax
    AS_LEAVE
    ret

; ---------- as_cmdline: srcpath e outpath a partir da linha de comando ----------
as_cmdline:
    AS_ENTER
    call [__imp_GetCommandLineA]
    mov rsi, rax
    cmp byte [rsi], '"'
    jne .nq
    inc rsi
.q:
    cmp byte [rsi], 0
    je .falha
    cmp byte [rsi], '"'
    je .qf
    inc rsi
    jmp .q
.qf:
    inc rsi
    jmp .sp
.nq:
    cmp byte [rsi], 0
    je .falha
    cmp byte [rsi], ' '
    je .sp
    inc rsi
    jmp .nq
.sp:
    cmp byte [rsi], ' '
    jne .t1
    inc rsi
    jmp .sp
.t1:
    lea rdi, [as_srcpath]
    call as_token
.sp2:
    cmp byte [rsi], ' '
    jne .t2
    inc rsi
    jmp .sp2
.t2:
    lea rdi, [as_outpath]
    call as_token
    cmp byte [as_srcpath], 0
    je .falha
    cmp byte [as_outpath], 0
    je .falha
    mov eax, 1
    AS_LEAVE
    ret
.falha:
    xor eax, eax
    AS_LEAVE
    ret

; copia um token (sem aspas) de rsi para rdi; rsi para no separador
as_token:
    xor ecx, ecx
.c:
    mov al, [rsi]
    test al, al
    jz .f
    cmp al, ' '
    je .f
    cmp al, '"'
    je .s
    cmp ecx, AS_NAME_MAX-1
    jae .s
    mov [rdi+rcx], al
    inc rcx
.s:
    inc rsi
    jmp .c
.f:
    mov byte [rdi+rcx], 0
    ret

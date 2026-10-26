bits 64
default rel
; ============ GERACAO DE TEXTO COM O TRANSFORMER ============
; So le: carrega MODELO, le o inicio do texto da entrada padrao e continua NGEN tokens
; (ou -n N). Opcoes de amostragem: ver tf_gen_core.asm (-t, -k, -p, -r, -s, -g).
%include "tf_gen_core.asm"

%ifndef NGEN
%define NGEN      400
%endif
%define PMAX      4096               ; maior inicio de texto aceito (bytes)
%define GMAX      65536              ; maior quantidade de tokens gerados

global main

section .data
padrao:      db "O Brasil "
padrao_len   equ $ - padrao
msg_nl_g:    db 13, 10

section .bss
alignb 16
glen:       resq 1                   ; tokens no texto
gcont:      resq 1
gini:       resq 1                   ; tokens do inicio
gtam:       resq 1                   ; bytes de saida
gtxt:       resb PMAX + 16
gtok:       resb (PMAX + GMAX + 16) * TB
gout:       resb GMAX * 64 + 16

section .text

main:
    sub rsp, 88
    call gc_inicia
    ; le a entrada ate o fim (um pipe pode entregar o texto em varios pedacos)
    xor r12d, r12d
.le:
    cmp r12, PMAX
    jae .leu
    mov rcx, [gc_hin]
    lea rdx, [gtxt]
    add rdx, r12
    mov r8d, PMAX
    sub r8, r12
    lea r9, [gc_wrote]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    test eax, eax
    jz .leu
    mov eax, [gc_wrote]
    test eax, eax
    jz .leu
    add r12, rax
    lea rdx, [gtxt]
    cmp byte [rdx+r12-1], 10         ; linha completa (console): para aqui
    je .leu
    jmp .le
.leu:
    mov rax, r12
    lea rsi, [gtxt]
    ; tira a marca BOM do UTF-8
    cmp eax, 3
    jb .apara
    cmp byte [rsi], 0xEF
    jne .apara
    cmp byte [rsi+1], 0xBB
    jne .apara
    cmp byte [rsi+2], 0xBF
    jne .apara
    add rsi, 3
    sub eax, 3
.apara:                              ; tira CR/LF do fim
    test eax, eax
    jz .vazio
    movzx ecx, byte [rsi+rax-1]
    cmp ecx, 13
    je .corta
    cmp ecx, 10
    je .corta
    jmp .tem
.corta:
    dec eax
    jmp .apara
.vazio:
    lea rsi, [padrao]
    mov eax, padrao_len
.tem:
    mov r12, rsi
    mov r13, rax
    mov rcx, rax
    call gc_say                      ; mostra o inicio
    mov rsi, r12
    mov rcx, r13
    lea rdi, [gtok]
    call gc_codifica
    mov [glen], rax
    mov [gini], rax
    mov rax, [gc_ngen]
    test rax, rax
    jnz .n_ok
    mov eax, NGEN
.n_ok:
    cmp rax, GMAX
    jbe .n_ok2
    mov eax, GMAX
.n_ok2:
    mov [gcont], rax
    mov qword [gtam], 0
.gera:
    cmp qword [gcont], 0
    je .fim
    lea rsi, [gtok]
    mov rcx, [glen]
    call tf_proximo
    mov rcx, [glen]
    lea rdx, [gtok]
%ifdef TOK16
    mov [rdx+rcx*2], ax
%else
    mov [rdx+rcx], al
%endif
    inc qword [glen]
    mov ecx, eax
    lea rdi, [gout]
    add rdi, [gtam]
    call gc_decodifica
    add [gtam], rax
    dec qword [gcont]
    jmp .gera
.fim:
    lea rsi, [gout]
    mov rcx, [gtam]
    call gc_say_utf8
    lea rsi, [msg_nl_g]
    mov ecx, 2
    call gc_say
    xor ecx, ecx
    call [__imp_ExitProcess]

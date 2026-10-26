bits 64
default rel
; ============ CODIFICADOR BPE: texto -> tokens (uint16) ============
; Le VOCAB e TEXTO e grava SAIDA com os tokens (2 bytes cada), na mesma ordem do texto.
; Montar com -DTOK16 -DTV=<tokens do vocabulario>. O texto e cortado em pedacos nas
; fronteiras das fusoes (antes de espaco/TAB/CR/LF e depois de LF) e cada pedaco e
; codificado com gc_codifica (pedacos sem fronteira sao cortados a cada PEDMAX bytes).
; So grava SAIDA se ela ainda nao existir.
%include "tf_gen_core.asm"

%ifndef TEXTO
%define TEXTO     "build/amostra.tsv"
%endif
%ifndef SAIDA
%define SAIDA     "build/amostra.tok"
%endif
%define CHK       4194304
%define PEDMAX    256

global main

section .data
cd_in:       db TEXTO, 0
cd_out:      db SAIDA, 0
cd_m1:       db "bytes: "
cd_m1_len    equ $ - cd_m1
cd_m2:       db "  tokens: "
cd_m2_len    equ $ - cd_m2
cd_nl:       db 13, 10
cd_erri:     db "erro: texto ausente", 13, 10
cd_erri_len  equ $ - cd_erri
cd_erro:     db "erro: SAIDA ja existe ou nao pode ser criada", 13, 10
cd_erro_len  equ $ - cd_erro

section .bss
alignb 16
cd_hin:     resq 1
cd_hout:    resq 1
cd_numb:    resb 24
cd_have:    resq 1
cd_fim:     resq 1
cd_tbytes:  resq 1
cd_ttok:    resq 1
cd_buf:     resb CHK + 16
cd_tok:     resw CHK + 16

section .text

cd_print:
    sub rsp, 88
    lea rdi, [cd_numb+20]
    mov rcx, 10
.p:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .p
    lea rax, [cd_numb+20]
    sub rax, rdi
    mov rcx, rax
    mov rsi, rdi
    call gc_say
    add rsp, 88
    ret

; fronteira: rsi = texto, rcx = posicao (>= 1) -> ZF=1 (je) se um pedaco comeca em rcx
cd_fronteira:
    movzx eax, byte [rsi+rcx]
    cmp eax, ' '
    je .s
    cmp eax, 9
    je .s
    cmp eax, 10
    je .s
    cmp eax, 13
    je .s
    cmp byte [rsi+rcx-1], 10
    ret
.s:
    ret

; cd_bloco: codifica cd_buf[0..r12) em pedacos e grava os tokens
cd_bloco:
    push rbx
    push r13
    push r14
    sub rsp, 48
    xor ebx, ebx                     ; inicio do pedaco
    mov r13d, 1                      ; posicao
    xor r14d, r14d                   ; tokens no bloco
.p:
    cmp r13, r12
    jae .ultimo
    mov rax, r13
    sub rax, rbx
    cmp rax, PEDMAX
    jae .corta
    lea rsi, [cd_buf]
    mov rcx, r13
    call cd_fronteira
    jne .n
.corta:
    lea rsi, [cd_buf]
    add rsi, rbx
    mov rcx, r13
    sub rcx, rbx
    lea rdi, [cd_tok]
    lea rdi, [rdi+r14*2]
    call gc_codifica
    add r14, rax
    mov rbx, r13
.n:
    inc r13
    jmp .p
.ultimo:
    cmp rbx, r12
    jae .grava
    lea rsi, [cd_buf]
    add rsi, rbx
    mov rcx, r12
    sub rcx, rbx
    lea rdi, [cd_tok]
    lea rdi, [rdi+r14*2]
    call gc_codifica
    add r14, rax
.grava:
    add [cd_ttok], r14
    mov rcx, [cd_hout]
    lea rdx, [cd_tok]
    lea r8, [r14*2]
    lea r9, [gc_wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 48
    pop r14
    pop r13
    pop rbx
    ret

main:
    sub rsp, 88
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [gc_hout], rax
    call gc_vocab
    lea rcx, [cd_in]
    mov edx, 0x80000000
    mov r8d, 1
    xor r9d, r9d
    mov qword [rsp+32], 3
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .erro_i
    mov [cd_hin], rax
    lea rcx, [cd_out]
    mov edx, 0x40000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 1            ; CREATE_NEW: nao sobrescreve
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .erro_o
    mov [cd_hout], rax
    mov qword [cd_have], 0
.le:
    mov rcx, [cd_hin]
    lea rdx, [cd_buf]
    add rdx, [cd_have]
    mov r8d, CHK
    sub r8, [cd_have]
    lea r9, [gc_wrote]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    mov eax, [gc_wrote]
    test eax, eax
    jz .final
    add [cd_tbytes], rax
    add [cd_have], rax
    ; ate a ultima fronteira do bloco (o resto volta para o comeco)
    mov rcx, [cd_have]
    dec rcx
    lea rsi, [cd_buf]
.ach:
    cmp rcx, 1
    jb .tudo
    call cd_fronteira
    je .achou
    dec rcx
    jmp .ach
.tudo:
    mov rcx, [cd_have]
.achou:
    mov r12, rcx
    mov [rsp+64], rcx
    call cd_bloco
    mov rcx, [cd_have]
    sub rcx, [rsp+64]
    mov [cd_have], rcx
    lea rsi, [cd_buf]
    add rsi, [rsp+64]
    lea rdi, [cd_buf]
    rep movsb
    jmp .le
.final:
    mov r12, [cd_have]
    test r12, r12
    jz .fecha
    call cd_bloco
.fecha:
    mov rcx, [cd_hout]
    call [__imp_CloseHandle]
    mov rcx, [cd_hin]
    call [__imp_CloseHandle]
    lea rsi, [cd_m1]
    mov ecx, cd_m1_len
    call gc_say
    mov rax, [cd_tbytes]
    call cd_print
    lea rsi, [cd_m2]
    mov ecx, cd_m2_len
    call gc_say
    mov rax, [cd_ttok]
    call cd_print
    lea rsi, [cd_nl]
    mov ecx, 2
    call gc_say
    xor ecx, ecx
    call [__imp_ExitProcess]
.erro_i:
    lea rsi, [cd_erri]
    mov ecx, cd_erri_len
    call gc_say
    mov ecx, 1
    call [__imp_ExitProcess]
.erro_o:
    lea rsi, [cd_erro]
    mov ecx, cd_erro_len
    call gc_say
    mov ecx, 1
    call [__imp_ExitProcess]

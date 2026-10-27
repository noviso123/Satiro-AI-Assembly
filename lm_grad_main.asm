default rel
; I/O e carga de texto (o antigo chat_core.asm nao existe mais; bloco autocontido)
%ifndef TEXTO_LM
%define TEXTO_LM  "dados/pira_valid.tsv"
%endif
%define TXTMAX_LM 16777216

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_CreateFileA
extern __imp_ReadFile
extern __imp_CloseHandle
extern __imp_ExitProcess

global main

section .data
align 8
msg_crlf:    db 13, 10
msg_semtexto_lm: db "erro: texto de avaliacao ausente ou curto demais (opcao -DTEXTO_LM=arquivo na montagem)", 13, 10
msg_semtexto_lm_len equ $ - msg_semtexto_lm
c_limg:      dd 1.0e-3               ; limite do erro (x1e9 = 1000000)

section .bss
alignb 8
hout:       resq 1
wrote_lm:   resd 1
hfile_lm:   resq 1
txt:        resb TXTMAX_LM
txtn:       resq 1

section .text

; ---------- out_bytes: rsi = bytes, rcx = quantidade -> stdout --------------------------
out_bytes:
    sub rsp, 56
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [hout]
    lea r9, [wrote_lm]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 56
    ret

; ---------- load_all: carrega o texto (TEXTO_LM) em txt/txtn ----------------------------
load_all:
    sub rsp, 56
    lea rcx, [path_txt_l]
    mov edx, 0x80000000
    mov r8d, 1
    xor r9d, r9d
    mov qword [rsp+32], 3
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .fim
    mov [hfile_lm], rax
    mov rcx, rax
    lea rdx, [txt]
    mov r8d, TXTMAX_LM
    lea r9, [wrote_lm]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    mov rcx, [hfile_lm]
    call [__imp_CloseHandle]
    mov eax, [wrote_lm]
    mov [txtn], rax
.fim:
    add rsp, 56
    ret

section .data
align 8
path_txt_l:  db TEXTO_LM, 0

%include "lm_core.asm"

; ============ TESTE DE GRADIENTE DO MODELO DE LINGUAGEM ============
; Compara o gradiente do train_step (analitico) com diferencas centrais
; sobre a perda -ln P(alvo | contexto), em TODOS os NP parametros.
section .data
align 8
c_tlr2:     dd 1.0e-3
c_h2:       dd 1.0e-1
c_2h2:      dd 2.0e-1
c_1e9:      dd 1.0e9
c_1e3:      dd 1000.0
msg_g1:     db "parametros testados: "
msg_g1_len  equ $ - msg_g1
msg_g2:     db "  erro max gradiente (x1e9): "
msg_g2_len  equ $ - msg_g2
msg_g3:     db "  |grad| max (x1e3): "
msg_g3_len  equ $ - msg_g3

section .bss
align 8
BKP:        resd NP
GAN:        resd NP
pidx:       resq 1
lnx:        resq 1
lny:        resq 1
lnc:        resq 1
L1:         resq 1
origv:      resq 1
maxerr2:    resq 1
maxg2:      resq 1
numbuf:     resb 24

section .text

; ---------- print_u: rax -> stdout ----------------------------------------
print_u:
    push rsi                         ; rsi e rdi sao preservados pela convencao x64
    push rdi
    sub rsp, 40
    lea rdi, [numbuf+20]
    mov rcx, 10
.pu:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .pu
    lea rax, [numbuf+20]
    sub rax, rdi
    mov rcx, rax
    mov rsi, rdi
    call out_bytes
    add rsp, 40
    pop rdi
    pop rsi
    ret

; ---------- ln_fn: xmm0 = ln(xmm0) por Newton sobre exp -------------------
ln_fn:
    movss [lnx], xmm0
    xorps xmm0, xmm0
    movss [lny], xmm0
    mov qword [lnc], 100
.l:
    movss xmm0, [lny]
    maxss xmm0, [c_neg30]
    minss xmm0, [c_30]
    call exp_fn
    movss xmm1, [lnx]
    movss xmm2, xmm0
    subss xmm0, xmm1
    divss xmm0, xmm2
    movss xmm3, [lny]
    subss xmm3, xmm0
    movss [lny], xmm3
    dec qword [lnc]
    jnz .l
    movss xmm0, [lny]
    ret

; ---------- loss: -ln Pv[tgt] -> xmm0 -----------------------------------
loss_t:
    lea rcx, [Pv]
    mov rax, [tgt]
    movss xmm0, [rcx+rax*4]
    call ln_fn
    mulss xmm0, [c_neg1]
    ret

main:
    sub rsp, 40
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout], rax

    call load_all
    call init_params_lm

    movss xmm0, [c_tlr2]
    movss [c_lr_lm], xmm0

    ; amostra: posicao 5000 do texto (precisa de texto suficiente)
    cmp qword [txtn], 5001
    jae .texto_ok
    lea rsi, [msg_semtexto_lm]
    mov rcx, msg_semtexto_lm_len
    call out_bytes
    mov ecx, 1
    call [__imp_ExitProcess]
.texto_ok:
    mov rax, 5000
    lea rbx, [txt]
    mov rcx, rax
    sub rcx, NCTX
    lea rdx, [rbx+rcx]
    mov [ctxp], rdx
    movzx ecx, byte [rbx+rax]
    mov [tgt], rcx

    ; backup, passo analitico, gradiente = (antes - depois)/lr
    xor r8d, r8d
.bk:
    cmp r8, NP
    jae .bkd
    lea rbx, [PAR]
    movss xmm0, [rbx+r8*4]
    lea rbx, [BKP]
    movss [rbx+r8*4], xmm0
    inc r8
    jmp .bk
.bkd:
    call train_step
    xor r8d, r8d
.ga:
    cmp r8, NP
    jae .gad
    lea rbx, [BKP]
    movss xmm0, [rbx+r8*4]
    lea rbx, [PAR]
    subss xmm0, [rbx+r8*4]
    divss xmm0, [c_tlr2]
    lea rbx, [GAN]
    movss [rbx+r8*4], xmm0
    inc r8
    jmp .ga
.gad:
    ; restaura PAR
    xor r8d, r8d
.rs:
    cmp r8, NP
    jae .rsd
    lea rbx, [BKP]
    movss xmm0, [rbx+r8*4]
    lea rbx, [PAR]
    movss [rbx+r8*4], xmm0
    inc r8
    jmp .rs
.rsd:

    ; gradiente numerico e comparacao, para cada parametro
    mov qword [pidx], 0
.gn:
    mov rax, [pidx]
    cmp rax, NP
    jae .gnd
    lea rbx, [PAR]
    movss xmm0, [rbx+rax*4]
    movss [origv], xmm0

    addss xmm0, [c_h2]
    mov rax, [pidx]
    lea rbx, [PAR]
    movss [rbx+rax*4], xmm0
    call forward_lm
    call loss_t
    movss [L1], xmm0

    mov rax, [pidx]
    lea rbx, [PAR]
    movss xmm0, [origv]
    subss xmm0, [c_h2]
    movss [rbx+rax*4], xmm0
    call forward_lm
    call loss_t
    movss xmm1, [L1]
    subss xmm1, xmm0
    divss xmm1, [c_2h2]            ; gradiente numerico em xmm1

    ; restaura o parametro
    mov rax, [pidx]
    lea rbx, [PAR]
    movss xmm0, [origv]
    movss [rbx+rax*4], xmm0

    ; erro = |GAN - gnum| ; |GAN|
    lea rbx, [GAN]
    movss xmm2, [rbx+rax*4]
    subss xmm2, xmm1
    mulss xmm2, xmm2
    sqrtss xmm2, xmm2
    movss xmm3, [maxerr2]
    maxss xmm3, xmm2
    movss [maxerr2], xmm3

    mov rax, [pidx]
    lea rbx, [GAN]
    movss xmm2, [rbx+rax*4]
    mulss xmm2, xmm2
    sqrtss xmm2, xmm2
    movss xmm3, [maxg2]
    maxss xmm3, xmm2
    movss [maxg2], xmm3

    inc qword [pidx]
    jmp .gn
.gnd:

    lea rsi, [msg_g1]
    mov rcx, msg_g1_len
    call out_bytes
    mov rax, NP
    call print_u
    lea rsi, [msg_g2]
    mov rcx, msg_g2_len
    call out_bytes
    movss xmm0, [maxerr2]
    mulss xmm0, [c_1e9]
    cvttss2si rax, xmm0
    call print_u
    lea rsi, [msg_g3]
    mov rcx, msg_g3_len
    call out_bytes
    movss xmm0, [maxg2]
    mulss xmm0, [c_1e3]
    cvttss2si rax, xmm0
    call print_u
    lea rsi, [msg_crlf]
    mov rcx, 2
    call out_bytes

    ; sai 1 se o erro passou do limite (o valida_tudo confere o exit code)
    movss xmm0, [maxerr2]
    comiss xmm0, [c_limg]
    jbe .ok_lg
    mov ecx, 1
    call [__imp_ExitProcess]
.ok_lg:
    xor ecx, ecx
    call [__imp_ExitProcess]

bits 64
default rel
; ============ TESTE: lote com threads == soma sequencial dos gradientes ========
; Mesmos pesos e mesmas amostras. Um lote com NTHREADS workers deve gerar o mesmo
; PAR que a soma sequencial das amostras no bloco ctx0 (mesmo fator c_lr_batch/n).
; Imprime o maior erro absoluto x1e12 (esperado: 0).
%include "lm_core.asm"

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ExitProcess

global main

%define NS 32                           ; amostras no lote

section .data
align 8
txt_b:      db "Satiro IA aprende bytes do portugues em lotes com threads!!"
msg_err:    db "erro maximo lote vs sequencial (x1e12): "
msg_err_len equ $ - msg_err
msg_nl:     db 13, 10
c_1e12:     dd 1.0e12

section .bss
alignb 32
P0:         resd NP
P1:         resd NP
hout:       resq 1
errv:       resq 1
wrote:      resd 1
numbuf:     resb 24

section .text

; ---------- say: rsi = texto, rcx = tamanho -> stdout ------------------------
say:
    sub rsp, 56
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [hout]
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 56
    ret

; ---------- print_u: rax -> stdout -------------------------------------------
print_u:
    sub rsp, 88
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
    call say
    add rsp, 88
    ret

main:
    sub rsp, 88
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout], rax

    call init_params_lm
    call init_workers

    ; P0 = pesos iniciais
    lea rsi, [PAR]
    lea rdi, [P0]
    mov ecx, NP
    rep movsd

    ; caminho paralelo: um lote com NS amostras
    lea rcx, [txt_b]
    mov edx, NS
    call train_batch

    ; P1 = pesos apos o lote
    lea rsi, [PAR]
    lea rdi, [P1]
    mov ecx, NP
    rep movsd

    ; referencia sequencial: G0 = soma dos gradientes com PAR = P0
    lea rsi, [P0]
    lea rdi, [PAR]
    mov ecx, NP
    rep movsd
    lea r15, [ctx0]
    call zero_grad
    xor r12d, r12d
.ref:
    cmp r12d, NS
    jae .refd
    lea rax, [txt_b]
    add rax, r12
    mov [ctxp], rax
    lea rax, [txt_b+NCTX]
    movzx ecx, byte [rax+r12]
    mov [tgt], rcx
    call grad_sample
    inc r12d
    jmp .ref
.refd:
    ; esperado = P0 + (c_upd * c_lr_batch / NS) * G0 ; erro = |P1 - esperado|
    movss xmm4, [c_upd]
    mulss xmm4, [c_lr_batch]
    mov eax, NS
    cvtsi2ss xmm5, rax
    divss xmm4, xmm5
    xorps xmm6, xmm6
    xor r8d, r8d
.cmp:
    cmp r8, NP
    jae .cmpd
    movss xmm0, [r15+r8*4+CX_G]
    mulss xmm0, xmm4
    lea rbx, [P0]
    movss xmm1, [rbx+r8*4]
    addss xmm0, xmm1
    lea rbx, [P1]
    movss xmm2, [rbx+r8*4]
    subss xmm2, xmm0
    mulss xmm2, xmm2
    maxss xmm6, xmm2
    inc r8
    jmp .cmp
.cmpd:
    sqrtss xmm6, xmm6
    mulss xmm6, [c_1e12]
    cvttss2si rax, xmm6
    mov [errv], rax                 ; say() sobrescreve rax (retorno do WriteFile)

    lea rsi, [msg_err]
    mov ecx, msg_err_len
    call say
    mov rax, [errv]
    call print_u
    lea rsi, [msg_nl]
    mov ecx, 2
    call say

    xor ecx, ecx
    call [__imp_ExitProcess]

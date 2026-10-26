bits 64
default rel
; ============ TESTE: derivada direcional do transformer, por regiao de parametros ============
; Para cada regiao R: d = sinais aleatorios (+1/-1) em R, 0 fora. Compara
;   dL = L(w + eps d) - L(w - eps d)   com   ga = sum_i g_i (w+_i - w-_i)
; (w+ e w- sao os floats realmente gravados). O sinal soma milhares de parametros e
; fica muito maior que o ruido do float32. Imprime o erro relativo |dL - ga| / |ga| x1000.
%include "tf_model.asm"

%define NREG 25

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ExitProcess
global main

section .data
align 8
txt_g:   db "O clima no Brasil muda com o aquecimento do oceano e as chuvas mudam tambem."
c_eps:   dd 1.0e-3
c_ln2:   dq 0.6931471805599453
c_one_d: dq 1.0
c_sqrt2: dq 1.4142135623730951
c_half:  dq 0.5
c_1e3:   dq 1000.0
c_1e6:   dq 1.0e6
; regioes: inicio, fim (indices em TPAR)
regs:
    dq OFF_E, OFF_E + TV*TD
    dq OFF_P, OFF_P + TT*TD
    dq OFF_L0 + L_LN1G, OFF_L0 + L_LN1G + 2*TD
    dq OFF_L0 + L_WQ, OFF_L0 + L_WQ + TD*TD
    dq OFF_L0 + L_WK, OFF_L0 + L_WK + TD*TD
    dq OFF_L0 + L_WV, OFF_L0 + L_WV + TD*TD
    dq OFF_L0 + L_WO, OFF_L0 + L_WO + TD*TD
    dq OFF_L0 + L_LN2G, OFF_L0 + L_LN2G + 2*TD
    dq OFF_L0 + L_W1, OFF_L0 + L_W1 + TD*TF
    dq OFF_L0 + L_B1, OFF_L0 + L_B1 + TF
    dq OFF_L0 + L_W2, OFF_L0 + L_W2 + TF*TD
    dq OFF_L0 + L_B2, OFF_L0 + L_B2 + TD
    dq OFF_L0 + LSZ + L_LN1G, OFF_L0 + LSZ + L_LN1G + 2*TD
    dq OFF_L0 + LSZ + L_WQ, OFF_L0 + LSZ + L_WQ + TD*TD
    dq OFF_L0 + LSZ + L_WK, OFF_L0 + LSZ + L_WK + TD*TD
    dq OFF_L0 + LSZ + L_WV, OFF_L0 + LSZ + L_WV + TD*TD
    dq OFF_L0 + LSZ + L_WO, OFF_L0 + LSZ + L_WO + TD*TD
    dq OFF_L0 + LSZ + L_LN2G, OFF_L0 + LSZ + L_LN2G + 2*TD
    dq OFF_L0 + LSZ + L_W1, OFF_L0 + LSZ + L_W1 + TD*TF
    dq OFF_L0 + LSZ + L_B1, OFF_L0 + LSZ + L_B1 + TF
    dq OFF_L0 + LSZ + L_W2, OFF_L0 + LSZ + L_W2 + TF*TD
    dq OFF_L0 + LSZ + L_B2, OFF_L0 + LSZ + L_B2 + TD
    dq OFF_LNFG, OFF_LNFG + 2*TD
    dq 0, TNP
    dq 0, TNP
nomes:
    db "E       ", "P       ", "b0 LN1  ", "b0 Wq   ", "b0 Wk   ", "b0 Wv   ", "b0 Wo   ", "b0 LN2  "
    db "b0 W1   ", "b0 b1   ", "b0 W2   ", "b0 b2   ", "b1 LN1  ", "b1 Wq   ", "b1 Wk   ", "b1 Wv   "
    db "b1 Wo   ", "b1 LN2  ", "b1 W1   ", "b1 b1   ", "b1 W2   ", "b1 b2   ", "LN final", "tudo    "
    db "tudo(2) "
s_rel:   db "  erro relativo x1000: "
s_rel_len equ $ - s_rel
s_ga:    db "  |ga| x1e6: "
s_ga_len equ $ - s_ga
s_nl:    db 13, 10

section .bss
alignb 32
BKP:     resd TNP
SINAL:   resb TNP
hout_g:  resq 1
wrote_g: resd 1
nbuf_g:  resb 24
reg_i:   resq 1
r_ini:   resq 1
r_fim:   resq 1
lplus:   resq 1
ga_s:    resq 1
lnx:     resq 1
seed_d:  resq 1

section .text
say_g:
    sub rsp, 56
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [hout_g]
    lea r9, [wrote_g]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 56
    ret
print_g:
    sub rsp, 88
    lea rdi, [nbuf_g+20]
    mov rcx, 10
.p:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .p
    lea rax, [nbuf_g+20]
    sub rax, rdi
    mov rcx, rax
    mov rsi, rdi
    call say_g
    add rsp, 88
    ret
ln_d:
    movsd [lnx], xmm0
    mov rax, [lnx]
    mov rcx, rax
    shr rcx, 52
    and ecx, 0x7FF
    sub ecx, 1023
    mov rdx, 0x000FFFFFFFFFFFFF
    and rax, rdx
    mov rdx, 0x3FF0000000000000
    or rax, rdx
    mov [lnx], rax
    movsd xmm1, [lnx]
    comisd xmm1, [c_sqrt2]
    jb .ok
    mulsd xmm1, [c_half]
    inc ecx
.ok:
    movsd xmm2, xmm1
    subsd xmm2, [c_one_d]
    addsd xmm1, [c_one_d]
    divsd xmm2, xmm1
    movsd xmm3, xmm2
    mulsd xmm3, xmm3
    movsd xmm4, xmm2
    xorpd xmm5, xmm5
    mov edx, 1
.s:
    cvtsi2sd xmm6, rdx
    movsd xmm7, xmm4
    divsd xmm7, xmm6
    addsd xmm5, xmm7
    mulsd xmm4, xmm3
    add edx, 2
    cmp edx, 23
    jbe .s
    addsd xmm5, xmm5
    cvtsi2sd xmm0, ecx
    mulsd xmm0, [c_ln2]
    addsd xmm0, xmm5
    ret
perda:
    push r12
    xorpd xmm8, xmm8
    xor r12d, r12d
.l:
    cmp r12, TT
    jae .f
    lea rax, [txt_g]
    movzx eax, byte [rax+r12+1]
    mov rdx, r12
    imul rdx, rdx, TV
    add rdx, rax
    lea rax, [r15+TX_A_PR]
    cvtss2sd xmm0, [rax+rdx*4]
    call ln_d
    subsd xmm8, xmm0
    inc r12
    jmp .l
.f:
    mov eax, TT
    cvtsi2sd xmm1, rax
    divsd xmm8, xmm1
    movsd xmm0, xmm8
    pop r12
    ret
; aplica: TPAR[i] = BKP[i] + s * eps * sinal[i] para i em [r_ini, r_fim); s em xmm7 (+1/-1)
aplica:
    mov rcx, [r_ini]
.l:
    cmp rcx, [r_fim]
    jae .f
    lea rax, [BKP]
    movss xmm0, [rax+rcx*4]
    movss xmm1, [c_eps]
    mulss xmm1, xmm7
    lea rax, [SINAL]
    cmp byte [rax+rcx], 0
    je .pos
    xorps xmm2, xmm2
    subss xmm2, xmm1
    movaps xmm1, xmm2
.pos:
    addss xmm0, xmm1
    lea rax, [TPAR]
    movss [rax+rcx*4], xmm0
    inc rcx
    jmp .l
.f:
    ret
restaura:
    lea rsi, [BKP]
    lea rdi, [TPAR]
    mov ecx, TNP
    rep movsd
    ret

main:
    sub rsp, 88
    lea r15, [TCTX]                 ; bloco de contexto da thread principal
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout_g], rax
    mov qword [tf_seed], 4242
    call tf_init_params
    lea rax, [txt_g]
    mov [r15+TX_tf_tok], rax
    lea rdi, [r15+TX_TG]
    mov ecx, TNP
    xor eax, eax
    rep stosd
    call tf_forward
    call tf_backward
    lea rsi, [TPAR]
    lea rdi, [BKP]
    mov ecx, TNP
    rep movsd
    ; sinais aleatorios para todos os parametros
    mov qword [seed_d], 777
    xor ecx, ecx
.sg:
    cmp rcx, TNP
    jae .sg_ok
    mov rax, [seed_d]
    imul rax, rax, 6364136223846793005
    add rax, 1442695040888963407
    mov [seed_d], rax
    shr rax, 63
    lea rdx, [SINAL]
    mov [rdx+rcx], al
    inc rcx
    jmp .sg
.sg_ok:
    mov qword [reg_i], 0
.reg:
    cmp qword [reg_i], NREG
    jae .fim
    mov rax, [reg_i]
    shl rax, 4
    lea rdx, [regs]
    mov rcx, [rdx+rax]
    mov [r_ini], rcx
    mov rcx, [rdx+rax+8]
    mov [r_fim], rcx
    ; L+
    movss xmm7, [tf_one]
    call aplica
    ; ga = sum g_i (w+_i - w-_i): guarda w+ em TG? nao: calcula ao vivo
    call tf_forward
    call perda
    movsd [lplus], xmm0
    ; ga parcial com w+
    xorpd xmm9, xmm9
    mov rcx, [r_ini]
.g1:
    cmp rcx, [r_fim]
    jae .g1_ok
    lea rax, [TPAR]
    cvtss2sd xmm0, [rax+rcx*4]
    lea rax, [r15+TX_TG]
    cvtss2sd xmm1, [rax+rcx*4]
    mulsd xmm0, xmm1
    addsd xmm9, xmm0
    inc rcx
    jmp .g1
.g1_ok:
    movsd [ga_s], xmm9
    ; L-
    xorps xmm7, xmm7
    subss xmm7, [tf_one]
    call aplica
    call tf_forward
    call perda
    movsd xmm8, [lplus]
    subsd xmm8, xmm0                ; dL
    xorpd xmm9, xmm9
    mov rcx, [r_ini]
.g2:
    cmp rcx, [r_fim]
    jae .g2_ok
    lea rax, [TPAR]
    cvtss2sd xmm0, [rax+rcx*4]
    lea rax, [r15+TX_TG]
    cvtss2sd xmm1, [rax+rcx*4]
    mulsd xmm0, xmm1
    addsd xmm9, xmm0
    inc rcx
    jmp .g2
.g2_ok:
    movsd xmm1, [ga_s]
    subsd xmm1, xmm9                ; ga = sum g (w+ - w-)
    movsd [ga_s], xmm1
    call restaura
    ; imprime nome, erro relativo, |ga|
    mov rax, [reg_i]
    lea rsi, [nomes]
    lea rsi, [rsi+rax*8]
    mov ecx, 8
    push rax
    sub rsp, 8
    movsd [rsp], xmm8
    call say_g
    movsd xmm8, [rsp]
    add rsp, 8
    pop rax
    movsd xmm0, xmm8
    subsd xmm0, [ga_s]
    mulsd xmm0, xmm0
    sqrtsd xmm0, xmm0
    movsd xmm1, [ga_s]
    mulsd xmm1, xmm1
    sqrtsd xmm1, xmm1
    divsd xmm0, xmm1
    mulsd xmm0, [c_1e3]
    cvttsd2si rax, xmm0
    push rax
    sub rsp, 8
    lea rsi, [s_rel]
    mov ecx, s_rel_len
    call say_g
    add rsp, 8
    pop rax
    call print_g
    lea rsi, [s_ga]
    mov ecx, s_ga_len
    call say_g
    movsd xmm0, [ga_s]
    mulsd xmm0, xmm0
    sqrtsd xmm0, xmm0
    mulsd xmm0, [c_1e6]
    cvttsd2si rax, xmm0
    call print_g
    lea rsi, [s_nl]
    mov ecx, 2
    call say_g
    inc qword [reg_i]
    jmp .reg
.fim:
    xor ecx, ecx
    call [__imp_ExitProcess]

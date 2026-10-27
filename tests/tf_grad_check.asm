bits 64
default rel
; ============ TESTE: gradiente do transformer contra diferencas finitas ============
; Perda L = -1/TT * sum_t ln P_t(alvo) (em double, a partir das probabilidades do
; forward). Compara o gradiente do backward com (L(w+h) - L(w-h)) / (w+h - (w-h))
; em um parametro a cada PASSO. Imprime o erro relativo maximo x1000 e o absoluto.
%include "tf_model.asm"

%ifndef PASSO
%define PASSO 37
%endif
%ifndef HPASSO
%define HPASSO 1.0e-2
%endif
%ifndef INICIO
%define INICIO 0
%endif
%ifndef FIM
%define FIM TNP
%endif

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ExitProcess
global main

section .data
c_lim_g:    dq 0.5                   ; limite do erro relativo (x1000 = 500)
align 8
txt_g:   db "O clima no Brasil muda com o aquecimento do oceano e as chuvas mudam tambem."
c_h:     dd HPASSO
c_ln2:   dq 0.6931471805599453
c_one_d: dq 1.0
c_two_d: dq 2.0
c_sqrt2: dq 1.4142135623730951
c_half:  dq 0.5
c_1e6:   dq 1.0e6
c_1e3:   dq 1000.0
c_tiny:  dq 1.0e-2
s_ini:   db "perda inicial x1000: "
s_ini_len equ $ - s_ini
s_n:     db 13, 10, "parametros verificados: "
s_n_len  equ $ - s_n
s_rel:   db "  erro relativo max x1000: "
s_rel_len equ $ - s_rel
s_abs:   db "  erro absoluto max x1e6: "
s_abs_len equ $ - s_abs
s_g:     db "  |grad| max x1e6: "
s_g_len  equ $ - s_g
s_nl:    db 13, 10
s_w:     db 13, 10, "pior indice: "
s_w_len  equ $ - s_w
s_wa:    db "  analitico x1e6: "
s_wa_len equ $ - s_wa
s_wn:    db "  numerico x1e6: "
s_wn_len equ $ - s_wn
s_menos: db "-"

section .bss
alignb 16
hout_g:  resq 1
wrote_g: resd 1
nbuf_g:  resb 24
pidx:    resq 1
nver:    resq 1
orig:    resd 1
wpl:     resd 1
wmi:     resd 1
lplus:   resq 1
maxrel:  resq 1
maxabs:  resq 1
maxg:    resq 1
lnx:     resq 1
widx:    resq 1
wga:     resq 1
wgn:     resq 1
aidx:    resq 1
aga:     resq 1
agn:     resq 1

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

; print_sd: xmm0 (double) * 1e6 com sinal
print_sd:
    sub rsp, 40
    mulsd xmm0, [c_1e6]
    cvttsd2si rax, xmm0
    test rax, rax
    jns .pos
    push rax
    sub rsp, 8
    lea rsi, [s_menos]
    mov ecx, 1
    call say_g
    add rsp, 8
    pop rax
    neg rax
.pos:
    call print_g
    add rsp, 40
    ret

; ln_d: xmm0 = ln(xmm0), x > 0 (double). x = m * 2^e, m em [sqrt(2)/2, sqrt(2))
ln_d:
    movsd [lnx], xmm0
    mov rax, [lnx]
    mov rcx, rax
    shr rcx, 52
    and ecx, 0x7FF
    sub ecx, 1023                   ; e
    mov rdx, 0x000FFFFFFFFFFFFF
    and rax, rdx
    mov rdx, 0x3FF0000000000000
    or rax, rdx                     ; m em [1, 2)
    mov [lnx], rax
    movsd xmm1, [lnx]
    comisd xmm1, [c_sqrt2]
    jb .ok
    mulsd xmm1, [c_half]
    inc ecx
.ok:
    ; z = (m-1)/(m+1); ln m = 2 (z + z^3/3 + ... + z^21/21)
    movsd xmm2, xmm1
    subsd xmm2, [c_one_d]
    addsd xmm1, [c_one_d]
    divsd xmm2, xmm1                ; z
    movsd xmm3, xmm2
    mulsd xmm3, xmm3                ; z^2
    movsd xmm4, xmm2                ; termo z^(2k+1)
    xorpd xmm5, xmm5                ; soma
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
    addsd xmm5, xmm5                ; ln m
    cvtsi2sd xmm0, ecx              ; expoente com sinal (32 bits)
    mulsd xmm0, [c_ln2]
    addsd xmm0, xmm5
    ret

; perda: xmm0 = -1/TT * sum_t ln P_t(alvo), a partir de A_PR (depois do forward)
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
    ; gradiente analitico
    lea rdi, [r15+TX_TG]
    mov ecx, TNP
    xor eax, eax
    rep stosd
    call tf_forward
    call perda
    lea rsi, [s_ini]
    mov ecx, s_ini_len
    movsd [lplus], xmm0
    call say_g
    movsd xmm0, [lplus]
    mulsd xmm0, [c_1e3]
    cvttsd2si rax, xmm0
    call print_g
    call tf_backward
    ; diferencas finitas
    mov qword [maxrel], 0
    mov qword [maxabs], 0
    mov qword [maxg], 0
    mov qword [nver], 0
    mov qword [pidx], INICIO
.gn:
    mov rax, [pidx]
    cmp rax, FIM
    jae .fim
    lea rbx, [TPAR]
    movss xmm0, [rbx+rax*4]
    movss [orig], xmm0
    addss xmm0, [c_h]
    movss [wpl], xmm0
    movss [rbx+rax*4], xmm0
    call tf_forward
    call perda
    movsd [lplus], xmm0
    mov rax, [pidx]
    lea rbx, [TPAR]
    movss xmm0, [orig]
    subss xmm0, [c_h]
    movss [wmi], xmm0
    movss [rbx+rax*4], xmm0
    call tf_forward
    call perda
    movsd xmm1, [lplus]
    subsd xmm1, xmm0                ; L+ - L-
    cvtss2sd xmm2, [wpl]
    cvtss2sd xmm3, [wmi]
    subsd xmm2, xmm3
    divsd xmm1, xmm2                ; gradiente numerico
    mov rax, [pidx]
    lea rbx, [TPAR]
    movss xmm0, [orig]
    movss [rbx+rax*4], xmm0         ; restaura
    lea rbx, [r15+TX_TG]
    cvtss2sd xmm2, [rbx+rax*4]      ; gradiente analitico
    ; erros
    movsd xmm3, xmm2
    subsd xmm3, xmm1
    mulsd xmm3, xmm3
    sqrtsd xmm3, xmm3               ; |ga - gn|
    comisd xmm3, [maxabs]
    jbe .naoabs
    movsd [maxabs], xmm3
    mov rax, [pidx]
    mov [aidx], rax
    movsd [aga], xmm2
    movsd [agn], xmm1
.naoabs:
    movsd xmm5, xmm2
    mulsd xmm5, xmm5
    sqrtsd xmm5, xmm5               ; |ga|
    movsd xmm4, [maxg]
    maxsd xmm4, xmm5
    movsd [maxg], xmm4
    movsd xmm6, xmm1
    mulsd xmm6, xmm6
    sqrtsd xmm6, xmm6               ; |gn|
    addsd xmm6, xmm5
    comisd xmm6, [c_tiny]
    jb .prox                        ; gradiente muito pequeno: so o absoluto conta
    divsd xmm3, xmm6
    comisd xmm3, [maxrel]
    jbe .prox
    movsd [maxrel], xmm3
    mov rax, [pidx]
    mov [widx], rax
    movsd [wga], xmm2
    movsd [wgn], xmm1
.prox:
    inc qword [nver]
    add qword [pidx], PASSO
    jmp .gn
.fim:
    lea rsi, [s_n]
    mov ecx, s_n_len
    call say_g
    mov rax, [nver]
    call print_g
    lea rsi, [s_rel]
    mov ecx, s_rel_len
    call say_g
    movsd xmm0, [maxrel]
    mulsd xmm0, [c_1e3]
    cvttsd2si rax, xmm0
    call print_g
    lea rsi, [s_abs]
    mov ecx, s_abs_len
    call say_g
    movsd xmm0, [maxabs]
    mulsd xmm0, [c_1e6]
    cvttsd2si rax, xmm0
    call print_g
    lea rsi, [s_g]
    mov ecx, s_g_len
    call say_g
    movsd xmm0, [maxg]
    mulsd xmm0, [c_1e6]
    cvttsd2si rax, xmm0
    call print_g
    lea rsi, [s_w]
    mov ecx, s_w_len
    call say_g
    mov rax, [widx]
    call print_g
    lea rsi, [s_wa]
    mov ecx, s_wa_len
    call say_g
    movsd xmm0, [wga]
    call print_sd
    lea rsi, [s_wn]
    mov ecx, s_wn_len
    call say_g
    movsd xmm0, [wgn]
    call print_sd
    lea rsi, [s_w]
    mov ecx, s_w_len
    call say_g
    mov rax, [aidx]
    call print_g
    lea rsi, [s_wa]
    mov ecx, s_wa_len
    call say_g
    movsd xmm0, [aga]
    call print_sd
    lea rsi, [s_wn]
    mov ecx, s_wn_len
    call say_g
    movsd xmm0, [agn]
    call print_sd
    lea rsi, [s_nl]
    mov ecx, 2
    call say_g
    ; sai 1 se o erro relativo maximo passou do limite (o valida confere o exit code)
    movsd xmm0, [maxrel]
    comisd xmm0, [c_lim_g]
    jbe .ok_g
    mov ecx, 1
    call [__imp_ExitProcess]
.ok_g:
    xor ecx, ecx
    call [__imp_ExitProcess]

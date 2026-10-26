bits 64
default rel
; ============ TESTE: produtos de matriz do nucleo transformer ============
; Compara mm_nn, mm_nt e mm_tn com uma implementacao ingenua (acumulando em
; double). Imprime o maior erro absoluto x1e9 de cada uma (esperado: pequeno).
%include "tf_core.asm"

%define TM 24
%define TK 40
%define TN 16

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ExitProcess
global main

section .data
align 8
c_inv2_31:  dq 4.656612873077393e-10      ; 1/2^31
c_1e9_t:    dq 1.0e9
s_nn:       db "mm_nn erro x1e9: "
s_nn_len    equ $ - s_nn
s_nt:       db "  mm_nt erro x1e9: "
s_nt_len    equ $ - s_nt
s_tn:       db "  mm_tn erro x1e9: "
s_tn_len    equ $ - s_tn
s_nl:       db 13, 10
seed_t:     dq 12345

section .bss
alignb 32
TCTXM: resb 256 + 16384*4         ; contexto: variaveis de mm_* e buffer de transposicao
MA:   resd TM*TK      ; A  [m x k]
MB:   resd TK*TN      ; B  [k x n]
MBT:  resd TN*TK      ; B' [n x k]
MAT:  resd TK*TM      ; A' [k x m]
MC:   resd TM*TN
hout_t:  resq 1
wrote_t: resd 1
nbuf_t:  resb 24
ii:   resq 1
jj:   resq 1
kk:   resq 1
maxe: resq 1                 ; double

section .text
say_t:
    sub rsp, 56
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [hout_t]
    lea r9, [wrote_t]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 56
    ret
print_t:
    sub rsp, 88
    lea rdi, [nbuf_t+20]
    mov rcx, 10
.p:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .p
    lea rax, [nbuf_t+20]
    sub rax, rdi
    mov rcx, rax
    mov rsi, rdi
    call say_t
    add rsp, 88
    ret
; rand_f: xmm0 = float em [-1, 1)
rand_f:
    mov rax, [seed_t]
    imul rax, rax, 1103515245
    add rax, 12345
    mov [seed_t], rax
    shr rax, 16
    and eax, 0x7FFFFFFF
    cvtsi2sd xmm0, rax
    mulsd xmm0, [c_inv2_31]
    addsd xmm0, xmm0
    subsd xmm0, [c_one_t]
    cvtsd2ss xmm0, xmm0
    ret
; fill: rdi = destino, rcx = quantidade
fill:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rcx
.l:
    test r12, r12
    jz .f
    call rand_f
    movss [rbx], xmm0
    add rbx, 4
    dec r12
    jmp .l
.f:
    pop r12
    pop rbx
    ret
zeroC:
    lea rdi, [MC]
    xor eax, eax
    mov ecx, TM*TN
    rep stosd
    ret
; checa: erro max entre MC e a referencia ref(i,j) dada por r10 (1=nn, 2=nt, 3=tn)
checa:
    mov qword [maxe], 0
    mov qword [ii], 0
.li:
    cmp qword [ii], TM
    jae .fim
    mov qword [jj], 0
.lj:
    cmp qword [jj], TN
    jae .pi
    ; soma em double
    xorpd xmm4, xmm4
    mov qword [kk], 0
.lk:
    cmp qword [kk], TK
    jae .cmp
    mov rax, [ii]
    mov rcx, [jj]
    mov rdx, [kk]
    cmp r10, 2
    je .ref_nt
    cmp r10, 3
    je .ref_tn
    ; nn: A[i][k] * B[k][j]
    imul rax, rax, TK
    add rax, rdx
    lea r8, [MA]
    cvtss2sd xmm0, [r8+rax*4]
    imul rdx, rdx, TN
    add rdx, rcx
    lea r8, [MB]
    cvtss2sd xmm1, [r8+rdx*4]
    jmp .mul
.ref_nt:
    ; nt: A[i][k] * B'[j][k]
    imul rax, rax, TK
    add rax, rdx
    lea r8, [MA]
    cvtss2sd xmm0, [r8+rax*4]
    imul rcx, rcx, TK
    add rcx, rdx
    lea r8, [MBT]
    cvtss2sd xmm1, [r8+rcx*4]
    jmp .mul
.ref_tn:
    ; tn: A'[k][i] * B[k][j]
    mov r9, rdx
    imul r9, r9, TM
    add r9, rax
    lea r8, [MAT]
    cvtss2sd xmm0, [r8+r9*4]
    imul rdx, rdx, TN
    add rdx, rcx
    lea r8, [MB]
    cvtss2sd xmm1, [r8+rdx*4]
.mul:
    mulsd xmm0, xmm1
    addsd xmm4, xmm0
    inc qword [kk]
    jmp .lk
.cmp:
    mov rax, [ii]
    imul rax, rax, TN
    add rax, [jj]
    lea r8, [MC]
    cvtss2sd xmm0, [r8+rax*4]
    subsd xmm0, xmm4
    mulsd xmm0, xmm0
    sqrtsd xmm0, xmm0
    maxsd xmm0, [maxe]
    movsd [maxe], xmm0
    inc qword [jj]
    jmp .lj
.pi:
    inc qword [ii]
    jmp .li
.fim:
    movsd xmm0, [maxe]
    mulsd xmm0, [c_1e9_t]
    cvttsd2si rax, xmm0
    ret

main:
    sub rsp, 88
    lea r15, [TCTXM]
    lea rax, [r15+256]
    mov [r15+TX_mm_tb], rax
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout_t], rax
    lea rdi, [MA]
    mov ecx, TM*TK
    call fill
    lea rdi, [MB]
    mov ecx, TK*TN
    call fill
    lea rdi, [MBT]
    mov ecx, TN*TK
    call fill
    lea rdi, [MAT]
    mov ecx, TK*TM
    call fill
    ; nn
    call zeroC
    lea rax, [MA]
    mov [r15+TX_mm_a], rax
    lea rax, [MB]
    mov [r15+TX_mm_b], rax
    lea rax, [MC]
    mov [r15+TX_mm_c], rax
    mov qword [r15+TX_mm_m], TM
    mov qword [r15+TX_mm_k], TK
    mov qword [r15+TX_mm_n], TN
    call mm_nn
    mov r10, 1
    call checa
    push rax
    lea rsi, [s_nn]
    mov ecx, s_nn_len
    call say_t
    pop rax
    call print_t
    ; nt
    call zeroC
    lea rax, [MBT]
    mov [r15+TX_mm_b], rax
    call mm_nt
    mov r10, 2
    call checa
    push rax
    lea rsi, [s_nt]
    mov ecx, s_nt_len
    call say_t
    pop rax
    call print_t
    ; tn
    call zeroC
    lea rax, [MAT]
    mov [r15+TX_mm_a], rax
    lea rax, [MB]
    mov [r15+TX_mm_b], rax
    call mm_tn
    mov r10, 3
    call checa
    push rax
    lea rsi, [s_tn]
    mov ecx, s_tn_len
    call say_t
    pop rax
    call print_t
    lea rsi, [s_nl]
    mov ecx, 2
    call say_t
    xor ecx, ecx
    call [__imp_ExitProcess]

section .data
c_one_t:    dq 1.0

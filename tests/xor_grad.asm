default rel
%include "xor_core.asm"

; ============ TESTE: gradiente do xor_nn (diferencas finitas) ============
section .data
align 8
%define NPX 17
c_tlr:      dq 1.0e-7
c_h:        dq 1.0e-5
c_2h:       dq 2.0e-5
c_halfx:    dq 0.5
c_1e9:      dq 1.0e9
c_1e3:      dq 1000.0
msg_gx:     db "xor gradiente: erro max (x1e9) / grad max (x1e3): "
msg_gx_len  equ $ - msg_gx
msg_sep2:   db " / "

section .bss
align 8
bkx:        resq 32
ganx:       resq 32
lpx:        resq 1
tmpx:       resq 1
maxex:      resq 1
maxgx:      resq 1

section .text
put_uint:
    xor r10d, r10d
    mov rcx, 10
.dv:
    xor edx, edx
    div rcx
    push rdx
    inc r10d
    test rax, rax
    jnz .dv
.em:
    pop rax
    add al, '0'
    call put_char
    dec r10d
    jnz .em
    ret

; forward independente (mesma logica do train_one, apenas a saida)
forward_x:
    push r12
    push r13
    mov r12, rdi
    xor r13d, r13d
.hj:
    cmp r13, NH
    jge .ho
    lea rax, [W1]
    mov rcx, r13
    shl rcx, 4
    movsd xmm0, [rax+rcx]
    mulsd xmm0, [r12]
    movsd xmm1, [rax+rcx+8]
    mulsd xmm1, [r12+8]
    addsd xmm0, xmm1
    lea rax, [B1]
    mov rcx, r13
    shl rcx, 3
    addsd xmm0, [rax+rcx]
    call sigmoid_fn
    lea rax, [Hs]
    mov rcx, r13
    shl rcx, 3
    movsd [rax+rcx], xmm0
    inc r13
    jmp .hj
.ho:
    xorpd xmm0, xmm0
    xor r13d, r13d
.hs:
    cmp r13, NH
    jge .hd
    mov rcx, r13
    shl rcx, 3
    lea rax, [W2]
    movsd xmm1, [rax+rcx]
    lea rax, [Hs]
    mulsd xmm1, [rax+rcx]
    addsd xmm0, xmm1
    inc r13
    jmp .hs
.hd:
    addsd xmm0, [B2]
    call sigmoid_fn
    pop r13
    pop r12
    ret

; loss_x: rdi = i -> 0.5*(o - T[i])^2
loss_x:
    push r12
    mov r12, rdi
    mov rdi, r12
    shl rdi, 4
    lea rax, [X]
    add rdi, rax
    call forward_x
    mov rax, r12
    shl rax, 3
    lea rdx, [T]
    subsd xmm0, [rdx+rax]
    mulsd xmm0, xmm0
    mulsd xmm0, [c_halfx]
    pop r12
    ret

main:
    sub rsp, 40
    movsd xmm0, [c_tlr]
    movsd [c_lr], xmm0
    lea rdi, [W1]
    mov ebx, NPX
.ii:
    call rand_sym
    movsd [rdi], xmm0
    add rdi, 8
    dec ebx
    jnz .ii

    xor r13d, r13d
.gs:
    cmp r13d, 4
    jge .gsd
    xor r14d, r14d
.cb:
    cmp r14, NPX
    jge .cbd
    lea rdx, [W1]
    movsd xmm0, [rdx+r14*8]
    lea rdx, [bkx]
    movsd [rdx+r14*8], xmm0
    inc r14
    jmp .cb
.cbd:
    mov rdi, r13
    shl rdi, 4
    lea rax, [X]
    add rdi, rax
    mov rdx, r13
    shl rdx, 3
    lea rax, [T]
    add rdx, rax
    call train_one

    xor r14d, r14d
.ga:
    cmp r14, NPX
    jge .gad
    lea rdx, [bkx]
    movsd xmm0, [rdx+r14*8]
    lea rdx, [W1]
    subsd xmm0, [rdx+r14*8]
    divsd xmm0, [c_tlr]
    lea rdx, [ganx]
    movsd [rdx+r14*8], xmm0
    inc r14
    jmp .ga
.gad:
    xor r14d, r14d
.rs:
    cmp r14, NPX
    jge .rsd
    lea rdx, [bkx]
    movsd xmm0, [rdx+r14*8]
    lea rdx, [W1]
    movsd [rdx+r14*8], xmm0
    inc r14
    jmp .rs
.rsd:

    xor r14d, r14d
.gn:
    cmp r14, NPX
    jge .gnd
    lea rdx, [W1]
    movsd xmm0, [rdx+r14*8]
    movsd [tmpx], xmm0
    addsd xmm0, [c_h]
    lea rdx, [W1]
    movsd [rdx+r14*8], xmm0
    mov rdi, r13
    call loss_x
    movsd [lpx], xmm0
    movsd xmm0, [tmpx]
    subsd xmm0, [c_h]
    lea rdx, [W1]
    movsd [rdx+r14*8], xmm0
    mov rdi, r13
    call loss_x
    movsd xmm1, [lpx]
    subsd xmm1, xmm0
    divsd xmm1, [c_2h]
    movsd xmm0, [tmpx]
    lea rdx, [W1]
    movsd [rdx+r14*8], xmm0

    lea rdx, [ganx]
    movsd xmm2, [rdx+r14*8]
    subsd xmm2, xmm1
    mulsd xmm2, xmm2
    sqrtsd xmm2, xmm2
    movsd xmm3, [maxex]
    maxsd xmm3, xmm2
    movsd [maxex], xmm3

    lea rdx, [ganx]
    movsd xmm2, [rdx+r14*8]
    mulsd xmm2, xmm2
    sqrtsd xmm2, xmm2
    movsd xmm3, [maxgx]
    maxsd xmm3, xmm2
    movsd [maxgx], xmm3

    inc r14
    jmp .gn
.gnd:
    inc r13d
    jmp .gs
.gsd:

    lea rsi, [msg_gx]
    mov ecx, msg_gx_len
    call put_str
    movsd xmm0, [maxex]
    mulsd xmm0, [c_1e9]
    cvttsd2si rax, xmm0
    call put_uint
    lea rsi, [msg_sep2]
    mov ecx, 3
    call put_str
    movsd xmm0, [maxgx]
    mulsd xmm0, [c_1e3]
    cvttsd2si rax, xmm0
    call put_uint
    lea rsi, [msg_nl]
    mov ecx, 2
    call put_str

    mov ecx, -11
    call [__imp_GetStdHandle]
    mov rcx, rax
    lea rdx, [obuf]
    mov r8, [olen]
    lea r9, [written]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    xor ecx, ecx
    call [__imp_ExitProcess]

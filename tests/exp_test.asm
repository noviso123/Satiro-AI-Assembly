default rel
; ============ TESTE: exp e sigmoide em [-30,30] ============
; Referencia independente: serie de Taylor direta (120 termos), em assembly.
; exp(x) para x < 0 = 1 / exp(-x).
%include "deep_core.asm"

section .data
align 8
%define NE 121
c_sixty:    dq 60.0
c_step:     dq 0.5
c_1e12:     dq 1.0e12
msg_ex:     db "exp max erro relativo (x1e12): "
msg_ex_len  equ $ - msg_ex
msg_sx:     db "sigmoide max erro absoluto (x1e12): "
msg_sx_len  equ $ - msg_sx
msg_pt:     db "pontos testados: "
msg_pt_len  equ $ - msg_pt

section .bss
align 8
maxe:       resq 1
maxs:       resq 1
xv:         resq 1
rv:         resq 1

section .text

; ref_pos: xmm0 = x >= 0 -> xmm0 = exp(x) pela serie (120 termos)
ref_pos:
    movsd xmm5, xmm0
    movsd xmm1, [c_one]
    movsd xmm2, [c_one]
    mov ecx, 1
.rp:
    cmp ecx, 120
    jg .rpd
    mulsd xmm1, xmm5
    cvtsi2sd xmm3, rcx
    divsd xmm1, xmm3
    addsd xmm2, xmm1
    inc ecx
    jmp .rp
.rpd:
    movsd xmm0, xmm2
    ret

; ref_exp: xmm0 = x -> xmm0 = exp(x) (referencia)
ref_exp:
    xorpd xmm4, xmm4
    comisd xmm0, xmm4
    jae .pos
    mulsd xmm0, [c_neg1]
    call ref_pos
    movsd xmm1, [c_one]
    divsd xmm1, xmm0
    movsd xmm0, xmm1
    ret
.pos:
    call ref_pos
    ret

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

main:
    sub rsp, 40
    xor ebx, ebx
.k:
    cmp ebx, NE
    jge .kd
    ; x = (k - 60) * 0.5
    cvtsi2sd xmm0, rbx
    subsd xmm0, [c_sixty]
    mulsd xmm0, [c_step]
    movsd [xv], xmm0

    ; exp: implementacao contra referencia
    call exp_fn
    movsd [rv], xmm0
    movsd xmm0, [xv]
    call ref_exp
    movsd xmm1, xmm0
    movsd xmm0, [rv]
    subsd xmm0, xmm1
    mulsd xmm0, xmm0
    sqrtsd xmm0, xmm0
    divsd xmm0, xmm1
    movsd xmm3, [maxe]
    maxsd xmm3, xmm0
    movsd [maxe], xmm3

    ; sigmoide: implementacao contra 1 / (1 + exp(-x))
    movsd xmm0, [xv]
    call sigmoid_fn
    movsd [rv], xmm0
    movsd xmm0, [xv]
    mulsd xmm0, [c_neg1]
    call ref_exp
    movsd xmm1, [c_one]
    addsd xmm0, xmm1
    movsd xmm2, [c_one]
    divsd xmm2, xmm0
    movsd xmm0, [rv]
    subsd xmm0, xmm2
    mulsd xmm0, xmm0
    sqrtsd xmm0, xmm0
    movsd xmm3, [maxs]
    maxsd xmm3, xmm0
    movsd [maxs], xmm3

    inc ebx
    jmp .k
.kd:
    lea rsi, [msg_ex]
    mov ecx, msg_ex_len
    call put_str
    movsd xmm0, [maxe]
    mulsd xmm0, [c_1e12]
    cvttsd2si rax, xmm0
    call put_uint
    lea rsi, [msg_nl]
    mov ecx, 2
    call put_str

    lea rsi, [msg_sx]
    mov ecx, msg_sx_len
    call put_str
    movsd xmm0, [maxs]
    mulsd xmm0, [c_1e12]
    cvttsd2si rax, xmm0
    call put_uint
    lea rsi, [msg_nl]
    mov ecx, 2
    call put_str

    lea rsi, [msg_pt]
    mov ecx, msg_pt_len
    call put_str
    mov eax, NE
    call put_uint
    lea rsi, [msg_nl]
    mov ecx, 2
    call put_str

    mov ecx, -11
    call [__imp_GetStdHandle]
    mov rcx, rax
    lea rdx, [obuf]
    mov r8, [olen]
    lea r9, [written_t]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    xor ecx, ecx
    call [__imp_ExitProcess]

section .bss
written_t: resd 1

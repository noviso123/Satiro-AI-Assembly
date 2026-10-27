bits 64
default rel
; ============ REGRESSAO DO CODIFICADOR: deve montar identico antes/depois das correcoes ==
; Exercicio proposital das formas usadas pelo projeto (e das bordas que continuam validas).

section .data
d_q:    dq 0x1122334455667788, -1, 1234567890123
d_d:    dd 1, -2, 0x89ABCDEF, 3.5, 1.0e-10
d_w:    dw 0x1234, 60000
d_b:    db "texto com acento: ", 0xC3, 0xA1, 0
align 16
d_a16:  dq 42
d_frac: dd 0.1, 0.2, 0.3
d_sum:  dd 1+2*3, 10/4, 17%5, 4096+5
d_cond: dd 1 > 2, 2 >= 2, 3 != 4

section .bss
b_v:    resq 8
b_b:    resb 100
b_w:    resw 16
alignb 32
b_a:    resd 64

section .text
global main
main:
    sub rsp, 40
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ; aritmetica com imediatos nas bordas validas (imm8 e imm32 com sinal)
    add rax, 127
    add rax, -128
    add rax, 2147483647
    add rax, -2147483648
    add eax, 100
    add ax, 300
    sub rbx, 1
    and rcx, 0xFF
    or  rdx, -5
    xor rsi, 0x7FFFFFFF
    cmp rdi, -1000000
    ; mov com imediato nas bordas
    mov rax, -1
    mov rbx, 0x12345678
    mov r12, -2147483648
    mov ecx, 255
    mov dx, 0xBEEF
    mov byte [b_b], 7
    mov word [b_w], 0x1234
    mov dword [d_d], 0xDEADBEEF
    mov qword [b_v], -2000000000
    mov qword [b_v+8], 2000000000
    ; imul de 3 operandos nas bordas
    imul r8, r9, 127
    imul r8, r9, -128
    imul r8, r9, 1000000
    imul r8, r9, -1000000
    imul eax, ecx, 100
    ; push/pop de memoria
    push qword [b_v]
    pop qword [b_v+16]
    push rax
    pop rax
    ; memoria com todas as formas
    mov al, [b_b]
    mov al, [b_b+120]
    mov al, [b_b-1]
    lea rbx, [b_v]
    mov rax, [rbx+rcx*8]
    mov rax, [rbx+rcx*2+16]
    mov rax, [rbx+rax]
    mov eax, [d_a16]
    mov rax, [d_q]
    lea rbp, [b_v]
    lea rbx, [rbp+rdi*4]
    ; saltos e setcc
    test eax, eax
    jz .zero
    jnz .naoz
    jp .zero
    js .naoz
    jmp .fim
.zero:
    sete al
    setne bl
    setg cl
.naoz:
    ; avx (kernel do projeto)
    vxorps ymm0, ymm0, ymm0
    vmovups ymm1, [b_v]
    vfmadd231ps ymm1, ymm2, ymm3
    vmovups [b_v+32], ymm1
    vmaxsd xmm0, xmm1, xmm2
    vdivps ymm4, ymm4, ymm5
    ; expressao com divisao por constante (nao zero)
    mov eax, 100/7
    mov eax, 100%7
.fim:
    xor eax, eax
    add rsp, 40
    ret

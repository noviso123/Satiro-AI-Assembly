; Teste unitario do avaliador de expressoes. Cada caso: texto, valor, tipo, indefinido.
bits 64
default rel
%include "tools/asm/as_base.asm"
%include "tools/asm/as_pre.asm"
%include "tools/asm/as_asm.asm"
%include "tools/asm/as_expr.asm"
%include "tools/asm/as_regs.asm"
%include "tools/asm/as_opnd.asm"
%include "tools/asm/as_enc.asm"
%include "tools/asm/as_stmt.asm"
%include "tools/asm/as_flt.asm"

global main

section .data
align 8
t_c00: db "1+2*3", 0
t_c01: db "(1+2)*3", 0
t_c02: db "10-3-2", 0
t_c03: db "0x10|0x01", 0
t_c04: db "1<<4", 0
t_c05: db "100/7", 0
t_c06: db "100%7", 0
t_c07: db "-5+2", 0
t_c08: db "~0 & 0xff", 0
t_c09: db "3 ^ 5", 0
t_c10: db "'A'", 0
t_c11: db "0FFh", 0
t_c12: db "__imp_GetStdHandle", 0
t_c13: db "lbl+8", 0
t_c14: db "lbl2-lbl", 0
t_c15: db "$-lbl", 0
t_c16: db "undef", 0
t_c17: db "lbl-5", 0
t_c18: db "0x7FFFFFFF+1", 0
t_name_lbl:  db "lbl", 0
t_name_lbl2: db "lbl2", 0
t_fail: db "FALHA no caso ", 0
t_ok:   db "todos os casos de expressao passaram", 13, 10, 0
t_nl:   db 13, 10, 0

; caso: ponteiro, tamanho, valor esperado, tipo esperado, indefinido esperado
cases:
    dq t_c00, 5, 7, 0, 0
    dq t_c01, 7, 9, 0, 0
    dq t_c02, 6, 5, 0, 0
    dq t_c03, 10, 17, 0, 0
    dq t_c04, 5, 16, 0, 0
    dq t_c05, 5, 14, 0, 0
    dq t_c06, 5, 2, 0, 0
    dq t_c07, 5, -3, 0, 0
    dq t_c08, 10, 255, 0, 0
    dq t_c09, 5, 6, 0, 0
    dq t_c10, 3, 65, 0, 0
    dq t_c11, 5, 255, 0, 0
    dq t_c12, 18, 0, 2, 0
    dq t_c13, 6, 24, 1, 0
    dq t_c14, 8, 24, 0, 0
    dq t_c15, 5, 84, 0, 0
    dq t_c16, 5, 0, 0, 1
    dq t_c17, 5, 11, 1, 0
    dq t_c18, 12, 0x80000000, 0, 0
ncases equ 19

section .bss
alignb 16
cur_case:   resq 1

section .text

; ---------- testa um caso: rsi = texto, rcx = tamanho -------------------------------
; retorna eax = 1 se o resultado bate com o esperado (valores em cases[cur_case])
main:
    AS_ENTER
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [as_hout], rax
    ; simbolos de teste
    mov qword [as_pass], 1
    mov qword [as_cur], 1
    mov qword [as_off+8], 100
    lea rsi, [t_name_lbl]
    mov rcx, 3
    call as_sym_new
    lea rdx, [as_sym_kind]
    mov qword [rdx+rax*8], 1
    lea rdx, [as_sym_sec]
    mov qword [rdx+rax*8], 1
    lea rdx, [as_sym_val]
    mov qword [rdx+rax*8], 16
    lea rsi, [t_name_lbl2]
    mov rcx, 4
    call as_sym_new
    lea rdx, [as_sym_kind]
    mov qword [rdx+rax*8], 1
    lea rdx, [as_sym_sec]
    mov qword [rdx+rax*8], 1
    lea rdx, [as_sym_val]
    mov qword [rdx+rax*8], 40
    ; roda os casos
    mov qword [cur_case], 0
.caso:
    mov rax, [cur_case]
    cmp rax, ncases
    jae .fim
    imul rax, rax, 40
    lea rbx, [cases]
    add rbx, rax                    ; registro do caso
    mov rsi, [rbx]
    mov rcx, [rbx+8]
    lea rdx, [as_inbuf]
    ; prepara a linha: copia o texto e fixa os limites de leitura
    mov [as_lp], rsi
    lea rax, [rsi]
    add rax, rcx
    mov [as_le], rax
    mov rax, [cur_case]
    call as_say_num
    call ex_expr
    ; compara: valor, tipo, indefinido
    mov rbx, [cur_case]
    imul rbx, rbx, 40
    lea rdx, [cases]
    mov rax, [rdx+rbx+16]
    cmp rax, [E_V]
    jne .falha
    mov rax, [rdx+rbx+24]
    cmp rax, [E_K]
    jne .falha
    mov rax, [rdx+rbx+32]
    cmp rax, [E_U]
    jne .falha
    inc qword [cur_case]
    jmp .caso
.falha:
    lea rsi, [t_fail]
    call as_say
    mov rax, [cur_case]
    call as_say_num
    lea rsi, [t_nl]
    call as_say
    mov ecx, 1
    call [__imp_ExitProcess]
.fim:
    lea rsi, [t_ok]
    call as_say
    xor ecx, ecx
    call [__imp_ExitProcess]

section .bss
as_inbuf:   resb 64

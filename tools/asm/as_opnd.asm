; ============ ASM: leitura de operandos ============
; Preenche op_* na posicao op_n:
;   op_t 0 nenhum, 1 registrador, 2 imediato, 3 memoria
;   op_reg (0..15), op_rsz (tamanho do registrador: 1,2,4,8,16,32)
;   op_base/op_index (16 = nenhum), op_scale, op_msz (tamanho declarado, 0 se nenhum)
;   op_v/op_k/op_s/op_u: valor, tipo (0 abs, 1 secao, 2 externo), secao/simbolo, indefinido

%define AS_NOREG 16

section .bss
alignb 16
mp_base:        resq 1
mp_index:       resq 1
mp_scale:       resq 1
mp_dv:          resq 1
mp_dk:          resq 1
mp_ds:          resq 1
mp_du:          resq 1
mp_sign:        resq 1
mp_reg:         resq 1
mp_msz:         resq 1
ao_save:        resq 1

section .data
align 8
as_e_opmiss:    db "operando ausente", 0
as_e_memreg:    db "registrador invalido em memoria (use 64 bits)", 0
as_e_memscl:    db "escala deve ser 1, 2, 4 ou 8", 0
as_e_memneg:    db "registrador subtraido em memoria", 0
as_e_memsym:    db "dois simbolos no mesmo operando de memoria", 0
as_e_memdup:    db "registrador de base ou indice repetido", 0
as_e_memrsp:    db "rsp nao pode ser indice de memoria (o hardware o ignora no SIB)", 0
as_szn:         db "byte", 0, 1, "word", 0, 2, "dword", 0, 4, "qword", 0, 8, "oword", 0, 16, "yword", 0, 32, 0

section .text

; ---------- as_opclear: zera o operando op_n ----------------------------------------
as_opclear:
    mov rcx, [op_n]
    lea rdx, [op_t]
    mov qword [rdx+rcx*8], 0
    lea rdx, [op_reg]
    mov qword [rdx+rcx*8], 0
    lea rdx, [op_rsz]
    mov qword [rdx+rcx*8], 0
    lea rdx, [op_base]
    mov qword [rdx+rcx*8], AS_NOREG
    lea rdx, [op_index]
    mov qword [rdx+rcx*8], AS_NOREG
    lea rdx, [op_scale]
    mov qword [rdx+rcx*8], 1
    lea rdx, [op_msz]
    mov qword [rdx+rcx*8], 0
    lea rdx, [op_v]
    mov qword [rdx+rcx*8], 0
    lea rdx, [op_k]
    mov qword [rdx+rcx*8], 0
    lea rdx, [op_s]
    mov qword [rdx+rcx*8], 0
    lea rdx, [op_u]
    mov qword [rdx+rcx*8], 0
    ret

; ---------- as_szname: rsi = inicio, rcx = tamanho -> eax = bytes ou 0 -----------------
as_szname:
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r12, rcx
    lea rdi, [as_szn]
.entrada:
    cmp byte [rdi], 0
    je .nao
    xor edx, edx
.cmp:
    cmp rdx, r12
    jae .fim_nome
    mov al, [rbx+rdx]
    or al, 32
    cmp al, [rdi+rdx]
    jne .prox
    inc rdx
    jmp .cmp
.fim_nome:
    cmp byte [rdi+rdx], 0
    jne .prox
    movzx eax, byte [rdi+rdx+1]
    pop r13
    pop r12
    pop rbx
    ret
.prox:
    cmp byte [rdi], 0
    je .pulou
    inc rdi
    jmp .prox
.pulou:
    add rdi, 2                      ; NUL do nome + 1 byte de tamanho
    jmp .entrada
.nao:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    ret

; ---------- as_regfind: rsi = nome, rcx = tamanho -> eax = indice|tam<<8|classe<<16 ---
as_regfind:
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r12, rcx
    lea rdi, [as_regtab]
.entrada:
    cmp byte [rdi], 0
    je .nao
    xor edx, edx
.cmp:
    cmp rdx, r12
    jae .fim_nome
    mov al, [rbx+rdx]
    or al, 32
    cmp al, [rdi+rdx]
    jne .prox
    inc rdx
    jmp .cmp
.fim_nome:
    cmp byte [rdi+rdx], 0
    jne .prox
    lea rax, [rdi+rdx+1]            ; indice, tamanho, classe
    movzx ecx, byte [rax]
    movzx edx, byte [rax+1]
    shl edx, 8
    or ecx, edx
    movzx edx, byte [rax+2]
    shl edx, 16
    or ecx, edx
    mov eax, ecx
    pop r13
    pop r12
    pop rbx
    ret
.prox:
    cmp byte [rdi], 0
    je .pulou
    inc rdi
    jmp .prox
.pulou:
    add rdi, 4                      ; NUL + 3 bytes de dados
    jmp .entrada
.nao:
    mov rax, -1
    pop r13
    pop r12
    pop rbx
    ret

; ---------- as_opnd: le um operando na posicao op_n ------------------------------------
as_opnd:
    call as_opclear
    call as_peek
    test al, al
    jz .falta
    cmp al, '['
    je .memoria_direta
    ; identificador: tamanho, registrador ou expressao
    mov rax, [as_lp]
    mov [ao_save], rax
    call as_ident
    test rcx, rcx
    jz .expressao
    mov rsi, rax
    call as_szname_chk              ; eax = tamanho se for palavra de tamanho
    test eax, eax
    jz .nao_tamanho
    ; palavra de tamanho: deve vir '[' em seguida
    mov [mp_msz], rax
    call as_peek
    cmp al, '['
    jne .falta_colchete
    inc qword [as_lp]
    call as_memop_body
    ret
.nao_tamanho:
    ; registrador?
    mov rsi, [ao_save]
    mov [as_lp], rsi
    call as_ident
    mov rsi, rax
    call as_regfind
    cmp eax, -1
    je .expressao
    ; registrador: indice, tamanho e classe
    mov rcx, [op_n]
    lea rdx, [op_t]
    mov qword [rdx+rcx*8], 1
    mov edx, eax
    and edx, 0xFF
    lea rdi, [op_reg]
    mov [rdi+rcx*8], rdx
    mov edx, eax
    shr edx, 8
    and edx, 0xFF
    cmp rdx, 8
    jne .tam_outro
    ; tamanho 8 (ou classe ymm/xmm conforme a classe)
.tam_outro:
    mov edx, eax
    shr edx, 16
    and edx, 0xFF
    cmp rdx, 1
    je .vetor
    cmp rdx, 2
    je .ymm
    ; geral: tamanho e' o byte do meio
    mov edx, eax
    shr edx, 8
    and edx, 0xFF
    lea rdi, [op_rsz]
    mov [rdi+rcx*8], rdx
    ret
.vetor:
    lea rdi, [op_rsz]
    mov qword [rdi+rcx*8], 16
    ret
.ymm:
    lea rdi, [op_rsz]
    mov qword [rdi+rcx*8], 32
    ret
.memoria_direta:
    mov qword [mp_msz], 0
    inc qword [as_lp]
    call as_memop_body
    ret
.expressao:
    mov rsi, [ao_save]
    mov [as_lp], rsi
    call ex_expr
    mov rcx, [op_n]
    lea rdx, [op_t]
    mov qword [rdx+rcx*8], 2
    lea rdx, [op_v]
    mov rax, [E_V]
    mov [rdx+rcx*8], rax
    lea rdx, [op_k]
    mov rax, [E_K]
    mov [rdx+rcx*8], rax
    lea rdx, [op_s]
    mov rax, [E_S]
    mov [rdx+rcx*8], rax
    lea rdx, [op_u]
    mov rax, [E_U]
    mov [rdx+rcx*8], rax
    ret
.falta:
    lea rsi, [as_e_opmiss]
    jmp as_fail_plain
.falta_colchete:
    lea rsi, [as_e_memreg]
    jmp as_fail_plain

; as_szname_chk: rsi = inicio, rcx = tamanho -> eax (wrapper de as_szname preservando rcx)
as_szname_chk:
    push rcx
    push rsi
    call as_szname
    pop rsi
    pop rcx
    ret


; ---------- as_memop_body: '[' ja consumido. Le ate ']' e preenche o operando ----------
as_memop_body:
    mov qword [mp_base], AS_NOREG
    mov qword [mp_index], AS_NOREG
    mov qword [mp_scale], 1
    mov qword [mp_dv], 0
    mov qword [mp_dk], 0
    mov qword [mp_ds], 0
    mov qword [mp_du], 0
    mov qword [mp_sign], 1
.laco:
    call as_peek
    cmp al, ']'
    je .fecha
    cmp al, '+'
    je .mais
    cmp al, '-'
    je .menos
    test al, al
    jz .erro
    cmp al, '0'
    jb .identificador
    cmp al, '9'
    jbe .numero
.identificador:
    ; registrador de 64 bits (base ou indice) ou expressao
    mov rax, [as_lp]
    mov [ao_save], rax
    call as_ident
    test rcx, rcx
    jz .expr
    mov rsi, rax
    call as_regfind
    cmp eax, -1
    je .expr_restaura
    ; eax = indice|tam<<8|classe<<16
    mov edx, eax
    shr edx, 8
    and edx, 0xFF
    cmp edx, 8
    jne .erro_reg
    mov edx, eax
    shr edx, 16
    and edx, 0xFF
    test edx, edx
    jnz .erro_reg
    and eax, 0xFF
    cmp qword [mp_sign], 0
    jl .erro_neg
    mov [mp_reg], rax               ; as_peek altera rax: guarda o indice
    call as_peek
    cmp al, '*'
    jne .reg_sem_escala
    inc qword [as_lp]
    call ex_numero
    mov rdx, rax
    mov rax, [mp_reg]
    cmp rdx, 1
    je .reg_esc_ok
    cmp rdx, 2
    je .reg_esc_ok
    cmp rdx, 4
    je .reg_esc_ok
    cmp rdx, 8
    je .reg_esc_ok
    lea rsi, [as_e_memscl]
    jmp as_fail_plain
.reg_esc_ok:
    mov [mp_scale], rdx
    call as_mem_idx
    jmp .laco
.reg_sem_escala:
    mov rax, [mp_reg]               ; indice do registrador (as_peek alterou rax)
    call as_mem_reg                 ; base (ou indice com escala 1)
    jmp .laco
.expr_restaura:
    mov rax, [ao_save]
    mov [as_lp], rax
    jmp .expr
.numero:
    ; numero: pode ser escala (n*reg) ou constante
    mov rax, [as_lp]
    mov [ao_save], rax
    call ex_numero
    mov rdx, rax                    ; valor
    call as_peek
    cmp al, '*'
    jne .numero_const
    mov rax, [as_lp]
    mov [ao_save2], rax
    inc qword [as_lp]
    call as_ident
    test rcx, rcx
    jz .numero_const_rest
    mov rsi, rax
    call as_regfind
    cmp eax, -1
    je .numero_const_rest
    and eax, 0xFF
    ; valor n = escala
    cmp rdx, 1
    je .escala_ok
    cmp rdx, 2
    je .escala_ok
    cmp rdx, 4
    je .escala_ok
    cmp rdx, 8
    je .escala_ok
    lea rsi, [as_e_memscl]
    jmp as_fail_plain
.escala_ok:
    cmp qword [mp_sign], 0
    jl .erro_neg
    mov [mp_scale], rdx
    call as_mem_idx
    jmp .laco
.numero_const_rest:
    mov rax, [ao_save2]
    mov [as_lp], rax
.numero_const:
    mov rax, [ao_save]
    mov [as_lp], rax
    jmp .expr
.mais:
    inc qword [as_lp]
    mov qword [mp_sign], 1
    jmp .laco
.menos:
    inc qword [as_lp]
    mov qword [mp_sign], -1
    jmp .laco
.expr:
    call ex_lvl_mul
    cmp qword [E_U], 0
    je .def
    mov qword [mp_du], 1
.def:
    cmp qword [E_K], 0
    je .abs
    cmp qword [mp_dk], 0
    jne .erro_sym
    cmp qword [mp_sign], 0
    jl .erro_neg
    mov rax, [E_K]
    mov [mp_dk], rax
    mov rax, [E_S]
    mov [mp_ds], rax
.abs:
    mov rax, [E_V]
    imul rax, [mp_sign]
    add [mp_dv], rax
    jmp .laco
.fecha:
    inc qword [as_lp]
    ; grava o operando de memoria
    mov rcx, [op_n]
    lea rdx, [op_t]
    mov qword [rdx+rcx*8], 3
    lea rdx, [op_base]
    mov rax, [mp_base]
    mov [rdx+rcx*8], rax
    lea rdx, [op_index]
    mov rax, [mp_index]
    mov [rdx+rcx*8], rax
    lea rdx, [op_scale]
    mov rax, [mp_scale]
    mov [rdx+rcx*8], rax
    lea rdx, [op_msz]
    mov rax, [mp_msz]
    mov [rdx+rcx*8], rax
    lea rdx, [op_v]
    mov rax, [mp_dv]
    mov [rdx+rcx*8], rax
    lea rdx, [op_k]
    mov rax, [mp_dk]
    mov [rdx+rcx*8], rax
    lea rdx, [op_s]
    mov rax, [mp_ds]
    mov [rdx+rcx*8], rax
    lea rdx, [op_u]
    mov rax, [mp_du]
    mov [rdx+rcx*8], rax
    ret
.erro:
    lea rsi, [as_e_memreg]
    jmp as_fail_plain
.erro_reg:
    lea rsi, [as_e_memreg]
    jmp as_fail_plain
.erro_neg:
    lea rsi, [as_e_memneg]
    jmp as_fail_plain
.erro_sym:
    lea rsi, [as_e_memsym]
    jmp as_fail_plain

section .bss
ao_save2:       resq 1
section .text

; as_mem_reg: eax = registrador de 64 bits -> base (se livre) ou indice (com escala 1)
as_mem_reg:
    cmp qword [mp_base], AS_NOREG
    jne .indice
    mov [mp_base], rax              ; rsp como base e valido (SIB trata bem)
    ret
.indice:
    cmp eax, 4                      ; rsp como indice: o SIB o interpreta como "sem indice"
    je .rsp
    cmp qword [mp_index], AS_NOREG
    jne .dup
    mov [mp_index], rax
    mov qword [mp_scale], 1
    ret
.dup:
    lea rsi, [as_e_memdup]
    jmp as_fail_plain
.rsp:
    lea rsi, [as_e_memrsp]
    jmp as_fail_plain

; as_mem_idx: eax = indice (escala ja em mp_scale)
as_mem_idx:
    cmp eax, 4                      ; rsp como indice: o SIB o interpreta como "sem indice"
    je .rsp
    cmp qword [mp_index], AS_NOREG
    jne .dup
    mov [mp_index], rax
    ret
.dup:
    lea rsi, [as_e_memdup]
    jmp as_fail_plain
.rsp:
    lea rsi, [as_e_memrsp]
    jmp as_fail_plain

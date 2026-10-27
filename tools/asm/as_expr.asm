; ============ ASM: expressoes ============
; Resultado em E_V (valor), E_K (0 absoluto, 1 secao, 2 externo), E_S (secao ou
; indice do simbolo) e E_U (1 = indefinido na passagem 1, valor provisorio 0).
; Multiplicacao, divisao, restos e operadores logicos aceitam apenas absolutos.

section .bss
alignb 16
rs_p:           resq 1                ; inicio do identificador em resolucao
rs_n:           resq 1                ; tamanho do identificador

section .text

; ---------- ex_set: rax = valor, rdx = tipo, rcx = secao/simbolo, r8 = indefinido -
ex_set:
    mov [E_V], rax
    mov [E_K], rdx
    mov [E_S], rcx
    mov [E_U], r8
    ret

; ---------- ex_abs_op: rbx = operador, esquerdo em r11 (v), r10 (k), r9 (s), r8 (u) --
; Direito em E_*. Resultado em E_*.
ex_abs_op:
    mov rax, r8
    or rax, [E_U]
    jnz .indef
    cmp r10, 0
    jne .nao_abs
    cmp qword [E_K], 0
    jne .nao_abs
    mov rax, r11                    ; esquerdo
    mov rdx, [E_V]                  ; direito
    cmp rbx, '|'
    je .or
    cmp rbx, '^'
    je .xor
    cmp rbx, '&'
    je .and
    cmp rbx, '*'
    je .mul
    cmp rbx, '/'
    je .div
    cmp rbx, '%'
    je .mod
    cmp rbx, '<'
    je .shl
    cmp rbx, '>'
    je .shr
    jmp .nao_abs
.or:
    or rax, rdx
    jmp .fim
.xor:
    xor rax, rdx
    jmp .fim
.and:
    and rax, rdx
    jmp .fim
.mul:
    imul rax, rdx
    jmp .fim
.div:
    test rdx, rdx
    jnz .div_ok
    cmp qword [as_pass], 2          ; na passada 2 divisao por zero e erro (antes era 0 mudo)
    jne .indef
    lea rsi, [as_e_divzero]
    jmp as_fail_plain
.div_ok:
    mov r9, rdx                     ; divisor fora de rdx (cqo o sobrescreve)
    cqo
    idiv r9
    jmp .fim
.mod:
    test rdx, rdx
    jnz .mod_ok
    cmp qword [as_pass], 2
    jne .indef
    lea rsi, [as_e_divzero]
    jmp as_fail_plain
.mod_ok:
    mov r9, rdx
    cqo
    idiv r9
    mov rax, rdx
    jmp .fim
.shl:
    mov rcx, rdx
    shl rax, cl
    jmp .fim
.shr:
    mov rcx, rdx
    sar rax, cl
    jmp .fim
.fim:
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call ex_set
    ret
.indef:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    mov r8d, 1
    call ex_set
    ret
.nao_abs:
    lea rsi, [as_e_expr]
    jmp as_fail_plain

; ---------- ex_addsub: rbx = '+' ou '-', esquerdo em r11/r10/r9/r8 -----------------
ex_addsub:
    mov rax, r8
    or rax, [E_U]
    mov r12, rax                    ; indefinido combinado
    cmp rbx, '+'
    je .soma
    ; subtracao: direito absoluto, ou dois rotulos da mesma secao
    cmp qword [E_K], 0
    je .sub_abs
    cmp r10, 1
    jne .sub_erro
    cmp qword [E_K], 1
    jne .sub_erro
    cmp r9, [E_S]
    jne .sub_erro
    mov rax, r11
    sub rax, [E_V]
    xor edx, edx
    xor ecx, ecx
    jmp .fim_ad
.sub_abs:
    mov rax, r11
    sub rax, [E_V]
    mov rdx, r10
    mov rcx, r9
    jmp .fim_ad
.sub_erro:
    test r12, r12
    jnz .indef_ad
    lea rsi, [as_e_expr]
    jmp as_fail_plain
.soma:
    mov rax, r11
    add rax, [E_V]
    cmp r10, 0
    jne .soma_esq_reloc
    ; esquerdo absoluto
    cmp qword [E_K], 0
    je .soma_abs
    mov rdx, [E_K]
    mov rcx, [E_S]
    jmp .fim_ad
.soma_abs:
    xor edx, edx
    xor ecx, ecx
    jmp .fim_ad
.soma_esq_reloc:
    cmp qword [E_K], 0
    jne .soma_dois
    mov rdx, r10
    mov rcx, r9
    jmp .fim_ad
.soma_dois:
    test r12, r12
    jnz .indef_ad
    lea rsi, [as_e_expr]
    jmp as_fail_plain
.indef_ad:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
.fim_ad:
    mov r8, r12
    call ex_set
    ret

; ---------- niveis de precedencia (do mais baixo ao mais alto) -----------------------
; Cada nivel: esquerdo = nivel seguinte; laco com o operador do nivel.

ex_expr:
    jmp ex_lvl_or

; Cada nivel: esquerdo = nivel seguinte; operador do nivel; direito = nivel seguinte.
ex_lvl_or:
    push rbx
    call ex_lvl_xor
.l:
    call as_peek
    cmp al, '|'
    jne .f
    inc qword [as_lp]
    push qword [E_V]
    push qword [E_K]
    push qword [E_S]
    push qword [E_U]
    call ex_lvl_xor
    pop r8
    pop r9
    pop r10
    pop r11
    mov rbx, '|'
    call ex_abs_op
    jmp .l
.f:
    pop rbx
    ret

ex_lvl_xor:
    push rbx
    call ex_lvl_and
.l:
    call as_peek
    cmp al, '^'
    jne .f
    inc qword [as_lp]
    push qword [E_V]
    push qword [E_K]
    push qword [E_S]
    push qword [E_U]
    call ex_lvl_and
    pop r8
    pop r9
    pop r10
    pop r11
    mov rbx, '^'
    call ex_abs_op
    jmp .l
.f:
    pop rbx
    ret

ex_lvl_and:
    push rbx
    call ex_lvl_shift
.l:
    call as_peek
    cmp al, '&'
    jne .f
    inc qword [as_lp]
    push qword [E_V]
    push qword [E_K]
    push qword [E_S]
    push qword [E_U]
    call ex_lvl_shift
    pop r8
    pop r9
    pop r10
    pop r11
    mov rbx, '&'
    call ex_abs_op
    jmp .l
.f:
    pop rbx
    ret

ex_lvl_shift:
    push rbx
    call ex_lvl_add
.l:
    call as_peek
    cmp al, '<'
    je .esq
    cmp al, '>'
    je .dir
    jmp .f
.esq:
    mov rsi, [as_lp]
    cmp byte [rsi+1], '<'
    jne .f
    add qword [as_lp], 2
    mov rbx, '<'
    jmp .op
.dir:
    mov rsi, [as_lp]
    cmp byte [rsi+1], '>'
    jne .f
    add qword [as_lp], 2
    mov rbx, '>'
.op:
    push qword [E_V]
    push qword [E_K]
    push qword [E_S]
    push qword [E_U]
    call ex_lvl_add
    pop r8
    pop r9
    pop r10
    pop r11
    call ex_abs_op
    jmp .l
.f:
    pop rbx
    ret
ex_lvl_add:
    push rbx
    call ex_lvl_mul
.l:
    call as_peek
    cmp al, '+'
    je .op
    cmp al, '-'
    je .op
    jmp .f
.op:
    movzx ebx, al
    inc qword [as_lp]
    push qword [E_V]
    push qword [E_K]
    push qword [E_S]
    push qword [E_U]
    call ex_lvl_mul
    pop r8
    pop r9
    pop r10
    pop r11
    call ex_addsub
    jmp .l
.f:
    pop rbx
    ret

ex_lvl_mul:
    push rbx
    call ex_unary
.l:
    call as_peek
    cmp al, '*'
    je .op
    cmp al, '/'
    je .op
    cmp al, '%'
    je .op
    jmp .f
.op:
    movzx ebx, al
    inc qword [as_lp]
    push qword [E_V]
    push qword [E_K]
    push qword [E_S]
    push qword [E_U]
    call ex_unary
    pop r8
    pop r9
    pop r10
    pop r11
    call ex_abs_op
    jmp .l
.f:
    pop rbx
    ret

; unario: - + ~ e primario
ex_unary:
    call as_peek
    cmp al, '-'
    je .menos
    cmp al, '+'
    je .mais
    cmp al, '~'
    je .til
    jmp ex_primary
.menos:
    inc qword [as_lp]
    call ex_unary
    cmp qword [E_K], 0
    jne .erro_un
    cmp qword [E_U], 0
    jne .fim_un
    neg qword [E_V]
.fim_un:
    ret
.mais:
    inc qword [as_lp]
    jmp ex_unary
.til:
    inc qword [as_lp]
    call ex_unary
    cmp qword [E_K], 0
    jne .erro_un
    not qword [E_V]
    ret
.erro_un:
    lea rsi, [as_e_expr]
    jmp as_fail_plain

; primario: numero, caractere, '$', '$$', '(' expr ')', identificador
ex_primary:
    call as_peek
    test al, al
    jz .erro
    cmp al, '('
    je .par
    cmp al, '$'
    je .dolar
    cmp al, '0'
    jb .nao_num
    cmp al, '9'
    jbe .numero
.nao_num:
    cmp al, 39
    je .char
    cmp al, '"'
    je .char
    call as_ident
    test rcx, rcx
    jz .erro
    push rbx
    call ex_resolve
    pop rbx
    ret
.par:
    inc qword [as_lp]
    call ex_expr
    call as_peek
    cmp al, ')'
    jne .erro
    inc qword [as_lp]
    ret
.dolar:
    inc qword [as_lp]
    mov rsi, [as_lp]
    mov rcx, [as_cur]
    cmp byte [rsi], '$'
    jne .dol_pos
    inc qword [as_lp]               ; "$$": inicio da secao
    xor eax, eax
    jmp .dol_set
.dol_pos:
    lea rdx, [as_off]
    mov rax, [rdx+rcx*8]            ; deslocamento atual da secao
.dol_set:
    mov rdx, 1
    xor r8d, r8d
    call ex_set
    ret
.numero:
    push rbx
    call ex_numero
    pop rbx
    ret
.char:
    mov rsi, [as_lp]
    cmp byte [rsi+2], 39
    je .char_ok
    cmp byte [rsi+2], '"'
    jne .erro
.char_ok:
    movzx eax, byte [rsi+1]
    add qword [as_lp], 3
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call ex_set
    ret
.erro:
    lea rsi, [as_e_expr]
    jmp as_fail_plain

; ex_isalnum: eax = caractere -> eax = 1 se letra ou digito
ex_isalnum:
    cmp al, '0'
    jb .nao
    cmp al, '9'
    jbe .sim
    or al, 32
    cmp al, 'a'
    jb .nao
    cmp al, 'z'
    jbe .sim
.nao:
    xor eax, eax
    ret
.sim:
    mov eax, 1
    ret

; ex_digit: r8d = caractere -> eax = valor do digito (0..15) ou -1
ex_digit:
    mov eax, r8d
    cmp al, '0'
    jb .nao
    cmp al, '9'
    jbe .dec
    or al, 32
    cmp al, 'a'
    jb .nao
    cmp al, 'f'
    ja .nao
    sub al, 'a'-10
    movzx eax, al
    ret
.dec:
    sub al, '0'
    movzx eax, al
    ret
.nao:
    mov eax, -1
    ret

; ex_numero: decimal, 0x... ou ...h (hexadecimal com sufixo), a partir de as_lp
ex_numero:
    mov rsi, [as_lp]
    xor ecx, ecx                    ; tamanho do token alfanumerico
.sc:
    movzx eax, byte [rsi+rcx]
    call ex_isalnum
    test eax, eax
    jz .scf
    inc rcx
    jmp .sc
.scf:
    mov r9, 10                      ; base
    mov r10, rcx                    ; digitos a converter
    xor r11d, r11d                  ; posicao inicial dos digitos
    cmp rcx, 2
    jb .base_ok
    cmp byte [rsi], '0'
    jne .base_ok
    cmp byte [rsi+1], 'x'
    je .prefixo
    cmp byte [rsi+1], 'X'
    je .prefixo
    jmp .base_ok
.prefixo:
    mov r9, 16
    add rsi, 2
    xor r11d, r11d
    sub r10, 2
    jmp .converte
.base_ok:
    movzx eax, byte [rsi+rcx-1]
    cmp al, 'h'
    je .sufixo
    cmp al, 'H'
    je .sufixo
    jmp .converte
.sufixo:
    mov r9, 16
    dec r10
.converte:
    xor eax, eax
    mov r12, rax                    ; valor acumulado
    xor edx, edx                    ; indice
.cl:
    cmp rdx, r10
    jae .cf
    movzx r8d, byte [rsi+rdx]
    push rdx
    call ex_digit
    pop rdx
    cmp eax, 0
    jl .invalido
    cmp rax, r9
    jae .invalido
    imul r12, r9
    add r12, rax
    inc rdx
    jmp .cl
.cf:
    add [as_lp], rcx               ; consome o token inteiro
    mov rax, r12
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call ex_set
    ret
.invalido:
    lea rsi, [as_e_num]
    jmp as_fail_plain

; ex_resolve: rax = inicio do identificador, rcx = tamanho -> valor da referencia
; Rotulos locais ('.x') sao chamados <ultimo rotulo global>.x.
ex_resolve:
    mov [rs_p], rax
    mov [rs_n], rcx
    cmp byte [rax], '.'
    jne .simples
    ; monta o nome completo em as_nmbuf
    lea rdi, [as_nmbuf]
    lea r8, [as_lastglob]
    xor edx, edx
.pre:
    cmp rdx, [as_lastglen]
    jae .pre_fim
    mov al, [r8+rdx]
    mov [rdi+rdx], al
    inc rdx
    jmp .pre
.pre_fim:
    mov r9, rdx                     ; tamanho do prefixo
    lea r8, [rdi+r9]
    mov rsi, [rs_p]
    xor edx, edx
.loc:
    cmp rdx, [rs_n]
    jae .loc_fim
    mov al, [rsi+rdx]
    mov [r8+rdx], al
    inc rdx
    jmp .loc
.loc_fim:
    lea rsi, [as_nmbuf]
    mov rcx, r9
    add rcx, [rs_n]
    jmp .procura
.simples:
    mov rsi, rax
    mov rcx, [rs_n]
.procura:
    push rsi
    push rcx
    call as_sym_find
    pop rcx
    pop rsi
    cmp rax, -1
    je .nao_existe
    mov rbx, rax
    lea rdx, [as_sym_kind]
    mov r9, [rdx+rbx*8]
    cmp r9, 1
    je .rotulo
    cmp r9, 2
    je .equ
    cmp r9, 3
    je .externo
    jmp .pendente
.rotulo:
    lea rdx, [as_sym_val]
    mov rax, [rdx+rbx*8]
    lea rdx, [as_sym_sec]
    mov rcx, [rdx+rbx*8]
    mov rdx, 1
    xor r8d, r8d
    call ex_set
    ret
.equ:
    lea rdx, [as_sym_val]
    mov rax, [rdx+rbx*8]
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call ex_set
    ret
.externo:
    mov rax, 0
    mov rdx, 2
    mov rcx, rbx
    xor r8d, r8d
    call ex_set
    ret
.nao_existe:
    push rsi
    push rcx
    call ex_is_imp                  ; rsi, rcx ja preparados
    pop rcx
    pop rsi
    test eax, eax
    jz .pendente
    ; simbolo externo implicito (entrada da IAT)
    push rsi
    push rcx
    call as_sym_new
    pop rcx
    pop rsi
    mov rbx, rax
    lea rdx, [as_sym_kind]
    mov qword [rdx+rbx*8], 3
    jmp .externo
.pendente:
    cmp qword [as_pass], 1
    je .indef
    lea rsi, [as_e_sym]
    jmp as_fail_plain
.indef:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    mov r8d, 1
    call ex_set
    ret

; ex_is_imp: rsi = nome, rcx = tamanho -> eax = 1 se comeca com "__imp_"
ex_is_imp:
    xor eax, eax
    cmp rcx, 6
    jb .nao
    lea rdi, [as_imp_pfx]
    xor edx, edx
.l:
    cmp rdx, 6
    jae .sim
    mov al, [rsi+rdx]
    cmp al, [rdi+rdx]
    jne .nao
    inc rdx
    jmp .l
.sim:
    mov eax, 1
    ret
.nao:
    xor eax, eax
    ret

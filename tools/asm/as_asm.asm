; ============ ASM: simbolos, expressoes, operandos, diretivas e passagens ============
; Duas passagens sobre as_exbuf. Passagem 1: rotulos e tamanhos (sem gravar).
; Passagem 2: gravacao das secoes e relocacoes. Expressoes devolvem (valor, tipo,
; secao/simbolo, indefinido): tipo 0 = absoluto, 1 = relativo a secao, 2 = externo.

%define AS_MAXSYM      65536
%define AS_HASHN       65536
%define AS_NAMEPOOL    8388608
%define AS_MAXREL      262144
%define AS_NOPTYPE     0
%define AS_OP_MAX      4

section .bss
alignb 16
as_pass:        resq 1                ; 1 ou 2
as_cur:         resq 1                ; secao atual: 1 .text, 2 .data, 3 .bss
as_off:         resq 4                ; deslocamento atual por secao (1..3)
as_secsize:     resq 4                ; tamanho final por secao (1..3)
as_hash:        resq AS_HASHN         ; cabeca da cadeia (indice+1)
as_nsym:        resq 1
as_sym_name:    resq AS_MAXSYM        ; ponteiro para o nome (namepool)
as_sym_len:     resq AS_MAXSYM
as_sym_kind:    resq AS_MAXSYM        ; 0 indefinido, 1 rotulo, 2 equ, 3 externo
as_sym_sec:     resq AS_MAXSYM
as_sym_val:     resq AS_MAXSYM
as_sym_glob:    resq AS_MAXSYM
as_sym_next:    resq AS_MAXSYM
as_sym_coff:    resq AS_MAXSYM        ; indice COFF do simbolo (-1 = ainda nao)
as_namepool:    resb AS_NAMEPOOL
as_nptop:       resq 1
as_lastglob:    resb 512              ; ultimo rotulo global (base dos locais '.x')
as_lastglen:    resq 1
as_nmbuf:       resb 1024             ; nome completo (com rotulo local resolvido)
as_mn:          resb 32               ; mnemonico/diretiva em minusculas
as_mnlen:       resq 1
as_lp:          resq 1                ; ponteiro de leitura na linha
as_le:          resq 1                ; fim da linha
as_lineno:      resq 1
as_rel_n:       resq 3                ; numero de relocacoes por secao
as_rel:         resb AS_MAXREL * 16 * 3   ; registros: va(4) sym(4) tipo(2) pad(6)
; valor da ultima expressao
E_V:            resq 1
E_K:            resq 1
E_S:            resq 1
E_U:            resq 1
; operandos
op_n:           resq 1
op_t:           resq AS_OP_MAX        ; 0 nenhum, 1 registro, 2 imediato, 3 memoria
op_reg:         resq AS_OP_MAX        ; indice do registro (0..15)
op_rsz:         resq AS_OP_MAX        ; tamanho do registro: 1,2,4,8 (16/32 = xmm/ymm)
op_base:        resq AS_OP_MAX        ; base da memoria (16 = nenhuma)
op_index:       resq AS_OP_MAX        ; indice da memoria (16 = nenhum)
op_scale:       resq AS_OP_MAX
op_msz:         resq AS_OP_MAX        ; tamanho declarado: 0, 1, 2, 4, 8
op_v:           resq AS_OP_MAX        ; valor (imediato ou deslocamento)
op_k:           resq AS_OP_MAX        ; tipo do valor (0,1,2)
op_s:           resq AS_OP_MAX        ; secao ou simbolo
op_u:           resq AS_OP_MAX        ; indefinido na passagem 1
; buffer de saida de uma instrucao
ins_buf:        resb 32
ins_len:        resq 1
ins_rel:        resq 1                ; 1 se ha relocacao
ins_relpos:     resq 1                ; posicao do campo dentro da instrucao
ins_reltype:    resq 1                ; 1 ADDR64, 4 REL32, 5..9 REL32_k
ins_relk:       resq 1                ; tipo da referencia (1 secao, 2 externo)
ins_rels:       resq 1                ; secao ou simbolo
ins_reladd:     resq 1                ; valor a gravar no campo
as_errln:       resq 1

section .data
align 8
as_e_sym:       db "simbolo indefinido", 0
as_e_expr:      db "expressao nao suportada", 0
as_e_divzero:   db "divisao por zero em expressao", 0
as_e_num:       db "numero invalido", 0
as_e_dup:       db "rotulo definido duas vezes", 0
as_e_pool:      db "pool de nomes cheio", 0
as_e_sec:       db "secao invalida", 0
as_e_op:        db "operando invalido", 0
as_e_rel:       db "relocacoes demais", 0
as_e_char:      db "caractere invalido", 0
as_imp_pfx:     db "__imp_", 0

section .text

; ---------- as_tolower: al -> al em minusculas ------------------------------------
as_tolower:
    cmp al, 'A'
    jb .f
    cmp al, 'Z'
    ja .f
    add al, 32
.f:
    ret

; ---------- as_isid: al = caractere -> eax = 1 se pode compor identificador -------
as_isid:
    cmp al, '_'
    je .sim
    cmp al, '.'
    je .sim
    cmp al, '?'
    je .sim
    cmp al, '0'
    jb .nao
    cmp al, '9'
    jbe .sim
    cmp al, 'A'
    jb .nao
    cmp al, 'Z'
    jbe .sim
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

; ---------- as_skipsp: avanca espacos da linha (as_lp) ---------------------------------
as_skipsp:
    mov rsi, [as_lp]
.l:
    cmp rsi, [as_le]
    jae .f
    mov al, [rsi]
    cmp al, ' '
    je .n
    cmp al, 9
    je .n
    jmp .f
.n:
    inc rsi
    jmp .l
.f:
    mov [as_lp], rsi
    ret

; ---------- as_peek: -> al = proximo caractere nao-espaco (0 no fim) -------------
as_peek:
    call as_skipsp
    mov rsi, [as_lp]
    xor eax, eax
    cmp rsi, [as_le]
    jae .f
    mov al, [rsi]
.f:
    ret

; ---------- as_ident: le identificador em as_lp -> rax = inicio, rcx = tamanho
as_ident:
    call as_skipsp
    mov rsi, [as_lp]
    mov r8, rsi                     ; inicio (r8 nao e alterado por as_isid)
    xor ecx, ecx
.l:
    mov rdx, rsi
    add rdx, rcx
    cmp rdx, [as_le]
    jae .f
    mov al, [rsi+rcx]
    call as_isid
    test eax, eax
    jz .f
    inc rcx
    jmp .l
.f:
    test rcx, rcx
    jz .vazio
    add [as_lp], rcx
    mov rax, r8
    ret
.vazio:
    xor ecx, ecx
    ret
; ---------- as_strcmp_ci: rsi = texto (tamanho rcx), rdi = minusculo ZT -> eax -----
as_eqci:
    push rbx
    xor ebx, ebx                    ; indice
.l:
    cmp rbx, rcx
    jae .fim_texto
    mov al, [rsi+rbx]
    call as_tolower
    cmp al, [rdi+rbx]
    jne .nao
    inc rbx
    jmp .l
.fim_texto:
    cmp byte [rdi+rbx], 0
    jne .nao
    mov eax, 1
    pop rbx
    ret
.nao:
    xor eax, eax
    pop rbx
    ret

; ---------- as_hashstr: rsi = nome, rcx = tamanho -> rax = bucket (FNV-1a) ---------
as_hashstr:
    mov rax, 0xcbf29ce484222325
    xor edx, edx
.l:
    cmp rdx, rcx
    jae .f
    xor al, [rsi+rdx]
    mov r8, 0x100000001b3
    imul rax, r8
    inc rdx
    jmp .l
.f:
    and rax, AS_HASHN-1
    ret

; ---------- as_sym_find: rsi = nome, rcx = tamanho -> rax = indice ou -1 ------------
as_sym_find:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rcx
    call as_hashstr
    lea rdx, [as_hash]
    mov rbx, [rdx+rax*8]            ; indice+1
.l:
    test rbx, rbx
    jz .nao
    dec rbx                         ; indice real
    mov rdx, rbx
    lea rax, [as_sym_len]
    mov r14, [rax+rdx*8]
    cmp r14, r13
    jne .prox
    lea rax, [as_sym_name]
    mov rsi, [rax+rdx*8]
    mov rdi, r12
    mov rcx, r13
    push rbx
    call as_memeq
    pop rbx
    test eax, eax
    jnz .achou
.prox:
    lea rax, [as_sym_next]
    mov rbx, [rax+rbx*8]
    jmp .l
.achou:
    mov rax, rbx
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.nao:
    mov rax, -1
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------- as_memeq: rsi, rdi, rcx -> eax = 1 se iguais -------------------------------
as_memeq:
    xor edx, edx
.l:
    cmp rdx, rcx
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

; ---------- as_sym_new: rsi = nome, rcx = tamanho -> rax = indice novo ----------
as_sym_new:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rcx
    mov rbx, [as_nsym]
    cmp rbx, AS_MAXSYM
    jae .cheio
    ; copia o nome para o pool de nomes
    mov rax, [as_nptop]
    lea rdi, [as_namepool]
    add rdi, rax
    mov rdx, rdi                    ; inicio do nome no pool
    lea rax, [rax+r13+1]
    cmp rax, AS_NAMEPOOL
    ja .cheio
    mov [as_nptop], rax
    xor ecx, ecx
.c:
    cmp rcx, r13
    jae .cfim
    mov al, [r12+rcx]
    mov [rdi+rcx], al
    inc rcx
    jmp .c
.cfim:
    mov byte [rdi+r13], 0
    lea rax, [as_sym_name]
    mov [rax+rbx*8], rdx
    lea rax, [as_sym_len]
    mov [rax+rbx*8], r13
    lea rax, [as_sym_kind]
    mov qword [rax+rbx*8], 0
    lea rax, [as_sym_coff]
    mov qword [rax+rbx*8], -1
    lea rax, [as_sym_glob]
    mov qword [rax+rbx*8], 0
    lea rax, [as_sym_val]
    mov qword [rax+rbx*8], 0
    lea rax, [as_sym_sec]
    mov qword [rax+rbx*8], 0
    ; encadeia: next = cabeca antiga; cabeca = indice+1
    mov rsi, r12
    mov rcx, r13
    call as_hashstr                 ; rax = balde
    lea rdx, [as_hash]
    mov rcx, [rdx+rax*8]
    lea rdx, [as_sym_next]
    mov [rdx+rbx*8], rcx
    lea rdx, [as_hash]
    lea rcx, [rbx+1]
    mov [rdx+rax*8], rcx
    inc qword [as_nsym]
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret
.cheio:
    lea rsi, [as_e_pool]
    call as_fail_plain

; ----------


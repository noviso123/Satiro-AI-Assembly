; ============ ASM: linhas, rotulos, diretivas de dados e passagens ============
; Contratos:
;   as_emit(rsi = bytes, rcx = quantidade): grava na secao atual (passagem 2) e
;       avanca o deslocamento da secao. Em .bss so aceita quantidade zero.
;   as_addrel(r8 = tipo COFF, r9 = alvo (1 secao, 2 externo), r10 = secao 1..3 ou
;       indice do simbolo): registra relocacao no deslocamento ATUAL da secao
;       (chamar antes de as_emit do campo). So na passagem 2.

%define AS_PAD 4096

section .bss
alignb 16
st_p:           resq 1                  ; inicio do primeiro identificador da linha
st_n:           resq 1                  ; tamanho desse identificador
st_full_p:      resq 1                  ; nome completo (local resolvido)
st_full_n:      resq 1
st_mn_end:      resq 1
as_secbuf:      resb AS_SEC_SIZE * 2    ; .text, depois .data (passagem 2)
as_valq:        resq 1                  ; valor de 8 bytes a gravar
as_padtop:      resq 1

section .data
align 8
as_e_bss:       db "dados nao permitidos em .bss", 0
as_e_ins0:      db "linha sem instrucao ou diretiva", 0
as_e_equ:       db "equ precisa de valor conhecido na passagem 1", 0
as_e_dup2:      db "rotulo definido duas vezes", 0
as_e_secnm:     db "secao desconhecida", 0
as_e_str:       db "string sem fechamento ou em dq/dw/dd", 0
as_e_size:      db "valor grande demais para o tamanho do dado", 0
as_e_relsz:     db "relocacao so em dq (8 bytes)", 0
as_e_times:     db "times precisa de um numero conhecido", 0
as_e_arg:       db "argumento de diretiva invalido", 0
as_s_txt:       db "    > ", 0
as_e_dir:       db "diretiva desconhecida", 0
as_e_relcheio: db "relocacoes demais", 0
as_e_align:     db "align precisa de um numero conhecido", 0
as_e_virg:      db "esperado virgula ou fim de linha", 0
as_w_section:   db "section", 0
as_w_segment:   db "segment", 0
as_w_global:    db "global", 0
as_w_extern:    db "extern", 0
as_w_bits:      db "bits", 0
as_w_default:   db "default", 0
as_w_align:     db "align", 0
as_w_alignb:    db "alignb", 0
as_w_times:     db "times", 0
as_w_db:        db "db", 0
as_w_dw:        db "dw", 0
as_w_dd:        db "dd", 0
as_w_dq:        db "dq", 0
as_w_resb:      db "resb", 0
as_w_resw:      db "resw", 0
as_w_resd:      db "resd", 0
as_w_resq:      db "resq", 0
as_w_equ:       db "equ", 0
as_s_text:      db ".text", 0
as_s_data:      db ".data", 0
as_s_bss:       db ".bss", 0
as_padnop:      times AS_PAD db 0x90
as_padzero:     times AS_PAD db 0

section .text

; ---------- as_emit: rsi = bytes, rcx = quantidade ----------------------------------
as_emit:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rcx
    mov rax, [as_cur]
    cmp rax, 3
    je .bss
    cmp qword [as_pass], 2
    jne .avanca
    lea rdx, [as_off]
    mov rbx, [rdx+rax*8]            ; deslocamento de escrita
    lea rdx, [as_secbuf]
    cmp rax, 2
    jne .texto
    add rdx, AS_SEC_SIZE
.texto:
    add rdx, rbx
    xor ecx, ecx
.copia:
    cmp rcx, r13
    jae .avanca
    mov al, [r12+rcx]
    mov [rdx+rcx], al
    inc rcx
    jmp .copia
.avanca:
    mov rax, [as_cur]
    lea rdx, [as_off]
    add [rdx+rax*8], r13
    jmp .fim
.bss:
    test r13, r13
    jz .fim
    lea rsi, [as_e_bss]
    jmp as_fail_plain
.fim:
    pop r13
    pop r12
    pop rbx
    ret

; ---------- as_addrel: ver contrato acima. Nada e feito na passagem 1 -------------
as_addrel:
    cmp qword [as_pass], 2
    jne .fim
    push rbx
    mov rbx, [as_cur]
    dec rbx                         ; secao 0..2
    lea rdx, [as_rel_n]
    mov rcx, [rdx+rbx*8]
    cmp rcx, AS_MAXREL
    jae .cheio
    mov rax, rbx
    imul rax, rax, AS_MAXREL*16
    lea rdi, [as_rel]
    add rdi, rax
    mov rax, rcx
    shl rax, 4
    add rdi, rax                    ; registro
    lea rdx, [as_off]
    mov rax, [rdx+rbx*8+8]          ; deslocamento da secao (indice 1..3)
    add rax, [ar_extra]             ; campo dentro da instrucao (0 para dados)
    mov qword [ar_extra], 0
    mov [rdi], eax                  ; va
    cmp r9, 2
    jne .secao
    mov [rdi+4], r10d               ; simbolo externo: indice na nossa tabela
    jmp .tipo
.secao:
    lea rax, [r10-1]
    or eax, 0x80000000              ; marca: referencia a secao (0..2)
    mov [rdi+4], eax
.tipo:
    mov [rdi+8], r8w
    mov word [rdi+10], 0
    lea rdx, [as_rel_n]
    inc qword [rdx+rbx*8]
    pop rbx
.fim:
    mov qword [ar_extra], 0         ; deslocamento extra so vale para a relocacao atual
    ret
.cheio:
    lea rsi, [as_e_relcheio]
    jmp as_fail_plain

; ---------- as_put_le: rax = valor, rdx = tamanho em bytes (1,2,4,8) -> emite ------
as_put_le:
    mov [as_valq], rax
    lea rsi, [as_valq]
    mov rcx, rdx
    call as_emit
    ret

; ---------- as_label_def: rax = inicio, rcx = tamanho (rotulo, com ':' ja consumido) --
as_label_def:
    push rbx
    call as_fullname                ; st_full_p/n = nome completo
    ; rotulo global: atualiza o rotulo base dos locais
    mov rsi, [st_p]
    cmp byte [rsi], '.'
    je .define
    mov rsi, [st_p]
    mov rcx, [st_n]
    cmp rcx, 511
    ja .define
    lea rdi, [as_lastglob]
    xor edx, edx
.cp:
    cmp rdx, rcx
    jae .cp_fim
    mov al, [rsi+rdx]
    mov [rdi+rdx], al
    inc rdx
    jmp .cp
.cp_fim:
    mov [as_lastglen], rcx
.define:
    cmp qword [as_pass], 1
    jne .fim                        ; na passagem 2 os rotulos ja estao definidos
    mov rsi, [st_full_p]
    mov rcx, [st_full_n]
    call as_sym_def
    mov rbx, rax
    lea rdx, [as_sym_kind]
    cmp qword [rdx+rbx*8], 0
    jne .dup
    mov qword [rdx+rbx*8], 1
    mov rax, [as_cur]
    lea rdx, [as_sym_sec]
    mov [rdx+rbx*8], rax
    lea rdx, [as_off]
    mov rax, [rdx+rax*8]
    lea rdx, [as_sym_val]
    mov [rdx+rbx*8], rax
.fim:
    pop rbx
    ret
.dup:
    lea rsi, [as_e_dup2]
    jmp as_fail_plain

; ---------- as_stmt: processa a linha atual (as_lp .. as_le) ----------------------------
as_stmt:
    call as_peek
    test al, al
    jz .fim
    call as_ident
    test rcx, rcx
    jz .sem_ident
    mov [st_p], rax
    mov [st_n], rcx
    call as_peek
    cmp al, ':'
    jne .sem_rotulo
    inc qword [as_lp]
    mov rax, [st_p]
    mov rcx, [st_n]
    call as_label_def
    call as_peek
    test al, al
    jz .fim
    call as_ident
    test rcx, rcx
    jz .sem_ident
    mov [st_p], rax
    mov [st_n], rcx
.sem_rotulo:
    ; 'nome equ expr'?
    mov rsi, [as_lp]
    mov [st_mn_end], rsi            ; posicao salva para restaurar
    call as_peek
    mov rax, [st_p]
    mov rcx, [st_n]
    cmp rcx, 0
    je .sem_ident
    call as_ident_next_is_equ
    test eax, eax
    jz .diretiva
    ; nome equ expressao
    call as_equ_def
    jmp .fim
.diretiva:
    mov rsi, [st_mn_end]
    mov [as_lp], rsi
    call as_dispatch
    jmp .fim
.sem_ident:
    lea rsi, [as_e_ins0]
    jmp as_fail_plain
.fim:
    ret

; as_ident_next_is_equ: eax = 1 se o proximo identificador e 'equ' (consome apenas se 1)
as_ident_next_is_equ:
    push rcx
    mov rsi, [as_lp]
    push rsi
    call as_ident
    test rcx, rcx
    jz .nao
    cmp rcx, 3
    jne .nao
    cmp byte [rax], 'e'
    jne .nao
    cmp byte [rax+1], 'q'
    jne .nao
    cmp byte [rax+2], 'u'
    jne .nao
    pop rsi
    mov eax, 1
    pop rcx
    ret
.nao:
    pop rsi
    mov [as_lp], rsi
    xor eax, eax
    pop rcx
    ret

; as_equ_def: st = nome; lp no valor. Define o equ (somente passagem 1).
as_equ_def:
    call ex_expr
    cmp qword [as_pass], 1
    jne .fim
    cmp qword [E_U], 0
    jne .erro
    cmp qword [E_K], 0
    jne .erro
    mov rsi, [st_p]
    mov rcx, [st_n]
    call as_sym_def
    mov rbx, rax
    lea rdx, [as_sym_kind]
    cmp qword [rdx+rbx*8], 0
    jne .dup
    mov qword [rdx+rbx*8], 2
    lea rdx, [as_sym_val]
    mov rax, [E_V]
    mov [rdx+rbx*8], rax
.fim:
    ret
.erro:
    lea rsi, [as_e_equ]
    jmp as_fail_plain
.dup:
    lea rsi, [as_e_dup2]
    jmp as_fail_plain

; ---------- as_dispatch: st = nome da diretiva ou instrucao; lp no restante --------------
as_dispatch:
    push rbx
    ; copia o nome em minusculas para as_mn (zero-terminado)
    lea rdi, [as_mn]
    mov rsi, [st_p]
    xor ecx, ecx
.lower:
    cmp rcx, [st_n]
    jae .lower_fim
    cmp rcx, 30
    jae .lower_fim
    mov al, [rsi+rcx]
    cmp al, 'A'
    jb .l2
    cmp al, 'Z'
    ja .l2
    add al, 32
.l2:
    mov [rdi+rcx], al
    inc rcx
    jmp .lower
.lower_fim:
    mov byte [rdi+rcx], 0
    lea rsi, [as_mn]
    lea rdi, [as_w_section]
    call as_streq
    test eax, eax
    jnz .d_section
    lea rsi, [as_mn]
    lea rdi, [as_w_segment]
    call as_streq
    test eax, eax
    jnz .d_section
    lea rsi, [as_mn]
    lea rdi, [as_w_global]
    call as_streq
    test eax, eax
    jnz .d_global
    lea rsi, [as_mn]
    lea rdi, [as_w_extern]
    call as_streq
    test eax, eax
    jnz .d_extern
    lea rsi, [as_mn]
    lea rdi, [as_w_bits]
    call as_streq
    test eax, eax
    jnz .d_ignora
    lea rsi, [as_mn]
    lea rdi, [as_w_default]
    call as_streq
    test eax, eax
    jnz .d_ignora
    lea rsi, [as_mn]
    lea rdi, [as_w_align]
    call as_streq
    test eax, eax
    jnz .d_align
    lea rsi, [as_mn]
    lea rdi, [as_w_alignb]
    call as_streq
    test eax, eax
    jnz .d_align
    lea rsi, [as_mn]
    lea rdi, [as_w_times]
    call as_streq
    test eax, eax
    jnz .d_times
    lea rsi, [as_mn]
    lea rdi, [as_w_resb]
    call as_streq
    test eax, eax
    jnz .d_res1
    lea rsi, [as_mn]
    lea rdi, [as_w_resw]
    call as_streq
    test eax, eax
    jnz .d_res2
    lea rsi, [as_mn]
    lea rdi, [as_w_resd]
    call as_streq
    test eax, eax
    jnz .d_res4
    lea rsi, [as_mn]
    lea rdi, [as_w_resq]
    call as_streq
    test eax, eax
    jnz .d_res8
    lea rsi, [as_mn]
    lea rdi, [as_w_db]
    call as_streq
    test eax, eax
    jnz .d_db
    lea rsi, [as_mn]
    lea rdi, [as_w_dw]
    call as_streq
    test eax, eax
    jnz .d_dw
    lea rsi, [as_mn]
    lea rdi, [as_w_dd]
    call as_streq
    test eax, eax
    jnz .d_dd
    lea rsi, [as_mn]
    lea rdi, [as_w_dq]
    call as_streq
    test eax, eax
    jnz .d_dq
    ; instrucao
    call as_insn
    jmp .fim
.d_section:
    call as_ident
    test rcx, rcx
    jz .erro_sec
    mov rsi, rax                    ; inicio do nome para as comparacoes
    lea rdi, [as_s_text]
    call as_name_is
    test eax, eax
    jnz .sec1
    lea rdi, [as_s_data]
    call as_name_is
    test eax, eax
    jnz .sec2
    lea rdi, [as_s_bss]
    call as_name_is
    test eax, eax
    jnz .sec3
    jmp .erro_sec
.sec1:
    mov qword [as_cur], 1
    jmp .fim
.sec2:
    mov qword [as_cur], 2
    jmp .fim
.sec3:
    mov qword [as_cur], 3
    jmp .fim
.d_global:
    mov qword [decl_mode], 1
    call as_decl_list
    jmp .fim
.d_extern:
    mov qword [decl_mode], 2
    call as_decl_list
    jmp .fim
.d_ignora:
    mov rsi, [as_le]
    mov [as_lp], rsi
    jmp .fim
.d_align:
    call ex_expr
    cmp qword [E_U], 0
    jne .erro_align
    cmp qword [E_K], 0
    jne .erro_align
    mov rax, [E_V]
    test rax, rax
    jz .fim
    call as_align_to
    jmp .fim
.d_times:
    call ex_expr
    cmp qword [E_U], 0
    jne .erro_times
    cmp qword [E_K], 0
    jne .erro_times
    mov rax, [E_V]
    mov [sd_count], rax
    ; a diretiva de dados segue; o restante da linha e repetido
    mov rsi, [as_lp]
    mov [sd_start], rsi
    call as_ident
    test rcx, rcx
    jz .erro_times
    mov rsi, rax
    lea rdi, [as_mn]
    call as_lower_copy
    mov qword [sd_rep], 1
    jmp .d_times_loop
.d_times_loop:
    mov rax, [sd_rep]
    cmp rax, [sd_count]
    ja .fim
    mov rsi, [sd_start]
    mov rax, [as_lp]
    ; cada repeticao reprocessa o nome da diretiva a partir de sd_start
    mov [as_lp], rsi
    call as_ident                   ; consome o nome da diretiva
    lea rsi, [as_mn]
    call as_data_by_name
    inc qword [sd_rep]
    jmp .d_times_loop
.d_res1:
    mov edx, 1
    jmp .d_res
.d_res2:
    mov edx, 2
    jmp .d_res
.d_res4:
    mov edx, 4
    jmp .d_res
.d_res8:
    mov edx, 8
.d_res:
    mov [sd_tmp], rdx
    call ex_expr
    cmp qword [E_U], 0
    jne .erro_arg
    cmp qword [E_K], 0
    jne .erro_arg
    mov rax, [E_V]
    mov rdx, [sd_tmp]
    imul rax, rdx
    mov rcx, rax
    ; reserva: avanca sem escrever (bss) ou escreve zeros (outras secoes)
    test rcx, rcx
    jz .fim
    call as_emit_zeros
    jmp .fim
.d_db:
    mov edx, 1
    jmp .d_data
.d_dw:
    mov edx, 2
    jmp .d_data
.d_dd:
    mov edx, 4
    jmp .d_data
.d_dq:
    mov edx, 8
.d_data:
    call as_data_list
    jmp .fim
.erro_sec:
    lea rsi, [as_e_secnm]
    jmp as_fail_plain
.erro_align:
    lea rsi, [as_e_align]
    jmp as_fail_plain
.erro_times:
    lea rsi, [as_e_times]
    jmp as_fail_plain
.erro_arg:
    lea rsi, [as_e_arg]
    jmp as_fail_plain
.erro:
    lea rsi, [as_e_dir]
    jmp as_fail_plain
.fim:
    pop rbx
    ret

section .bss
sd_count:       resq 1
ar_extra:       resq 1                  ; deslocamento extra do campo (instrucoes)
sd_tmp:         resq 1
decl_mode:      resq 1
sd_start:       resq 1
sd_rep:         resq 1
dl_size:        resq 1
as_errlin:      resb 256
section .text

; as_streq: rsi, rdi (zero-terminados) -> eax = 1 se iguais
as_streq:
    xor ecx, ecx
.l:
    mov al, [rsi+rcx]
    cmp al, [rdi+rcx]
    jne .nao
    test al, al
    jz .sim
    inc rcx
    jmp .l
.sim:
    mov eax, 1
    ret
.nao:
    xor eax, eax
    ret


; as_lower_copy: rsi = texto, rcx = tamanho, rdi = destino (zero-terminado, minusculo)
as_lower_copy:
    xor edx, edx
.l:
    cmp rdx, rcx
    jae .f
    mov al, [rsi+rdx]
    cmp al, 'A'
    jb .n
    cmp al, 'Z'
    ja .n
    add al, 32
.n:
    mov [rdi+rdx], al
    inc rdx
    jmp .l
.f:
    mov byte [rdi+rdx], 0
    ret

as_decl_list:
    push rbx
.nome:
    call as_ident
    test rcx, rcx
    jz .fim
    mov rsi, rax
    push rsi
    push rcx
    call as_sym_def
    pop rcx
    pop rsi
    mov rbx, rax
    cmp qword [decl_mode], 1
    jne .ext
    lea rdx, [as_sym_glob]
    mov qword [rdx+rbx*8], 1
    jmp .virg
.ext:
    lea rdx, [as_sym_kind]
    cmp qword [rdx+rbx*8], 0
    jne .virg
    mov qword [rdx+rbx*8], 3
.virg:
    call as_peek
    cmp al, ','
    jne .fim
    inc qword [as_lp]
    jmp .nome
.fim:
    pop rbx
    ret
; as_align_to: rax = alinhamento; emite preenchimento ate o alinhamento
as_align_to:
    push rbx
    mov rbx, rax
    mov rax, [as_cur]
    lea rdx, [as_off]
    mov rdx, [rdx+rax*8]
    mov rax, rdx
    xor edx, edx
    div rbx                         ; rdx = resto
    test rdx, rdx
    jz .fim
    mov rcx, rbx
    sub rcx, rdx                    ; bytes de preenchimento
    call as_emit_pad
.fim:
    pop rbx
    ret

; as_emit_pad: rcx = bytes de preenchimento (NOP em .text, zero nas outras)
as_emit_pad:
    push rbx
    mov rbx, rcx
    mov rax, [as_cur]
    cmp rax, 3
    je .avanca_bss
    lea r8, [as_padnop]             ; align preenche com NOP em qualquer secao (como o NASM)
.zero:
.loop:
    test rbx, rbx
    jz .fim
    mov rcx, rbx
    cmp rcx, AS_PAD
    jbe .ok
    mov rcx, AS_PAD
.ok:
    mov rsi, r8
    push rcx
    call as_emit
    pop rcx
    sub rbx, rcx
    jmp .loop
.avanca_bss:
    mov rax, [as_cur]
    lea rdx, [as_off]
    add [rdx+rax*8], rbx
.fim:
    pop rbx
    ret

; as_emit_zeros: rcx = quantidade de zeros (res*)
as_emit_zeros:
    push rbx
    mov rbx, rcx
    mov rax, [as_cur]
    cmp rax, 3
    je .avanca_bss
.loop:
    test rbx, rbx
    jz .fim
    mov rcx, rbx
    cmp rcx, AS_PAD
    jbe .ok
    mov rcx, AS_PAD
.ok:
    lea rsi, [as_padzero]
    push rcx
    call as_emit
    pop rcx
    sub rbx, rcx
    jmp .loop
.avanca_bss:
    mov rax, [as_cur]
    lea rdx, [as_off]
    add [rdx+rax*8], rbx
.fim:
    pop rbx
    ret

; as_data_by_name: rsi = nome da diretiva (minusculo) -> processa a lista restante
as_data_by_name:
    push rbx
    mov rbx, rsi
    lea rdi, [as_w_db]
    call as_streq
    test eax, eax
    jnz .b
    mov rsi, rbx
    lea rdi, [as_w_dw]
    call as_streq
    test eax, eax
    jnz .w
    mov rsi, rbx
    lea rdi, [as_w_dd]
    call as_streq
    test eax, eax
    jnz .d
    mov rsi, rbx
    lea rdi, [as_w_dq]
    call as_streq
    test eax, eax
    jnz .q
    lea rsi, [as_e_dir]
    jmp as_fail_plain
.fim:
    pop rbx
    ret
.b:
    mov edx, 1
    jmp .go
.w:
    mov edx, 2
    jmp .go
.d:
    mov edx, 4
    jmp .go
.q:
    mov edx, 8
.go:
    call as_data_list
    pop rbx
    ret

; as_data_list: rdx = tamanho do item (1,2,4,8); processa itens separados por virgula
as_data_list:
    push rbx
    mov [dl_size], rdx              ; tamanho em memoria: expressoes usam [dl_size]
.item:
    call as_peek
    test al, al
    jz .fim
    cmp al, '"'
    je .string
    cmp al, 39
    je .string
    ; expressao (ou ponto flutuante)
    call as_is_float
    test eax, eax
    jnz .flt
    call ex_expr
    cmp qword [E_U], 0
    jne .indef
    cmp qword [E_K], 0
    jne .reloc
    ; absoluto: verifica o tamanho e grava
    mov rax, [E_V]
    mov rdx, [dl_size]
    call as_check_size
    mov rdx, [dl_size]
    call as_put_le
    jmp .sep
.indef:
    xor eax, eax
    mov rdx, [dl_size]
    call as_put_le
    jmp .sep
.reloc:
    cmp qword [dl_size], 8
    jne .erro_relsz
    ; relocacao ADDR64: registra antes de gravar o campo
    mov r9, [E_K]
    mov r10, [E_S]
    mov r8, 1
    call as_addrel
    mov rax, [E_V]
    mov rdx, 8
    call as_put_le
    jmp .sep
.flt:
    call as_flt_parse               ; rax = bits IEEE 754 (dq ou dd)
    mov rdx, [dl_size]
    call as_put_le
    jmp .sep
.string:
    call as_data_string
    jmp .sep
.sep:
    call as_peek
    cmp al, ','
    jne .fim
    inc qword [as_lp]
    jmp .item
.fim:
    pop rbx
    ret
.erro_relsz:
    lea rsi, [as_e_relsz]
    jmp as_fail_plain

; as_is_float: eax = 1 se o item atual e um literal de ponto flutuante (ex.: 1.0, 2e-3)
as_is_float:
    mov rsi, [as_lp]
    xor ecx, ecx
    xor eax, eax
    ; o literal comeca com digito (sinal opcional): rotulos como e5 nao contam
    mov dl, [rsi]
    cmp dl, '-'
    je .sinal
    cmp dl, '+'
    jne .primeiro
.sinal:
    inc rsi
.primeiro:
    mov dl, [rsi]
    cmp dl, '0'
    jb .fim
    cmp dl, '9'
    ja .fim
.l:
    mov rdx, rsi
    add rdx, rcx
    cmp rdx, [as_le]
    jae .fim
    mov dl, [rsi+rcx]
    cmp dl, ','
    je .fim
    cmp dl, '.'
    je .sim
    cmp dl, 'e'
    je .expo
    cmp dl, 'E'
    je .expo
    inc rcx
    jmp .l
.expo:
    ; 'e' so conta como float se seguido de digito ou sinal e digito
    mov rdx, rsi
    add rdx, rcx
    inc rdx
    cmp rdx, [as_le]
    jae .fim_nao
    mov dl, [rdx]
    cmp dl, '-'
    je .sim
    cmp dl, '+'
    je .sim
    cmp dl, '0'
    jb .fim_nao
    cmp dl, '9'
    ja .fim_nao
    jmp .sim
.fim_nao:
    xor eax, eax
    ret
.sim:
    mov eax, 1
    ret
.fim:
    ret

; as_check_size: rax = valor, rdx = tamanho -> erro se nao couber
as_check_size:
    cmp rdx, 8
    je .ok
    mov rcx, rdx
    shl rcx, 3
    mov r8, 1
    shl r8, cl                      ; 2^bits
    ; faixa aceita: -2^(bits-1) .. 2^bits - 1
    mov r9, r8
    shr r9, 1
    neg r9
    cmp rax, r9
    jl .erro
    lea r10, [r8-1]
    cmp rax, r10
    jg .erro
.ok:
    ret
.erro:
    lea rsi, [as_e_size]
    jmp as_fail_plain

; as_data_string: texto entre aspas (somente db)
as_data_string:
    push rbx
    push r12
    mov r12, [as_lp]
    movzx ebx, byte [r12]           ; aspa
    inc r12
    xor ecx, ecx
.c:
    cmp r12, [as_le]
    jae .erro
    cmp byte [r12], bl
    je .fim
    mov al, [r12]
    lea rsi, [as_strbyte]
    mov [rsi], al
    push rcx
    mov rcx, 1
    call as_emit
    pop rcx
    inc r12
    jmp .c
.fim:
    inc r12
    mov [as_lp], r12
    pop r12
    pop rbx
    ret
.erro:
    lea rsi, [as_e_str]
    jmp as_fail_plain

section .bss
as_strbyte:     resb 1

section .text

; as_name_is: rsi = inicio, rcx = tamanho, rdi = nome ZT -> eax = 1 se iguais (rsi/rcx intactos)
as_name_is:
    push rbx                        ; rsi = inicio do nome (preservado entre chamadas)
    xor edx, edx
.cmp_n:
    cmp byte [rdi+rdx], 0
    je .fim_n
    cmp rdx, rcx
    jae .nao_n
    mov al, [rsi+rdx]
    cmp al, [rdi+rdx]
    jne .nao_n
    inc rdx
    jmp .cmp_n
.fim_n:
    cmp rdx, rcx
    jne .nao_n
    mov eax, 1
    pop rbx
    ret
.nao_n:
    xor eax, eax
    pop rbx
    ret
section .text

; ---------- as_fullname: rax = inicio, rcx = tamanho -> st_full_p/st_full_n ------------
; Rotulo local ('.x') vira <ultimo rotulo global><.x> em as_nmbuf; outro nome fica igual.
as_fullname:
    mov [st_full_p], rax
    mov [st_full_n], rcx
    cmp byte [rax], '.'
    jne .fim
    lea rdi, [as_nmbuf]
    lea r8, [as_lastglob]
    xor edx, edx
.g:
    cmp rdx, [as_lastglen]
    jae .g_fim
    mov al, [r8+rdx]
    mov [rdi+rdx], al
    inc rdx
    jmp .g
.g_fim:
    mov r9, rdx                     ; tamanho do prefixo
    lea r8, [rdi+r9]
    mov rsi, [st_full_p]
    xor edx, edx
.c:
    cmp rdx, [st_full_n]
    jae .c_fim
    mov al, [rsi+rdx]
    mov [r8+rdx], al
    inc rdx
    jmp .c
.c_fim:
    lea rax, [as_nmbuf]
    mov [st_full_p], rax
    mov rax, r9
    add rax, [st_full_n]
    mov [st_full_n], rax
.fim:
    ret

; ---------- as_sym_def: rsi = nome, rcx = tamanho -> rax = indice (cria se preciso) ------
as_sym_def:
    push rsi
    push rcx
    call as_sym_find
    pop rcx
    pop rsi
    cmp rax, -1
    jne .ok
    call as_sym_new
.ok:
    ret
; ---------- as_fail_plain: rsi = mensagem; imprime com o numero da linha e sai ------
as_fail_plain:
    AS_ENTER
    push rsi
    lea rsi, [as_s_err]
    call as_say
    pop rsi
    call as_say
    lea rsi, [as_s_at]
    call as_say
    mov rax, [as_lineno]
    call as_say_num
    lea rsi, [as_s_close]
    call as_say
    ; mostra o texto da linha: o numero acima conta as linhas ja expandidas
    ; (%include, %macro), entao pode nao coincidir com a linha do arquivo
    mov rdx, [as_le]
    test rdx, rdx
    jz .sai
    lea r8, [as_exbuf]
    mov rsi, rdx
.volta:
    cmp rsi, r8
    jbe .achou
    cmp byte [rsi-1], 10
    je .achou
    dec rsi
    jmp .volta
.achou:
    mov rcx, rdx
    sub rcx, rsi                    ; tamanho da linha
    cmp rcx, 200
    jbe .tam_ok
    mov ecx, 200
.tam_ok:
    lea rdi, [as_errlin]
    xor eax, eax
.cp:
    cmp rax, rcx
    jae .cp_fim
    mov r9b, [rsi+rax]
    cmp r9b, 13
    je .cp_fim
    mov [rdi+rax], r9b
    inc rax
    jmp .cp
.cp_fim:
    mov byte [rdi+rax], 0
    lea rsi, [as_s_txt]
    call as_say
    lea rsi, [as_errlin]
    call as_say
    lea rsi, [as_s_nl]
    call as_say
.sai:
    mov ecx, 1
    call [__imp_ExitProcess]

; ============ ASM: pre-processador (%include, %define, %if/%ifdef/%else/%endif, %error) ==
; Entrada: arquivo de codigo. Saida: as_exbuf com as linhas expandidas (sem comentarios
; e sem linhas vazias). Substituicao de %define e textual, como no NASM. Identificadores
; precedidos de '.' (rotulos locais) e conteudo entre aspas nao sao substituidos.

%define AS_DEF_MAX     1024
%define AS_DEFPOOL     262144
%define AS_PATHPOOL    65536
%define AS_LBUF        8192
%define AS_COND_MAX    64
%define AS_SUBST_DEPTH 64
%define AS_MAC_MAX     16           ; macros %macro NOME 0 (sem parametros)
%define AS_MAC_BODY    4096         ; bytes do corpo de cada macro

section .bss
alignb 16
pre_level:    resq 1
pre_ndef:     resq 1
pre_defname:  resq AS_DEF_MAX
pre_defval:   resq AS_DEF_MAX
pre_defvlen:  resq AS_DEF_MAX
pre_defpool:  resb AS_DEFPOOL
pre_defptop:  resq 1
pre_pathpool: resb AS_PATHPOOL
pre_pathtop:  resq 1
pre_lbuf:     resb AS_LBUF
pre_word:     resb 256
pre_tbuf:     resb AS_LBUF
pre_cdepth:   resq 1
pre_ccur:     resq AS_COND_MAX        ; bloco atual esta ativo (dentro do pai ativo)
pre_cpar:     resq AS_COND_MAX        ; bloco pai estava ativo
pre_cfirst:   resq AS_COND_MAX        ; ja houve um ramo ativo (para %else)
pre_cdef:     resq AS_COND_MAX        ; bloco adiado: a condicao e avaliada pelo montador
pre_dbuf:     resb AS_LBUF            ; linha de diretiva emitida (%if/%else/%endif/%error)
pre_mac_mode: resq 1                 ; 0 fora, 1 capturando corpo, 2 capturando e descartando
pre_mac_cur:  resq 1
pre_mac_n:    resq 1
pre_mac_hit:  resq 1
pre_mac_i:    resq 1
pre_mac_blen: resq AS_MAC_MAX
pre_mac_names: resb AS_MAC_MAX*32
pre_mac_bodies: resb AS_MAC_MAX*AS_MAC_BODY

section .data
align 8
pre_s_include: db "include", 0
pre_s_define:  db "define", 0
pre_s_ifdef:   db "ifdef", 0
pre_s_ifndef:  db "ifndef", 0
pre_s_if:      db "if", 0
pre_s_else:    db "else", 0
pre_s_endif:   db "endif", 0
pre_s_error:   db "error", 0
pre_e_depth:   db "%include aninhado demais", 0
pre_e_dir:     db "diretiva desconhecida", 0
pre_e_inc:     db "%include sem caminho entre aspas", 0
pre_e_if:      db "%if espera: numero OP numero", 0
pre_e_space:   db "tabela de defines cheia", 0
pre_e_exbuf:   db "codigo expandido grande demais", 0
pre_s_pref_if:    db "%if ", 0
pre_s_pref_else:  db "%else", 0
pre_s_pref_endif: db "%endif", 0
pre_s_pref_error: db "%error ", 0
pre_s_vazio:      db 0
pre_s_macro:      db "macro", 0
pre_s_endmacro:   db "endmacro", 0
pre_s_endm_txt:   db "%endmacro", 0
pre_e_macro:      db "tabela de macros cheia", 0

section .text

; ---------- pre_active: rax = 1 se o trecho atual esta ativo -------------------
pre_active:
    mov rax, [pre_cdepth]
    test rax, rax
    jz .sim
    dec rax
    lea rdx, [pre_ccur]
    cmp qword [rdx+rax*8], 0
    je .nao
    lea rdx, [pre_cpar]
    cmp qword [rdx+rax*8], 0
    je .nao
.sim:
    mov eax, 1
    ret
.nao:
    xor eax, eax
    ret

; ---------- pre_str_eq: rsi, rdi (zero-terminados) -> eax -----------------------
pre_str_eq:
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

; ---------- pre_dup: rsi = texto, rcx = tamanho -> rax = copia em defpool ----------
pre_dup:
    mov rax, [pre_defptop]
    lea rdi, [pre_defpool]
    add rdi, rax
    mov rdx, rdi                    ; inicio da copia
    add rax, rcx
    inc rax
    cmp rax, AS_DEFPOOL
    ja .cheio
    mov [pre_defptop], rax
    xor eax, eax
.c:
    cmp rax, rcx
    jae .fim
    mov r8b, [rsi+rax]
    mov [rdi+rax], r8b
    inc rax
    jmp .c
.fim:
    mov byte [rdi+rcx], 0
    mov rax, rdx
    ret
.cheio:
    lea rsi, [pre_e_space]
    jmp as_fail

; ---------- pre_find: rsi = nome zero-terminado -> rax = indice ou -1 -------------
pre_find:
    push rdi                        ; pre_find altera rdi; o chamador o usa
    xor ecx, ecx
.l:
    cmp rcx, [pre_ndef]
    jae .nao
    lea rdx, [pre_defname]
    mov rdi, [rdx+rcx*8]
    push rcx
    push rsi
    call pre_str_eq
    pop rsi
    pop rcx
    test eax, eax
    jnz .achou
    inc rcx
    jmp .l
.achou:
    mov rax, rcx
    pop rdi
    ret
.nao:
    mov rax, -1
    pop rdi
    ret

; ---------- pre_define: rsi = nome, rdi = valor, rdx = tamanho do valor ---------
pre_define:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rdi
    mov r14, rdx
    cmp qword [pre_ndef], AS_DEF_MAX
    jae .cheio
    mov rsi, r12
    call as_strlen
    mov rcx, rax
    mov rsi, r12
    call pre_dup
    mov rbx, rax                    ; copia do nome
    mov rsi, r13
    mov rcx, r14
    call pre_dup
    mov rdx, [pre_ndef]
    lea rcx, [pre_defname]
    mov [rcx+rdx*8], rbx
    lea rcx, [pre_defval]
    mov [rcx+rdx*8], rax
    lea rcx, [pre_defvlen]
    mov [rcx+rdx*8], r14
    inc qword [pre_ndef]
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.cheio:
    lea rsi, [pre_e_space]
    jmp as_fail

; ---------- pre_subst: rsi = origem, rcx = tamanho, rdi = destino, r8 = profundidade
; -> rdi = fim do texto escrito. Substitui %define por seu valor (recursivo).
pre_subst:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                    ; origem
    mov r13, rcx                    ; tamanho
    xor r14d, r14d                  ; i
    mov r15, r8                     ; profundidade
.loop:
    cmp r14, r13
    jae .fim
    movzx eax, byte [r12+r14]
    ; aspas: copia literalmente ate a aspa de fechamento
    cmp al, '"'
    je .aspas
    cmp al, 39                      ; '
    je .aspas
    ; numero: copia o token inteiro (ex.: 0x8664)
    cmp al, '0'
    jb .simples
    cmp al, '9'
    jbe .numero
    ; identificador: letra ou '_' (um '.' antes impede a substituicao)
    cmp al, '_'
    je .ident
    cmp al, 'A'
    jb .simples
    cmp al, 'Z'
    jbe .ident
    cmp al, 'a'
    jb .simples
    cmp al, 'z'
    jbe .ident
    jmp .simples
.numero:
    movzx eax, byte [r12+r14]
    mov byte [rdi], al
    inc rdi
    inc r14
    cmp r14, r13
    jae .loop
    movzx eax, byte [r12+r14]
    call pre_altnum
    test eax, eax
    jz .loop
    jmp .numero
.ident:
    ; tamanho do identificador
    mov rbx, r14
.id:
    cmp rbx, r13
    jae .idfim
    movzx eax, byte [r12+rbx]
    call pre_altnum
    test eax, eax
    jz .idfim
    inc rbx
    jmp .id
.idfim:
    ; precedido de '.'? (rotulo local): copia sem substituir
    test r14, r14
    jz .procura
    cmp byte [r12+r14-1], '.'
    je .copia_id
.procura:
    ; copia o identificador para o pool temporario (zero-terminado) e procura
    mov rcx, rbx
    sub rcx, r14
    cmp rcx, 255
    ja .copia_id
    lea rdx, [pre_word]
    lea r9, [r12+r14]
    xor eax, eax
.cp:
    cmp rax, rcx
    jae .cp_fim
    mov r8b, [r9+rax]
    mov [rdx+rax], r8b
    inc rax
    jmp .cp
.cp_fim:
    mov byte [rdx+rcx], 0
    mov rsi, rdx
    call pre_find
    cmp rax, -1
    je .copia_id
    cmp r15, AS_SUBST_DEPTH
    jae .copia_id
    ; expande o valor do define recursivamente
    lea rdx, [pre_defval]
    mov rsi, [rdx+rax*8]
    lea rdx, [pre_defvlen]
    mov rcx, [rdx+rax*8]
    lea r8, [r15+1]
    call pre_subst
    mov r14, rbx
    jmp .loop
.copia_id:
    ; copia o identificador sem substituir
.cid:
    cmp r14, rbx
    jae .loop
    movzx eax, byte [r12+r14]
    mov [rdi], al
    inc rdi
    inc r14
    jmp .cid
.aspas:
    ; copia de aspa a aspa (inclusive)
    mov bl, al
    mov byte [rdi], al
    inc rdi
    inc r14
.as:
    cmp r14, r13
    jae .loop
    movzx eax, byte [r12+r14]
    mov [rdi], al
    inc rdi
    inc r14
    cmp al, bl
    jne .as
    jmp .loop
.simples:
    movzx eax, byte [r12+r14]
    mov [rdi], al
    inc rdi
    inc r14
    jmp .loop
.fim:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; pre_altnum: eax = caractere -> eax = 1 se e letra, digito ou '_'
pre_altnum:
    cmp al, '_'
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

; ---------- pre_emit: rsi = texto, rcx = tamanho (com substituicao) -> exbuf -------
pre_emit:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rcx
    lea rbx, [as_exbuf]
    mov r14, [as_exlen]
    lea rdi, [rbx+r14]
    ; limite: texto expandido pode crescer; reserva 1 MB de folga por linha
    cmp r14, AS_EXBUF_SIZE - 1048576
    ja .grande
    mov rsi, r12
    mov rcx, r13
    xor r8d, r8d
    call pre_subst
    mov byte [rdi], 10
    inc rdi
    lea rax, [as_exbuf]
    sub rdi, rax
    mov [as_exlen], rdi
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.grande:
    lea rsi, [pre_e_exbuf]
    jmp as_fail

; ---------- pre_cond_push: rax = bloco inicial ativo (0/1) ---------------------------
pre_cond_push:
    push rax
    mov rcx, [pre_cdepth]
    cmp rcx, AS_COND_MAX
    jae .fim
    call pre_active                 ; pai ativo?
    lea rdx, [pre_cpar]
    mov rcx, [pre_cdepth]
    mov [rdx+rcx*8], rax
    pop rax
    push rax
    lea rdx, [pre_ccur]
    mov rcx, [pre_cdepth]
    mov [rdx+rcx*8], rax
    lea rdx, [pre_cfirst]
    mov qword [rdx+rcx*8], 0
    inc qword [pre_cdepth]
.fim:
    pop rax
    ret

; ---------- pre_emit_pref: rsi = prefixo, rdi = texto (zero-terminados) -> emite a linha ---
pre_emit_pref:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rdi
    lea rbx, [pre_dbuf]
.p1:
    mov al, [r12]
    test al, al
    jz .p2
    mov [rbx], al
    inc r12
    inc rbx
    jmp .p1
.p2:
    mov al, [r13]
    test al, al
    jz .p3
    mov [rbx], al
    inc r13
    inc rbx
    jmp .p2
.p3:
    mov byte [rbx], 0
    lea rsi, [pre_dbuf]
    mov rcx, rbx
    sub rcx, rsi
    call pre_emit
    pop r13
    pop r12
    pop rbx
    ret

; ---------- pre_mac_find: rsi = texto (zero-terminado) -> rax = indice da macro ou -1 -----
pre_mac_find:
    mov qword [pre_mac_i], 0
.l:
    mov rax, [pre_mac_i]
    cmp rax, [pre_mac_n]
    jae .nao
    lea rdi, [pre_mac_names]
    shl rax, 5
    add rdi, rax
    call pre_str_eq                 ; rsi = texto, rdi = nome
    test eax, eax
    jnz .sim
    inc qword [pre_mac_i]
    jmp .l
.sim:
    mov rax, [pre_mac_i]
    ret
.nao:
    mov rax, -1
    ret

; ---------- pre_mac_captura: rsi = linha (trecho util), rcx = tamanho ---------------------
; Dentro de %macro: fecha em %endmacro; senao guarda a linha no corpo (modo 1) ou descarta (2).
pre_mac_captura:
    cmp rcx, 9
    jb .nao_fim
    cmp byte [rsi], '%'
    jne .nao_fim
    lea rdi, [pre_s_endm_txt]
    xor edx, edx
.cmp:
    cmp edx, 9
    je .fecha
    mov al, [rsi+rdx]
    cmp al, [rdi+rdx]
    jne .nao_fim
    inc edx
    jmp .cmp
.fecha:
    mov qword [pre_mac_mode], 0
    ret
.nao_fim:
    cmp qword [pre_mac_mode], 1
    jne .fim
    mov r8, [pre_mac_cur]
    lea r9, [pre_mac_blen]
    mov rdi, [r9+r8*8]              ; deslocamento atual no corpo
    mov r10, r8
    shl r10, 12
    lea r11, [pre_mac_bodies]
    add r11, r10                    ; inicio do corpo desta macro
    test rdi, rdi
    jz .copia
    cmp rdi, AS_MAC_BODY-2
    jae .fim
    mov byte [r11+rdi], 10
    inc rdi
.copia:
    xor edx, edx
.cp:
    cmp rdx, rcx
    jae .cp_fim
    cmp rdi, AS_MAC_BODY-1
    jae .cp_fim
    mov al, [rsi+rdx]
    mov [r11+rdi], al
    inc rdi
    inc rdx
    jmp .cp
.cp_fim:
    mov [r9+r8*8], rdi
.fim:
    ret

; ---------- pre_def_ativo: eax = 1 se algum bloco aberto e adiado (montador decide) -------
pre_def_ativo:
    xor eax, eax
    mov rcx, [pre_cdepth]
    lea rdx, [pre_cdef]
.l:
    test rcx, rcx
    jz .f
    dec rcx
    cmp qword [rdx+rcx*8], 0
    je .l
    mov eax, 1
.f:
    ret

; ---------- pre_skip_ws: rsi = ponteiro (pode avancar) -----------------------------
pre_skip_ws:
    cmp byte [rsi], ' '
    je .a
    cmp byte [rsi], 9
    jne .fim
.a:
    inc rsi
    jmp pre_skip_ws
.fim:
    ret

; ---------- pre_word_copy: rsi = inicio, copia a palavra para pre_word; rsi avanca --
pre_word_copy:
    lea rdi, [pre_word]
    xor ecx, ecx
.c:
    mov al, [rsi]
    test al, al
    jz .f
    cmp al, ' '
    je .f
    cmp al, 9
    je .f
    cmp ecx, 254
    jae .f
    mov [rdi+rcx], al
    inc rcx
    inc rsi
    jmp .c
.f:
    mov byte [rdi+rcx], 0
    ret

; ---------- pre_line: rsi = linha (sem \n), rcx = tamanho ---------------------------
pre_line:
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; copia sem comentario ';' (fora de aspas) para pre_lbuf
    lea rdi, [pre_lbuf]
    xor r8d, r8d                    ; dentro de aspas?
    xor r9d, r9d                    ; origem
    xor r10d, r10d                  ; destino
.cm:
    cmp r9, rcx
    jae .cm_fim
    mov al, [rsi+r9]
    test r8b, r8b
    jnz .cm_dentro
    ; fora de aspas: ';' comenta o resto; aspa abre string
    cmp al, ';'
    je .cm_fim
    cmp al, '"'
    je .cm_abre
    cmp al, 39
    je .cm_abre
    jmp .cm_copia
.cm_abre:
    mov r8b, al                     ; aspa de abertura (estado)
    jmp .cm_copia
.cm_dentro:
    cmp al, r8b                     ; aspa de fechamento sai do estado
    jne .cm_copia
    xor r8d, r8d
.cm_copia:
    cmp r10, AS_LBUF-2
    jae .cm_fim
    mov [rdi+r10], al
    inc r10
    inc r9
    jmp .cm
.cm_fim:
    ; apara o fim (espacos e CR)
.apara:
    test r10, r10
    jz .vazia
    mov al, [rdi+r10-1]
    cmp al, 13
    je .corta
    cmp al, ' '
    je .corta
    cmp al, 9
    je .corta
    jmp .inicio
.corta:
    dec r10
    jmp .apara
.inicio:
    mov byte [rdi+r10], 0
    lea rsi, [pre_lbuf]
    call pre_skip_ws
    mov r12, rsi                    ; inicio do texto util
    cmp byte [r12], 0
    je .vazia
    cmp qword [pre_mac_mode], 0
    je .sem_captura
    lea rcx, [pre_lbuf]
    add rcx, r10
    sub rcx, r12
    mov rsi, r12
    call pre_mac_captura
    jmp .vazia
.sem_captura:
    cmp byte [r12], '%'
    je .diretiva
    ; macro sem parametros: a linha inteira e o nome -> emite o corpo
    mov rsi, r12
    call pre_mac_find
    cmp rax, -1
    je .comum
    mov [pre_mac_hit], rax
    call pre_active
    test eax, eax
    jz .vazia
    mov rax, [pre_mac_hit]
    lea rdx, [pre_mac_blen]
    mov rcx, [rdx+rax*8]
    mov rdx, rax
    shl rdx, 12
    lea rsi, [pre_mac_bodies]
    add rsi, rdx
    call pre_emit
    jmp .vazia
.comum:
    ; linha de codigo comum: emite o trecho util (inicio em r12, fim em r10)
    call pre_active
    test eax, eax
    jz .vazia
    lea rax, [pre_lbuf]
    add rax, r10
    mov rcx, rax
    sub rcx, r12
    mov rsi, r12
    call pre_emit
    jmp .vazia
.vazia:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.diretiva:
    lea rsi, [r12+1]
    call pre_word_copy              ; pre_word = nome da diretiva
    lea rsi, [r12+1]
    ; localiza o fim da palavra e pula espacos para os argumentos
.ap:
    mov al, [rsi]
    test al, al
    jz .arg
    cmp al, ' '
    je .arg
    cmp al, 9
    je .arg
    inc rsi
    jmp .ap
.arg:
    call pre_skip_ws
    mov r13, rsi                    ; argumentos
    lea rdi, [pre_word]
    lea rsi, [pre_s_include]
    call pre_str_eq
    test eax, eax
    jnz .d_include
    lea rdi, [pre_word]
    lea rsi, [pre_s_define]
    call pre_str_eq
    test eax, eax
    jnz .d_define
    lea rdi, [pre_word]
    lea rsi, [pre_s_ifdef]
    call pre_str_eq
    test eax, eax
    jnz .d_ifdef
    lea rdi, [pre_word]
    lea rsi, [pre_s_ifndef]
    call pre_str_eq
    test eax, eax
    jnz .d_ifndef
    lea rdi, [pre_word]
    lea rsi, [pre_s_macro]
    call pre_str_eq
    test eax, eax
    jnz .d_macro
    lea rdi, [pre_word]
    lea rsi, [pre_s_endmacro]
    call pre_str_eq
    test eax, eax
    jnz .d_endmacro
    lea rdi, [pre_word]
    lea rsi, [pre_s_if]
    call pre_str_eq
    test eax, eax
    jnz .d_if
    lea rdi, [pre_word]
    lea rsi, [pre_s_else]
    call pre_str_eq
    test eax, eax
    jnz .d_else
    lea rdi, [pre_word]
    lea rsi, [pre_s_endif]
    call pre_str_eq
    test eax, eax
    jnz .d_endif
    lea rdi, [pre_word]
    lea rsi, [pre_s_error]
    call pre_str_eq
    test eax, eax
    jnz .d_error
    lea rsi, [pre_e_dir]
    jmp as_fail

.d_include:
    call pre_active
    test eax, eax
    jz .vazia
    mov rsi, r13
    cmp byte [rsi], '"'
    jne .inc_erro
    inc rsi
    lea rdi, [pre_word]
    xor ecx, ecx
.ic:
    mov al, [rsi]
    test al, al
    jz .inc_erro
    cmp al, '"'
    je .ic_fim
    cmp ecx, 254
    jae .inc_erro
    mov [rdi+rcx], al
    inc rcx
    inc rsi
    jmp .ic
.ic_fim:
    mov byte [rdi+rcx], 0
    ; copia o caminho para o pool (cada chamada usa o seu)
    mov rsi, rdi
    mov rax, [pre_pathtop]
    lea rdi, [pre_pathpool]
    add rdi, rax
    mov r14, rdi
    xor eax, eax
.pc:
    mov dl, [rsi+rax]
    mov [rdi+rax], dl
    test dl, dl
    jz .pc_fim
    inc rax
    jmp .pc
.pc_fim:
    add [pre_pathtop], rax
    inc qword [pre_pathtop]
    inc qword [pre_level]
    cmp qword [pre_level], AS_FBUF_LEVELS
    ja .inc_fundo
    mov rsi, r14
    call pre_file
    dec qword [pre_level]
    jmp .vazia
.inc_fundo:
    lea rsi, [pre_e_depth]
    jmp as_fail
.inc_erro:
    lea rsi, [pre_e_inc]
    jmp as_fail

.d_define:
    call pre_active
    test eax, eax
    jz .vazia
    ; nome do define: palavra logo apos %define
    mov rsi, r13
    lea rdi, [pre_word]
    xor ecx, ecx
.dn:
    mov al, [rsi]
    test al, al
    jz .dn_fim
    cmp al, ' '
    je .dn_fim
    cmp al, 9
    je .dn_fim
    mov [rdi+rcx], al
    inc rcx
    inc rsi
    jmp .dn
.dn_fim:
    mov byte [rdi+rcx], 0
    call pre_skip_ws                ; rsi = inicio do valor
    mov r14, rsi
    mov rsi, r14
    call as_strlen                  ; rax = tamanho do valor
    mov rdx, rax
    lea rsi, [pre_word]
    mov rdi, r14
    call pre_define                 ; pre_define(nome, valor, tamanho)
    jmp .vazia
.d_ifdef:
    call pre_active
    push rax
    mov rsi, r13
    lea rdi, [pre_word]
    call pre_word_copy
    lea rsi, [pre_word]
    call pre_find
    cmp rax, -1
    setne al
    movzx eax, al
    pop rdx
    test rdx, rdx
    jz .ifdef_pai_off
    jmp .ifdef_fim
.ifdef_pai_off:
    xor eax, eax
.ifdef_fim:
    call pre_cond_push
    jmp .vazia
.d_ifndef:
    call pre_active
    push rax
    mov rsi, r13
    lea rdi, [pre_word]
    call pre_word_copy
    lea rsi, [pre_word]
    call pre_find
    cmp rax, -1
    sete al
    movzx eax, al
    pop rdx
    test rdx, rdx
    jz .ifndef_pai_off
    jmp .ifndef_fim
.ifndef_pai_off:
    xor eax, eax
.ifndef_fim:
    call pre_cond_push
    jmp .vazia
.d_if:
    call pre_active
    push rax
    mov rsi, r13
    call pre_eval_cond
    pop rdx
    cmp eax, 2
    je .if_adiado
    test rdx, rdx
    jz .if_off
    jmp .if_fim
.if_off:
    xor eax, eax
.if_fim:
    call pre_cond_push
    jmp .vazia
.if_adiado:
    ; condicao com simbolo: o montador avalia. Os dois ramos ficam ativos aqui
    ; (o pre-processador emite as diretivas), mas so se o pai estiver ativo.
    push rdx
    test rdx, rdx
    jz .if_adiado_off
    lea rsi, [pre_s_pref_if]
    lea rdi, [pre_tbuf]
    call pre_emit_pref
    mov eax, 1
    jmp .if_adiado_push
.if_adiado_off:
    xor eax, eax
.if_adiado_push:
    call pre_cond_push
    pop rdx
    mov rcx, [pre_cdepth]
    dec rcx
    lea rax, [pre_cdef]
    mov [rax+rcx*8], rdx
    jmp .vazia
.d_else:
    mov rax, [pre_cdepth]
    test rax, rax
    jz .vazia
    dec rax
    lea rdx, [pre_cdef]
    cmp qword [rdx+rax*8], 0
    je .else_normal
    lea rsi, [pre_s_pref_else]
    lea rdi, [pre_s_vazio]
    call pre_emit_pref
    jmp .vazia
.else_normal:
    lea rdx, [pre_ccur]
    xor qword [rdx+rax*8], 1
    jmp .vazia
.d_endif:
    mov rax, [pre_cdepth]
    test rax, rax
    jz .vazia
    dec rax
    lea rdx, [pre_cdef]
    cmp qword [rdx+rax*8], 0
    je .endif_normal
    lea rsi, [pre_s_pref_endif]
    lea rdi, [pre_s_vazio]
    call pre_emit_pref
.endif_normal:
    dec qword [pre_cdepth]
    jmp .vazia
.d_error:
    call pre_active
    test eax, eax
    jz .vazia
    call pre_def_ativo
    test eax, eax
    jz .erro_pre
    lea rsi, [pre_s_pref_error]
    mov rdi, r13
    call pre_emit_pref
    jmp .vazia
.erro_pre:
    mov rsi, r13
    jmp as_fail
.d_macro:
    call pre_active
    test eax, eax
    jz .macro_descarta
    mov rax, [pre_mac_n]
    cmp rax, AS_MAC_MAX
    jae .erro_macro
    mov [pre_mac_cur], rax
    shl rax, 5
    lea rdi, [pre_mac_names]
    add rdi, rax
    mov rsi, r13
    xor ecx, ecx
.nome:
    mov al, [rsi]
    test al, al
    jz .nome_fim
    cmp al, ' '
    je .nome_fim
    cmp al, 9
    je .nome_fim
    cmp ecx, 30
    jae .nome_fim
    mov [rdi+rcx], al
    inc rsi
    inc rcx
    jmp .nome
.nome_fim:
    mov byte [rdi+rcx], 0
    mov rax, [pre_mac_cur]
    lea rdx, [pre_mac_blen]
    mov qword [rdx+rax*8], 0
    inc qword [pre_mac_n]
    mov qword [pre_mac_mode], 1
    jmp .vazia
.macro_descarta:
    mov qword [pre_mac_mode], 2
    jmp .vazia
.d_endmacro:
    jmp .vazia
.erro_macro:
    lea rsi, [pre_e_macro]
    jmp as_fail

; ---------- pre_file: rsi = caminho (zero-terminado) ----------------------------------
pre_file:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rsi                    ; caminho
    mov rdi, r15
    lea rsi, [as_fbuf]
    mov rax, [pre_level]
    imul rax, rax, AS_FBUF_SIZE
    add rsi, rax
    mov r12, rsi                    ; buffer deste nivel
    call as_read_file
    cmp rax, -1
    je .abre_erro
    mov r13, rax                    ; comprimento
    mov byte [r12+r13], 0
    xor r14d, r14d                  ; inicio da linha
.l:
    cmp r14, r13
    jae .fim
    mov rbx, r14                    ; fim da linha
.f:
    cmp rbx, r13
    jae .f_fim
    cmp byte [r12+rbx], 10
    je .f_fim
    inc rbx
    jmp .f
.f_fim:
    lea rsi, [r12+r14]
    mov rcx, rbx
    sub rcx, r14
    ; retira o CR final
    test rcx, rcx
    jz .semcr
    cmp byte [rsi+rcx-1], 13
    jne .semcr
    dec rcx
.semcr:
    push rbx
    call pre_line
    pop rbx
    lea r14, [rbx+1]
    jmp .l
.fim:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.abre_erro:
    lea rsi, [as_s_open]
    call as_say
    mov rsi, r15
    call as_say
    lea rsi, [as_s_nl]
    call as_say
    mov ecx, 1
    call [__imp_ExitProcess]

; ---------- pre_eval_cond: rsi = "A OP B" -> rax = 0/1 ----------------------------------
; Substitui os defines e compara dois numeros decimais.
pre_eval_cond:
    push rbx
    push r12
    push r13
    push r14
    push r15
    ; substitui defines em pre_tbuf
    mov r12, rsi
    mov rcx, 0
.len:
    cmp byte [r12+rcx], 0
    je .lend
    inc rcx
    jmp .len
.lend:
    lea rdi, [pre_tbuf]
    xor r8d, r8d
    mov rsi, r12
    call pre_subst
    mov byte [rdi], 0
    lea r12, [pre_tbuf]
    mov rsi, r12                    ; primeiro numero
    cmp byte [rsi], '-'
    je .lhs_ok
    cmp byte [rsi], '0'
    jb .adiado
    cmp byte [rsi], '9'
    ja .adiado
.lhs_ok:
    call pre_num                    ; rax = valor, rsi avancado
    mov r13, rax
    call pre_skip_ws
    ; operador
    xor r14d, r14d                  ; 0 '<' 1 '<=' 2 '>' 3 '>=' 4 '=' 5 '!='
    mov al, [rsi]
    cmp al, '<'
    jne .o2
    inc rsi
    cmp byte [rsi], '='
    jne .lt
    inc rsi
    mov r14d, 1
    jmp .opok
.lt:
    xor r14d, r14d
    jmp .opok
.o2:
    cmp al, '>'
    jne .o3
    inc rsi
    cmp byte [rsi], '='
    jne .gt
    inc rsi
    mov r14d, 3
    jmp .opok
.gt:
    mov r14d, 2
    jmp .opok
.o3:
    cmp al, '='
    jne .o4
    inc rsi
    mov r14d, 4
    jmp .opok
.o4:
    cmp al, '!'
    jne .erro
    inc rsi
    cmp byte [rsi], '='
    jne .erro
    inc rsi
    mov r14d, 5
.opok:
    call pre_skip_ws
    cmp byte [rsi], '-'
    je .rhs_ok
    cmp byte [rsi], '0'
    jb .adiado
    cmp byte [rsi], '9'
    ja .adiado
.rhs_ok:
    call pre_num
    mov r15, rax
    xor eax, eax
    cmp r14d, 0
    je .c0
    cmp r14d, 1
    je .c1
    cmp r14d, 2
    je .c2
    cmp r14d, 3
    je .c3
    cmp r14d, 4
    je .c4
    cmp r14d, 5
    je .c5
.c0: cmp r13, r15
     jl .one
     jmp .zero
.c1: cmp r13, r15
     jle .one
     jmp .zero
.c2: cmp r13, r15
     jg .one
     jmp .zero
.c3: cmp r13, r15
     jge .one
     jmp .zero
.c4: cmp r13, r15
     je .one
     jmp .zero
.c5: cmp r13, r15
     jne .one
     jmp .zero
.one:
    mov eax, 1
    jmp .fim
.zero:
    xor eax, eax
    jmp .fim
.erro:
    lea rsi, [pre_e_if]
    jmp as_fail
.adiado:
    mov eax, 2                      ; simbolo na condicao: o montador avalia (ver as_cond_line)
.fim:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; pre_num: rsi = texto -> rax = numero decimal (com sinal), rsi avanca
pre_num:
    xor eax, eax
    xor ecx, ecx                    ; sinal
    cmp byte [rsi], '-'
    jne .d
    mov ecx, 1
    inc rsi
.d:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .fim
    imul rax, rax, 10
    add rax, rdx
    inc rsi
    jmp .d
.fim:
    test ecx, ecx
    jz .pos
    neg rax
.pos:
    ret

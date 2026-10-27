; ============ ASM: escritor COFF x64 (objeto para o pelink) ============
; Layout: cabecalho (20), 3 cabecalhos de secao (40 cada), dados .text, .data,
; relocacoes por secao, tabela de simbolos (18 bytes por registro), tabela de nomes.
; Simbolos: 0..2 = secoes (.text, .data, .bss); depois externos e rotulos globais.
; Referencias de relocacao a secao usam o indice da secao (bit 31 marcado).

section .bss
alignb 16
co_p:           resq 1                  ; ponteiro de escrita em as_outbuf
co_base:        resq 1
co_strtop:      resq 1                  ; tamanho corrente da tabela de nomes
co_nsyms:       resq 1                  ; registros de simbolo emitidos
co_rawoff:      resq 4                  ; deslocamento dos dados brutos por secao
co_relptr:      resq 4                  ; deslocamento das relocacoes por secao
co_symptr:      resq 1
co_strptr:      resq 1

section .data
align 8
co_s_text:      db ".text", 0
co_s_data:      db ".data", 0
co_s_bss:       db ".bss", 0
co_e_relocs:   db "secao com realocacoes demais (65534 e o limite do formato COFF)", 0

section .text

; ---------- co_put8/16/32/64: rax = valor -> escreve em co_p ---------------------------
co_put8:
    mov rdi, [co_p]
    mov [rdi], al
    inc qword [co_p]
    ret
co_put16:
    mov rdi, [co_p]
    mov [rdi], ax
    add qword [co_p], 2
    ret
co_put32:
    mov rdi, [co_p]
    mov [rdi], eax
    add qword [co_p], 4
    ret
co_put64:
    mov rdi, [co_p]
    mov [rdi], rax
    add qword [co_p], 8
    ret

; ---------- co_putn: rsi = bytes, rcx = quantidade -> escreve --------------------------
co_putn:
    mov rdi, [co_p]
    xor edx, edx
.l:
    cmp rdx, rcx
    jae .f
    mov al, [rsi+rdx]
    mov [rdi+rdx], al
    inc rdx
    jmp .l
.f:
    add [co_p], rcx
    ret

; ---------- co_name8: rsi = nome zero-terminado ----------------------------------------
; Escreve 8 bytes do nome se couber; senao 4 zeros + offset na tabela de nomes.
co_name8:
    push rbx
    mov rbx, rsi
    xor ecx, ecx
.len:
    cmp byte [rbx+rcx], 0
    je .lenf
    inc rcx
    jmp .len
.lenf:
    cmp rcx, 8
    ja .longo
    ; cabe em 8 bytes (preenche com zeros)
    mov rdi, [co_p]
    xor edx, edx
.cp:
    cmp rdx, 8
    jae .cpf
    cmp rdx, rcx
    jae .zero
    mov al, [rbx+rdx]
    mov [rdi+rdx], al
    jmp .prox
.zero:
    mov byte [rdi+rdx], 0
.prox:
    inc rdx
    jmp .cp
.cpf:
    add qword [co_p], 8
    pop rbx
    ret
.longo:
    ; zeros + offset na tabela de nomes (tabela comeca em 4, apos o tamanho)
    xor eax, eax
    call co_put32
    mov eax, [co_strtop]
    call co_put32
    ; copia o nome para a tabela de nomes (co_strptr)
    mov rdi, [co_strptr]
    add rdi, [co_strtop]
    xor edx, edx
.cn:
    cmp rdx, rcx
    jae .cnf
    mov al, [rbx+rdx]
    mov [rdi+rdx], al
    inc rdx
    jmp .cn
.cnf:
    mov byte [rdi+rdx], 0
    lea rax, [rcx+1]
    add [co_strtop], rax
    pop rbx
    ret

; ---------- co_secname: rdi = nome em co_s_* (8 bytes escritos) ----------------------------
co_sec8:
    mov rdi, [co_p]
    mov rax, [rsi]                  ; rsi aponta para 8 bytes ja prontos
    mov [rdi], rax
    add qword [co_p], 8
    ret

; ---------- as_write_coff: monta o objeto em as_outbuf e grava em as_outpath -----------
as_write_coff:
    AS_ENTER
    lea rax, [as_outbuf]
    mov [co_base], rax
    ; tabela de nomes comeca em co_strptr + 0 (tamanho em 4 bytes na frente)
    lea rax, [as_outbuf]
    add rax, AS_OUT_SIZE/2          ; metade final do buffer: tabela de nomes
    mov [co_strptr], rax
    mov qword [co_strtop], 4
    call co_assign
    ; 2) secoes: deslocamentos dos dados e das relocacoes
    mov rax, 20 + 40*3
    mov [co_rawoff+8], rax          ; .text
    mov rcx, [as_off+8]
    add rax, rcx
    mov [co_rawoff+16], rax         ; .data
    mov rcx, [as_off+16]
    add rax, rcx
    mov [co_relptr+8], rax          ; relocacoes de .text
    mov rcx, [as_rel_n]
    imul rcx, rcx, 10
    add rax, rcx
    mov [co_relptr+16], rax         ; relocacoes de .data
    mov rcx, [as_rel_n+8]
    imul rcx, rcx, 10
    add rax, rcx
    mov [co_symptr], rax
    ; 3) escreve o cabecalho do arquivo
    lea rax, [as_outbuf]
    mov [co_p], rax
    mov eax, 0x8664
    call co_put16                   ; Machine
    mov eax, 3
    call co_put16                   ; NumberOfSections
    xor eax, eax
    call co_put32                   ; TimeDateStamp
    mov rax, [co_symptr]
    call co_put32                   ; PointerToSymbolTable
    mov rax, [co_nsyms]
    add rax, 3
    call co_put32                   ; NumberOfSymbols (3 secoes + externos/globais)
    xor eax, eax
    call co_put16                   ; SizeOfOptionalHeader
    xor eax, eax
    call co_put16                   ; Characteristics
    ; 4) cabecalhos das secoes
    lea rsi, [co_s_text]
    mov edx, 1
    mov rcx, [as_off+8]
    mov r8, [co_rawoff+8]
    mov r9, [co_relptr+8]
    mov r10, [as_rel_n]
    mov r11d, 0x60500020
    call co_sechdr
    lea rsi, [co_s_data]
    mov edx, 2
    mov rcx, [as_off+16]
    mov r8, [co_rawoff+16]
    mov r9, [co_relptr+16]
    mov r10, [as_rel_n+8]
    mov r11d, 0xC0500040
    call co_sechdr
    lea rsi, [co_s_bss]
    mov edx, 3
    mov rcx, [as_off+24]
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    mov r11d, 0xC0500080
    call co_sechdr
    ; 5) dados brutos
    lea rsi, [as_secbuf]
    mov rcx, [as_off+8]
    mov rdx, [co_rawoff+8]
    call co_rawcopy
    lea rsi, [as_secbuf+AS_SEC_SIZE]
    mov rcx, [as_off+16]
    mov rdx, [co_rawoff+16]
    call co_rawcopy
    ; 6) relocacoes
    mov rcx, [as_rel_n]
    lea rsi, [as_rel]
    mov rdx, [co_relptr+8]
    call co_relcopy
    mov rcx, [as_rel_n+8]
    lea rsi, [as_rel+AS_MAXREL*16]
    mov rdx, [co_relptr+16]
    call co_relcopy
    ; 7) tabela de simbolos
    mov rax, [co_symptr]
    lea rdi, [as_outbuf]
    add rdi, rax
    mov [co_p], rdi
    call co_symbols
    ; 8) tabela de nomes: tamanho total (4 bytes) e nomes, logo depois dos simbolos
    mov rdi, [co_strptr]
    mov eax, [co_strtop]
    mov [rdi], eax
    mov rsi, [co_strptr]
    mov rcx, [co_strtop]
    mov rdi, [co_p]
    xor edx, edx
.cs:
    cmp rdx, rcx
    jae .csf
    mov al, [rsi+rdx]
    mov [rdi+rdx], al
    inc rdx
    jmp .cs
.csf:
    add rdi, rcx
    mov [co_p], rdi    ; 9) grava o arquivo
    lea rdi, [as_outpath]
    lea rsi, [as_outbuf]
    mov rdx, [co_p]
    sub rdx, rsi
    call as_write_file
    test eax, eax
    jnz .ok
    lea rsi, [as_e_wr]
    call as_say
    mov ecx, 1
    call [__imp_ExitProcess]
.ok:
    AS_LEAVE
    ret

; ---------- co_assign: numera simbolos externos e globais (kind 3 ou glob de rotulos) --
co_assign:
    mov qword [co_nsyms], 0
    mov qword [as_tmp], 0
.l:
    mov rcx, [as_tmp]
    cmp rcx, [as_nsym]
    jae .f
    lea rdx, [as_sym_kind]
    mov rax, [rdx+rcx*8]
    cmp rax, 3
    je .conta
    cmp rax, 1
    jne .prox
    lea rdx, [as_sym_glob]
    cmp qword [rdx+rcx*8], 0
    je .prox
.conta:
    lea rdx, [as_sym_coff]
    mov rax, [co_nsyms]
    add rax, 3
    mov [rdx+rcx*8], rax
    inc qword [co_nsyms]
.prox:
    inc qword [as_tmp]
    jmp .l
.f:
    ret

; ---------- co_sechdr: rsi = nome, edx = indice (nao usado), rcx = tamanho bruto,
; r8 = ponteiro bruto, r9 = relocacoes, r10 = contagem, r11d = caracteristicas ---------
co_sechdr:
    push rbx
    push r12
    mov rbx, rcx
    mov r12, r10
    cmp r12, 0xFFFE                 ; o campo COFF tem 16 bits: mais que isso truncaria
    jbe .relocs_ok
    lea rsi, [co_e_relocs]
    jmp as_fail_plain
.relocs_ok:
    mov rdi, [co_p]
    ; nome de 8 bytes
    xor ecx, ecx
.nm:
    cmp ecx, 8
    jae .nmf
    mov al, [rsi+rcx]
    mov [rdi+rcx], al
    test al, al
    jz .nmz
    inc rcx
    jmp .nm
.nmz:
    inc rcx
.nmz2:
    cmp ecx, 8
    jae .nmf
    mov byte [rdi+rcx], 0
    inc rcx
    jmp .nmz2
.nmf:
    add qword [co_p], 8             ; os bytes do nome foram escritos direto em co_p
    mov rax, rbx
    test r11d, 0x80                 ; CNT_UNINITIALIZED_DATA: so .bss leva VirtualSize
    jnz .vsz_bss
    xor eax, eax
.vsz_bss:
    call co_put32                   ; VirtualSize (0; em .bss, o tamanho)
    xor eax, eax
    call co_put32                   ; VirtualAddress
    mov rax, rbx
    call co_put32                   ; SizeOfRawData
    mov rax, r8
    call co_put32                   ; PointerToRawData (0 em .bss)
    mov rax, r9
    call co_put32                   ; PointerToRelocations
    xor eax, eax
    call co_put32                   ; PointerToLinenumbers
    mov rax, r12
    call co_put16                   ; NumberOfRelocations
    xor eax, eax
    call co_put16                   ; NumberOfLinenumbers
    mov eax, r11d
    call co_put32                   ; Characteristics
    pop r12
    pop rbx
    ret

; ---------- co_rawcopy: rsi = origem, rcx = tamanho, rdx = deslocamento no arquivo -------
co_rawcopy:
    test rcx, rcx
    jz .f
    lea rdi, [as_outbuf]
    add rdi, rdx
    xor r8d, r8d
.l:
    cmp r8, rcx
    jae .f
    mov al, [rsi+r8]
    mov [rdi+r8], al
    inc r8
    jmp .l
.f:
    ret

; ---------- co_relcopy: rsi = registros da secao, rcx = quantidade, rdx = deslocamento ----
co_relcopy:
    test rcx, rcx
    jz .f
    lea rdi, [as_outbuf]
    add rdi, rdx
    xor r8d, r8d                    ; registro
.r:
    cmp r8, rcx
    jae .f
    mov eax, r8d
    imul rax, rax, 16
    mov r9d, [rsi+rax]              ; va
    mov [rdi], r9d
    mov r9d, [rsi+rax+4]            ; indice (bit 31 = secao)
    test r9d, r9d
    js .secao
    ; simbolo: indice COFF
    push rcx
    push rsi
    mov r10, r9
    lea rdx, [as_sym_coff]
    mov r9, [rdx+r10*8]
    pop rsi
    pop rcx
    jmp .grava_sym
.secao:
    and r9d, 0x7FFFFFFF             ; indice da secao = indice COFF da secao
.grava_sym:
    mov [rdi+4], r9d
    movzx r10d, word [rsi+rax+8]
    mov [rdi+8], r10w
    add rdi, 10
    inc r8
    jmp .r
.f:
    ret

; ---------- co_symbols: escreve os registros das secoes e dos simbolos exportados -------
co_symbols:
    push rbx
    ; secoes: .text, .data, .bss (valor 0, secao 1..3, classe STATIC)
    mov edx, 1
.sec:
    cmp edx, 3
    ja .simb
    lea rsi, [co_s_text]
    cmp edx, 2
    jne .n1
    lea rsi, [co_s_data]
    jmp .nome_sec
.n1:
    cmp edx, 3
    jne .nome_sec
    lea rsi, [co_s_bss]
.nome_sec:
    push rdx
    call co_name8
    pop rdx
    xor eax, eax
    call co_put32                   ; valor
    mov eax, edx
    call co_put16                   ; secao
    xor eax, eax
    call co_put16                   ; tipo
    mov al, 3
    call co_put8                    ; classe STATIC
    xor eax, eax
    call co_put8                    ; registros auxiliares
    inc edx
    jmp .sec
.simb:
    xor ecx, ecx
    mov [as_tmp], rcx
.l:
    mov rcx, [as_tmp]
    cmp rcx, [as_nsym]
    jae .fim
    lea rdx, [as_sym_kind]
    mov rax, [rdx+rcx*8]
    cmp rax, 3
    je .emite_ext
    cmp rax, 1
    jne .prox
    lea rdx, [as_sym_glob]
    cmp qword [rdx+rcx*8], 0
    je .prox
    ; rotulo global definido: valor e secao
    lea rsi, [as_nmbuf]
    call co_copia_nome
    lea rsi, [as_nmbuf]
    call co_name8
    mov rcx, [as_tmp]
    lea rdx, [as_sym_val]
    mov rax, [rdx+rcx*8]
    call co_put32
    lea rdx, [as_sym_sec]
    mov rax, [rdx+rcx*8]
    call co_put16
    xor eax, eax
    call co_put16
    mov al, 2
    call co_put8                    ; classe EXTERNAL
    xor eax, eax
    call co_put8
    jmp .prox
.emite_ext:
    lea rsi, [as_nmbuf]
    call co_copia_nome
    lea rsi, [as_nmbuf]
    call co_name8
    xor eax, eax
    call co_put32                   ; valor
    xor eax, eax
    call co_put16                   ; secao 0 (indefinida)
    xor eax, eax
    call co_put16
    mov al, 2
    call co_put8                    ; classe EXTERNAL
    xor eax, eax
    call co_put8
.prox:
    inc qword [as_tmp]
    jmp .l
.fim:
    pop rbx
    ret

; co_copia_nome: copia o nome do simbolo as_tmp para as_nmbuf (zero-terminado)
co_copia_nome:
    mov rcx, [as_tmp]
    lea rdx, [as_sym_name]
    mov rsi, [rdx+rcx*8]
    lea rdx, [as_sym_len]
    mov rcx, [rdx+rcx*8]
    cmp rcx, 1023                   ; as_nmbuf tem 1024 bytes (o resto do montador usa)
    jbe .tam_ok
    mov rcx, 1023                   ; corta em vez de transbordar para as_mn
.tam_ok:
    lea rdi, [as_nmbuf]
    xor edx, edx
.c:
    cmp rdx, rcx
    jae .f
    mov al, [rsi+rdx]
    mov [rdi+rdx], al
    inc rdx
    jmp .c
.f:
    mov byte [rdi+rdx], 0
    ret

section .data
align 8
as_e_wr:        db "asm: nao foi possivel gravar o objeto", 13, 10, 0

section .data

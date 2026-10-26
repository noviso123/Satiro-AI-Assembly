; ============ PELINK: linker PE32+ x64 em assembly ============
; Uso:  pelink <entrada.obj> <saida.exe>
; Entrada: UM objeto COFF x64 gerado pelo NASM (secoes .text, .data, .bss).
; Saida: executavel de console, base fixa 0x140000000, importando somente
; KERNEL32.dll. Cada externo "__imp_<nome>" vira uma entrada da IAT.
; Relocacoes: ADDR64, ADDR32NB e REL32 (REL32_1..REL32_5). Ponto de entrada:
; simbolo "main". Caminhos sem espacos. Sem CRT, sem bibliotecas.
; Codigos de saida: 0 ok, 1 erro de entrada/objeto, 2 uso incorreto.
; Bootstrap (uma vez; depois o proprio pelink liga tudo):
;   build\asm.exe tools\pelink.asm build\pelink.obj
;   link /nologo /subsystem:console /entry:main /nodefaultlib /out:build\pelink.exe build\pelink.obj kernel32.lib
bits 64
default rel

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ReadFile
extern __imp_CreateFileA
extern __imp_CloseHandle
extern __imp_GetFileSize
extern __imp_GetCommandLineA
extern __imp_ExitProcess

global main

%define IMAGE_BASE    0x140000000
%define HDRSZ         0x400           ; cabecalhos (multiplo de FILEALIGN)
%define SECALIGN      0x1000
%define FILEALIGN     0x200
%define BUF_SIZE      8388608
%define MAXSYM        16384
%define MAXIMP        512
%define IMPPOOL_SIZE  16384
%define NAMEMAX       512
%define GENERIC_READ  0x80000000
%define GENERIC_WRITE 0x40000000

section .data
align 8
s_dll:      db "KERNEL32.dll", 0
s_main:     db "main", 0
s_imp:      db "__imp_", 0
t_text:     db ".text", 0
t_data:     db ".data", 0
t_bss:      db ".bss", 0
s_usage:    db "pelink: uso: pelink <entrada.obj> <saida.exe>", 13, 10, 0
s_eread:    db "pelink: nao foi possivel ler o objeto", 13, 10, 0
s_ewrite:   db "pelink: nao foi possivel gravar o executavel", 13, 10, 0
s_ecoff:    db "pelink: objeto nao e COFF x64 valido", 13, 10, 0
s_esec:     db "pelink: secao nao suportada (somente .text, .data, .bss)", 13, 10, 0
s_edup:     db "pelink: secao duplicada", 13, 10, 0
s_eunres:   db "pelink: simbolo nao resolvido", 13, 10, 0
s_sym:      db "pelink: simbolo: ", 0
s_nl:       db 13, 10, 0
s_ereloc:   db "pelink: tipo de relocacao nao suportado", 13, 10, 0
s_ebss:     db "pelink: relocacao dentro de .bss", 13, 10, 0
s_erange:   db "pelink: relocacao fora da secao", 13, 10, 0
s_eovf:     db "pelink: relocacao fora do alcance de 32 bits", 13, 10, 0
s_emain:    db "pelink: simbolo main nao encontrado", 13, 10, 0
s_ebig:     db "pelink: tamanho excede o limite", 13, 10, 0
s_eimp:     db "pelink: muitos imports", 13, 10, 0

section .bss
alignb 16
hout:       resq 1
hfile:      resq 1
bytesrd:    resd 1
byteswr:    resd 1
inlen:      resq 1
outtotal:   resq 1
nsec:       resq 1
symoff:     resq 1                  ; deslocamento da tabela de simbolos em inbuf
nsym:       resq 1
stroff:     resq 1                  ; deslocamento da tabela de strings em inbuf
entry_rva:  resq 1
imagesize:  resq 1
idsize:     resq 1
ilt_off:    resq 1                  ; deslocamentos dentro de .idata
iat_off:    resq 1
dll_off:    resq 1
hn_top:     resq 1
nimp:       resq 1
imptop:     resq 1
tmp1:       resq 1
tmp2:       resq 1
tmp3:       resq 1
tmp4:       resq 1
secmap:     resq 9                  ; secao do objeto (1..8) -> saida (1 .text, 2 .data, 3 .bss; 0 = ignorada)
secraw:     resq 9                  ; PointerToRawData no objeto
secsz:      resq 9                  ; SizeOfRawData no objeto
secrel:     resq 9                  ; PointerToRelocations no objeto
secrelcnt:  resq 9                  ; NumberOfRelocations
outdef:     resq 4                  ; saida 1..3 definida
outsz:      resq 4                  ; tamanho de cada saida 1..3
outrva:     resq 5                  ; RVA das saidas 1..4 (4 = .idata)
outraw:     resq 5                  ; deslocamento no arquivo das saidas 1..4
outrawsz:   resq 5                  ; tamanho no arquivo (alinhado) das saidas 1..4
impnamep:   resq MAXIMP             ; ponteiro para o nome do import em imppool
impho:      resq MAXIMP             ; deslocamento do hint/name dentro de .idata
imppool:    resb IMPPOOL_SIZE
symva:      resq MAXSYM             ; VA absoluta de cada simbolo
symimp:     resq MAXSYM             ; indice do import + 1 (0 = nao e import)
symnbuf:    resb NAMEMAX
objpath:    resb 512
exepath:    resb 512
inbuf:      resb BUF_SIZE           ; objeto de entrada
outbuf:     resb BUF_SIZE           ; executavel de saida

section .text

; ---------- strlen_z: rsi -> rax ---------------------------------------------
strlen_z:
    xor eax, eax
.l:
    cmp byte [rsi+rax], 0
    je .d
    inc rax
    jmp .l
.d:
    ret

; ---------- copy_z: rdi = destino, rsi = origem (limite NAMEMAX) ------------
copy_z:
    xor ecx, ecx
.c:
    mov al, [rsi+rcx]
    mov [rdi+rcx], al
    test al, al
    jz .d
    inc rcx
    cmp rcx, NAMEMAX-1
    jb .c
    mov byte [rdi+rcx], 0
.d:
    ret

; ---------- starts_with: rsi = texto, rdi = prefixo -> eax --------------------
starts_with:
    xor ecx, ecx
.sw:
    mov al, [rdi+rcx]
    test al, al
    jz .sim
    cmp al, [rsi+rcx]
    jne .nao
    inc rcx
    jmp .sw
.sim:
    mov eax, 1
    ret
.nao:
    xor eax, eax
    ret

; ---------- str_eq: rsi, rdi (zero-terminados) -> eax ------------------------
str_eq:
    xor ecx, ecx
.se:
    mov al, [rsi+rcx]
    cmp al, [rdi+rcx]
    jne .nao
    test al, al
    jz .sim
    inc rcx
    jmp .se
.sim:
    mov eax, 1
    ret
.nao:
    xor eax, eax
    ret

; ---------- name8_eq: rsi = campo de 8 bytes, rdi = texto -> eax -------------
name8_eq:
    xor ecx, ecx
.n:
    cmp ecx, 8
    jae .sim
    mov al, [rsi+rcx]
    cmp al, [rdi+rcx]
    jne .nao
    test al, al
    jz .sim
    inc ecx
    jmp .n
.sim:
    mov eax, 1
    ret
.nao:
    xor eax, eax
    ret

; ---------- align_up: rax = valor, rcx = alinhamento -> rax ------------------
align_up:
    mov rdx, rcx
    dec rdx
    add rax, rdx
    not rdx
    and rax, rdx
    ret

; ---------- say: rsi = texto zero-terminado -> stdout -----------------------
say:
    sub rsp, 88
    mov [tmp1], rsi
    call strlen_z
    mov r8, rax
    mov rcx, [hout]
    mov rdx, [tmp1]
    lea r9, [byteswr]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 88
    ret

; ---------- parse_cmdline: objpath e exepath; eax = 1 se ok ------------------
parse_cmdline:
    sub rsp, 88
    call [__imp_GetCommandLineA]
    mov rsi, rax
    cmp byte [rsi], '"'             ; pula o nome do programa
    jne .nq
    inc rsi
.q:
    cmp byte [rsi], 0
    je .falha
    cmp byte [rsi], '"'
    je .qf
    inc rsi
    jmp .q
.qf:
    inc rsi
    jmp .sp
.nq:
    cmp byte [rsi], 0
    je .falha
    cmp byte [rsi], ' '
    je .sp
    inc rsi
    jmp .nq
.sp:
    cmp byte [rsi], ' '
    jne .t1
    inc rsi
    jmp .sp
.t1:
    lea rdi, [objpath]
    call copy_token
.sp2:
    cmp byte [rsi], ' '
    jne .t2
    inc rsi
    jmp .sp2
.t2:
    lea rdi, [exepath]
    call copy_token
    cmp byte [objpath], 0
    je .falha
    cmp byte [exepath], 0
    je .falha
    mov eax, 1
    add rsp, 88
    ret
.falha:
    xor eax, eax
    add rsp, 88
    ret

; copia um token de rsi para rdi (sem aspas); rsi para no separador
copy_token:
    xor ecx, ecx
.ct:
    mov al, [rsi]
    test al, al
    jz .fim
    cmp al, ' '
    je .fim
    cmp al, '"'
    je .pula
    cmp ecx, NAMEMAX-1
    jae .pula
    mov [rdi+rcx], al
    inc rcx
.pula:
    inc rsi
    jmp .ct
.fim:
    mov byte [rdi+rcx], 0
    ret

; ---------- read_file: rdi = caminho, rsi = destino -> rax = bytes ou -1 ------
read_file:
    sub rsp, 88
    mov [tmp1], rsi
    mov rcx, rdi
    mov edx, GENERIC_READ
    mov r8d, 1
    xor r9d, r9d
    mov qword [rsp+32], 3           ; OPEN_EXISTING
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .erro
    mov [hfile], rax
    mov rcx, rax
    xor edx, edx
    call [__imp_GetFileSize]
    cmp eax, -1
    je .fecha
    cmp rax, BUF_SIZE
    ja .fecha
    mov [tmp2], rax
    mov rcx, [hfile]
    mov rdx, [tmp1]
    mov r8, [tmp2]
    lea r9, [bytesrd]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    test eax, eax
    jz .fecha
    mov rcx, [hfile]
    call [__imp_CloseHandle]
    mov eax, [bytesrd]
    add rsp, 88
    ret
.fecha:
    mov rcx, [hfile]
    call [__imp_CloseHandle]
.erro:
    mov rax, -1
    add rsp, 88
    ret

; ---------- write_file: rdi = caminho, rsi = buffer, rdx = tamanho -> eax ----
write_file:
    sub rsp, 88
    mov [tmp1], rsi
    mov [tmp2], rdx
    mov rcx, rdi
    mov edx, GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 2           ; CREATE_ALWAYS
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .erro
    mov [hfile], rax
    mov rcx, rax
    mov rdx, [tmp1]
    mov r8, [tmp2]
    lea r9, [byteswr]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    mov rcx, [hfile]
    call [__imp_CloseHandle]
    mov eax, [byteswr]
    cmp rax, [tmp2]
    jne .erro
    mov eax, 1
    add rsp, 88
    ret
.erro:
    xor eax, eax
    add rsp, 88
    ret

; ---------- sym_rec: rcx = indice -> rbx = registro (18 bytes) ---------------
sym_rec:
    mov rbx, [symoff]
    imul rax, rcx, 18
    add rbx, rax
    lea rax, [inbuf]
    add rbx, rax
    ret

; ---------- sym_name: rcx = indice -> rsi = symnbuf (nome zero-terminado) ----
sym_name:
    call sym_rec
    cmp dword [rbx], 0
    jne .inline
    mov eax, [rbx+4]                ; deslocamento na tabela de strings
    lea rsi, [inbuf]
    add rsi, [stroff]
    add rsi, rax
    lea rdi, [symnbuf]
    call copy_z
    lea rsi, [symnbuf]
    ret
.inline:
    lea rdi, [symnbuf]
    xor ecx, ecx
.c:
    cmp ecx, 8
    jae .cheio
    mov al, [rbx+rcx]
    mov [rdi+rcx], al
    test al, al
    jz .pronto
    inc ecx
    jmp .c
.cheio:
    mov byte [rdi+8], 0
.pronto:
    lea rsi, [symnbuf]
    ret

; ---------- parse_coff: valida o cabecalho -> rax = 0 ou mensagem -----------
parse_coff:
    lea rsi, [inbuf]
    cmp word [rsi], 0x8664
    jne .erro
    movzx eax, word [rsi+2]
    cmp rax, 8
    ja .erro
    mov [nsec], rax
    mov eax, [rsi+8]
    mov [symoff], rax
    mov eax, [rsi+12]
    mov [nsym], rax
    cmp rax, MAXSYM
    ja .grande
    mov rax, [nsym]
    imul rax, rax, 18
    add rax, [symoff]
    mov [stroff], rax
    cmp rax, [inlen]
    ja .erro
    xor eax, eax
    ret
.erro:
    lea rax, [s_ecoff]
    ret
.grande:
    lea rax, [s_ebig]
    ret

; ---------- map_sections: secoes do objeto -> .text/.data/.bss ----------------
map_sections:
    mov qword [tmp1], 1
.loop:
    mov rax, [tmp1]
    cmp rax, [nsec]
    ja .ok
    dec rax
    imul rax, rax, 40
    lea rsi, [inbuf+20]
    add rsi, rax
    mov [tmp2], rsi                 ; cabecalho da secao k
    mov rcx, [tmp1]
    mov rbx, [tmp2]
    lea rdx, [secraw]
    mov eax, [rbx+20]
    mov [rdx+rcx*8], rax
    lea rdx, [secsz]
    mov eax, [rbx+16]
    mov [rdx+rcx*8], rax
    lea rdx, [secrel]
    mov eax, [rbx+24]
    mov [rdx+rcx*8], rax
    lea rdx, [secrelcnt]
    movzx eax, word [rbx+32]
    mov [rdx+rcx*8], rax
    lea rdx, [secmap]
    mov qword [rdx+rcx*8], 0
    mov rsi, [tmp2]
    lea rdi, [t_text]
    call name8_eq
    test eax, eax
    jz .nd
    mov qword [tmp3], 1
    jmp .mapa
.nd:
    mov rsi, [tmp2]
    lea rdi, [t_data]
    call name8_eq
    test eax, eax
    jz .nb
    mov qword [tmp3], 2
    jmp .mapa
.nb:
    mov rsi, [tmp2]
    lea rdi, [t_bss]
    call name8_eq
    test eax, eax
    jz .outra
    mov qword [tmp3], 3
    jmp .mapa
.outra:
    mov rcx, [tmp1]
    lea rdx, [secsz]
    cmp qword [rdx+rcx*8], 0        ; secao vazia (ex.: .drectve) e ignorada
    je .next
    lea rax, [s_esec]
    ret
.mapa:
    mov rdx, [tmp3]
    lea rbx, [outdef]
    cmp qword [rbx+rdx*8], 0
    jne .dup
    mov qword [rbx+rdx*8], 1
    mov rcx, [tmp1]
    lea rbx, [secmap]
    mov [rbx+rcx*8], rdx
    mov rbx, [tmp2]
    mov eax, [rbx+16]
    lea rcx, [outsz]
    mov rdx, [tmp3]
    mov [rcx+rdx*8], rax
    jmp .next
.dup:
    lea rax, [s_edup]
    ret
.next:
    inc qword [tmp1]
    jmp .loop
.ok:
    xor eax, eax
    ret

; ---------- count_imports: externos __imp_* -> impnamep/symimp ----------------
count_imports:
    mov qword [nimp], 0
    mov qword [imptop], 0
    mov qword [tmp1], 0
.loop:
    mov rcx, [tmp1]
    cmp rcx, [nsym]
    jae .ok
    call sym_rec
    movzx eax, byte [rbx+17]        ; registros auxiliares
    mov [tmp2], rax
    cmp word [rbx+12], 0            ; indefinido
    jne .next
    cmp byte [rbx+16], 2            ; EXTERNAL
    jne .next
    mov rcx, [tmp1]
    call sym_name
    lea rdi, [s_imp]
    call starts_with
    test eax, eax
    jz .next
    mov rax, [nimp]
    cmp rax, MAXIMP
    jae .muitos
    lea rsi, [symnbuf+6]            ; nome sem o prefixo "__imp_"
    lea rdi, [imppool]
    add rdi, [imptop]
    mov rdx, rdi
    lea rbx, [impnamep]
    mov rax, [nimp]
    mov [rbx+rax*8], rdx
    call copy_z
    mov rsi, rdx
    call strlen_z
    inc rax
    add [imptop], rax
    cmp qword [imptop], IMPPOOL_SIZE
    ja .muitos
    lea rbx, [symimp]
    mov rcx, [tmp1]
    mov rax, [nimp]
    inc rax
    mov [rbx+rcx*8], rax
    inc qword [nimp]
.next:
    mov rax, [tmp1]
    add rax, [tmp2]
    inc rax
    mov [tmp1], rax
    jmp .loop
.ok:
    xor eax, eax
    ret
.muitos:
    lea rax, [s_eimp]
    ret

; ---------- layout: RVAs, deslocamentos de arquivo e tabelas do .idata --------
layout:
    ; .idata: descritores (40), ILT e IAT (n+1 qwords cada), nomes e hint/name
    mov rax, [nimp]
    lea rcx, [rax+1]
    shl rcx, 3                      ; 8 * (n+1)
    mov qword [ilt_off], 40
    mov rdx, 40
    add rdx, rcx
    mov [iat_off], rdx
    add rdx, rcx
    mov [dll_off], rdx
    add rdx, 14                     ; "KERNEL32.dll" + NUL = 13 bytes, alinhado em 2
    and rdx, -2
    mov [hn_top], rdx
    xor r8d, r8d
.hn:
    cmp r8, [nimp]
    jae .hn_fim
    lea rbx, [impho]
    mov rax, [hn_top]
    mov [rbx+r8*8], rax
    lea rbx, [impnamep]
    mov rsi, [rbx+r8*8]
    call strlen_z                   ; rax = comprimento do nome
    add rax, 3                      ; hint (2) + nome + NUL
    and rax, -2
    add [hn_top], rax
    inc r8
    jmp .hn
.hn_fim:
    mov rax, [hn_top]
    mov [idsize], rax
    ; RVAs: .text em SECALIGN, cada secao seguinte alinhada
    lea rbx, [outrva]
    mov qword [rbx+8], SECALIGN
    mov qword [tmp1], 1
.rva:
    mov rcx, [tmp1]
    lea rbx, [outrva]
    mov rax, [rbx+rcx*8]
    lea rdx, [outsz]
    add rax, [rdx+rcx*8]
    mov rcx, SECALIGN
    call align_up
    mov rcx, [tmp1]
    lea rbx, [outrva]
    mov [rbx+rcx*8+8], rax
    inc qword [tmp1]
    cmp qword [tmp1], 3
    jbe .rva
    ; .idata (saida 4) vem depois de .bss
    lea rbx, [outrva]
    mov rax, [rbx+32]
    add rax, [idsize]
    mov rcx, SECALIGN
    call align_up
    mov [imagesize], rax
    ; deslocamentos no arquivo: cabecalhos (HDRSZ), depois as secoes com dados
    lea rdx, [outsz]
    mov rax, [rdx+8]
    mov rcx, FILEALIGN
    call align_up
    lea rbx, [outrawsz]
    mov [rbx+8], rax
    lea rbx, [outraw]
    mov qword [rbx+8], HDRSZ
    lea rdx, [outsz]
    mov rax, [rdx+16]
    mov rcx, FILEALIGN
    call align_up
    lea rbx, [outrawsz]
    mov [rbx+16], rax
    lea rbx, [outraw]
    mov rax, [rbx+8]
    lea rdx, [outrawsz]
    add rax, [rdx+8]
    lea rbx, [outraw]
    mov [rbx+16], rax
    lea rbx, [outraw]               ; .bss nao tem dados no arquivo
    mov qword [rbx+24], 0
    lea rbx, [outrawsz]
    mov qword [rbx+24], 0
    lea rbx, [outraw]
    mov rax, [rbx+16]
    lea rdx, [outrawsz]
    add rax, [rdx+16]
    lea rbx, [outraw]
    mov [rbx+32], rax
    mov rax, [idsize]
    mov rcx, FILEALIGN
    call align_up
    lea rbx, [outrawsz]
    mov [rbx+32], rax
    lea rbx, [outraw]
    mov rax, [rbx+32]
    lea rdx, [outrawsz]
    add rax, [rdx+32]
    mov [outtotal], rax
    cmp rax, BUF_SIZE
    ja .grande
    xor eax, eax
    ret
.grande:
    lea rax, [s_ebig]
    ret

; ---------- show_name: rcx = indice -> imprime "pelink: simbolo: <nome>" -----
show_name:
    sub rsp, 88
    call sym_name
    mov [tmp4], rsi
    lea rsi, [s_sym]
    call say
    mov rsi, [tmp4]
    call say
    lea rsi, [s_nl]
    call say
    add rsp, 88
    ret

; ---------- fill_symbols: VA absoluta de cada simbolo ------------------------
fill_symbols:
    mov qword [tmp1], 0
.loop:
    mov rcx, [tmp1]
    cmp rcx, [nsym]
    jae .ok
    call sym_rec
    movzx eax, byte [rbx+17]
    mov [tmp2], rax
    movsx rax, word [rbx+12]        ; SectionNumber
    mov [tmp3], rax
    mov eax, [rbx+8]                ; Value
    mov [tmp4], rax
    mov rax, [tmp3]
    cmp rax, 0
    jg .sec
    je .indef
    cmp rax, -1                     ; ABS
    je .abs
    cmp rax, -2                     ; IMAGE_SYM_DEBUG (ex.: .file): nao vai ao executavel
    je .zero
    jmp .nres
.abs:
    mov rax, [tmp4]
    jmp .store
.zero:
    xor eax, eax
    jmp .store
.sec:
    cmp rax, [nsec]
    ja .nres
    lea rdx, [secmap]
    mov rdx, [rdx+rax*8]
    test rdx, rdx
    jz .nres
    lea rbx, [outrva]
    mov rax, [rbx+rdx*8]
    add rax, [tmp4]
    mov rcx, IMAGE_BASE
    add rax, rcx
    jmp .store
.indef:
    mov rcx, [tmp1]
    lea rbx, [symimp]
    mov rdx, [rbx+rcx*8]
    test rdx, rdx
    jz .nres
    dec rdx
    lea rbx, [outrva]
    mov rax, [rbx+32]               ; RVA do .idata
    add rax, [iat_off]
    shl rdx, 3
    add rax, rdx
    mov rcx, IMAGE_BASE
    add rax, rcx
    jmp .store
.nres:
    sub rsp, 8                      ; alinha a pilha para a chamada ao Windows
    mov rcx, [tmp1]
    call show_name
    add rsp, 8
    lea rax, [s_eunres]
    ret
.store:
    mov rcx, [tmp1]
    lea rbx, [symva]
    mov [rbx+rcx*8], rax
    mov rax, [tmp1]
    add rax, [tmp2]
    inc rax
    mov [tmp1], rax
    jmp .loop
.ok:
    xor eax, eax
    ret

; ---------- find_main: entry_rva = RVA do simbolo main (secao definida) -------
find_main:
    mov qword [tmp1], 0
.loop:
    mov rcx, [tmp1]
    cmp rcx, [nsym]
    jae .nao
    call sym_rec
    movzx eax, byte [rbx+17]
    mov [tmp2], rax
    cmp word [rbx+12], 0
    jle .prox
    mov rcx, [tmp1]
    call sym_name
    lea rdi, [s_main]
    call str_eq
    test eax, eax
    jz .prox
    lea rbx, [symva]
    mov rcx, [tmp1]
    mov rax, [rbx+rcx*8]
    mov rcx, IMAGE_BASE
    sub rax, rcx
    mov [entry_rva], rax
    xor eax, eax
    ret
.prox:
    mov rax, [tmp1]
    add rax, [tmp2]
    inc rax
    mov [tmp1], rax
    jmp .loop
.nao:
    lea rax, [s_emain]
    ret

; ---------- apply_relocs: copia as secoes e aplica as relocacoes -------------
apply_relocs:
    push r12
    push r13
    push r14
    push r15
    ; zera a saida inteira (preenchimento e cabecalhos)
    lea rdi, [outbuf]
    xor eax, eax
    mov rcx, [outtotal]
    rep stosb
    ; copia os dados brutos de .text e .data
    mov qword [tmp1], 1
.copia:
    mov rcx, [tmp1]
    cmp rcx, [nsec]
    ja .relocs
    lea rdx, [secmap]
    mov rax, [rdx+rcx*8]
    cmp rax, 1
    je .faz
    cmp rax, 2
    jne .copia_prox
.faz:
    lea rdx, [outraw]
    mov rdi, [rdx+rax*8]            ; deslocamento da saida no arquivo
    lea rbx, [outbuf]
    add rdi, rbx
    lea rdx, [secraw]
    mov rsi, [rdx+rcx*8]
    lea rbx, [inbuf]
    add rsi, rbx
    lea rdx, [secsz]
    mov rcx, [rdx+rcx*8]
    rep movsb
.copia_prox:
    inc qword [tmp1]
    jmp .copia
.relocs:
    mov qword [tmp1], 1
.secao:
    mov rcx, [tmp1]
    cmp rcx, [nsec]
    ja .ok
    lea rdx, [secmap]
    mov r14, [rdx+rcx*8]            ; saida da secao
    test r14, r14
    jz .prox_secao
    mov r15, rcx                    ; secao do objeto
    lea rdx, [secrelcnt]
    mov r13, [rdx+rcx*8]
    test r13, r13
    jz .prox_secao
    cmp r14, 3
    je .ebss
    lea rdx, [secrel]
    mov r12, [rdx+rcx*8]
    lea rax, [inbuf]
    add r12, rax                    ; primeira relocacao da secao
    mov rax, r13
    imul rax, rax, 10
    add rax, r12
    lea rdx, [inbuf]
    add rdx, [inlen]
    cmp rax, rdx                    ; a tabela de relocacoes tem de caber no arquivo
    ja .ecoff
.rel:
    test r13, r13
    jz .prox_secao
    mov eax, [r12]                  ; VirtualAddress (deslocamento na secao)
    lea rdx, [secsz]
    mov rcx, [rdx+r15*8]
    cmp rax, rcx
    jae .erange
    mov ebx, [r12+4]                ; indice do simbolo
    cmp rbx, [nsym]
    jae .ecoff
    movzx ecx, word [r12+8]         ; tipo
    lea rdx, [outrva]
    mov r9, [rdx+r14*8]
    add r9, rax
    mov r10, IMAGE_BASE
    add r9, r10                     ; P = VA do campo a corrigir
    lea rdx, [symva]
    mov r8, [rdx+rbx*8]             ; S = VA do simbolo
    lea rdx, [outraw]
    mov rdi, [rdx+r14*8]
    add rdi, rax
    lea rdx, [outbuf]
    add rdi, rdx                    ; onde o campo esta no executavel
    cmp rcx, 1                      ; ADDR64
    je .abs64
    cmp rcx, 3                      ; ADDR32NB
    je .nb
    cmp rcx, 4                      ; REL32 .. REL32_5 (4..9)
    jb .ereloc
    cmp rcx, 9
    ja .ereloc
    sub rcx, 4                      ; bytes apos o campo
    movsxd rdx, dword [rdi]
    add rdx, r8
    lea rax, [r9+4]
    add rax, rcx
    sub rdx, rax
    movsxd rax, edx
    cmp rax, rdx
    jne .eovf
    mov [rdi], edx
    jmp .prox_rel
.abs64:
    mov rdx, [rdi]
    add rdx, r8
    mov [rdi], rdx
    jmp .prox_rel
.nb:
    movsxd rdx, dword [rdi]
    add rdx, r8
    mov rax, IMAGE_BASE
    sub rdx, rax
    movsxd rax, edx
    cmp rax, rdx
    jne .eovf
    mov [rdi], edx
.prox_rel:
    add r12, 10
    dec r13
    jmp .rel
.prox_secao:
    inc qword [tmp1]
    jmp .secao
.ok:
    xor eax, eax
    jmp .fim
.ebss:
    lea rax, [s_ebss]
    jmp .fim
.ecoff:
    lea rax, [s_ecoff]
    jmp .fim
.erange:
    lea rax, [s_erange]
    jmp .fim
.ereloc:
    lea rax, [s_ereloc]
    jmp .fim
.eovf:
    lea rax, [s_eovf]
.fim:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ---------- write_headers: DOS, PE, COFF, opcional, secoes e .idata ----------
write_headers:
    push r12
    push r13
    ; DOS
    mov word [outbuf], 0x5A4D       ; "MZ"
    mov dword [outbuf+0x3C], 0x40   ; e_lfanew
    ; assinatura PE e cabecalho COFF
    mov dword [outbuf+0x40], 0x00004550
    mov word [outbuf+0x44], 0x8664  ; Machine = AMD64
    mov word [outbuf+0x46], 4       ; NumberOfSections
    mov word [outbuf+0x54], 240     ; SizeOfOptionalHeader (PE32+)
    mov word [outbuf+0x56], 0x0023  ; EXECUTABLE_IMAGE | RELOCS_STRIPPED | LARGE_ADDRESS_AWARE
    ; cabecalho opcional PE32+
    mov word [outbuf+0x58], 0x020B  ; Magic
    mov byte [outbuf+0x5A], 14      ; MajorLinkerVersion
    lea rbx, [outrawsz]
    mov eax, [rbx+8]
    mov [outbuf+0x5C], eax          ; SizeOfCode
    mov eax, [rbx+16]
    add eax, [rbx+32]
    mov [outbuf+0x60], eax          ; SizeOfInitializedData
    lea rbx, [outsz]
    mov eax, [rbx+24]
    mov [outbuf+0x64], eax          ; SizeOfUninitializedData
    mov rax, [entry_rva]
    mov [outbuf+0x68], eax          ; AddressOfEntryPoint
    lea rbx, [outrva]
    mov eax, [rbx+8]
    mov [outbuf+0x6C], eax          ; BaseOfCode
    mov rax, IMAGE_BASE
    mov [outbuf+0x70], rax          ; ImageBase
    mov dword [outbuf+0x78], SECALIGN
    mov dword [outbuf+0x7C], FILEALIGN
    mov word [outbuf+0x80], 6       ; versoes do SO e do subsistema
    mov word [outbuf+0x88], 6
    mov rax, [imagesize]
    mov [outbuf+0x90], eax          ; SizeOfImage
    mov dword [outbuf+0x94], HDRSZ  ; SizeOfHeaders
    mov word [outbuf+0x9C], 3       ; IMAGE_SUBSYSTEM_WINDOWS_CUI
    mov word [outbuf+0x9E], 0x8100  ; NX_COMPAT | TERMINAL_SERVER_AWARE
    mov qword [outbuf+0xA0], 0x100000
    mov qword [outbuf+0xA8], 0x1000
    mov qword [outbuf+0xB0], 0x100000
    mov qword [outbuf+0xB8], 0x1000
    mov dword [outbuf+0xC4], 16     ; NumberOfRvaAndSizes
    ; diretorio 1 (importacao): RVA e tamanho dos descritores
    lea rbx, [outrva]
    mov eax, [rbx+32]
    mov [outbuf+0xD0], eax
    mov dword [outbuf+0xD4], 40
    ; tabela de secoes em 0x148: .text, .data, .bss, .idata
    lea rdi, [outbuf+0x148]
    mov rax, 0x000000747865742E     ; ".text"
    lea rbx, [outrva]
    mov edx, [outsz+8]
    mov ecx, [rbx+8]
    mov r8d, [outrawsz+8]
    mov r9d, [outraw+8]
    mov r10d, 0x60000020
    call put_sec
    lea rdi, [outbuf+0x148+40]
    mov rax, 0x000000617461642E     ; ".data"
    lea rbx, [outrva]
    mov edx, [outsz+16]
    mov ecx, [rbx+16]
    mov r8d, [outrawsz+16]
    mov r9d, [outraw+16]
    mov r10d, 0xC0000040
    call put_sec
    lea rdi, [outbuf+0x148+80]
    mov rax, 0x000000007373622E     ; ".bss"
    lea rbx, [outrva]
    mov edx, [outsz+24]
    mov ecx, [rbx+24]
    mov r8d, 0
    mov r9d, 0
    mov r10d, 0xC0000080
    call put_sec
    lea rdi, [outbuf+0x148+120]
    mov rax, 0x000061746164692E     ; ".idata"
    lea rbx, [outrva]
    mov edx, [idsize]
    mov ecx, [rbx+32]
    mov r8d, [outrawsz+32]
    mov r9d, [outraw+32]
    mov r10d, 0xC0000040
    call put_sec
    call build_idata
    pop r13
    pop r12
    ret

; rdi = entrada da secao, rax = nome, edx = VirtualSize, ecx = VA, r8d = rawsz,
; r9d = ponteiro bruto, r10d = caracteristicas
put_sec:
    mov [rdi], rax
    mov [rdi+8], edx
    mov [rdi+12], ecx
    mov [rdi+16], r8d
    mov [rdi+20], r9d
    mov [rdi+36], r10d
    ret

; ---------- build_idata: descritor, ILT, IAT, nomes e hint/name ----------------
build_idata:
    push r12
    push r13
    lea r12, [outbuf]
    lea rbx, [outraw]
    add r12, [rbx+32]               ; r12 = inicio de .idata no executavel
    lea rbx, [outrva]
    mov r13, [rbx+32]               ; r13 = RVA de .idata
    ; descritor da DLL (o segundo, zero, ja esta no buffer)
    mov rax, r13
    add rax, [ilt_off]
    mov [r12], eax                  ; OriginalFirstThunk
    mov dword [r12+4], 0            ; TimeDateStamp
    mov dword [r12+8], 0            ; ForwarderChain
    mov rax, r13
    add rax, [dll_off]
    mov [r12+12], eax               ; Name
    mov rax, r13
    add rax, [iat_off]
    mov [r12+16], eax               ; FirstThunk
    lea rdi, [r12]
    add rdi, [dll_off]
    lea rsi, [s_dll]
    call copy_z
    mov qword [tmp1], 0
.imp:
    mov rcx, [tmp1]
    cmp rcx, [nimp]
    jae .fim
    lea rbx, [impho]
    mov rax, [rbx+rcx*8]
    add rax, r13                    ; RVA do hint/name do import i
    mov rdx, rcx
    shl rdx, 3
    mov rsi, rdx
    add rdx, [ilt_off]
    mov [r12+rdx], rax              ; ILT[i]
    mov rdx, rsi
    add rdx, [iat_off]
    mov [r12+rdx], rax              ; IAT[i] (o loader sobrescreve com o endereco)
    lea rbx, [impho]
    mov rdi, [rbx+rcx*8]
    add rdi, r12
    add rdi, 2                      ; hint = 0 (ja zerado); nome logo depois
    lea rbx, [impnamep]
    mov rsi, [rbx+rcx*8]
    call copy_z
    inc qword [tmp1]
    jmp .imp
.fim:
    pop r13
    pop r12
    ret

; ---------- main ----------------------------------------------------------------
main:
    sub rsp, 88
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout], rax
    call parse_cmdline
    test eax, eax
    jz .uso
    lea rdi, [objpath]
    lea rsi, [inbuf]
    call read_file
    cmp rax, -1
    je .eread
    cmp rax, 20
    jb .ecoff
    mov [inlen], rax
    call parse_coff
    test rax, rax
    jnz .erro
    call map_sections
    test rax, rax
    jnz .erro
    call count_imports
    test rax, rax
    jnz .erro
    call layout
    test rax, rax
    jnz .erro
    call fill_symbols
    test rax, rax
    jnz .erro
    call find_main
    test rax, rax
    jnz .erro
    call apply_relocs
    test rax, rax
    jnz .erro
    call write_headers
    lea rdi, [exepath]
    lea rsi, [outbuf]
    mov rdx, [outtotal]
    call write_file
    test eax, eax
    jz .ewrite
    xor ecx, ecx
    call [__imp_ExitProcess]
.uso:
    lea rsi, [s_usage]
    call say
    mov ecx, 2
    call [__imp_ExitProcess]
.eread:
    lea rax, [s_eread]
    jmp .erro
.ecoff:
    lea rax, [s_ecoff]
    jmp .erro
.ewrite:
    lea rax, [s_ewrite]
.erro:
    mov rsi, rax
    call say
    mov ecx, 1
    call [__imp_ExitProcess]

bits 64
default rel
; ============ TREINO DO TOKENIZADOR BPE (por bytes) ============
; Le ate BPEMAX bytes de TEXTO e aprende NV-256 fusoes: a cada passo conta os pares
; vizinhos, funde o mais frequente (todas as ocorrencias, da esquerda para a direita) e
; cria um token novo. Fusoes nunca atravessam palavras: o token da direita nao pode
; comecar com espaco/TAB/CR/LF e o da esquerda nao pode terminar em LF (os tokens ficam
; como " palavra", "ção", ","). Grava em SAIDA: "BPE1", NV, e os pares (a, b) de cada
; token 256..NV-1 (uint16). Para antes se o melhor par aparecer menos de 2 vezes.
; So grava SAIDA se ela ainda nao existir.
%ifndef TEXTO
%define TEXTO     "build/amostra.tsv"
%endif
%ifndef SAIDA
%define SAIDA     "build/vocab_bpe.bin"
%endif
%ifndef NV
%define NV        4096
%endif
%ifndef BPEMAX
%define BPEMAX    8388608
%endif

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ReadFile
extern __imp_CreateFileA
extern __imp_CloseHandle
extern __imp_GetTickCount64
extern __imp_ExitProcess

global main

section .data
path_in:     db TEXTO, 0
path_out:    db SAIDA, 0
msg_tok:     db "tokens no vocabulario: "
msg_tok_len  equ $ - msg_tok
msg_seq:     db "  texto: "
msg_seq_len  equ $ - msg_seq
msg_seq2:    db " bytes -> "
msg_seq2_len equ $ - msg_seq2
msg_seq3:    db " tokens  tempo (ms): "
msg_seq3_len equ $ - msg_seq3
msg_nl:      db 13, 10
msg_erri:    db "erro: texto ausente ou vazio", 13, 10
msg_erri_len equ $ - msg_erri
msg_erro:    db "erro: SAIDA ja existe ou nao pode ser criada", 13, 10
msg_erro_len equ $ - msg_erro
msg_erro_g:  db "erro: gravacao incompleta (disco cheio?)", 13, 10
msg_erro_g_len equ $ - msg_erro_g

section .bss
alignb 16
hout:       resq 1
hfile:      resq 1
wrote:      resd 1
numbuf:     resb 24
nbytes:     resq 1
n:          resq 1                   ; tokens na sequencia
cur:        resq 1                   ; tokens no vocabulario
t0:         resq 1
pa:         resw NV                  ; par de cada token
pb:         resw NV
first:      resb NV                  ; primeiro e ultimo byte de cada token
last:       resb NV
tlen:       resb NV                  ; bytes de texto de cada token (fusoes param em 63)
okr:        resb NV                  ; 1 = pode ser o token da direita
okl:        resb NV                  ; 1 = pode ser o token da esquerda
alignb 16
cnt:        resd NV*NV               ; contagem dos pares (a*NV + b)
seq:        resw BPEMAX
lst:        resd BPEMAX              ; pares que apareceram nesta contagem
rbuf:       resb BPEMAX
hdr:        resd 2

section .text

say:
    sub rsp, 56
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [hout]
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 56
    ret

print_u:
    push rsi                         ; rsi e rdi sao preservados pela convencao x64
    push rdi
    sub rsp, 88
    lea rdi, [numbuf+20]
    mov rcx, 10
.p:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .p
    lea rax, [numbuf+20]
    sub rax, rdi
    mov rcx, rax
    mov rsi, rdi
    call say
    add rsp, 88
    pop rdi
    pop rsi
    ret

; marca: ecx = token -> okl/okr pelas regras de fronteira
marca:
    lea rax, [first]
    movzx edx, byte [rax+rcx]
    lea rax, [okr]
    mov byte [rax+rcx], 1
    cmp edx, ' '
    je .r0
    cmp edx, 9
    je .r0
    cmp edx, 10
    je .r0
    cmp edx, 13
    je .r0
    jmp .l
.r0:
    mov byte [rax+rcx], 0
.l:
    lea rax, [last]
    movzx edx, byte [rax+rcx]
    lea rax, [okl]
    mov byte [rax+rcx], 1
    cmp edx, 10
    jne .f
    mov byte [rax+rcx], 0
.f:
    ret

main:
    sub rsp, 88
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout], rax
    call [__imp_GetTickCount64]
    mov [t0], rax
    lea rcx, [path_in]
    mov edx, 0x80000000
    mov r8d, 1
    xor r9d, r9d
    mov qword [rsp+32], 3
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .erro_i
    mov [hfile], rax
    mov rcx, rax
    lea rdx, [rbuf]
    mov r8d, BPEMAX
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    mov rcx, [hfile]
    call [__imp_CloseHandle]
    mov eax, [wrote]
    test eax, eax
    jz .erro_i
    mov [nbytes], rax
    mov [n], rax
    ; sequencia inicial: os bytes
    lea rsi, [rbuf]
    lea rdi, [seq]
    xor ecx, ecx
.ini:
    cmp rcx, rax
    jae .ini_ok
    movzx edx, byte [rsi+rcx]
    mov [rdi+rcx*2], dx
    inc rcx
    jmp .ini
.ini_ok:
    xor ecx, ecx
.bytes:
    lea rax, [first]
    mov [rax+rcx], cl
    lea rax, [last]
    mov [rax+rcx], cl
    lea rax, [tlen]
    mov byte [rax+rcx], 1
    call marca
    inc ecx
    cmp ecx, 256
    jb .bytes
    mov qword [cur], 256
.passo:
    cmp qword [cur], NV
    jae .grava
    ; conta os pares permitidos
    lea rsi, [seq]
    lea rdi, [cnt]
    lea r8, [okl]
    lea r9, [okr]
    mov r10, [n]
    dec r10
    lea r13, [lst]
    xor r14d, r14d                   ; pares distintos
    xor ecx, ecx
.conta:
    cmp rcx, r10
    jae .conta_ok
    movzx eax, word [rsi+rcx*2]
    movzx edx, word [rsi+rcx*2+2]
    cmp byte [r8+rax], 0
    je .cn
    cmp byte [r9+rdx], 0
    je .cn
    imul eax, eax, NV
    add eax, edx
    cmp dword [rdi+rax*4], 0
    jne .cinc
    mov [r13+r14*4], eax             ; par novo: entra na lista
    inc r14
.cinc:
    inc dword [rdi+rax*4]
.cn:
    inc rcx
    jmp .conta
.conta_ok:
    ; o par mais frequente entre os da lista (e zera a tabela no caminho)
    xor r11d, r11d                   ; melhor contagem
    xor ebx, ebx                     ; melhor par (a*NV + b)
    xor ecx, ecx
.lm:
    cmp rcx, r14
    jae .max_ok
    mov r8d, [r13+rcx*4]             ; par a*NV+b
    mov r12d, [rdi+r8*4]             ; contagem
    mov dword [rdi+r8*4], 0          ; zera a tabela no caminho
    cmp r12d, r11d
    jbe .lm_n
    ; a fusao nao pode passar de 63 bytes: o pipeline recusa tokens maiores
    mov rax, r8
    xor edx, edx
    mov r9d, NV
    div r9                           ; rax = a, rdx = b
    lea r9, [tlen]
    movzx r10d, byte [r9+rax]
    movzx eax, byte [r9+rdx]
    add eax, r10d
    cmp eax, 63
    ja .lm_n
    mov r11d, r12d                   ; novo melhor
    mov ebx, r8d
.lm_n:
    inc rcx
    jmp .lm
.max_ok:
    cmp r11d, 2
    jb .grava
    ; novo token = (a, b)
    mov rax, rbx
    xor edx, edx
    mov ecx, NV
    div rcx                          ; rax = a, rdx = b
    mov r8, rax
    mov r9, rdx
    mov rcx, [cur]
    lea rax, [pa]
    mov [rax+rcx*2], r8w
    lea rax, [pb]
    mov [rax+rcx*2], r9w
    ; comprimento do token novo (a escolha do par ja garantiu <= 63)
    lea rax, [tlen]
    movzx edx, byte [rax+r8]
    movzx r10d, byte [rax+r9]
    add edx, r10d
    mov [rax+rcx], dl
    lea rax, [first]
    mov dl, [rax+r8]
    mov [rax+rcx], dl
    lea rax, [last]
    mov dl, [rax+r9]
    mov [rax+rcx], dl
    push r8
    push r9
    call marca
    pop r9
    pop r8
    ; funde todas as ocorrencias, da esquerda para a direita
    mov r12, [cur]
    lea rsi, [seq]
    mov r10, [n]
    xor ecx, ecx                     ; leitura
    xor edx, edx                     ; escrita
.junta:
    cmp rcx, r10
    jae .junta_ok
    movzx eax, word [rsi+rcx*2]
    lea r11, [rcx+1]
    cmp r11, r10
    jae .copia
    cmp rax, r8
    jne .copia
    movzx r11d, word [rsi+rcx*2+2]
    cmp r11, r9
    jne .copia
    mov [rsi+rdx*2], r12w
    add rcx, 2
    inc rdx
    jmp .junta
.copia:
    mov [rsi+rdx*2], ax
    inc rcx
    inc rdx
    jmp .junta
.junta_ok:
    mov [n], rdx
    inc qword [cur]
    jmp .passo
.grava:
    lea rcx, [path_out]
    mov edx, 0x40000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 1            ; CREATE_NEW: nao sobrescreve
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .erro_o
    mov [hfile], rax
    mov dword [hdr], 0x31455042      ; "BPE1"
    mov rax, [cur]
    mov [hdr+4], eax
    mov rcx, [hfile]
    lea rdx, [hdr]
    mov r8d, 8
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    cmp dword [wrote], 8
    jne .erro_g
    ; pares intercalados: a, b de cada token 256..cur-1
    lea rsi, [pa]
    lea rdi, [rbuf]
    mov ecx, 256
.pp:
    cmp rcx, [cur]
    jae .pp_ok
    mov ax, [rsi+rcx*2]
    mov [rdi], ax
    lea rax, [pb]
    mov ax, [rax+rcx*2]
    mov [rdi+2], ax
    add rdi, 4
    inc rcx
    jmp .pp
.pp_ok:
    mov rcx, [hfile]
    lea rdx, [rbuf]
    mov r8, rdi
    sub r8, rdx
    mov [rsp+56], r8
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    mov eax, [wrote]
    cmp rax, [rsp+56]
    jne .erro_g
    mov rcx, [hfile]
    call [__imp_CloseHandle]
    lea rsi, [msg_tok]
    mov ecx, msg_tok_len
    call say
    mov rax, [cur]
    call print_u
    lea rsi, [msg_seq]
    mov ecx, msg_seq_len
    call say
    mov rax, [nbytes]
    call print_u
    lea rsi, [msg_seq2]
    mov ecx, msg_seq2_len
    call say
    mov rax, [n]
    call print_u
    lea rsi, [msg_seq3]
    mov ecx, msg_seq3_len
    call say
    call [__imp_GetTickCount64]
    sub rax, [t0]
    call print_u
    lea rsi, [msg_nl]
    mov ecx, 2
    call say
    xor ecx, ecx
    call [__imp_ExitProcess]
.erro_i:
    lea rsi, [msg_erri]
    mov ecx, msg_erri_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]
.erro_o:
    lea rsi, [msg_erro]
    mov ecx, msg_erro_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]
.erro_g:
    lea rsi, [msg_erro_g]
    mov ecx, msg_erro_g_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]

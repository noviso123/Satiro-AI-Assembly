bits 64
default rel
; ============ GERACAO DE TEXTO COM O MODELO TREINADO ============
; So le: carrega os pesos de MODELO, le o inicio do texto da entrada padrao e
; continua NGEN bytes. Amostragem com temperatura (c_temp no nucleo), ou o byte
; mais provavel com -DGULOSO. -DSEMENTE=n muda a semente da amostragem.
%include "lm_core.asm"

%ifndef MODELO
%define MODELO    "dados/modelo_lm.bin"
%endif
%ifndef NGEN
%define NGEN      400
%endif
%define PMAX      1024               ; maior inicio de texto aceito

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ReadFile
extern __imp_CreateFileA
extern __imp_CloseHandle
extern __imp_SetConsoleOutputCP
extern __imp_ExitProcess

global main

section .data
align 8
path_m:      db MODELO, 0
padrao:      db "O Brasil "
padrao_len   equ $ - padrao
msg_nl_g:    db 13, 10
msg_errm:    db "erro: modelo ausente ou de tamanho errado (esperado float32)", 13, 10
msg_errm_len equ $ - msg_errm
msg_avx_g:   db "CPU sem AVX2/FMA", 13, 10
msg_avx_g_len equ $ - msg_avx_g

section .bss
alignb 16
hout_g:     resq 1
hin_g:      resq 1
wrote_g:    resd 1
hfile_g:    resq 1
glen:       resq 1                   ; bytes no texto (inicio + gerado)
gcont:      resq 1
gtxt:       resb PMAX + NCTX + NGEN + 16
mbuf:       resb NP*4 + 8

section .text

say_g:
    sub rsp, 56
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [hout_g]
    lea r9, [wrote_g]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 56
    ret

; le_modelo: rax = bytes lidos de MODELO em mbuf (ou -1)
le_modelo:
    sub rsp, 56
    lea rcx, [path_m]
    mov edx, 0x80000000
    mov r8d, 1
    xor r9d, r9d
    mov qword [rsp+32], 3
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .fim
    mov [hfile_g], rax
    mov rcx, rax
    lea rdx, [mbuf]
    mov r8d, NP*4+1
    lea r9, [wrote_g]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    mov rcx, [hfile_g]
    call [__imp_CloseHandle]
    mov eax, [wrote_g]
.fim:
    add rsp, 56
    ret

main:
    sub rsp, 88
    call set_ftz
    mov ecx, 65001                   ; UTF-8 na saida
    call [__imp_SetConsoleOutputCP]
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout_g], rax
    mov ecx, -10
    call [__imp_GetStdHandle]
    mov [hin_g], rax
    call check_avx2
    test eax, eax
    jz .sem_avx
%ifdef SEMENTE
    mov rax, SEMENTE
    mov [lm_seed], rax
%endif
    call le_modelo
    cmp rax, NP*4
    jne .erro_m
    lea rsi, [mbuf]
    lea rdi, [PAR]
    mov ecx, NP
    rep movsd
    ; inicio do texto: NCTX espacos de folga e depois a entrada padrao
    lea rdi, [gtxt]
    mov ecx, NCTX
    mov al, ' '
    rep stosb
    mov rcx, [hin_g]
    lea rdx, [gtxt+NCTX]
    mov r8d, PMAX
    lea r9, [wrote_g]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    test eax, eax
    jnz .leu
    mov dword [wrote_g], 0
.leu:
    mov eax, [wrote_g]
    ; tira CR/LF do fim
.apara:
    test eax, eax
    jz .vazio
    lea rdx, [gtxt]
    movzx ecx, byte [rdx+rax+NCTX-1]
    cmp ecx, 13
    je .corta
    cmp ecx, 10
    je .corta
    jmp .tem
.corta:
    dec eax
    jmp .apara
.vazio:
    ; sem entrada: usa o inicio padrao
    lea rsi, [padrao]
    lea rdi, [gtxt+NCTX]
    mov ecx, padrao_len
    rep movsb
    mov eax, padrao_len
.tem:
    add eax, NCTX
    mov [glen], rax
    ; mostra o inicio (sem a folga)
    lea rsi, [gtxt+NCTX]
    mov rcx, [glen]
    sub rcx, NCTX
    call say_g
    mov qword [gcont], NGEN
.gera:
    cmp qword [gcont], 0
    je .fim
    mov rax, [glen]
    lea rcx, [gtxt]
    lea rdx, [rcx+rax-NCTX]
    mov [ctxp], rdx
    call forward_lm
%ifdef GULOSO
    call argmax_lm
%else
    call sample_lm
%endif
    mov rcx, [glen]
    lea rdx, [gtxt]
    mov [rdx+rcx], al
    inc qword [glen]
    dec qword [gcont]
    jmp .gera
.fim:
    ; mostra o texto gerado de uma vez
    mov rax, [glen]
    sub rax, NGEN
    lea rsi, [gtxt]
    add rsi, rax
    mov ecx, NGEN
    ; nao corta um caractere UTF-8 no meio: acha o inicio do ultimo caractere
    mov r8, rcx
    xor r9d, r9d
.u8:
    test r8, r8
    jz .u8_ok
    cmp r9d, 4
    jae .u8_ok
    movzx eax, byte [rsi+r8-1]
    mov edx, eax
    and edx, 0xC0
    cmp edx, 0x80
    jne .u8_lead                     ; nao e byte de continuacao (10xxxxxx)
    dec r8
    inc r9d
    jmp .u8
.u8_lead:
    cmp eax, 0x80
    jb .u8_ok                        ; ASCII: completo
    mov edx, 2
    cmp eax, 0xE0
    jb .u8_t
    mov edx, 3
    cmp eax, 0xF0
    jb .u8_t
    mov edx, 4
.u8_t:
    mov r10, rcx
    sub r10, r8
    inc r10                          ; bytes do inicio do caractere ate o fim
    cmp r10, rdx
    jae .u8_ok
    lea rcx, [r8-1]                  ; incompleto: mostra so ate antes dele
.u8_ok:
    call say_g
    lea rsi, [msg_nl_g]
    mov ecx, 2
    call say_g
    xor ecx, ecx
    call [__imp_ExitProcess]
.erro_m:
    lea rsi, [msg_errm]
    mov ecx, msg_errm_len
    call say_g
    mov ecx, 1
    call [__imp_ExitProcess]
.sem_avx:
    lea rsi, [msg_avx_g]
    mov ecx, msg_avx_g_len
    call say_g
    mov ecx, 1
    call [__imp_ExitProcess]

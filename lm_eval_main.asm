bits 64
default rel
; ============ AVALIACAO DO MODELO DE LINGUAGEM EM TEXTO NAO VISTO ============
; So le: carrega os pesos de MODELO e percorre TEXTO byte a byte com o forward
; (sem treino, sem gravar nada). Informa a P(alvo) media e o acerto do argmax.
%include "lm_core.asm"

%ifndef MODELO
%define MODELO    "dados/modelo_lm.bin"
%endif
%ifndef TEXTO
%define TEXTO     "dados/pira_valid.tsv"
%endif
%define EVMAX     8388608            ; avalia no maximo 8 MB do texto

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ReadFile
extern __imp_CreateFileA
extern __imp_CloseHandle
extern __imp_ExitProcess

global main

section .data
align 8
path_m:      db MODELO, 0
path_t:      db TEXTO, 0
c_mil_e:     dq 1000.0
msg_am:      db "amostras: "
msg_am_len   equ $ - msg_am
msg_p:       db "  P(alvo) medio x1000: "
msg_p_len    equ $ - msg_p
msg_ac:      db "  acerto argmax x1000: "
msg_ac_len   equ $ - msg_ac
msg_nl_e:    db 13, 10
msg_errm:    db "erro: modelo ausente ou de tamanho errado (esperado float32)", 13, 10
msg_errm_len equ $ - msg_errm
msg_errt:    db "erro: texto de avaliacao ausente ou curto demais", 13, 10
msg_errt_len equ $ - msg_errt
msg_avx_e:   db "CPU sem AVX2/FMA", 13, 10
msg_avx_e_len equ $ - msg_avx_e

section .bss
alignb 16
hout_e:     resq 1
wrote_e:    resd 1
hfile_e:    resq 1
numbuf_e:   resb 24
tlen:       resq 1
idx_e:      resq 1
soma_e:     resq 1                   ; soma de P(alvo) (double)
acertos:    resq 1
tbuf:       resb EVMAX

section .text

say_e:
    sub rsp, 56
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [hout_e]
    lea r9, [wrote_e]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 56
    ret

print_e:                             ; rax -> stdout (decimal)
    push rsi                         ; rsi e rdi sao preservados pela convencao x64
    push rdi
    sub rsp, 88
    lea rdi, [numbuf_e+20]
    mov rcx, 10
.pu:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .pu
    lea rax, [numbuf_e+20]
    sub rax, rdi
    mov rcx, rax
    mov rsi, rdi
    call say_e
    add rsp, 88
    pop rdi
    pop rsi
    ret

; le_arquivo: rcx = caminho, rdx = destino, r8 = maximo -> rax = bytes lidos ou -1
le_arquivo:
    sub rsp, 72
    mov [rsp+56], rdx
    mov [rsp+64], r8
    mov edx, 0x80000000              ; GENERIC_READ
    mov r8d, 1                       ; FILE_SHARE_READ
    xor r9d, r9d
    mov qword [rsp+32], 3            ; OPEN_EXISTING
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .fim
    mov [hfile_e], rax
    mov rcx, rax
    mov rdx, [rsp+56]
    mov r8, [rsp+64]
    lea r9, [wrote_e]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    mov rcx, [hfile_e]
    call [__imp_CloseHandle]
    mov eax, [wrote_e]
.fim:
    add rsp, 72
    ret

main:
    sub rsp, 88
    call set_ftz
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout_e], rax
    call check_avx2
    test eax, eax
    jz .sem_avx
    ; pesos float32: o arquivo precisa ter exatamente NP*4 bytes (um modelo double tem o dobro)
    lea rcx, [path_m]
    lea rdx, [tbuf]
    mov r8d, NP*4+1
    call le_arquivo
    cmp rax, NP*4
    jne .erro_m
    lea rsi, [tbuf]
    lea rdi, [PAR]
    mov ecx, NP
    rep movsd
    ; texto
    lea rcx, [path_t]
    lea rdx, [tbuf]
    mov r8d, EVMAX
    call le_arquivo
    cmp rax, -1
    je .erro_t
    cmp rax, NCTX+1
    jb .erro_t
    mov [tlen], rax
    mov qword [soma_e], 0
    mov qword [acertos], 0
    mov qword [idx_e], NCTX
.l:
    mov rax, [idx_e]
    cmp rax, [tlen]
    jae .fim
    lea rcx, [tbuf]
    lea rdx, [rcx+rax-NCTX]
    mov [ctxp], rdx
    movzx edx, byte [rcx+rax]
    mov [tgt], rdx
    call forward_lm
    mov rax, [tgt]
    lea rcx, [Pv]
    movss xmm0, [rcx+rax*4]
    cvtss2sd xmm0, xmm0
    addsd xmm0, [soma_e]
    movsd [soma_e], xmm0
    call argmax_lm
    cmp rax, [tgt]
    jne .n
    inc qword [acertos]
.n:
    inc qword [idx_e]
    jmp .l
.fim:
    mov r12, [tlen]
    sub r12, NCTX                    ; amostras avaliadas
    lea rsi, [msg_am]
    mov ecx, msg_am_len
    call say_e
    mov rax, r12
    call print_e
    lea rsi, [msg_p]
    mov ecx, msg_p_len
    call say_e
    movsd xmm0, [soma_e]
    mulsd xmm0, [c_mil_e]
    cvtsi2sd xmm1, r12
    divsd xmm0, xmm1
    cvttsd2si rax, xmm0
    call print_e
    lea rsi, [msg_ac]
    mov ecx, msg_ac_len
    call say_e
    mov rax, [acertos]
    imul rax, rax, 1000
    xor edx, edx
    div r12
    call print_e
    lea rsi, [msg_nl_e]
    mov ecx, 2
    call say_e
    xor ecx, ecx
    call [__imp_ExitProcess]
.erro_m:
    lea rsi, [msg_errm]
    mov ecx, msg_errm_len
    call say_e
    mov ecx, 1
    call [__imp_ExitProcess]
.erro_t:
    lea rsi, [msg_errt]
    mov ecx, msg_errt_len
    call say_e
    mov ecx, 1
    call [__imp_ExitProcess]
.sem_avx:
    lea rsi, [msg_avx_e]
    mov ecx, msg_avx_e_len
    call say_e
    mov ecx, 1
    call [__imp_ExitProcess]

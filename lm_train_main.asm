default rel
; I/O e carga de texto (o antigo chat_core.asm nao existe mais; bloco autocontido)
%ifndef TEXTO_LM
%define TEXTO_LM  "dados/pira_valid.tsv"
%endif
%define TXTMAX_LM 16777216

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_CreateFileA
extern __imp_ReadFile
extern __imp_CloseHandle
extern __imp_ExitProcess

global main

section .data
align 8
msg_crlf:    db 13, 10
msg_semtexto_lm: db "erro: texto de treino ausente ou curto demais (opcao -DTEXTO_LM=arquivo na montagem)", 13, 10
msg_semtexto_lm_len equ $ - msg_semtexto_lm

section .bss
alignb 8
hout:       resq 1
wrote_lm:   resd 1
hfile_lm:   resq 1
txt:        resb TXTMAX_LM
txtn:       resq 1

section .text

; ---------- out_bytes: rsi = bytes, rcx = quantidade -> stdout --------------------------
out_bytes:
    sub rsp, 56
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [hout]
    lea r9, [wrote_lm]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 56
    ret

; ---------- load_all: carrega o texto (TEXTO_LM) em txt/txtn ----------------------------
load_all:
    sub rsp, 56
    lea rcx, [path_txt_l]
    mov edx, 0x80000000
    mov r8d, 1
    xor r9d, r9d
    mov qword [rsp+32], 3
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .fim
    mov [hfile_lm], rax
    mov rcx, rax
    lea rdx, [txt]
    mov r8d, TXTMAX_LM
    lea r9, [wrote_lm]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    mov rcx, [hfile_lm]
    call [__imp_CloseHandle]
    mov eax, [wrote_lm]
    mov [txtn], rax
.fim:
    add rsp, 56
    ret

section .data
align 8
path_txt_l:  db TEXTO_LM, 0

%include "lm_core.asm"

; ============ TREINO E GERACAO DO MODELO DE LINGUAGEM ============
; Treina por SGD sobre o texto do Pira (campos 1..3 de cada registro)
; e gera texto com decodificacao gulosa (argmax) a partir de um prefixo.
%define NTRAIN  200000              ; bytes de treino (limite)
%define NGEN    200                 ; bytes gerados
%define REPORT  20000               ; passos entre relatorios
%define EVALN   20000               ; bytes de texto nao visto para avaliar

section .data
align 8
c_1000b:    dq 1000.0
prompt:     db "Qual ", 0xC3, 0xA9, " o "      ; "Qual ?? o " (10 bytes >= NCTX)
prompt_len  equ $ - prompt
%if prompt_len < NCTX
%error "prompt de geracao deve ter pelo menos NCTX bytes (senao o contexto le antes do buffer)"
%endif
msg_r1:     db "passos: "
msg_r1_len  equ $ - msg_r1
msg_r2:     db "  P(alvo) medio x1000: "
msg_r2_len  equ $ - msg_r2
msg_r3:     db "  acerto argmax x1000: "
msg_r3_len  equ $ - msg_r3
msg_ev:     db "--- texto nao visto (sem atualizacao):", 13, 10
msg_ev_len  equ $ - msg_ev
msg_gen:    db "geracao: "
msg_gen_len equ $ - msg_gen

section .bss
align 8
gbuf:       resb 512
gl:         resq 1
gcount:     resq 1
steps:      resq 1
hits:       resq 1
sump:       resq 1
tcur:       resq 1
ntr:        resq 1
evend:      resq 1
numbuf:     resb 24

section .text

print_u:
    push rsi                         ; rsi e rdi sao preservados pela convencao x64
    push rdi
    sub rsp, 40
    lea rdi, [numbuf+20]
    mov rcx, 10
.pu:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .pu
    lea rax, [numbuf+20]
    sub rax, rdi
    mov rcx, rax
    mov rsi, rdi
    call out_bytes
    add rsp, 40
    pop rdi
    pop rsi
    ret

; ---------- report: estatisticas do treino at?? agora --------------------
report:
    sub rsp, 40
    cmp qword [steps], 0            ; sem passos nao ha medias (evita divisao por zero)
    je .rep_end
    lea rsi, [msg_r1]
    mov rcx, msg_r1_len
    call out_bytes
    mov rax, [steps]
    call print_u
    lea rsi, [msg_r2]
    mov rcx, msg_r2_len
    call out_bytes
    movsd xmm0, [sump]
    cvtsi2sd xmm1, qword [steps]
    divsd xmm0, xmm1
    mulsd xmm0, [c_1000b]
    cvttsd2si rax, xmm0
    call print_u
    lea rsi, [msg_r3]
    mov rcx, msg_r3_len
    call out_bytes
    mov rax, [hits]
    imul rax, rax, 1000
    xor edx, edx
    mov rcx, [steps]
    div rcx
    call print_u
    lea rsi, [msg_crlf]
    mov rcx, 2
    call out_bytes
.rep_end:
    add rsp, 40
    ret

main:
    sub rsp, 40
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout], rax

    call load_all
    cmp qword [txtn], NCTX+1
    jae .texto_ok
    lea rsi, [msg_semtexto_lm]
    mov rcx, msg_semtexto_lm_len
    call out_bytes
    mov ecx, 1
    call [__imp_ExitProcess]
.texto_ok:
    call init_params_lm

    ; treino: tcur percorre o texto a partir de NCTX
    mov rax, [txtn]
    mov rbx, NTRAIN
    cmp rax, rbx
    jbe .nt
    mov rax, rbx
.nt:
    mov [ntr], rax
    mov qword [steps], 0
    mov qword [hits], 0
    xorpd xmm0, xmm0
    movsd [sump], xmm0
    mov qword [tcur], NCTX
.tr:
    mov rax, [tcur]
    cmp rax, [ntr]
    jae .trd
    lea rbx, [txt]
    mov rcx, rax
    sub rcx, NCTX
    lea rdx, [rbx+rcx]
    mov [ctxp], rdx
    movzx ecx, byte [rbx+rax]
    mov [tgt], rcx

    call train_step                 ; Pv = previsao antes da atualizacao
    lea rcx, [Pv]
    mov rax, [tgt]
    movss xmm0, [rcx+rax*4]         ; P(alvo) e float32
    cvtss2sd xmm0, xmm0
    movsd xmm1, [sump]
    addsd xmm1, xmm0
    movsd [sump], xmm1
    call argmax_lm
    cmp rax, [tgt]
    jne .nh
    inc qword [hits]
.nh:
    inc qword [steps]
    mov rax, [steps]
    xor edx, edx
    mov rcx, REPORT
    div rcx
    test rdx, rdx
    jnz .np
    call report
.np:
    inc qword [tcur]
    jmp .tr
.trd:
    call report

    ; avaliacao em texto nao visto (sem atualizar pesos)
    lea rsi, [msg_ev]
    mov rcx, msg_ev_len
    call out_bytes
    xorpd xmm0, xmm0
    movsd [sump], xmm0
    mov qword [steps], 0
    mov qword [hits], 0
    mov rax, [ntr]
    mov [tcur], rax
    mov rax, [ntr]
    add rax, EVALN
    cmp rax, [txtn]
    jbe .ee
    mov rax, [txtn]
.ee:
    mov [evend], rax
.ev:
    mov rax, [tcur]
    cmp rax, [evend]
    jae .evd
    lea rbx, [txt]
    mov rcx, rax
    sub rcx, NCTX
    lea rdx, [rbx+rcx]
    mov [ctxp], rdx
    movzx ecx, byte [rbx+rax]
    mov [tgt], rcx
    call forward_lm
    lea rcx, [Pv]
    mov rax, [tgt]
    movss xmm0, [rcx+rax*4]         ; P(alvo) e float32
    cvtss2sd xmm0, xmm0
    movsd xmm1, [sump]
    addsd xmm1, xmm0
    movsd [sump], xmm1
    call argmax_lm
    cmp rax, [tgt]
    jne .evn
    inc qword [hits]
.evn:
    inc qword [steps]
    inc qword [tcur]
    jmp .ev
.evd:
    call report

    ; geracao por amostragem (temperatura c_temp) a partir do prefixo "Qual "
    lea rsi, [prompt]
    lea rdi, [gbuf]
    mov ecx, prompt_len
    rep movsb
    mov qword [gl], prompt_len
    mov qword [gcount], 0
.gen:
    cmp qword [gcount], NGEN
    jae .gend
    mov rax, [gl]
    sub rax, NCTX
    lea rbx, [gbuf]
    add rbx, rax
    mov [ctxp], rbx
    call forward_lm
    call sample_lm
    lea rbx, [gbuf]
    mov rcx, [gl]
    mov [rbx+rcx], al
    inc qword [gl]
    inc qword [gcount]
    jmp .gen
.gend:
    lea rsi, [msg_gen]
    mov rcx, msg_gen_len
    call out_bytes
    lea rsi, [gbuf]
    mov rcx, [gl]
    call out_bytes
    lea rsi, [msg_crlf]
    mov rcx, 2
    call out_bytes

    xor ecx, ecx
    call [__imp_ExitProcess]

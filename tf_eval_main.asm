bits 64
default rel
; ============ AVALIACAO DO TRANSFORMER EM TEXTO NAO VISTO ============
; So le: carrega os pesos de MODELO (e o VOCAB com -DTOK16) e percorre TEXTO (bytes, ou
; tokens uint16 com -DTOK16) em sequencias de TT+1 tokens com passo TT, como no treino.
; Informa a P(alvo) media e o acerto do argmax por token, e os bits por byte
; (-log2 P somado / bytes previstos), que comparam modelos com tokenizacoes diferentes.
%include "tf_gen_core.asm"

%ifndef TEXTO
%define TEXTO     "dados/pira_valid.tsv"
%endif
%define EVMAX     8388608

global main

section .data
align 8
path_t:      db TEXTO, 0
c_mil_e:     dq 1000.0
c_ln2_e:     dq 0.6931471805599453
msg_am:      db "tokens: "
msg_am_len   equ $ - msg_am
msg_p:       db "  P(alvo) medio x1000: "
msg_p_len    equ $ - msg_p
msg_ac:      db "  acerto argmax x1000: "
msg_ac_len   equ $ - msg_ac
msg_bpb:     db "  bits por byte x1000: "
msg_bpb_len  equ $ - msg_bpb
msg_nl_e:    db 13, 10
msg_errt:    db "erro: texto de avaliacao ausente ou curto demais", 13, 10
msg_errt_len equ $ - msg_errt
msg_corta:   db "aviso: texto maior que 8 MB; avaliando so os primeiros 8 MB", 13, 10
msg_corta_len equ $ - msg_corta

section .bss
alignb 16
numbuf_e:   resb 24
tlen:       resq 1                   ; tokens no texto
spos:       resq 1
amostras:   resq 1
soma_e:     resq 1
nats:       resq 1                   ; soma de -ln P(alvo)
bytes_e:    resq 1                   ; bytes dos alvos
acertos:    resq 1
tbuf:       resb EVMAX + 8

section .text

print_e:
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
    call gc_say
    add rsp, 88
    ret

main:
    sub rsp, 88
    call gc_inicia
    lea rcx, [path_t]
    lea rdx, [tbuf]
    mov r8d, EVMAX+1
    call gc_le_arq
    cmp rax, -1
    je .erro_t
    cmp rax, EVMAX
    jbe .tam_ok
    lea rsi, [msg_corta]
    mov ecx, msg_corta_len
    call gc_say
    mov rax, EVMAX
.tam_ok:
    xor edx, edx
    mov ecx, TB
    div rcx                          ; bytes -> tokens
    cmp rax, TT+1
    jb .erro_t
    mov [tlen], rax
.seq:
    mov rax, [tlen]
    sub rax, [spos]
    cmp rax, TT+1
    jb .fim
    lea rax, [tbuf]
    mov rcx, [spos]
    imul rcx, rcx, TB
    add rax, rcx
    mov [r15+TX_tf_tok], rax
    call tf_forward
    movsd xmm0, [soma_e]
    addsd xmm0, [r15+TX_tf_pal]
    movsd [soma_e], xmm0
    xor r12d, r12d
.pos:
    cmp r12, TT
    jae .pos_ok
    mov rax, r12
    imul rax, rax, TV
    lea rsi, [r15+TX_A_PR]
    lea rsi, [rsi+rax*4]
    ; alvo da posicao
    mov rax, [r15+TX_tf_tok]
%ifdef TOK16
    movzx r13d, word [rax+r12*2+2]
    lea rax, [gc_vlen]
    mov eax, [rax+r13*4]
    add [bytes_e], rax
%else
    movzx r13d, byte [rax+r12+1]
    inc qword [bytes_e]
%endif
    ; -ln P(alvo)
    movss xmm0, [rsi+r13*4]
    comiss xmm0, [gc_tiny]
    ja .ln_ok
    movss xmm0, [gc_tiny]
.ln_ok:
    call tf_ln
    cvtss2sd xmm0, xmm0
    movsd xmm1, [nats]
    subsd xmm1, xmm0
    movsd [nats], xmm1
    ; acerto do argmax
    movss xmm0, [rsi]
    xor ecx, ecx
    mov edx, 1
.am:
    cmp edx, TV
    jae .am_ok
    movss xmm1, [rsi+rdx*4]
    comiss xmm1, xmm0
    jbe .am_n
    movss xmm0, xmm1
    mov ecx, edx
.am_n:
    inc edx
    jmp .am
.am_ok:
    cmp ecx, r13d
    jne .pos_n
    inc qword [acertos]
.pos_n:
    inc r12
    jmp .pos
.pos_ok:
    add qword [amostras], TT
    add qword [spos], TT
    jmp .seq
.fim:
    mov r12, [amostras]
    lea rsi, [msg_am]
    mov ecx, msg_am_len
    call gc_say
    mov rax, r12
    call print_e
    lea rsi, [msg_p]
    mov ecx, msg_p_len
    call gc_say
    movsd xmm0, [soma_e]
    mulsd xmm0, [c_mil_e]
    cvtsi2sd xmm1, r12
    divsd xmm0, xmm1
    cvttsd2si rax, xmm0
    call print_e
    lea rsi, [msg_ac]
    mov ecx, msg_ac_len
    call gc_say
    mov rax, [acertos]
    imul rax, rax, 1000
    xor edx, edx
    div r12
    call print_e
    lea rsi, [msg_bpb]
    mov ecx, msg_bpb_len
    call gc_say
    movsd xmm0, [nats]
    divsd xmm0, [c_ln2_e]
    mulsd xmm0, [c_mil_e]
    mov rax, [bytes_e]
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    cvttsd2si rax, xmm0
    call print_e
    lea rsi, [msg_nl_e]
    mov ecx, 2
    call gc_say
    xor ecx, ecx
    call [__imp_ExitProcess]
.erro_t:
    lea rsi, [msg_errt]
    mov ecx, msg_errt_len
    call gc_say
    mov ecx, 1
    call [__imp_ExitProcess]

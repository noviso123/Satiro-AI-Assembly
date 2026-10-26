bits 64
default rel
; ============ GERACAO COM O TRANSFORMER (nucleo do gerador e do chat) ============
; So le os pesos de MODELO (e o vocabulario BPE com -DTOK16). tf_proximo escolhe o
; proximo token a partir dos ultimos TT tokens. Amostragem configuravel na linha de
; comando:
;   -t T   temperatura (padrao 0.8; 0 = sempre o mais provavel)
;   -k K   so os K tokens mais provaveis (padrao 40)
;   -p P   nucleo: os mais provaveis ate somar P da massa (padrao 0.95)
;   -r R   penalidade de repeticao para os ultimos RJAN tokens (padrao 1 = desligada;
;          faz sentido com BPE, nao com bytes)
;   -s S   semente da amostragem (padrao: relogio)
;   -n N   tokens a gerar (so no gerador)
;   -g     guloso (o mesmo que -t 0)
; -DGULOSO e -DSEMENTE=n continuam valendo como padrao de compilacao.
%include "tf_model.asm"

%ifndef MODELO
%define MODELO    "dados/modelo_tf.bin"
%endif
%ifndef VOCAB
%define VOCAB     "dados/vocab_bpe.bin"
%endif
%define RJAN      64                 ; janela da penalidade de repeticao
%define HS        16384              ; tabela de pares do BPE (potencia de 2, > 2*TV)
%define POOLMAX   1048576            ; bytes de todos os tokens do vocabulario

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ReadFile
extern __imp_CreateFileA
extern __imp_CloseHandle
extern __imp_SetConsoleCP
extern __imp_SetConsoleOutputCP
extern __imp_GetTickCount64
extern __imp_GetCommandLineA
extern __imp_ExitProcess

%include "tf_sistema.asm"

section .data
align 8
gc_path_m:   db MODELO, 0
gc_path_v:   db VOCAB, 0
gc_2m24:     dd 5.9604644775390625e-8 ; 2^-24
gc_dec:      dd 0.1
gc_tiny:     dd 1.0e-30
gc_tmin:     dd 0.01
gc_temp:     dd 0.8
gc_topp:     dd 0.95
gc_rep:      dd 1.0
align 8
gc_topk:     dq 40
gc_ngen:     dq 0                    ; 0 = padrao do programa
gc_ctx:      dq TT                   ; contexto usado (tokens anteriores vistos), 1..TT (opcao -c)
%ifdef GULOSO
gc_guloso:   dq 1
%else
gc_guloso:   dq 0
%endif
gc_semente:  dq 0                    ; 1 = -s na linha de comando
gc_errm:     db "erro: modelo do transformer ausente ou de tamanho errado", 13, 10
gc_errm_len  equ $ - gc_errm
gc_errv:     db "erro: vocabulario BPE ausente ou incompativel com o modelo", 13, 10
gc_errv_len  equ $ - gc_errv

section .bss
alignb 16
gc_hout:    resq 1
gc_hin:     resq 1
gc_wrote:   resd 1
gc_hfile:   resq 1
gc_seed:    resq 1
gc_invt:    resd 1
gc_lnrep:   resd 1
gc_lnmax:   resd 1
gc_tot:     resd 1
gc_cum:     resd 1
gc_lim:     resd 1
gc_best:    resd 1
gc_win:     resb (TT + 16) * TB
gc_pw:      resd TV
gc_vis:     resb TV
gc_sel:     resb TV
gc_mbuf:    resb TNP*4 + 16
%ifdef TOK16
gc_va:      resd TV                  ; par que forma cada token (a, b)
gc_vb:      resd TV
gc_vlen:    resd TV                  ; bytes de cada token
gc_voff:    resd TV                  ; inicio no pool
gc_pool:    resb POOLMAX
gc_hkey:    resd HS                  ; (a<<16 | b) + 1; 0 = vazio
gc_hval:    resd HS
gc_vbuf:    resb 8 + TV*4 + 16
%endif

section .text

; ---------- gc_say: rsi = bytes, rcx = quantidade -> saida padrao ----------------------
gc_say:
    sub rsp, 56
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [gc_hout]
    lea r9, [gc_wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 56
    ret

; ---------- gc_say_utf8: como gc_say, mas nao corta um caractere UTF-8 no fim ------------
gc_say_utf8:
    mov r8, rcx
    xor r9d, r9d
.u8:
    test r8, r8
    jz .ok
    cmp r9d, 4
    jae .ok
    movzx eax, byte [rsi+r8-1]
    mov edx, eax
    and edx, 0xC0
    cmp edx, 0x80
    jne .lead                        ; nao e byte de continuacao (10xxxxxx)
    dec r8
    inc r9d
    jmp .u8
.lead:
    cmp eax, 0x80
    jb .ok                           ; ASCII: completo
    mov edx, 2
    cmp eax, 0xE0
    jb .t
    mov edx, 3
    cmp eax, 0xF0
    jb .t
    mov edx, 4
.t:
    mov r10, rcx
    sub r10, r8
    inc r10                          ; bytes do inicio do caractere ate o fim
    cmp r10, rdx
    jae .ok
    lea rcx, [r8-1]                  ; incompleto: mostra so ate antes dele
.ok:
    jmp gc_say

; ---------- gc_num: le um numero decimal em rsi ("12", "0.8", "0,8") ---------------------
; rax = parte inteira, xmm0 = valor; rsi avanca.
gc_num:
    xor eax, eax
.i:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .ip
    imul rax, rax, 10
    add rax, rcx
    inc rsi
    jmp .i
.ip:
    cvtsi2ss xmm0, rax
    cmp byte [rsi], '.'
    je .fr0
    cmp byte [rsi], ','
    jne .f
.fr0:
    inc rsi
    movss xmm1, [gc_dec]
.fr:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .f
    cvtsi2ss xmm2, ecx
    mulss xmm2, xmm1
    addss xmm0, xmm2
    mulss xmm1, [gc_dec]
    inc rsi
    jmp .fr
.f:
    ret

; ---------- gc_args: le as opcoes da linha de comando ------------------------------------
gc_args:
    push rbx
    push rsi
    sub rsp, 32
    call [__imp_GetCommandLineA]
    mov rsi, rax
    cmp byte [rsi], '"'
    jne .nome
    inc rsi
.q:
    mov al, [rsi]
    test al, al
    jz .fim
    inc rsi
    cmp al, '"'
    jne .q
    jmp .tok
.nome:
    mov al, [rsi]
    test al, al
    jz .fim
    cmp al, ' '
    je .tok
    inc rsi
    jmp .nome
.tok:
    mov al, [rsi]
    test al, al
    jz .fim
    cmp al, ' '
    je .esp
    cmp al, 9
    je .esp
    cmp al, '-'
    jne .palavra
    movzx ebx, byte [rsi+1]
    test bl, bl
    jz .fim
    add rsi, 2
    cmp bl, 'g'
    je .g
.ev:                                 ; espacos antes do valor
    cmp byte [rsi], ' '
    jne .val
    inc rsi
    jmp .ev
.val:
    call gc_num
    cmp bl, 't'
    jne .nk
    movss [gc_temp], xmm0
    jmp .tok
.nk:
    cmp bl, 'k'
    jne .np
    mov [gc_topk], rax
    jmp .tok
.np:
    cmp bl, 'p'
    jne .nr
    movss [gc_topp], xmm0
    jmp .tok
.nr:
    cmp bl, 'r'
    jne .ns
    movss [gc_rep], xmm0
    jmp .tok
.ns:
    cmp bl, 's'
    jne .nc
    or rax, 1
    mov [gc_seed], rax
    mov qword [gc_semente], 1
    jmp .tok
.nc:
    cmp bl, 'c'
    jne .nn
    mov [gc_ctx], rax
    jmp .tok
.nn:
    cmp bl, 'n'
    jne .tok
    mov [gc_ngen], rax
    jmp .tok
.g:
    mov qword [gc_guloso], 1
    jmp .tok
.esp:
    inc rsi
    jmp .tok
.palavra:
    mov al, [rsi]
    test al, al
    jz .fim
    cmp al, ' '
    je .tok
    inc rsi
    jmp .palavra
.fim:
    add rsp, 32
    pop rsi
    pop rbx
    ret

; ---------- gc_le_arq: rcx = caminho, rdx = destino, r8 = maximo -> rax = bytes ou -1 ----
gc_le_arq:
    sub rsp, 72
    mov [rsp+56], rdx
    mov [rsp+64], r8
    mov edx, 0x80000000
    mov r8d, 1
    xor r9d, r9d
    mov qword [rsp+32], 3
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .fim
    mov [gc_hfile], rax
    mov rcx, rax
    mov rdx, [rsp+56]
    mov r8, [rsp+64]
    lea r9, [gc_wrote]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    mov rcx, [gc_hfile]
    call [__imp_CloseHandle]
    mov eax, [gc_wrote]
.fim:
    add rsp, 72
    ret

; ---------- gc_inicia: console UTF-8, FTZ/DAZ, opcoes, semente, pesos e vocabulario -----
gc_inicia:
    sub rsp, 72
    call sis_inicia                  ; CPU (AVX2/FMA), pasta do projeto e threads
    sub rsp, 8
    db 0x0F, 0xAE, 0x1C, 0x24        ; stmxcsr [rsp]
    or dword [rsp], 0x8040
    db 0x0F, 0xAE, 0x14, 0x24        ; ldmxcsr [rsp]
    add rsp, 8
    mov ecx, 65001
    call [__imp_SetConsoleCP]
    mov ecx, 65001
    call [__imp_SetConsoleOutputCP]
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [gc_hout], rax
    mov ecx, -10
    call [__imp_GetStdHandle]
    mov [gc_hin], rax
%ifdef SEMENTE
    mov rax, SEMENTE
%else
    call [__imp_GetTickCount64]
%endif
    or rax, 1                        ; xorshift nao pode partir de zero
    mov [gc_seed], rax
    call gc_args
    ; contexto dentro dos limites do modelo: 1..TT
    mov rax, [gc_ctx]
    cmp rax, TT
    jbe .ctx_max
    mov eax, TT
.ctx_max:
    test rax, rax
    jnz .ctx_min
    mov eax, 1
.ctx_min:
    mov [gc_ctx], rax
    ; temperatura muito baixa = guloso; 1/T e ln(R) para a amostragem
    movss xmm0, [gc_temp]
    comiss xmm0, [gc_tmin]
    jae .t_ok
    mov qword [gc_guloso], 1
    movss xmm0, [tf_one]
.t_ok:
    movss xmm1, [tf_one]
    divss xmm1, xmm0
    movss [gc_invt], xmm1
    movss xmm0, [gc_rep]
    comiss xmm0, [tf_one]
    jae .r_ok
    movss xmm0, [tf_one]
    movss [gc_rep], xmm0
.r_ok:
    call tf_ln
    movss [gc_lnrep], xmm0
    ; pesos: o arquivo precisa ter exatamente TNP*4 bytes
    lea rcx, [gc_path_m]
    lea rdx, [gc_mbuf]
    mov r8d, TNP*4+1
    call gc_le_arq
    cmp rax, TNP*4
    jne .erro
    lea rsi, [gc_mbuf]
    lea rdi, [TPAR]
    mov ecx, TNP
    rep movsd
%ifdef TOK16
    call gc_vocab
%endif
    lea r15, [TCTX]
    add rsp, 72
    ret
.erro:
    lea rsi, [gc_errm]
    mov ecx, gc_errm_len
    call gc_say
    mov ecx, 1
    call [__imp_ExitProcess]

%ifdef TOK16
; ---------- gc_vocab: le VOCAB ("BPE1", TV, pares dos tokens 256..TV-1) e monta as tabelas
gc_vocab:
    push rbx
    push r12
    sub rsp, 40
    lea rcx, [gc_path_v]
    lea rdx, [gc_vbuf]
    mov r8d, 8 + TV*4 + 1
    call gc_le_arq
    cmp rax, 8 + (TV-256)*4
    jne .erro
    lea rbx, [gc_vbuf]
    cmp dword [rbx], 0x31455042      ; "BPE1"
    jne .erro
    cmp dword [rbx+4], TV
    jne .erro
    ; bytes: tokens 0..255
    lea rdi, [gc_pool]
    xor ecx, ecx
.b:
    lea rax, [gc_pool]
    mov [rax+rcx], cl
    lea rax, [gc_voff]
    mov [rax+rcx*4], ecx
    lea rax, [gc_vlen]
    mov dword [rax+rcx*4], 1
    lea rax, [gc_va]
    mov dword [rax+rcx*4], -1
    inc ecx
    cmp ecx, 256
    jb .b
    mov r12d, 256                    ; proximo livre no pool
    mov ecx, 256
.m:
    cmp ecx, TV
    jae .ok
    lea rax, [rbx+8]
    lea rdx, [rcx-256]
    movzx r8d, word [rax+rdx*4]      ; a
    movzx r9d, word [rax+rdx*4+2]    ; b
    cmp r8d, ecx
    jae .erro                        ; partes precisam vir antes
    cmp r9d, ecx
    jae .erro
    lea rax, [gc_va]
    mov [rax+rcx*4], r8d
    lea rax, [gc_vb]
    mov [rax+rcx*4], r9d
    ; texto do token = texto(a) + texto(b)
    lea rax, [gc_vlen]
    mov r10d, [rax+r8*4]
    add r10d, [rax+r9*4]
    mov [rax+rcx*4], r10d
    mov eax, r12d
    add eax, r10d
    cmp eax, POOLMAX
    ja .erro
    lea rax, [gc_voff]
    mov [rax+rcx*4], r12d
    push rcx
    lea rdi, [gc_pool]
    add rdi, r12
    lea rax, [gc_voff]
    mov esi, [rax+r8*4]
    lea rdx, [gc_pool]
    add rsi, rdx
    lea rax, [gc_vlen]
    mov ecx, [rax+r8*4]
    rep movsb
    lea rax, [gc_voff]
    mov esi, [rax+r9*4]
    add rsi, rdx
    lea rax, [gc_vlen]
    mov ecx, [rax+r9*4]
    rep movsb
    pop rcx
    add r12d, r10d
    ; tabela de pares
    mov eax, r8d
    shl eax, 16
    or eax, r9d
    inc eax                          ; chave (nunca 0)
    mov r10d, eax
    imul eax, eax, 0x045D9F3B
    shr eax, 18                      ; 14 bits
.h:
    lea rdx, [gc_hkey]
    cmp dword [rdx+rax*4], 0
    je .hlivre
    inc eax
    and eax, HS-1
    jmp .h
.hlivre:
    mov [rdx+rax*4], r10d
    lea rdx, [gc_hval]
    mov [rdx+rax*4], ecx
    inc ecx
    jmp .m
.ok:
    add rsp, 40
    pop r12
    pop rbx
    ret
.erro:
    lea rsi, [gc_errv]
    mov ecx, gc_errv_len
    call gc_say
    mov ecx, 1
    call [__imp_ExitProcess]

; ---------- gc_par: eax = a, edx = b -> eax = token do par ou -1 ---------------------------
gc_par:
    shl eax, 16
    or eax, edx
    inc eax
    mov r10d, eax
    imul eax, eax, 0x045D9F3B
    shr eax, 18
.h:
    lea rdx, [gc_hkey]
    mov r11d, [rdx+rax*4]
    test r11d, r11d
    jz .nao
    cmp r11d, r10d
    je .sim
    inc eax
    and eax, HS-1
    jmp .h
.sim:
    lea rdx, [gc_hval]
    mov eax, [rdx+rax*4]
    ret
.nao:
    mov eax, -1
    ret
%endif

; ---------- gc_codifica: rsi = bytes, rcx = n, rdi = tokens (TB bytes cada) -> rax = tokens
; Com BPE aplica as fusoes em ordem (o par de menor indice primeiro), como no treino.
gc_codifica:
%ifndef TOK16
    mov rax, rcx
    rep movsb
    ret
%else
    push rbx
    push r12
    push r13
    push r14
    push rdi
    mov r12, rdi                     ; tokens
    xor eax, eax
.cp:
    cmp rax, rcx
    jae .cpd
    movzx edx, byte [rsi+rax]
    mov [r12+rax*2], dx
    inc rax
    jmp .cp
.cpd:
    mov r13, rcx                     ; n
.passo:
    cmp r13, 2
    jb .fim
    mov ebx, -1                      ; melhor token (menor indice)
    xor r14d, r14d
.busca:
    lea rax, [r14+1]
    cmp rax, r13
    jae .achou
    movzx eax, word [r12+r14*2]
    movzx edx, word [r12+r14*2+2]
    call gc_par
    cmp eax, ebx
    jae .bn                          ; -1 (sem par) e maior que tudo sem sinal
    mov ebx, eax
.bn:
    inc r14
    jmp .busca
.achou:
    cmp ebx, -1
    je .fim
    lea rax, [gc_va]
    mov r8d, [rax+rbx*4]
    lea rax, [gc_vb]
    mov r9d, [rax+rbx*4]
    xor ecx, ecx                     ; leitura
    xor edx, edx                     ; escrita
.junta:
    cmp rcx, r13
    jae .jd
    movzx eax, word [r12+rcx*2]
    lea r10, [rcx+1]
    cmp r10, r13
    jae .copia
    cmp eax, r8d
    jne .copia
    movzx r11d, word [r12+rcx*2+2]
    cmp r11d, r9d
    jne .copia
    mov [r12+rdx*2], bx
    add rcx, 2
    inc rdx
    jmp .junta
.copia:
    mov [r12+rdx*2], ax
    inc rcx
    inc rdx
    jmp .junta
.jd:
    mov r13, rdx
    jmp .passo
.fim:
    mov rax, r13
    pop rdi
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
%endif

; ---------- gc_decodifica: ecx = token, rdi = destino -> rax = bytes (rdi avanca) ---------
gc_decodifica:
%ifndef TOK16
    mov [rdi], cl
    inc rdi
    mov eax, 1
    ret
%else
    push rsi
    lea rax, [gc_voff]
    mov esi, [rax+rcx*4]
    lea rax, [gc_pool]
    add rsi, rax
    lea rax, [gc_vlen]
    mov eax, [rax+rcx*4]
    mov ecx, eax
    rep movsb
    pop rsi
    ret
%endif

; ---------- gc_rand01: xmm0 em [0,1) (xorshift64*) ---------------------------------------
gc_rand01:
    mov rax, [gc_seed]
    mov rdx, rax
    shr rdx, 12
    xor rax, rdx
    mov rdx, rax
    shl rdx, 25
    xor rax, rdx
    mov rdx, rax
    shr rdx, 27
    xor rax, rdx
    mov [gc_seed], rax
    mov rdx, 0x2545F4914F6CDD1D
    imul rax, rdx
    shr rax, 40                      ; 24 bits
    cvtsi2ss xmm0, eax
    mulss xmm0, [gc_2m24]
    ret

; ---------- tf_proximo: rsi = tokens, rcx = quantos (>= 1) -> eax = proximo token ---------
; A janela sao os ultimos TT tokens; com menos, o resto fica zerado (a atencao e causal,
; entao a linha do ultimo token real nao ve o enchimento).
tf_proximo:
    push rbx
    push r12
    push r13
    push r14
    push rsi
    push rdi
    sub rsp, 40
    mov r12, rcx
    cmp r12, [gc_ctx]
    jbe .cp
    mov rax, r12
    sub rax, [gc_ctx]
    imul rax, rax, TB
    add rsi, rax
    mov r12, [gc_ctx]
.cp:
    lea rdi, [gc_win]
    mov rcx, r12
    imul rcx, rcx, TB
    rep movsb
    mov ecx, TT+1
    sub rcx, r12
    imul rcx, rcx, TB
    xor eax, eax
    rep stosb
    lea rax, [gc_win]
    mov [r15+TX_tf_tok], rax
    call tf_forward
    lea rbx, [r15+TX_A_PR]
    mov rax, r12
    dec rax
    imul rax, rax, TV*4
    add rbx, rax                     ; probabilidades do proximo token
    ; maior probabilidade (e o seu token)
    movss xmm2, [rbx]
    xor r13d, r13d
    mov ecx, 1
.mx:
    movss xmm0, [rbx+rcx*4]
    comiss xmm0, xmm2
    jbe .mxn
    movss xmm2, xmm0
    mov r13d, ecx
.mxn:
    inc ecx
    cmp ecx, TV
    jb .mx
    cmp qword [gc_guloso], 0
    jne .argmax
    movss xmm0, xmm2
    call tf_ln
    movss [gc_lnmax], xmm0
    ; tokens recentes (penalidade de repeticao)
    lea rdi, [gc_vis]
    mov ecx, TV
    xor eax, eax
    rep stosb
    movss xmm0, [gc_rep]
    comiss xmm0, [tf_one]
    jbe .pesos
    mov rcx, r12
    sub rcx, RJAN
    jge .vj
    xor ecx, ecx
.vj:
    cmp rcx, r12
    jae .pesos
    lea rdx, [gc_win]
%ifdef TOK16
    movzx eax, word [rdx+rcx*2]
%else
    movzx eax, byte [rdx+rcx]
%endif
    lea rdx, [gc_vis]
    mov byte [rdx+rax], 1
    inc rcx
    jmp .vj
    ; pesos w = exp((ln p - ln pmax - [visto] ln R) / T)
.pesos:
    xorps xmm0, xmm0
    movss [gc_tot], xmm0
    xor r14d, r14d
.w:
    movss xmm0, [rbx+r14*4]
    comiss xmm0, [gc_tiny]
    ja .wl
    xorps xmm0, xmm0
    jmp .ws
.wl:
    call tf_ln
    subss xmm0, [gc_lnmax]
    lea rax, [gc_vis]
    cmp byte [rax+r14], 0
    je .wv
    subss xmm0, [gc_lnrep]
.wv:
    mulss xmm0, [gc_invt]
    call tf_exp
.ws:
    lea rax, [gc_pw]
    movss [rax+r14*4], xmm0
    addss xmm0, [gc_tot]
    movss [gc_tot], xmm0
    inc r14
    cmp r14, TV
    jb .w
    ; nucleo: escolhe os maiores ate K tokens ou P da massa
    lea rdi, [gc_sel]
    mov ecx, TV
    xor eax, eax
    rep stosb
    xorps xmm0, xmm0
    movss [gc_cum], xmm0
    movss xmm0, [gc_tot]
    mulss xmm0, [gc_topp]
    movss [gc_lim], xmm0
    xor r14d, r14d                   ; escolhidos
.sel:
    cmp r14, [gc_topk]
    jae .sorteia
    movss xmm0, [gc_cum]
    comiss xmm0, [gc_lim]
    jae .sorteia
    mov edx, -1
    xorps xmm1, xmm1                 ; maior peso ainda livre
    lea r8, [gc_pw]
    lea r9, [gc_sel]
    xor ecx, ecx
.sm:
    cmp byte [r9+rcx], 0
    jne .smn
    movss xmm0, [r8+rcx*4]
    comiss xmm0, xmm1
    jbe .smn
    movss xmm1, xmm0
    mov edx, ecx
.smn:
    inc ecx
    cmp ecx, TV
    jb .sm
    cmp edx, -1
    je .sorteia
    mov byte [r9+rdx], 1
    addss xmm1, [gc_cum]
    movss [gc_cum], xmm1
    inc r14
    jmp .sel
.sorteia:
    call gc_rand01
    mulss xmm0, [gc_cum]
    xorps xmm1, xmm1
    lea r8, [gc_pw]
    lea r9, [gc_sel]
    xor ecx, ecx
.c:
    cmp byte [r9+rcx], 0
    je .cn
    addss xmm1, [r8+rcx*4]
    comiss xmm1, xmm0
    ja .hit
.cn:
    inc ecx
    cmp ecx, TV
    jb .c
.argmax:
    mov eax, r13d                    ; guloso, ou arredondamento: o mais provavel
    jmp .fim
.hit:
    mov eax, ecx
.fim:
    add rsp, 40
    pop rdi
    pop rsi
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

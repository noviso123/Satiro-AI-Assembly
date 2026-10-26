default rel
%ifdef MUTANT_SIGN
%define SGN addss          ; mutante de teste: sinal invertido no backprop
%else
%define SGN subss
%endif

; ============ NUCLEO DO MODELO DE LINGUAGEM (por bytes UTF-8) ============
; Janela de NCTX bytes -> embeddings (NEMB) -> camada oculta tanh (NHID)
; -> softmax sobre NVOC = 256 valores de byte.
; Os pesos (PAR) sao compartilhados e so lidos durante o forward/backward.
; Cada execucao tem um bloco de contexto (apontado por r15) com as
; ativacoes, os deltas e o gradiente acumulado G. Assim cada thread trabalha
; no seu bloco, sem disputa. Requisito: CPU com AVX2 e FMA (ver check_avx2).
;
; API:
;   train_step   SGD em uma amostra (usa ctx0; ctxp/tgt devem estar definidos)
;   train_batch  SGD em lote, com NTHREADS threads (init_workers antes)
;   forward_lm / argmax_lm / sample_lm  usam ctx0 (avaliacao e geracao)

%ifndef LR_BATCH
%define LR_BATCH 0.1                ; taxa do SGD em lote (-DLR_BATCH=... para ajustar)
%endif

%ifndef NTHREADS
%define NTHREADS 8
%endif

; tamanho do modelo (configuravel por -D): NHID precisa ser multiplo de 8
%ifndef NCTX
%define NCTX    8                   ; bytes de contexto
%endif
%ifndef NEMB
%define NEMB    16                  ; dimensao do embedding de cada byte
%endif
%define NIN     (NCTX*NEMB)         ; 128 no padrao
%ifndef NHID
%define NHID    64                  ; neuronios da camada oculta
%endif
%define NVOC    256
%define OFF_W1  (NVOC*NEMB)
%define OFF_B1  (OFF_W1 + NHID*NIN)
%define OFF_W2  (OFF_B1 + NHID)
%define OFF_B2  (OFF_W2 + NVOC*NHID)
%define NP      (OFF_B2 + NVOC)     ; 28992 (multiplo de 4)

; deslocamentos no bloco de contexto (bytes)
%define CX_X     0
%define CX_H     (CX_X  + NIN*4)
%define CX_P     (CX_H  + NHID*4)
%define CX_L     (CX_P  + NVOC*4)
%define CX_DP    (CX_L  + NVOC*4)
%define CX_DH    (CX_DP + NVOC*4)
%define CX_DZ    (CX_DH + NHID*4)
%define CX_DX    (CX_DZ + NHID*4)
%define CX_MX    (CX_DX + NIN*4)
%define CX_SUM   (CX_MX + 8)
%define CX_RT    (CX_SUM + 8)
%define CX_CTXP  (CX_RT + 8)         ; ponteiro para os NCTX bytes de contexto
%define CX_TGT   (CX_CTXP + 8)       ; byte alvo
%define CX_LOSS  (CX_TGT + 8)        ; soma de P(alvo) no bloco
%define CX_START (CX_LOSS + 8)       ; evento: lote pronto para o worker
%define CX_DONE  (CX_START + 8)      ; evento: worker terminou o lote
%define CX_BASE  (CX_DONE + 8)       ; inicio do lote (amostra i: base+i)
%define CX_LO    (CX_BASE + 8)       ; primeira amostra do worker no lote
%define CX_N     (CX_LO + 8)         ; quantidade de amostras do worker
%define CX_G     (CX_N + 8)          ; gradiente acumulado (NP doubles)
%define CX_SIZE  (CX_G + NP*4)

extern __imp_CreateEventA
extern __imp_CreateThread
extern __imp_SetEvent
extern __imp_WaitForSingleObject
extern __imp_WaitForMultipleObjects

section .data
align 8
c_one:      dd 1.0
c_zero:     dd 0.0
c_neg1:     dd -1.0
c_two:      dd 2.0
c_30:       dd 30.0
c_neg30:    dd -30.0
c_inv256:   dd 0.00390625
c_inv2_32:  dd 2.3283064365386963e-10
c_lr_lm:    dd 0.01                 ; taxa do SGD por amostra (train_step)
c_lr_batch: dd LR_BATCH             ; taxa do SGD em lote (media do gradiente)
c_init:     dd 0.1
c_temp:     dd 0.8                  ; temperatura da amostragem
c_invn:     dd 1.0, 0.5, 0.3333333333333333, 0.25, 0.2, 0.16666666666666666, 0.14285714285714285, 0.125   ; 1/n
; constantes em vetor de 4 doubles (AVX)
c_one4:     times 8 dd 1.0
c_zerov:    times 8 dd 0.0
c_neg30v:   times 8 dd -30.0
c_15v:      times 8 dd 15.0
c_neg15v:   times 8 dd -15.0
c_inv256v:  times 8 dd 0.00390625
c_invn4:    times 8 dd 1.0
            times 8 dd 0.5
            times 8 dd 0.3333333333333333
            times 8 dd 0.25
            times 8 dd 0.2
            times 8 dd 0.16666666666666666
            times 8 dd 0.14285714285714285
            times 8 dd 0.125
%ifdef MUTANT_SIGN
c_upd:      dd 1.0                  ; sinal da atualizacao (mutante)
%else
c_upd:      dd -1.0                 ; SGD: parametro -= lr * grad
%endif
lm_seed:    dq 987654321

section .bss
alignb 32
PAR:        resd NP
ctx0:       resb CX_SIZE            ; bloco da thread principal (avaliacao, train_step)
alignb 32
wblock:     resb NTHREADS*CX_SIZE   ; bloco de cada worker
wdone:      resq NTHREADS           ; handles de "terminou" (para WaitForMultipleObjects)
loss_total: resq 1                  ; soma de P(alvo) de todos os lotes

; atalhos para o bloco ctx0 (usados pelos programas de teste e de treino)
%define Pv   (ctx0+CX_P)
%define tgt  (ctx0+CX_TGT)
%define ctxp (ctx0+CX_CTXP)

section .text

; ---------- check_avx2: eax = 1 se CPU e SO suportam AVX2 e FMA -----------
check_avx2:
    push rbx
    mov eax, 1
    xor ecx, ecx
    cpuid
    mov r8d, ecx
    and r8d, 0x19001000             ; OSXSAVE (27), AVX (28) e FMA (12)
    cmp r8d, 0x19001000
    jne .no
    xor ecx, ecx
    xgetbv                          ; SO habilita YMM (XCR0 bits 1 e 2)
    and eax, 6
    cmp eax, 6
    jne .no
    mov eax, 7
    xor ecx, ecx
    cpuid
    test ebx, 0x20                  ; AVX2 (bit 5 de EBX)
    jz .no
    mov eax, 1
    pop rbx
    ret
.no:
    xor eax, eax
    pop rbx
    ret

; ---------- dot_avx: rsi = a, rdi = b, ecx = n (multiplo de 8, floats) -> xmm0 ----
; Quatro acumuladores independentes (32 floats por volta): a latencia do FMA de
; uma cadeia fica escondida pelas outras tres.
dot_avx:
    vxorps ymm0, ymm0, ymm0
    vxorps ymm3, ymm3, ymm3
    vxorps ymm4, ymm4, ymm4
    vxorps ymm5, ymm5, ymm5
.da32:
    cmp ecx, 32
    jb .da
    vmovups ymm1, [rsi]
    vfmadd231ps ymm0, ymm1, [rdi]
    vmovups ymm1, [rsi+32]
    vfmadd231ps ymm3, ymm1, [rdi+32]
    vmovups ymm1, [rsi+64]
    vfmadd231ps ymm4, ymm1, [rdi+64]
    vmovups ymm1, [rsi+96]
    vfmadd231ps ymm5, ymm1, [rdi+96]
    add rsi, 128
    add rdi, 128
    sub ecx, 32
    jmp .da32
.da:
    cmp ecx, 8
    jb .da_fim
    vmovups ymm1, [rsi]
    vfmadd231ps ymm0, ymm1, [rdi]   ; ymm0 += ymm1 * [rdi]  (FMA)
    add rsi, 32
    add rdi, 32
    sub ecx, 8
    jmp .da
.da_fim:
    vaddps ymm0, ymm0, ymm3
    vaddps ymm4, ymm4, ymm5
    vaddps ymm0, ymm0, ymm4
    vextractf128 xmm1, ymm0, 1
    vaddps xmm0, xmm0, xmm1         ; 4 lanes
    vhaddps xmm0, xmm0, xmm0        ; pares
    vhaddps xmm0, xmm0, xmm0        ; soma das 4 lanes
    vzeroupper
    ret

; ---------- axpy_avx: dst(rdi) += xmm0 * src(rsi), ecx = n (multiplo de 8, floats) --
axpy_avx:
    vbroadcastss ymm2, xmm0
.ax16:
    cmp ecx, 16                     ; 16 floats por volta (dois FMAs)
    jb .ax
    vmovups ymm1, [rsi]
    vmovups ymm3, [rdi]
    vmovups ymm4, [rsi+32]
    vmovups ymm5, [rdi+32]
    vfmadd231ps ymm3, ymm1, ymm2
    vfmadd231ps ymm5, ymm4, ymm2
    vmovups [rdi], ymm3
    vmovups [rdi+32], ymm5
    add rsi, 64
    add rdi, 64
    sub ecx, 16
    jmp .ax16
.ax:
    cmp ecx, 8
    jb .ax_fim
    vmovups ymm1, [rsi]
    vmovups ymm3, [rdi]
    vfmadd231ps ymm3, ymm1, ymm2    ; ymm3 += ymm1 * s  (FMA)
    vmovups [rdi], ymm3
    add rsi, 32
    add rdi, 32
    sub ecx, 8
    jmp .ax
.ax_fim:
    vzeroupper
    ret

; ---------- exp4_avx: ymm0 = exp(ymm0), 4 valores em [-30,30] --------------
; Mesmo metodo do exp_fn (Taylor em y/256 com 8 termos + 8 quadrados), em
; 4 pistas paralelas: a latencia de uma cadeia nao atrasa as outras 3.
exp4_avx:
    vmulps ymm0, ymm0, [c_inv256v]  ; y' = y / 256
    vmovups ymm1, [c_one4]          ; termo = 1
    vmovups ymm2, [c_one4]          ; soma = 1
    vmulps ymm1, ymm1, ymm0
    vmulps ymm1, ymm1, [c_invn4+0]
    vaddps ymm2, ymm2, ymm1
    vmulps ymm1, ymm1, ymm0
    vmulps ymm1, ymm1, [c_invn4+32]
    vaddps ymm2, ymm2, ymm1
    vmulps ymm1, ymm1, ymm0
    vmulps ymm1, ymm1, [c_invn4+64]
    vaddps ymm2, ymm2, ymm1
    vmulps ymm1, ymm1, ymm0
    vmulps ymm1, ymm1, [c_invn4+96]
    vaddps ymm2, ymm2, ymm1
    vmulps ymm1, ymm1, ymm0
    vmulps ymm1, ymm1, [c_invn4+128]
    vaddps ymm2, ymm2, ymm1
    vmulps ymm1, ymm1, ymm0
    vmulps ymm1, ymm1, [c_invn4+160]
    vaddps ymm2, ymm2, ymm1
    vmulps ymm1, ymm1, ymm0
    vmulps ymm1, ymm1, [c_invn4+192]
    vaddps ymm2, ymm2, ymm1
    vmulps ymm1, ymm1, ymm0
    vmulps ymm1, ymm1, [c_invn4+224]
    vaddps ymm2, ymm2, ymm1
    vmulps ymm2, ymm2, ymm2         ; 8 quadrados: (e^(y/256))^256 = e^y
    vmulps ymm2, ymm2, ymm2
    vmulps ymm2, ymm2, ymm2
    vmulps ymm2, ymm2, ymm2
    vmulps ymm2, ymm2, ymm2
    vmulps ymm2, ymm2, ymm2
    vmulps ymm2, ymm2, ymm2
    vmulps ymm2, ymm2, ymm2
    vmovaps ymm0, ymm2
    ret

; ---------- exp_fn: xmm0 = exp(xmm0) escalar (usado na amostragem) ---------
exp_fn:
    mulss xmm0, [c_inv256]
    movss xmm1, [c_one]
    movss xmm2, [c_one]
    mov ecx, 1
.taylor:
    mulss xmm1, xmm0
    lea rdx, [c_invn]
    mulss xmm1, [rdx+rcx*4-4]       ; termo /= n  (inverso precalculado)
    addss xmm2, xmm1
    inc ecx
    cmp ecx, 8
    jle .taylor
    mov ecx, 8
.square:
    mulss xmm2, xmm2
    dec ecx
    jnz .square
    movss xmm0, xmm2
    ret

; ---------- rand01 / rand_sym (gerador LCG, so na inicializacao/amostragem) --
rand01:
    mov rax, [lm_seed]
    imul rax, rax, 1664525
    add rax, 1013904223
    mov eax, eax
    mov [lm_seed], rax
    cvtsi2ss xmm0, rax
    mulss xmm0, [c_inv2_32]
    ret

rand_sym:
    call rand01
    mulss xmm0, [c_two]
    subss xmm0, [c_one]
    ret

; ---------- init_params_lm: PAR = rand_sym * c_init ----------------------
init_params_lm:
    xor r8d, r8d
.ip:
    cmp r8, NP
    jae .ipd
    call rand_sym
    mulss xmm0, [c_init]
    lea rbx, [PAR]
    movss [rbx+r8*4], xmm0
    inc r8
    jmp .ip
.ipd:
    ret

; ---------- tanh_all_ctx: H[h] = tanh(H[h]) no bloco r15 ---------------------
tanh_all_ctx:
    lea rsi, [r15+CX_H]
    mov ecx, NHID/8
.t4:
    vmovups ymm0, [rsi]
    vmaxps ymm0, ymm0, [c_neg15v]
    vminps ymm0, ymm0, [c_15v]
    vaddps ymm0, ymm0, ymm0         ; 2z
    call exp4_avx                   ; ymm0 = e^(2z)
    vsubps ymm1, ymm0, [c_one4]     ; e - 1
    vaddps ymm0, ymm0, [c_one4]     ; e + 1
    vdivps ymm0, ymm1, ymm0         ; tanh(z)
    vmovups [rsi], ymm0
    add rsi, 32
    dec ecx
    jnz .t4
    vzeroupper
    ret

; ---------- forward_ctx: bloco r15, contexto em [r15+CX_CTXP] ----------------
; Grava X (embeddings), H (tanh), P (probabilidades) e L (logits).
forward_ctx:
    mov rsi, [r15+CX_CTXP]
    ; 1. X = concatenacao dos embeddings E[ctx_k]
    xor r8d, r8d
.f_k:
    cmp r8, NCTX
    jae .f_h0
    movzx eax, byte [rsi+r8]
    imul rax, rax, NEMB
    xor r9d, r9d
.f_d:
    cmp r9, NEMB
    jae .f_dn
    lea rbx, [PAR]
    lea rdx, [rax+r9]
    movss xmm0, [rbx+rdx*4]
    mov rcx, r8
    imul rcx, rcx, NEMB
    add rcx, r9
    movss [r15+rcx*4+CX_X], xmm0
    inc r9
    jmp .f_d
.f_dn:
    inc r8
    jmp .f_k
    ; 2. H = B1 + W1 X (pre-ativacao), depois tanh em lote
.f_h0:
    xor r8d, r8d
.f_h:
    cmp r8, NHID
    jae .f_v0
    lea rsi, [PAR]
    mov rax, r8
    imul rax, rax, NIN
    add rax, OFF_W1
    lea rsi, [rsi+rax*4]
    lea rdi, [r15+CX_X]
    mov ecx, NIN
    call dot_avx
    lea rbx, [PAR]
    lea rdx, [r8+OFF_B1]
    addss xmm0, [rbx+rdx*4]
    movss [r15+r8*4+CX_H], xmm0
    inc r8
    jmp .f_h
    ; 3. logits = B2 + W2 H (em P)
.f_v0:
    call tanh_all_ctx
    xor r8d, r8d
.f_v:
    cmp r8, NVOC
    jae .f_sm
    lea rsi, [PAR]
    mov rax, r8
    imul rax, rax, NHID
    add rax, OFF_W2
    lea rsi, [rsi+rax*4]
    lea rdi, [r15+CX_H]
    mov ecx, NHID
    call dot_avx
    lea rbx, [PAR]
    lea rdx, [r8+OFF_B2]
    addss xmm0, [rbx+rdx*4]
    movss [r15+r8*4+CX_P], xmm0
    inc r8
    jmp .f_v
    ; 4. softmax estavel: copia logits para L, max, exp em 4 pistas, normaliza
.f_sm:
    xor r8d, r8d
.f_cp:
    cmp r8, NVOC
    jae .f_sm1
    movss xmm0, [r15+r8*4+CX_P]
    movss [r15+r8*4+CX_L], xmm0
    inc r8
    jmp .f_cp
.f_sm1:
    vmovups ymm0, [r15+CX_P]
    lea rsi, [r15+CX_P+32]
    mov ecx, NVOC/8-1
.f_mx4:
    vmaxps ymm0, ymm0, [rsi]
    add rsi, 32
    dec ecx
    jnz .f_mx4
    vextractf128 xmm1, ymm0, 1
    vmaxps xmm0, xmm0, xmm1         ; 4 lanes
    vpermilps xmm1, xmm0, 0x4E      ; troca as metades de 64 bits
    vmaxps xmm0, xmm0, xmm1         ; 2 lanes
    vpermilps xmm1, xmm0, 0xB1      ; troca os pares de 32 bits
    vmaxss xmm0, xmm0, xmm1         ; maximo final
    movss [r15+CX_MX], xmm0
    vbroadcastss ymm4, [r15+CX_MX]
    vxorps ymm5, ymm5, ymm5
    lea rsi, [r15+CX_P]
    mov ecx, NVOC/8
.f_ex4:
    vmovups ymm0, [rsi]
    vsubps ymm0, ymm0, ymm4
    vmaxps ymm0, ymm0, [c_neg30v]
    vminps ymm0, ymm0, [c_zerov]
    call exp4_avx
    vmovups [rsi], ymm0
    vaddps ymm5, ymm5, ymm0
    add rsi, 32
    dec ecx
    jnz .f_ex4
    vextractf128 xmm1, ymm5, 1
    vaddps xmm5, xmm5, xmm1
    vhaddps xmm5, xmm5, xmm5        ; soma das 4 lanes (duas passadas)
    vhaddps xmm5, xmm5, xmm5
    movss [r15+CX_SUM], xmm5
    vbroadcastss ymm6, [r15+CX_SUM]
    lea rsi, [r15+CX_P]
    mov ecx, NVOC/8
.f_dv4:
    vmovups ymm0, [rsi]
    vdivps ymm0, ymm0, ymm6
    vmovups [rsi], ymm0
    add rsi, 32
    dec ecx
    jnz .f_dv4
    vzeroupper
    ret

; ---------- argmax_ctx: rax = indice do maior P no bloco r15 ---------------
argmax_ctx:
    movss xmm0, [r15+CX_P]
    xor eax, eax
    mov r8d, 1
.am:
    cmp r8, NVOC
    jae .amd
    movss xmm1, [r15+r8*4+CX_P]
    comiss xmm1, xmm0
    jbe .am_n
    movss xmm0, xmm1
    mov rax, r8
.am_n:
    inc r8
    jmp .am
.amd:
    ret

; ---------- sample_ctx: amostra do softmax com temperatura (usa L) -----------
; rax = indice escolhido. Escreve as probabilidades em P.
sample_ctx:
    movss xmm0, [r15+CX_L]
    mov r8d, 1
.s_mx:
    cmp r8, NVOC
    jae .s_mxd
    maxss xmm0, [r15+r8*4+CX_L]
    inc r8
    jmp .s_mx
.s_mxd:
    movss [r15+CX_MX], xmm0
    xorps xmm1, xmm1
    movss [r15+CX_SUM], xmm1
    xor r8d, r8d
.s_w:
    cmp r8, NVOC
    jae .s_wd
    movss xmm0, [r15+r8*4+CX_L]
    subss xmm0, [r15+CX_MX]
    divss xmm0, [c_temp]
    maxss xmm0, [c_neg30]
    minss xmm0, [c_zero]
    call exp_fn
    movss [r15+r8*4+CX_P], xmm0
    movss xmm1, [r15+CX_SUM]
    addss xmm1, xmm0
    movss [r15+CX_SUM], xmm1
    inc r8
    jmp .s_w
.s_wd:
    call rand01                     ; xmm0 em [0,1)
    mulss xmm0, [r15+CX_SUM]
    movss [r15+CX_RT], xmm0
    xorps xmm1, xmm1
    xor r8d, r8d
.s_c:
    cmp r8, NVOC
    jae .s_last
    addss xmm1, [r15+r8*4+CX_P]
    comiss xmm1, [r15+CX_RT]
    jae .s_hit
    inc r8
    jmp .s_c
.s_hit:
    mov rax, r8
    ret
.s_last:
    mov rax, NVOC-1
    ret

; ---------- backward_grad: acumula o gradiente da amostra em G (bloco r15) ----
; Pre: forward_ctx feito. G += gradiente (sem aplicar a atualizacao).
backward_grad:
    ; dP = P - onehot(tgt)
    xor r8d, r8d
.b_dp:
    cmp r8, NVOC
    jae .b_dh
    movss xmm0, [r15+r8*4+CX_P]
    cmp r8, [r15+CX_TGT]
    jne .b_dpn
    subss xmm0, [c_one]
.b_dpn:
    movss [r15+r8*4+CX_DP], xmm0
    inc r8
    jmp .b_dp
    ; dH = sum_v dP[v] * W2[v]   (vetorizado sobre h)
.b_dh:
    lea rdi, [r15+CX_DH]
    xor eax, eax
    mov ecx, NHID
    rep stosd
    xor r8d, r8d
.b_dh_v:
    cmp r8, NVOC
    jae .b_dz
    movss xmm0, [r15+r8*4+CX_DP]
    lea rsi, [PAR]
    mov rax, r8
    imul rax, rax, NHID
    add rax, OFF_W2
    lea rsi, [rsi+rax*4]
    lea rdi, [r15+CX_DH]
    mov ecx, NHID
    call axpy_avx
    inc r8
    jmp .b_dh_v
    ; dZ[h] = dH[h] * (1 - h^2)
.b_dz:
    xor r8d, r8d
.b_dz1:
    cmp r8, NHID
    jae .b_dx
    movss xmm0, [r15+r8*4+CX_DH]
    movss xmm1, [r15+r8*4+CX_H]
    mulss xmm1, xmm1
    movss xmm2, [c_one]
    SGN xmm2, xmm1
    mulss xmm0, xmm2
    movss [r15+r8*4+CX_DZ], xmm0
    inc r8
    jmp .b_dz1
    ; dX = sum_h dZ[h] * W1[h]   (vetorizado sobre j)
.b_dx:
    lea rdi, [r15+CX_DX]
    xor eax, eax
    mov ecx, NIN
    rep stosd
    xor r8d, r8d
.b_dx_h:
    cmp r8, NHID
    jae .b_acc
    movss xmm0, [r15+r8*4+CX_DZ]
    lea rsi, [PAR]
    mov rax, r8
    imul rax, rax, NIN
    add rax, OFF_W1
    lea rsi, [rsi+rax*4]
    lea rdi, [r15+CX_DX]
    mov ecx, NIN
    call axpy_avx
    inc r8
    jmp .b_dx_h
    ; G_W2[v] += dP[v] * H ; G_B2[v] += dP[v]
.b_acc:
    xor r8d, r8d
.b_acc_v:
    cmp r8, NVOC
    jae .b_acc_h
    movss xmm0, [r15+r8*4+CX_DP]
    lea rdi, [r15+CX_G+OFF_W2*4]
    mov rax, r8
    imul rax, rax, NHID
    lea rdi, [rdi+rax*4]
    lea rsi, [r15+CX_H]
    mov ecx, NHID
    call axpy_avx
    movss xmm0, [r15+r8*4+CX_DP]
    lea rbx, [r15+CX_G+OFF_B2*4]
    movss xmm1, [rbx+r8*4]
    addss xmm1, xmm0
    movss [rbx+r8*4], xmm1
    inc r8
    jmp .b_acc_v
    ; G_W1[h] += dZ[h] * X ; G_B1[h] += dZ[h]
.b_acc_h:
    xor r8d, r8d
.b_acc_h1:
    cmp r8, NHID
    jae .b_acc_e
    movss xmm0, [r15+r8*4+CX_DZ]
    lea rdi, [r15+CX_G+OFF_W1*4]
    mov rax, r8
    imul rax, rax, NIN
    lea rdi, [rdi+rax*4]
    lea rsi, [r15+CX_X]
    mov ecx, NIN
    call axpy_avx
    movss xmm0, [r15+r8*4+CX_DZ]
    lea rbx, [r15+CX_G+OFF_B1*4]
    movss xmm1, [rbx+r8*4]
    addss xmm1, xmm0
    movss [rbx+r8*4], xmm1
    inc r8
    jmp .b_acc_h1
    ; G_E[ctx_k][d] += dX[k*NEMB + d]
.b_acc_e:
    mov rsi, [r15+CX_CTXP]
    xor r8d, r8d
.b_e_k:
    cmp r8, NCTX
    jae .b_done
    movzx eax, byte [rsi+r8]
    imul rax, rax, NEMB
    xor r9d, r9d
.b_e_d:
    cmp r9, NEMB
    jae .b_e_kn
    mov rdx, r8
    imul rdx, rdx, NEMB
    add rdx, r9
    movss xmm0, [r15+rdx*4+CX_DX]
    lea r10, [rax+r9]
    movss xmm1, [r15+r10*4+CX_G]
    addss xmm1, xmm0
    movss [r15+r10*4+CX_G], xmm1
    inc r9
    jmp .b_e_d
.b_e_kn:
    inc r8
    jmp .b_e_k
.b_done:
    ret

; ---------- zero_grad: zera o gradiente acumulado do bloco r15 ---------------
zero_grad:
    lea rdi, [r15+CX_G]
    xor eax, eax
    mov ecx, NP
    rep stosd
    ret

; ---------- grad_sample: forward + backward, acumula em G, soma a perda ------
grad_sample:
    call forward_ctx
    mov rax, [r15+CX_TGT]
    movss xmm0, [r15+rax*4+CX_P]    ; P(alvo) em float -> double para somar a perda
    cvtss2sd xmm0, xmm0
    addsd xmm0, [r15+CX_LOSS]
    movsd [r15+CX_LOSS], xmm0
    call backward_grad
    ret

; ---------- apply_grad: PAR += c_upd * c_lr_lm * G (bloco r15) ---------------
apply_grad:
    movss xmm1, [c_upd]
    mulss xmm1, [c_lr_lm]
    lea rbx, [PAR]
    xor r8d, r8d
.ap:
    cmp r8, NP
    jae .ap_d
    movss xmm0, [r15+r8*4+CX_G]
    mulss xmm0, xmm1
    movss xmm2, [rbx+r8*4]
    addss xmm2, xmm0
    movss [rbx+r8*4], xmm2
    inc r8
    jmp .ap
.ap_d:
    ret

; ---------- programas de uma amostra (usam ctx0) ----------------------------
; train_step: SGD em uma amostra. Pre: ctxp e tgt definidos.
train_step:
    push r15
    lea r15, [ctx0]
    call zero_grad
    call grad_sample
    call apply_grad
    pop r15
    ret

forward_lm:
    push r15
    lea r15, [ctx0]
    call forward_ctx
    pop r15
    ret

argmax_lm:
    push r15
    lea r15, [ctx0]
    call argmax_ctx
    pop r15
    ret

sample_lm:
    push r15
    lea r15, [ctx0]
    call sample_ctx
    pop r15
    ret

; ---------- worker_proc: thread que processa o seu pedaco de cada lote --------
; rcx = bloco do worker. Espera o evento de inicio, calcula o gradiente das
; amostras [CX_LO, CX_LO+CX_N) do lote [CX_BASE] e avisa o evento de fim.
; Nao termina: o processo encerra com ExitProcess.
; ---------- set_ftz: liga FTZ e DAZ no MXCSR desta thread (denormais viram zero) ----
; Numeros denormais em float sao muito lentos; o treino nao precisa deles.
set_ftz:
    sub rsp, 8
    db 0x0F, 0xAE, 0x1C, 0x24       ; stmxcsr [rsp]
    or dword [rsp], 0x8040
    db 0x0F, 0xAE, 0x14, 0x24       ; ldmxcsr [rsp]
    add rsp, 8
    ret

worker_proc:
    call set_ftz
    push r12
    push r13
    push r15
    sub rsp, 32
    mov r15, rcx
.wloop:
    mov rcx, [r15+CX_START]
    mov edx, 0xFFFFFFFF
    call [__imp_WaitForSingleObject]
    call zero_grad
    mov qword [r15+CX_LOSS], 0
    mov r12, [r15+CX_LO]
    mov r13, [r15+CX_N]
.wsample:
    test r13, r13
    jz .wdone
    mov rax, [r15+CX_BASE]
    add rax, r12
    mov [r15+CX_CTXP], rax
    movzx ecx, byte [rax+NCTX]
    mov [r15+CX_TGT], rcx
    call grad_sample
    inc r12
    dec r13
    jmp .wsample
.wdone:
    mov rcx, [r15+CX_DONE]
    call [__imp_SetEvent]
    jmp .wloop

; ---------- init_workers: cria os eventos e as threads (uma vez) -------------
init_workers:
    push rbx
    push r14
    sub rsp, 88
    xor ebx, ebx
.iw:
    cmp ebx, NTHREADS
    jae .iwd
    mov rax, rbx
    imul rax, rax, CX_SIZE
    lea r14, [wblock]
    add r14, rax                    ; r14 = bloco do worker ebx
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_CreateEventA]       ; evento de inicio (auto-reset)
    mov [r14+CX_START], rax
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_CreateEventA]       ; evento de fim (auto-reset)
    mov [r14+CX_DONE], rax
    lea rdx, [wdone]
    mov [rdx+rbx*8], rax
    xor ecx, ecx
    xor edx, edx
    lea r8, [worker_proc]
    mov r9, r14
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0
    call [__imp_CreateThread]
    inc ebx
    jmp .iw
.iwd:
    add rsp, 88
    pop r14
    pop rbx
    ret

; ---------- train_batch: rcx = inicio do lote, rdx = tamanho (<= 4096) -------
; Amostra i do lote: contexto em base+i, alvo em base[NCTX+i].
; Divide as amostras entre os workers, espera todos e aplica a media do
; gradiente: PAR += c_upd * c_lr_batch * (soma G) / n.
train_batch:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 40
    mov r12, rcx                    ; base
    mov r13, rdx                    ; n
    ; amostras por worker (arredonda para cima)
    mov eax, r13d
    add eax, NTHREADS-1
    xor edx, edx
    mov ecx, NTHREADS
    div ecx
    mov r14d, eax                   ; per
    xor ebx, ebx
.tb_split:
    cmp ebx, NTHREADS
    jae .tb_go
    mov rax, rbx
    imul rax, rax, CX_SIZE
    lea rcx, [wblock]
    add rcx, rax                    ; rcx = bloco do worker ebx
    mov eax, ebx
    imul eax, r14d                  ; lo = w * per (limitado a n)
    cmp eax, r13d
    jbe .lo_ok
    mov eax, r13d
.lo_ok:
    mov [rcx+CX_LO], rax
    mov edx, r13d
    sub edx, eax                    ; restante
    cmp edx, r14d
    jbe .n_ok
    mov edx, r14d
.n_ok:
    mov [rcx+CX_N], rdx
    mov [rcx+CX_BASE], r12
    inc ebx
    jmp .tb_split
.tb_go:
    xor ebx, ebx
.tb_sig:
    cmp ebx, NTHREADS
    jae .tb_wait
    mov rax, rbx
    imul rax, rax, CX_SIZE
    lea rcx, [wblock]
    add rcx, rax
    mov rcx, [rcx+CX_START]
    call [__imp_SetEvent]
    inc ebx
    jmp .tb_sig
.tb_wait:
    mov ecx, NTHREADS
    lea rdx, [wdone]
    mov r8d, 1                      ; espera todos
    mov r9d, 0xFFFFFFFF             ; INFINITE
    call [__imp_WaitForMultipleObjects]
    ; fator = c_upd * c_lr_batch / n
    cvtsi2ss xmm1, r13
    movss xmm0, [c_upd]
    mulss xmm0, [c_lr_batch]
    divss xmm0, xmm1
    vbroadcastss ymm7, xmm0
    ; PAR += fator * soma_w G_w
    xor r8d, r8d
.tb_k:
    cmp r8, NP
    jae .tb_loss
    vxorps ymm0, ymm0, ymm0
    xor r9d, r9d
.tb_w:
    cmp r9d, NTHREADS
    jae .tb_wd
    mov rax, r9
    imul rax, rax, CX_SIZE
    lea rsi, [wblock+CX_G]
    add rsi, rax
    lea rsi, [rsi+r8*4]
    vaddps ymm0, ymm0, [rsi]
    inc r9d
    jmp .tb_w
.tb_wd:
    vmulps ymm0, ymm0, ymm7
    lea rdi, [PAR]
    lea rdi, [rdi+r8*4]
    vaddps ymm0, ymm0, [rdi]
    vmovups [rdi], ymm0
    add r8, 8
    jmp .tb_k
    ; perda: loss_total += soma das perdas dos workers
.tb_loss:
    vzeroupper
    xorpd xmm2, xmm2
    xor r9d, r9d
.tb_l:
    cmp r9d, NTHREADS
    jae .tb_ld
    mov rax, r9
    imul rax, rax, CX_SIZE
    lea rsi, [wblock+CX_LOSS]
    addsd xmm2, [rsi+rax]
    inc r9d
    jmp .tb_l
.tb_ld:
    movsd xmm3, [loss_total]
    addsd xmm3, xmm2
    movsd [loss_total], xmm3
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

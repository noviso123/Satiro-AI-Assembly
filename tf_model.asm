default rel
; ============ MODELO TRANSFORMER: configuracao, parametros, ativacoes e camadas ============
; Inclui tf_core.asm (produtos de matriz). Forward e backward de uma sequencia de TT
; bytes; o gradiente acumula em TG (quem chama zera TG antes de cada lote).
%include "tf_core.asm"

%ifndef TT
%define TT   256                    ; contexto (tokens = bytes; multiplo de 8)
%endif
%ifndef TL
%define TL   2                      ; blocos
%endif
%ifndef TV
%define TV   256                    ; vocabulario (bytes; com BPE use -DTOK16 -DTV=n)
%endif
%ifdef TOK16
%define TB   2                      ; bytes por token na entrada (uint16)
%else
%define TB   1                      ; tokens sao os proprios bytes
%endif
%ifndef TD
%define TD   64                     ; dimensao do modelo (multiplo de 8)
%endif
%ifndef TH
%define TH   4                      ; cabecas de atencao
%endif
%define THD  (TD/TH)                ; dimensao de cada cabeca (multiplo de 8)
%ifndef TF
%define TF   256                    ; camada oculta do MLP (multiplo de 8)
%endif

; parametros (floats). Wq/Wk/Wv por cabeca: [TH][TD][THD]; Wo: [TH][THD][TD]
%define OFF_E    0                  ; embedding de token [TV][TD] (tambem e a saida)
%define OFF_P    (TV*TD)            ; embedding de posicao [TT][TD]
%define OFF_L0   (OFF_P + TT*TD)
%define L_LN1G   0
%define L_LN1B   (TD)
%define L_WQ     (2*TD)
%define L_WK     (L_WQ + TD*TD)
%define L_WV     (L_WK + TD*TD)
%define L_WO     (L_WV + TD*TD)
%define L_LN2G   (L_WO + TD*TD)
%define L_LN2B   (L_LN2G + TD)
%define L_W1     (L_LN2B + TD)      ; [TD][TF]
%define L_B1     (L_W1 + TD*TF)
%define L_W2     (L_B1 + TF)        ; [TF][TD]
%define L_B2     (L_W2 + TF*TD)
%define LSZ      (L_B2 + TD)
%define OFF_LNFG (OFF_L0 + TL*LSZ)
%define OFF_LNFB (OFF_LNFG + TD)
%define TNP      (OFF_LNFB + TD)    ; total de parametros

; ---- bloco de contexto (um por thread, apontado por r15): variaveis de trabalho,
; ativacoes, gradientes de ativacoes e o gradiente acumulado TG. Os pesos (TPAR) sao
; compartilhados e so lidos no forward/backward. (0..71 sao as variaveis de tf_core)
%define TX_tf_tok  72
%define TX_tf_pal  80
%define TX_tf_l    88
%define TX_tf_h    96
%define TX_tf_t    104
%define TX_tf_q3   112
%define TX_la_x    120
%define TX_la_y    128
%define TX_la_g    136
%define TX_la_b    144
%define TX_la_xh   152
%define TX_la_rs   160
%define TX_la_dy   168
%define TX_la_dx   176
%define TX_la_dg   184
%define TX_la_db   192
%define TX_ut_p    200
%define TX_ut_q    208
%define TX_ut_n    216
%define TX_ut_r    224
%define TX_tf_itt  232                ; 1/TT (float)
%define TX_A_XIN   256
%define TX_A_XH1   (TX_A_XIN + (TL+1)*TT*TD*4)
%define TX_A_RS1   (TX_A_XH1 + TL*TT*TD*4)
%define TX_A_H1    (TX_A_RS1 + TL*TT*4)
%define TX_A_Q     (TX_A_H1 + TL*TT*TD*4)
%define TX_A_K     (TX_A_Q + TL*TH*TT*THD*4)
%define TX_A_V     (TX_A_K + TL*TH*TT*THD*4)
%define TX_A_P     (TX_A_V + TL*TH*TT*THD*4)
%define TX_A_AO    (TX_A_P + TL*TH*TT*TT*4)
%define TX_A_XMID  (TX_A_AO + TL*TH*TT*THD*4)
%define TX_A_XH2   (TX_A_XMID + TL*TT*TD*4)
%define TX_A_RS2   (TX_A_XH2 + TL*TT*TD*4)
%define TX_A_H2    (TX_A_RS2 + TL*TT*4)
%define TX_A_A1    (TX_A_H2 + TL*TT*TD*4)
%define TX_A_R1    (TX_A_A1 + TL*TT*TF*4)
%define TX_A_XHF   (TX_A_R1 + TL*TT*TF*4)
%define TX_A_RSF   (TX_A_XHF + TT*TD*4)
%define TX_A_HF    (TX_A_RSF + TT*4)
%define TX_A_PR    (TX_A_HF + TT*TD*4)
%define TX_D_X     (TX_A_PR + TT*TV*4)
%define TX_D_H     (TX_D_X + TT*TD*4)
%define TX_D_Q     (TX_D_H + TT*TD*4)
%define TX_D_K     (TX_D_Q + TH*TT*THD*4)
%define TX_D_V     (TX_D_K + TH*TT*THD*4)
%define TX_D_AO    (TX_D_V + TH*TT*THD*4)
%define TX_D_P     (TX_D_AO + TH*TT*THD*4)
%define TX_D_A1    (TX_D_P + TT*TT*4)
%define TX_D_LOG   (TX_D_A1 + TT*TF*4)
%define TX_TG      (TX_D_LOG + TT*TV*4)
%define TX_MMT     (TX_TG + TNP*4)     ; buffer de transposicao de mm_nt (o maior B e [TV|TF][TD])
%define TX_SIZE    (TX_MMT + (TV+TF)*TD*4 + 64)

section .bss
alignb 32
TPAR:   resd TNP                    ; parametros
alignb 64
TCTX:   resb TX_SIZE                ; bloco de contexto da thread principal
; ativacoes guardadas para o backward
; gradientes de ativacoes (temporarios)
; argumentos das rotinas de LN e utilitarias

section .data
align 8
tf_one:     dd 1.0
tf_eps:     dd 1.0e-5
tf_invd:    dd 0.015625             ; 1/TD        (recalculados por tf_consts para
tf_scale:   dd 0.25                 ; 1/sqrt(THD)  qualquer -DTD/-DTH)
tf_sqrt2:   dd 1.4142135623730951
tf_half:    dd 0.5
tf_ln2:     dd 0.6931471805599453
tf_c3:      dd 0.3333333333333333
tf_c5:      dd 0.2
tf_c7:      dd 0.14285714285714285
tf_c9:      dd 0.1111111111111111
tf_neg80:   dd -80.0
tf_inv256:  dd 0.00390625
tf_invn:    dd 1.0, 0.5, 0.3333333333333333, 0.25, 0.2, 0.16666666666666666, 0.14285714285714285, 0.125

section .text

; ---------- tf_consts: 1/TD e 1/sqrt(THD) (globais) e 1/TT (no contexto r15) ----------
; Chamado no inicio do forward e do backward; todas as threads gravam os mesmos valores.
tf_consts:
    movss xmm2, [tf_one]
    mov eax, TD
    cvtsi2ss xmm1, eax
    movss xmm0, xmm2
    divss xmm0, xmm1
    movss [tf_invd], xmm0
    mov eax, THD
    cvtsi2ss xmm1, eax
    sqrtss xmm1, xmm1
    movss xmm0, xmm2
    divss xmm0, xmm1
    movss [tf_scale], xmm0
    mov eax, TT
    cvtsi2ss xmm1, eax
    movss xmm0, xmm2
    divss xmm0, xmm1
    movss [r15+TX_tf_itt], xmm0
    ret

; ---------- tf_exp:xmm0 = e^xmm0 (para x <= 0; abaixo de -80 da 0) ------------------
tf_exp:
    comiss xmm0, [tf_neg80]
    jae tf_exp_ok
    xorps xmm0, xmm0
    ret

; ---------- tf_ln: xmm0 = ln(xmm0), x > 0 (erro relativo ~1e-6) ------------------------
; x = m * 2^e com m em [1,2) (ou [sqrt2/2, sqrt2)); ln m = 2 atanh((m-1)/(m+1)) em serie.
tf_ln:
    sub rsp, 8
    movss [rsp], xmm0
    mov eax, [rsp]
    mov ecx, eax
    shr ecx, 23
    and ecx, 255
    sub ecx, 127                     ; expoente
    and eax, 0x007FFFFF
    or eax, 0x3F800000
    mov [rsp], eax
    movss xmm0, [rsp]                ; mantissa em [1,2)
    add rsp, 8
    comiss xmm0, [tf_sqrt2]
    jbe .m_ok
    mulss xmm0, [tf_half]
    inc ecx
.m_ok:
    movss xmm1, xmm0
    subss xmm0, [tf_one]
    addss xmm1, [tf_one]
    divss xmm0, xmm1                 ; s = (m-1)/(m+1)
    movss xmm1, xmm0
    mulss xmm1, xmm1                 ; s^2
    movss xmm2, xmm1
    mulss xmm2, [tf_c9]
    addss xmm2, [tf_c7]
    mulss xmm2, xmm1
    addss xmm2, [tf_c5]
    mulss xmm2, xmm1
    addss xmm2, [tf_c3]
    mulss xmm2, xmm1
    addss xmm2, [tf_one]
    mulss xmm0, xmm2
    addss xmm0, xmm0                 ; ln m
    cvtsi2ss xmm1, ecx
    mulss xmm1, [tf_ln2]
    addss xmm0, xmm1
    ret

tf_exp_ok:
    comiss xmm0, [tf_neg80]
    jae .ok
    xorps xmm0, xmm0
    ret
.ok:
    mulss xmm0, [tf_inv256]
    movss xmm1, [tf_one]
    movss xmm2, [tf_one]
    xor ecx, ecx
.t:
    mulss xmm1, xmm0
    lea rdx, [tf_invn]
    mulss xmm1, [rdx+rcx*4]
    addss xmm2, xmm1
    inc ecx
    cmp ecx, 8
    jb .t
    mov ecx, 8
.q:
    mulss xmm2, xmm2
    dec ecx
    jnz .q
    movaps xmm0, xmm2
    ret

; ---------- utilitarios: ut_p = destino, ut_q = origem, ut_n = n, ut_r = linhas ---------
tf_zero_n:                          ; ut_p[0..n) = 0
    mov rdi, [r15+TX_ut_p]
    mov rcx, [r15+TX_ut_n]
    xor eax, eax
    rep stosd
    ret
tf_copy_n:                          ; ut_p[0..n) = ut_q[0..n)
    mov rdi, [r15+TX_ut_p]
    mov rsi, [r15+TX_ut_q]
    mov rcx, [r15+TX_ut_n]
    rep movsd
    ret
tf_add_rowbias:                     ; ut_p[r][j] += ut_q[j] (ut_r linhas, ut_n colunas, n mult. de 8)
    xor r8d, r8d
.r:
    cmp r8, [r15+TX_ut_r]
    jae .f
    mov rax, r8
    imul rax, [r15+TX_ut_n]
    mov rdi, [r15+TX_ut_p]
    lea rdi, [rdi+rax*4]
    mov rsi, [r15+TX_ut_q]
    xor ecx, ecx
.c:
    cmp rcx, [r15+TX_ut_n]
    jae .nr
    vmovups ymm0, [rdi+rcx*4]
    vaddps ymm0, ymm0, [rsi+rcx*4]
    vmovups [rdi+rcx*4], ymm0
    add rcx, 8
    jmp .c
.nr:
    inc r8
    jmp .r
.f:
    vzeroupper
    ret
tf_colsum_acc:                      ; ut_p[j] += sum_r ut_q[r][j] (n mult. de 8)
    xor r8d, r8d
.r:
    cmp r8, [r15+TX_ut_r]
    jae .f
    mov rax, r8
    imul rax, [r15+TX_ut_n]
    mov rsi, [r15+TX_ut_q]
    lea rsi, [rsi+rax*4]
    mov rdi, [r15+TX_ut_p]
    xor ecx, ecx
.c:
    cmp rcx, [r15+TX_ut_n]
    jae .nr
    vmovups ymm0, [rdi+rcx*4]
    vaddps ymm0, ymm0, [rsi+rcx*4]
    vmovups [rdi+rcx*4], ymm0
    add rcx, 8
    jmp .c
.nr:
    inc r8
    jmp .r
.f:
    vzeroupper
    ret

; ---------- tf_ln_fwd: la_x [TT][TD] -> la_y; guarda la_xh (normalizado) e la_rs --------
tf_ln_fwd:
    xor r8d, r8d
.r:
    cmp r8, TT
    jae .f
    mov rax, r8
    imul rax, rax, TD
    mov rsi, [r15+TX_la_x]
    lea rsi, [rsi+rax*4]
    mov rdi, [r15+TX_la_xh]
    lea rdi, [rdi+rax*4]
    mov r9, [r15+TX_la_y]
    lea r9, [r9+rax*4]
    vxorps ymm0, ymm0, ymm0
    xor ecx, ecx
.m:
    vaddps ymm0, ymm0, [rsi+rcx*4]
    add ecx, 8
    cmp ecx, TD
    jb .m
    vextractf128 xmm1, ymm0, 1
    vaddps xmm0, xmm0, xmm1
    vhaddps xmm0, xmm0, xmm0
    vhaddps xmm0, xmm0, xmm0
    vbroadcastss ymm3, xmm0
    vbroadcastss ymm6, [tf_invd]
    vmulps ymm3, ymm3, ymm6         ; media em todas as lanes
    vxorps ymm4, ymm4, ymm4
    xor ecx, ecx
.v:
    vmovups ymm0, [rsi+rcx*4]
    vsubps ymm0, ymm0, ymm3
    vfmadd231ps ymm4, ymm0, ymm0
    add ecx, 8
    cmp ecx, TD
    jb .v
    vextractf128 xmm1, ymm4, 1
    vaddps xmm4, xmm4, xmm1
    vhaddps xmm4, xmm4, xmm4
    vhaddps xmm4, xmm4, xmm4
    vzeroupper                       ; parte escalar (a media segue em xmm3)
    mulss xmm4, [tf_invd]
    addss xmm4, [tf_eps]
    sqrtss xmm4, xmm4
    movss xmm5, [tf_one]
    divss xmm5, xmm4                ; 1/desvio
    mov r10, [r15+TX_la_rs]
    movss [r10+r8*4], xmm5
    vbroadcastss ymm3, xmm3
    vbroadcastss ymm5, xmm5
    mov r10, [r15+TX_la_g]
    mov r11, [r15+TX_la_b]
    xor ecx, ecx
.n:
    vmovups ymm0, [rsi+rcx*4]
    vsubps ymm0, ymm0, ymm3
    vmulps ymm0, ymm0, ymm5
    vmovups [rdi+rcx*4], ymm0
    vmulps ymm0, ymm0, [r10+rcx*4]
    vaddps ymm0, ymm0, [r11+rcx*4]
    vmovups [r9+rcx*4], ymm0
    add ecx, 8
    cmp ecx, TD
    jb .n
    inc r8
    jmp .r
.f:
    vzeroupper
    ret

; ---------- tf_ln_bwd: la_dy, la_xh, la_rs, la_g -> la_dg +=, la_db +=, la_dx += --------
; dx = rs * (dxh - media(dxh) - xh * media(dxh * xh)), com dxh = dy * g
tf_ln_bwd:
    xor r8d, r8d
.r:
    cmp r8, TT
    jae .f
    mov rax, r8
    imul rax, rax, TD
    mov rsi, [r15+TX_la_dy]
    lea rsi, [rsi+rax*4]
    mov rdi, [r15+TX_la_xh]
    lea rdi, [rdi+rax*4]
    mov r9, [r15+TX_la_dx]
    lea r9, [r9+rax*4]
    mov r10, [r15+TX_la_g]
    mov r11, [r15+TX_la_dg]
    mov rdx, [r15+TX_la_db]
    vxorps ymm3, ymm3, ymm3         ; soma dxh
    vxorps ymm4, ymm4, ymm4         ; soma dxh*xh
    xor ecx, ecx
.a:
    vmovups ymm0, [rsi+rcx*4]       ; dy
    vmovups ymm1, [rdi+rcx*4]       ; xh
    vmovups ymm2, [r11+rcx*4]
    vfmadd231ps ymm2, ymm0, ymm1
    vmovups [r11+rcx*4], ymm2       ; dg += dy*xh
    vaddps ymm2, ymm0, [rdx+rcx*4]
    vmovups [rdx+rcx*4], ymm2       ; db += dy
    vmulps ymm0, ymm0, [r10+rcx*4]  ; dxh
    vaddps ymm3, ymm3, ymm0
    vfmadd231ps ymm4, ymm0, ymm1
    add ecx, 8
    cmp ecx, TD
    jb .a
    vbroadcastss ymm6, [tf_invd]
    vextractf128 xmm1, ymm3, 1
    vaddps xmm3, xmm3, xmm1
    vhaddps xmm3, xmm3, xmm3
    vhaddps xmm3, xmm3, xmm3
    vbroadcastss ymm3, xmm3
    vmulps ymm3, ymm3, ymm6         ; media(dxh)
    vextractf128 xmm1, ymm4, 1
    vaddps xmm4, xmm4, xmm1
    vhaddps xmm4, xmm4, xmm4
    vhaddps xmm4, xmm4, xmm4
    vbroadcastss ymm4, xmm4
    vmulps ymm4, ymm4, ymm6         ; media(dxh*xh)
    mov rax, [r15+TX_la_rs]
    vbroadcastss ymm5, [rax+r8*4]
    xor ecx, ecx
.d:
    vmovups ymm0, [rsi+rcx*4]
    vmulps ymm0, ymm0, [r10+rcx*4]
    vsubps ymm0, ymm0, ymm3
    vmulps ymm1, ymm4, [rdi+rcx*4]
    vsubps ymm0, ymm0, ymm1
    vmulps ymm0, ymm0, ymm5
    vaddps ymm0, ymm0, [r9+rcx*4]
    vmovups [r9+rcx*4], ymm0
    add ecx, 8
    cmp ecx, TD
    jb .d
    inc r8
    jmp .r
.f:
    vzeroupper
    ret

; ---------- tf_exp8: ymm0 = e^ymm0 em 8 lanes (x <= 0; abaixo de -80 satura) -----------
; Mesma formula de tf_exp: Taylor de 8 termos em x/256 e 8 quadrados. Usa ymm1-ymm3.
tf_exp8:
    vbroadcastss ymm1, [tf_neg80]
    vmaxps ymm0, ymm0, ymm1
    vbroadcastss ymm1, [tf_inv256]
    vmulps ymm0, ymm0, ymm1
    vbroadcastss ymm2, [tf_one]      ; soma
    vmovaps ymm3, ymm2               ; termo
    lea rdx, [tf_invn]
    xor ecx, ecx
.t:
    vmulps ymm3, ymm3, ymm0
    vbroadcastss ymm1, [rdx+rcx*4]
    vmulps ymm3, ymm3, ymm1
    vaddps ymm2, ymm2, ymm3
    inc ecx
    cmp ecx, 8
    jb .t
    mov ecx, 8
.q:
    vmulps ymm2, ymm2, ymm2
    dec ecx
    jnz .q
    vmovaps ymm0, ymm2
    ret

; ---------- tf_softmax_causal: ut_p = [TT][TT]; a linha t usa as colunas 0..t ------------
; Vetorizado: as colunas futuras recebem -1e30 antes do maximo e sao zeradas
; depois da exponencial (a mascara continua exata).
tf_softmax_causal:
    push rbx
    xor r8d, r8d
.r:
    cmp r8, TT
    jae .f
    mov rax, r8
    imul rax, rax, TT
    mov rbx, [r15+TX_ut_p]
    lea rbx, [rbx+rax*4]
    lea r9, [r8+1]
.mk:
    cmp r9, TT
    jae .mkd
    mov dword [rbx+r9*4], 0xF149F2CA ; -1e30
    inc r9
    jmp .mk
.mkd:
    vmovups ymm0, [rbx]
    mov r9d, 8
.mx:
    cmp r9, TT
    jae .mxd
    vmaxps ymm0, ymm0, [rbx+r9*4]
    add r9, 8
    jmp .mx
.mxd:
    vextractf128 xmm1, ymm0, 1
    vmaxps xmm0, xmm0, xmm1
    vpermilps xmm1, xmm0, 0x4E
    vmaxps xmm0, xmm0, xmm1
    vpermilps xmm1, xmm0, 0xB1
    vmaxss xmm0, xmm0, xmm1
    vbroadcastss ymm6, xmm0
    xor r9d, r9d
.ex:
    cmp r9, TT
    jae .exd
    vmovups ymm0, [rbx+r9*4]
    vsubps ymm0, ymm0, ymm6
    call tf_exp8
    vmovups [rbx+r9*4], ymm0
    add r9, 8
    jmp .ex
.exd:
    lea r9, [r8+1]
.zr:
    cmp r9, TT
    jae .zrd
    mov dword [rbx+r9*4], 0          ; futuro: probabilidade exatamente 0
    inc r9
    jmp .zr
.zrd:
    vxorps ymm7, ymm7, ymm7
    xor r9d, r9d
.sm:
    cmp r9, TT
    jae .smd
    vaddps ymm7, ymm7, [rbx+r9*4]
    add r9, 8
    jmp .sm
.smd:
    vextractf128 xmm1, ymm7, 1
    vaddps xmm0, xmm7, xmm1
    vhaddps xmm0, xmm0, xmm0
    vhaddps xmm0, xmm0, xmm0
    vbroadcastss ymm0, xmm0
    vbroadcastss ymm1, [tf_one]
    vdivps ymm1, ymm1, ymm0          ; 1 / soma
    xor r9d, r9d
.nm:
    cmp r9, TT
    jae .nmd
    vmulps ymm0, ymm1, [rbx+r9*4]
    vmovups [rbx+r9*4], ymm0
    add r9, 8
    jmp .nm
.nmd:
    inc r8
    jmp .r
.f:
    vzeroupper
    pop rbx
    ret

; ---------- tf_softmax_rows: ut_p = [TT][TV], softmax completo por linha (vetorizado) ----
tf_softmax_rows:
    push rbx
    xor r8d, r8d
.r:
    cmp r8, TT
    jae .f
    mov rax, r8
    imul rax, rax, TV
    mov rbx, [r15+TX_ut_p]
    lea rbx, [rbx+rax*4]
    vmovups ymm0, [rbx]
    mov r9d, 8
.mx:
    cmp r9, TV
    jae .mxd
    vmaxps ymm0, ymm0, [rbx+r9*4]
    add r9, 8
    jmp .mx
.mxd:
    vextractf128 xmm1, ymm0, 1
    vmaxps xmm0, xmm0, xmm1
    vpermilps xmm1, xmm0, 0x4E
    vmaxps xmm0, xmm0, xmm1
    vpermilps xmm1, xmm0, 0xB1
    vmaxss xmm0, xmm0, xmm1
    vbroadcastss ymm6, xmm0
    vxorps ymm7, ymm7, ymm7
    xor r9d, r9d
.ex:
    cmp r9, TV
    jae .exd
    vmovups ymm0, [rbx+r9*4]
    vsubps ymm0, ymm0, ymm6
    call tf_exp8
    vmovups [rbx+r9*4], ymm0
    vaddps ymm7, ymm7, ymm0
    add r9, 8
    jmp .ex
.exd:
    vextractf128 xmm1, ymm7, 1
    vaddps xmm0, xmm7, xmm1
    vhaddps xmm0, xmm0, xmm0
    vhaddps xmm0, xmm0, xmm0
    vbroadcastss ymm0, xmm0
    vbroadcastss ymm1, [tf_one]
    vdivps ymm1, ymm1, ymm0
    xor r9d, r9d
.nm:
    cmp r9, TV
    jae .nmd
    vmulps ymm0, ymm1, [rbx+r9*4]
    vmovups [rbx+r9*4], ymm0
    add r9, 8
    jmp .nm
.nmd:
    inc r8
    jmp .r
.f:
    vzeroupper
    pop rbx
    ret

%include "tf_passes.asm"

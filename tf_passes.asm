default rel
; ============ TRANSFORMER: inicializacao, forward e backward de uma sequencia ============
; Entrada: tf_tok aponta para TT+1 bytes (posicoes 0..TT-1 sao a entrada; o alvo da
; posicao t e o byte t+1). Saida do forward: A_PR (probabilidades) e tf_pal (soma de
; P(alvo)). O backward acumula em TG o gradiente de  -1/TT * sum_t ln P_t(alvo).

section .bss
alignb 8
tf_seed:  resq 1

section .data
align 8
tf_init:    dd 0.05                 ; pesos iniciais em [-0.05, 0.05)
tf_inv2_31: dd 4.656612873077393e-10

section .text

; ---------- enderecos ------------------------------------------------------------------
; tf_lpar / tf_lgrad: rcx = deslocamento dentro do bloco tf_l -> rax = &TPAR/&TG[...]
tf_lpar:
    mov rax, [r15+TX_tf_l]
    imul rax, rax, LSZ
    add rax, rcx
    add rax, OFF_L0
    lea rdx, [TPAR]
    lea rax, [rdx+rax*4]
    ret
tf_lgrad:
    mov rax, [r15+TX_tf_l]
    imul rax, rax, LSZ
    add rax, rcx
    add rax, OFF_L0
    lea rdx, [r15+TX_TG]
    lea rax, [rdx+rax*4]
    ret
; tf_act: rdx = base, rcx = floats por bloco -> rax = rdx + tf_l*rcx*4
tf_act:
    mov rax, [r15+TX_tf_l]
    imul rax, rcx
    lea rax, [rdx+rax*4]
    ret
; tf_acth: rdx = base, rcx = floats por cabeca -> rax = rdx + (tf_l*TH + tf_h)*rcx*4
tf_acth:
    mov rax, [r15+TX_tf_l]
    imul rax, rax, TH
    add rax, [r15+TX_tf_h]
    imul rax, rcx
    lea rax, [rdx+rax*4]
    ret
; tf_head: rdx = base (sem bloco), rcx = floats por cabeca -> rax = rdx + tf_h*rcx*4
tf_head:
    mov rax, [r15+TX_tf_h]
    imul rax, rcx
    lea rax, [rdx+rax*4]
    ret
; tf_wqkv: tf_q3 (0 q, 1 k, 2 v) e tf_h -> rcx = deslocamento de W*_h no bloco
tf_wqkv:
    mov rcx, [r15+TX_tf_h]
    imul rcx, rcx, TD*THD
    mov rax, [r15+TX_tf_q3]
    imul rax, rax, TD*TD
    add rcx, rax
    add rcx, L_WQ                   ; L_WK = L_WQ + TD*TD, L_WV = L_WQ + 2*TD*TD
    ret

; ---------- tf_tanh: xmm0 = tanh(xmm0) = sinal(x) (1 - e^-2|x|) / (1 + e^-2|x|) ---------
tf_tanh:
    sub rsp, 24
    movss [rsp], xmm0
    mov eax, [rsp]
    and eax, 0x7FFFFFFF
    mov [rsp+4], eax
    movss xmm0, [rsp+4]             ; |x|
    addss xmm0, xmm0
    xorps xmm1, xmm1
    subss xmm1, xmm0                ; -2|x|
    movaps xmm0, xmm1
    call tf_exp
    movss xmm1, [tf_one]
    subss xmm1, xmm0                ; 1 - e
    addss xmm0, [tf_one]            ; 1 + e
    divss xmm1, xmm0
    mov eax, [rsp]
    test eax, eax
    jns .pos
    xorps xmm2, xmm2
    subss xmm2, xmm1
    movaps xmm1, xmm2
.pos:
    movaps xmm0, xmm1
    add rsp, 24
    ret

; ---------- tf_init_params: pesos uniformes pequenos; LN com ganho 1 e vies 0 -----------
tf_rand:                            ; xmm0 = float em [-1, 1)
    mov rax, [tf_seed]
    imul rax, rax, 1103515245
    add rax, 12345
    mov [tf_seed], rax
    shr rax, 16
    and eax, 0x7FFFFFFF
    cvtsi2ss xmm0, rax
    mulss xmm0, [tf_inv2_31]
    addss xmm0, xmm0
    subss xmm0, [tf_one]
    ret
tf_init_params:
    push rbx
    xor ebx, ebx
.p:
    cmp rbx, TNP
    jae .ln
    call tf_rand
    mulss xmm0, [tf_init]
    lea rax, [TPAR]
    movss [rax+rbx*4], xmm0
    inc rbx
    jmp .p
.ln:
    ; ganhos = 1, vieses (LN, b1, b2) = 0, em cada bloco e no LN final
    mov qword [r15+TX_tf_l], 0
.bl:
    cmp qword [r15+TX_tf_l], TL
    jae .lnf
    mov rcx, L_LN1G
    call tf_lpar
    mov rbx, rax
    call .uns
    mov rcx, L_LN2G
    call tf_lpar
    mov rbx, rax
    call .uns
    mov rcx, L_LN1B
    call tf_lpar
    mov rdi, rax
    mov ecx, TD
    xor eax, eax
    rep stosd
    mov rcx, L_LN2B
    call tf_lpar
    mov rdi, rax
    mov ecx, TD
    xor eax, eax
    rep stosd
    mov rcx, L_B1
    call tf_lpar
    mov rdi, rax
    mov ecx, TF
    xor eax, eax
    rep stosd
    mov rcx, L_B2
    call tf_lpar
    mov rdi, rax
    mov ecx, TD
    xor eax, eax
    rep stosd
    inc qword [r15+TX_tf_l]
    jmp .bl
.lnf:
    lea rbx, [TPAR+OFF_LNFG*4]
    call .uns
    lea rdi, [TPAR+OFF_LNFB*4]
    mov ecx, TD
    xor eax, eax
    rep stosd
    pop rbx
    ret
.uns:                               ; rbx[0..TD) = 1.0
    xor ecx, ecx
    mov eax, [tf_one]
.u:
    mov [rbx+rcx*4], eax
    inc ecx
    cmp ecx, TD
    jb .u
    ret

; ---------- tf_forward ------------------------------------------------------------------
tf_forward:
    push rbx
    push r12
    push r13
    lea rax, [r15+TX_MMT]
    mov [r15+TX_mm_tb], rax         ; buffer de transposicao desta thread
    call tf_consts
    ; 1. x0[t] = E[tok[t]] + P[t]
    xor r12d, r12d
.emb:
    cmp r12, TT
    jae .emb_ok
    mov rax, [r15+TX_tf_tok]
%ifdef TOK16
    movzx eax, word [rax+r12*2]
%else
    movzx eax, byte [rax+r12]
%endif
    imul rax, rax, TD
    lea rsi, [TPAR]
    lea rsi, [rsi+rax*4]
    mov rax, r12
    imul rax, rax, TD
    lea rdx, [TPAR+OFF_P*4]
    lea rdx, [rdx+rax*4]
    lea rdi, [r15+TX_A_XIN]
    lea rdi, [rdi+rax*4]
    xor ecx, ecx
.e1:
    vmovups ymm0, [rsi+rcx*4]
    vaddps ymm0, ymm0, [rdx+rcx*4]
    vmovups [rdi+rcx*4], ymm0
    add ecx, 8
    cmp ecx, TD
    jb .e1
    vzeroupper
    inc r12
    jmp .emb
.emb_ok:
    mov qword [r15+TX_tf_l], 0
.bloco:
    cmp qword [r15+TX_tf_l], TL
    jae .final
    ; LN1(x_in) -> h1
    lea rdx, [r15+TX_A_XIN]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_la_x], rax
    lea rdx, [r15+TX_A_XH1]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_la_xh], rax
    lea rdx, [r15+TX_A_RS1]
    mov rcx, TT
    call tf_act
    mov [r15+TX_la_rs], rax
    lea rdx, [r15+TX_A_H1]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_la_y], rax
    mov rcx, L_LN1G
    call tf_lpar
    mov [r15+TX_la_g], rax
    mov rcx, L_LN1B
    call tf_lpar
    mov [r15+TX_la_b], rax
    call tf_ln_fwd
    ; atencao, cabeca por cabeca
    mov qword [r15+TX_tf_h], 0
.cab:
    cmp qword [r15+TX_tf_h], TH
    jae .cab_ok
    ; q, k, v = h1 . W*_h   ([TT][TD] . [TD][THD])
    mov qword [r15+TX_tf_q3], 0
.qkv:
    cmp qword [r15+TX_tf_q3], 3
    jae .qkv_ok
    lea rdx, [r15+TX_A_Q]
    cmp qword [r15+TX_tf_q3], 1
    jne .d1
    lea rdx, [r15+TX_A_K]
.d1:
    cmp qword [r15+TX_tf_q3], 2
    jne .d2
    lea rdx, [r15+TX_A_V]
.d2:
    mov rcx, TT*THD
    call tf_acth
    mov [r15+TX_mm_c], rax
    mov [r15+TX_ut_p], rax
    mov qword [r15+TX_ut_n], TT*THD
    call tf_zero_n
    call tf_wqkv
    call tf_lpar
    mov [r15+TX_mm_b], rax
    lea rdx, [r15+TX_A_H1]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_mm_a], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TD
    mov qword [r15+TX_mm_n], THD
    call mm_nn
    inc qword [r15+TX_tf_q3]
    jmp .qkv
.qkv_ok:
    ; P = softmax_causal(q . k^T / sqrt(THD))
    lea rdx, [r15+TX_A_P]
    mov rcx, TT*TT
    call tf_acth
    mov rbx, rax
    mov [r15+TX_mm_c], rax
    mov [r15+TX_ut_p], rax
    mov qword [r15+TX_ut_n], TT*TT
    call tf_zero_n
    lea rdx, [r15+TX_A_Q]
    mov rcx, TT*THD
    call tf_acth
    mov [r15+TX_mm_a], rax
    lea rdx, [r15+TX_A_K]
    mov rcx, TT*THD
    call tf_acth
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], THD
    mov qword [r15+TX_mm_n], TT
    call mm_nt
    vbroadcastss ymm1, [tf_scale]
    xor ecx, ecx
.sc:
    vmulps ymm0, ymm1, [rbx+rcx*4]
    vmovups [rbx+rcx*4], ymm0
    add ecx, 8
    cmp ecx, TT*TT
    jb .sc
    vzeroupper
    mov [r15+TX_ut_p], rbx
    call tf_softmax_causal
    ; ao_h = P . v_h
    lea rdx, [r15+TX_A_AO]
    mov rcx, TT*THD
    call tf_acth
    mov [r15+TX_mm_c], rax
    mov [r15+TX_ut_p], rax
    mov qword [r15+TX_ut_n], TT*THD
    call tf_zero_n
    mov [r15+TX_mm_a], rbx
    lea rdx, [r15+TX_A_V]
    mov rcx, TT*THD
    call tf_acth
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TT
    mov qword [r15+TX_mm_n], THD
    call mm_nn
    inc qword [r15+TX_tf_h]
    jmp .cab
.cab_ok:
    ; x_mid = x_in + sum_h ao_h . Wo_h
    lea rdx, [r15+TX_A_XMID]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_ut_p], rax
    mov [r15+TX_mm_c], rax
    lea rdx, [r15+TX_A_XIN]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_ut_q], rax
    mov qword [r15+TX_ut_n], TT*TD
    call tf_copy_n
    mov qword [r15+TX_tf_h], 0
.wo:
    cmp qword [r15+TX_tf_h], TH
    jae .wo_ok
    lea rdx, [r15+TX_A_AO]
    mov rcx, TT*THD
    call tf_acth
    mov [r15+TX_mm_a], rax
    mov rcx, [r15+TX_tf_h]
    imul rcx, rcx, THD*TD
    add rcx, L_WO
    call tf_lpar
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], THD
    mov qword [r15+TX_mm_n], TD
    call mm_nn
    inc qword [r15+TX_tf_h]
    jmp .wo
.wo_ok:
    ; LN2(x_mid) -> h2
    lea rdx, [r15+TX_A_XMID]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_la_x], rax
    lea rdx, [r15+TX_A_XH2]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_la_xh], rax
    lea rdx, [r15+TX_A_RS2]
    mov rcx, TT
    call tf_act
    mov [r15+TX_la_rs], rax
    lea rdx, [r15+TX_A_H2]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_la_y], rax
    mov rcx, L_LN2G
    call tf_lpar
    mov [r15+TX_la_g], rax
    mov rcx, L_LN2B
    call tf_lpar
    mov [r15+TX_la_b], rax
    call tf_ln_fwd
    ; a1 = h2 . W1 + b1
    lea rdx, [r15+TX_A_A1]
    mov rcx, TT*TF
    call tf_act
    mov rbx, rax
    mov [r15+TX_mm_c], rax
    mov [r15+TX_ut_p], rax
    mov qword [r15+TX_ut_n], TT*TF
    call tf_zero_n
    lea rdx, [r15+TX_A_H2]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_mm_a], rax
    mov rcx, L_W1
    call tf_lpar
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TD
    mov qword [r15+TX_mm_n], TF
    call mm_nn
    mov [r15+TX_ut_p], rbx
    mov rcx, L_B1
    call tf_lpar
    mov [r15+TX_ut_q], rax
    mov qword [r15+TX_ut_n], TF
    mov qword [r15+TX_ut_r], TT
    call tf_add_rowbias
    ; r1 = max(a1, 0)
    lea rdx, [r15+TX_A_R1]
    mov rcx, TT*TF
    call tf_act
    mov r12, rax
%ifdef ATIV_TANH
    ; variante suave (so para testar o gradiente sem o bico da ReLU em 0)
    xor r13d, r13d
.tanh:
    movss xmm0, [rbx+r13*4]
    call tf_tanh
    movss [r12+r13*4], xmm0
    inc r13
    cmp r13, TT*TF
    jb .tanh
%else
    vxorps ymm1, ymm1, ymm1
    xor ecx, ecx
.relu:
    vmaxps ymm0, ymm1, [rbx+rcx*4]
    vmovups [r12+rcx*4], ymm0
    add ecx, 8
    cmp ecx, TT*TF
    jb .relu
    vzeroupper
%endif
    ; x_out = x_mid + r1 . W2 + b2   (x_out = A_XIN do bloco seguinte)
    lea rdx, [r15+TX_A_XIN]
    mov rcx, TT*TD
    call tf_act
    add rax, TT*TD*4
    mov rbx, rax
    mov [r15+TX_ut_p], rax
    mov [r15+TX_mm_c], rax
    lea rdx, [r15+TX_A_XMID]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_ut_q], rax
    mov qword [r15+TX_ut_n], TT*TD
    call tf_copy_n
    mov [r15+TX_mm_a], r12
    mov rcx, L_W2
    call tf_lpar
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TF
    mov qword [r15+TX_mm_n], TD
    call mm_nn
    mov [r15+TX_ut_p], rbx
    mov rcx, L_B2
    call tf_lpar
    mov [r15+TX_ut_q], rax
    mov qword [r15+TX_ut_n], TD
    mov qword [r15+TX_ut_r], TT
    call tf_add_rowbias
    inc qword [r15+TX_tf_l]
    jmp .bloco
.final:
    ; LN final
    lea rax, [r15+TX_A_XIN]
    add rax, TL*TT*TD*4
    mov [r15+TX_la_x], rax
    lea rax, [r15+TX_A_XHF]
    mov [r15+TX_la_xh], rax
    lea rax, [r15+TX_A_RSF]
    mov [r15+TX_la_rs], rax
    lea rax, [r15+TX_A_HF]
    mov [r15+TX_la_y], rax
    lea rax, [TPAR+OFF_LNFG*4]
    mov [r15+TX_la_g], rax
    lea rax, [TPAR+OFF_LNFB*4]
    mov [r15+TX_la_b], rax
    call tf_ln_fwd
    ; logits = hf . E^T, softmax por linha
    lea rax, [r15+TX_A_PR]
    mov [r15+TX_mm_c], rax
    mov [r15+TX_ut_p], rax
    mov qword [r15+TX_ut_n], TT*TV
    call tf_zero_n
    lea rax, [r15+TX_A_HF]
    mov [r15+TX_mm_a], rax
    lea rax, [TPAR+OFF_E*4]
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TD
    mov qword [r15+TX_mm_n], TV
    call mm_nt
    lea rax, [r15+TX_A_PR]
    mov [r15+TX_ut_p], rax
    call tf_softmax_rows
    ; soma de P(alvo)
    xorpd xmm4, xmm4
    xor r12d, r12d
.pal:
    cmp r12, TT
    jae .pal_ok
    mov rax, [r15+TX_tf_tok]
%ifdef TOK16
    movzx eax, word [rax+r12*2+2]
%else
    movzx eax, byte [rax+r12+1]
%endif
    mov rdx, r12
    imul rdx, rdx, TV
    add rdx, rax
    lea rax, [r15+TX_A_PR]
    cvtss2sd xmm0, [rax+rdx*4]
    addsd xmm4, xmm0
    inc r12
    jmp .pal
.pal_ok:
    movsd [r15+TX_tf_pal], xmm4
    pop r13
    pop r12
    pop rbx
    ret

; ---------- tf_backward (depois de tf_forward; acumula em TG) ------------------------------
tf_backward:
    push rbx
    push r12
    push r13
    lea rax, [r15+TX_MMT]
    mov [r15+TX_mm_tb], rax
    call tf_consts
    ; dlog = (PR - onehot(alvo)) / TT
    xor r12d, r12d
.dl:
    cmp r12, TT
    jae .dl_ok
    mov rax, r12
    imul rax, rax, TV
    lea rsi, [r15+TX_A_PR]
    lea rsi, [rsi+rax*4]
    lea rdi, [r15+TX_D_LOG]
    lea rdi, [rdi+rax*4]
    vbroadcastss ymm1, [r15+TX_tf_itt]
    xor ecx, ecx
.dl1:
    vmulps ymm0, ymm1, [rsi+rcx*4]
    vmovups [rdi+rcx*4], ymm0
    add ecx, 8
    cmp ecx, TV
    jb .dl1
    vzeroupper
    mov rax, [r15+TX_tf_tok]
%ifdef TOK16
    movzx eax, word [rax+r12*2+2]
%else
    movzx eax, byte [rax+r12+1]
%endif
    movss xmm0, [rdi+rax*4]
    subss xmm0, [r15+TX_tf_itt]
    movss [rdi+rax*4], xmm0
    inc r12
    jmp .dl
.dl_ok:
    ; dE += dlog^T . hf      ([TT][TV]^T . [TT][TD] -> [TV][TD])
    lea rax, [r15+TX_D_LOG]
    mov [r15+TX_mm_a], rax
    lea rax, [r15+TX_A_HF]
    mov [r15+TX_mm_b], rax
    lea rax, [r15+TX_TG+OFF_E*4]
    mov [r15+TX_mm_c], rax
    mov qword [r15+TX_mm_m], TV
    mov qword [r15+TX_mm_k], TT
    mov qword [r15+TX_mm_n], TD
    call mm_tn
    ; dhf = dlog . E          ([TT][TV] . [TV][TD])
    lea rax, [r15+TX_D_H]
    mov [r15+TX_ut_p], rax
    mov [r15+TX_mm_c], rax
    mov qword [r15+TX_ut_n], TT*TD
    call tf_zero_n
    lea rax, [r15+TX_D_LOG]
    mov [r15+TX_mm_a], rax
    lea rax, [TPAR+OFF_E*4]
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TV
    mov qword [r15+TX_mm_n], TD
    call mm_nn
    ; LN final -> D_X
    lea rax, [r15+TX_D_X]
    mov [r15+TX_ut_p], rax
    mov [r15+TX_la_dx], rax
    mov qword [r15+TX_ut_n], TT*TD
    call tf_zero_n
    lea rax, [r15+TX_D_H]
    mov [r15+TX_la_dy], rax
    lea rax, [r15+TX_A_XHF]
    mov [r15+TX_la_xh], rax
    lea rax, [r15+TX_A_RSF]
    mov [r15+TX_la_rs], rax
    lea rax, [TPAR+OFF_LNFG*4]
    mov [r15+TX_la_g], rax
    lea rax, [r15+TX_TG+OFF_LNFG*4]
    mov [r15+TX_la_dg], rax
    lea rax, [r15+TX_TG+OFF_LNFB*4]
    mov [r15+TX_la_db], rax
    call tf_ln_bwd
    mov qword [r15+TX_tf_l], TL-1
.bloco:
    cmp qword [r15+TX_tf_l], 0
    jl .emb
    ; ---- MLP: x_out = x_mid + r1 . W2 + b2, r1 = relu(h2 . W1 + b1) ----
    mov rcx, L_B2
    call tf_lgrad
    mov [r15+TX_ut_p], rax
    lea rax, [r15+TX_D_X]
    mov [r15+TX_ut_q], rax
    mov qword [r15+TX_ut_n], TD
    mov qword [r15+TX_ut_r], TT
    call tf_colsum_acc              ; db2 += soma das linhas de dx_out
    lea rdx, [r15+TX_A_R1]
    mov rcx, TT*TF
    call tf_act
    mov [r15+TX_mm_a], rax
    lea rax, [r15+TX_D_X]
    mov [r15+TX_mm_b], rax
    mov rcx, L_W2
    call tf_lgrad
    mov [r15+TX_mm_c], rax
    mov qword [r15+TX_mm_m], TF
    mov qword [r15+TX_mm_k], TT
    mov qword [r15+TX_mm_n], TD
    call mm_tn                      ; dW2 += r1^T . dx_out
    lea rax, [r15+TX_D_A1]
    mov [r15+TX_ut_p], rax
    mov [r15+TX_mm_c], rax
    mov qword [r15+TX_ut_n], TT*TF
    call tf_zero_n
    lea rax, [r15+TX_D_X]
    mov [r15+TX_mm_a], rax
    mov rcx, L_W2
    call tf_lpar
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TD
    mov qword [r15+TX_mm_n], TF
    call mm_nt                      ; dr1 = dx_out . W2^T
%ifdef ATIV_TANH
    ; da1 = dr1 * (1 - r1^2)
    lea rdx, [r15+TX_A_R1]
    mov rcx, TT*TF
    call tf_act
    lea rdi, [r15+TX_D_A1]
    xor ecx, ecx
.dtanh:
    movss xmm0, [rax+rcx*4]
    mulss xmm0, xmm0
    movss xmm2, [tf_one]
    subss xmm2, xmm0
    mulss xmm2, [rdi+rcx*4]
    movss [rdi+rcx*4], xmm2
    inc ecx
    cmp ecx, TT*TF
    jb .dtanh
%else
    lea rdx, [r15+TX_A_A1]
    mov rcx, TT*TF
    call tf_act
    lea rdi, [r15+TX_D_A1]
    xorps xmm1, xmm1
    xor ecx, ecx
.drelu:
    movss xmm0, [rax+rcx*4]
    comiss xmm0, xmm1
    ja .drelu_ok
    mov dword [rdi+rcx*4], 0        ; a1 <= 0: sem gradiente
.drelu_ok:
    inc ecx
    cmp ecx, TT*TF
    jb .drelu
%endif
    mov rcx, L_B1
    call tf_lgrad
    mov [r15+TX_ut_p], rax
    lea rax, [r15+TX_D_A1]
    mov [r15+TX_ut_q], rax
    mov qword [r15+TX_ut_n], TF
    mov qword [r15+TX_ut_r], TT
    call tf_colsum_acc              ; db1 += soma das linhas de da1
    lea rdx, [r15+TX_A_H2]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_mm_a], rax
    lea rax, [r15+TX_D_A1]
    mov [r15+TX_mm_b], rax
    mov rcx, L_W1
    call tf_lgrad
    mov [r15+TX_mm_c], rax
    mov qword [r15+TX_mm_m], TD
    mov qword [r15+TX_mm_k], TT
    mov qword [r15+TX_mm_n], TF
    call mm_tn                      ; dW1 += h2^T . da1
    lea rax, [r15+TX_D_H]
    mov [r15+TX_ut_p], rax
    mov [r15+TX_mm_c], rax
    mov qword [r15+TX_ut_n], TT*TD
    call tf_zero_n
    lea rax, [r15+TX_D_A1]
    mov [r15+TX_mm_a], rax
    mov rcx, L_W1
    call tf_lpar
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TF
    mov qword [r15+TX_mm_n], TD
    call mm_nt                      ; dh2 = da1 . W1^T
    ; LN2: dx_mid = dx_out + LN2'(dh2)
    lea rax, [r15+TX_D_H]
    mov [r15+TX_la_dy], rax
    lea rax, [r15+TX_D_X]
    mov [r15+TX_la_dx], rax
    lea rdx, [r15+TX_A_XH2]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_la_xh], rax
    lea rdx, [r15+TX_A_RS2]
    mov rcx, TT
    call tf_act
    mov [r15+TX_la_rs], rax
    mov rcx, L_LN2G
    call tf_lpar
    mov [r15+TX_la_g], rax
    mov rcx, L_LN2G
    call tf_lgrad
    mov [r15+TX_la_dg], rax
    mov rcx, L_LN2B
    call tf_lgrad
    mov [r15+TX_la_db], rax
    call tf_ln_bwd
    ; ---- atencao: x_mid = x_in + sum_h ao_h . Wo_h ----
    lea rax, [r15+TX_D_H]
    mov [r15+TX_ut_p], rax
    mov qword [r15+TX_ut_n], TT*TD
    call tf_zero_n                  ; D_H acumula dh1
    mov qword [r15+TX_tf_h], 0
.cab:
    cmp qword [r15+TX_tf_h], TH
    jae .cab_ok
    ; dWo_h += ao_h^T . dx_mid
    lea rdx, [r15+TX_A_AO]
    mov rcx, TT*THD
    call tf_acth
    mov [r15+TX_mm_a], rax
    lea rax, [r15+TX_D_X]
    mov [r15+TX_mm_b], rax
    mov rcx, [r15+TX_tf_h]
    imul rcx, rcx, THD*TD
    add rcx, L_WO
    call tf_lgrad
    mov [r15+TX_mm_c], rax
    mov qword [r15+TX_mm_m], THD
    mov qword [r15+TX_mm_k], TT
    mov qword [r15+TX_mm_n], TD
    call mm_tn
    ; dao_h = dx_mid . Wo_h^T
    lea rdx, [r15+TX_D_AO]
    mov rcx, TT*THD
    call tf_head
    mov r12, rax
    mov [r15+TX_mm_c], rax
    mov [r15+TX_ut_p], rax
    mov qword [r15+TX_ut_n], TT*THD
    call tf_zero_n
    lea rax, [r15+TX_D_X]
    mov [r15+TX_mm_a], rax
    mov rcx, [r15+TX_tf_h]
    imul rcx, rcx, THD*TD
    add rcx, L_WO
    call tf_lpar
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TD
    mov qword [r15+TX_mm_n], THD
    call mm_nt
    ; dP = dao_h . v_h^T
    lea rax, [r15+TX_D_P]
    mov [r15+TX_mm_c], rax
    mov [r15+TX_ut_p], rax
    mov qword [r15+TX_ut_n], TT*TT
    call tf_zero_n
    mov [r15+TX_mm_a], r12
    lea rdx, [r15+TX_A_V]
    mov rcx, TT*THD
    call tf_acth
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], THD
    mov qword [r15+TX_mm_n], TT
    call mm_nt
    ; dv_h = P^T . dao_h
    lea rdx, [r15+TX_D_V]
    mov rcx, TT*THD
    call tf_head
    mov [r15+TX_mm_c], rax
    mov [r15+TX_ut_p], rax
    mov qword [r15+TX_ut_n], TT*THD
    call tf_zero_n
    lea rdx, [r15+TX_A_P]
    mov rcx, TT*TT
    call tf_acth
    mov rbx, rax                    ; P da cabeca
    mov [r15+TX_mm_a], rax
    mov [r15+TX_mm_b], r12
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TT
    mov qword [r15+TX_mm_n], THD
    call mm_tn
    ; dS = P * (dP - soma_linha(dP * P)) / sqrt(THD)   (em D_P)
    lea r13, [r15+TX_D_P]
    xor r8d, r8d
.ds:
    cmp r8, TT
    jae .ds_ok
    mov rax, r8
    imul rax, rax, TT
    lea rsi, [rbx+rax*4]
    lea rdi, [r13+rax*4]
    vxorps ymm3, ymm3, ymm3
    xor ecx, ecx
.ds1:
    vmovups ymm0, [rdi+rcx*4]
    vfmadd231ps ymm3, ymm0, [rsi+rcx*4]
    add ecx, 8
    cmp ecx, TT
    jb .ds1
    vextractf128 xmm1, ymm3, 1
    vaddps xmm3, xmm3, xmm1
    vhaddps xmm3, xmm3, xmm3
    vhaddps xmm3, xmm3, xmm3
    vbroadcastss ymm3, xmm3
    vbroadcastss ymm2, [tf_scale]
    xor ecx, ecx
.ds2:
    vmovups ymm0, [rdi+rcx*4]
    vsubps ymm0, ymm0, ymm3
    vmulps ymm0, ymm0, [rsi+rcx*4]
    vmulps ymm0, ymm0, ymm2
    vmovups [rdi+rcx*4], ymm0
    add ecx, 8
    cmp ecx, TT
    jb .ds2
    inc r8
    jmp .ds
.ds_ok:
    vzeroupper
    ; dq_h = dS . k_h
    lea rdx, [r15+TX_D_Q]
    mov rcx, TT*THD
    call tf_head
    mov [r15+TX_mm_c], rax
    mov [r15+TX_ut_p], rax
    mov qword [r15+TX_ut_n], TT*THD
    call tf_zero_n
    mov [r15+TX_mm_a], r13
    lea rdx, [r15+TX_A_K]
    mov rcx, TT*THD
    call tf_acth
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TT
    mov qword [r15+TX_mm_n], THD
    call mm_nn
    ; dk_h = dS^T . q_h
    lea rdx, [r15+TX_D_K]
    mov rcx, TT*THD
    call tf_head
    mov [r15+TX_mm_c], rax
    mov [r15+TX_ut_p], rax
    mov qword [r15+TX_ut_n], TT*THD
    call tf_zero_n
    mov [r15+TX_mm_a], r13
    lea rdx, [r15+TX_A_Q]
    mov rcx, TT*THD
    call tf_acth
    mov [r15+TX_mm_b], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], TT
    mov qword [r15+TX_mm_n], THD
    call mm_tn
    ; para q, k, v: dW*_h += h1^T . d*_h ; dh1 += d*_h . W*_h^T
    mov qword [r15+TX_tf_q3], 0
.g3:
    cmp qword [r15+TX_tf_q3], 3
    jae .g3_ok
    lea rdx, [r15+TX_D_Q]
    cmp qword [r15+TX_tf_q3], 1
    jne .g3a
    lea rdx, [r15+TX_D_K]
.g3a:
    cmp qword [r15+TX_tf_q3], 2
    jne .g3b
    lea rdx, [r15+TX_D_V]
.g3b:
    mov rcx, TT*THD
    call tf_head
    mov r12, rax                    ; d*_h
    lea rdx, [r15+TX_A_H1]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_mm_a], rax
    mov [r15+TX_mm_b], r12
    call tf_wqkv
    call tf_lgrad
    mov [r15+TX_mm_c], rax
    mov qword [r15+TX_mm_m], TD
    mov qword [r15+TX_mm_k], TT
    mov qword [r15+TX_mm_n], THD
    call mm_tn
    mov [r15+TX_mm_a], r12
    call tf_wqkv
    call tf_lpar
    mov [r15+TX_mm_b], rax
    lea rax, [r15+TX_D_H]
    mov [r15+TX_mm_c], rax
    mov qword [r15+TX_mm_m], TT
    mov qword [r15+TX_mm_k], THD
    mov qword [r15+TX_mm_n], TD
    call mm_nt
    inc qword [r15+TX_tf_q3]
    jmp .g3
.g3_ok:
    inc qword [r15+TX_tf_h]
    jmp .cab
.cab_ok:
    ; LN1: dx_in = dx_mid + LN1'(dh1)
    lea rax, [r15+TX_D_H]
    mov [r15+TX_la_dy], rax
    lea rax, [r15+TX_D_X]
    mov [r15+TX_la_dx], rax
    lea rdx, [r15+TX_A_XH1]
    mov rcx, TT*TD
    call tf_act
    mov [r15+TX_la_xh], rax
    lea rdx, [r15+TX_A_RS1]
    mov rcx, TT
    call tf_act
    mov [r15+TX_la_rs], rax
    mov rcx, L_LN1G
    call tf_lpar
    mov [r15+TX_la_g], rax
    mov rcx, L_LN1G
    call tf_lgrad
    mov [r15+TX_la_dg], rax
    mov rcx, L_LN1B
    call tf_lgrad
    mov [r15+TX_la_db], rax
    call tf_ln_bwd
    dec qword [r15+TX_tf_l]
    jmp .bloco
.emb:
    ; dE[tok[t]] += dx0[t] ; dP[t] += dx0[t]
    xor r12d, r12d
.e:
    cmp r12, TT
    jae .fim
    mov rax, r12
    imul rax, rax, TD
    lea rsi, [r15+TX_D_X]
    lea rsi, [rsi+rax*4]
    lea rdx, [r15+TX_TG+OFF_P*4]
    lea rdx, [rdx+rax*4]
    mov rax, [r15+TX_tf_tok]
%ifdef TOK16
    movzx eax, word [rax+r12*2]
%else
    movzx eax, byte [rax+r12]
%endif
    imul rax, rax, TD
    lea rdi, [r15+TX_TG+OFF_E*4]
    lea rdi, [rdi+rax*4]
    xor ecx, ecx
.e1:
    vmovups ymm0, [rsi+rcx*4]
    vaddps ymm1, ymm0, [rdi+rcx*4]
    vmovups [rdi+rcx*4], ymm1
    vaddps ymm1, ymm0, [rdx+rcx*4]
    vmovups [rdx+rcx*4], ymm1
    add ecx, 8
    cmp ecx, TD
    jb .e1
    vzeroupper
    inc r12
    jmp .e
.fim:
    pop r13
    pop r12
    pop rbx
    ret

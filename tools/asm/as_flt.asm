; ============ ASM: literais decimais em ponto flutuante (dq/dd, arredondamento correto) ==
; as_flt_parse: le [sinal] digitos [. digitos] [e [sinal] digitos] a partir de as_lp e
; devolve em rax os bits IEEE 754 (double se dl_size = 8, single se dl_size = 4).
; Aritmetica com inteiros grandes de FL_W palavras de 64 bits (ate FL_BITS bits).
; Arredondamento para o mais proximo, empate para par. Subnormais, overflow e
; literais grandes demais geram erro.
; Convencao: rbx = ponteiro de leitura; as rotinas bi_* nao alteram rbx nem r12.

%define FL_W 32                     ; palavras de 64 bits por inteiro grande
%define FL_BITS (FL_W*64)

section .bss
alignb 16
fl_M:           resq FL_W           ; mantissa decimal (todos os digitos)
fl_Q:           resq FL_W           ; numero a dividir / inteiro a arredondar
fl_D:           resq FL_W           ; divisor 10^k
fl_R:           resq FL_W           ; resto da divisao
fl_T:           resq FL_W           ; temporario de deslocamento
fl_cnt:         resq 1              ; contador de laco (sobrevive a chamadas)
fl_k:           resq 1              ; posicao da divisao / expoente de 10
fl_s:           resq 1              ; deslocamento binario: valor = Q / 2^s
fl_nd:          resq 1              ; digitos lidos
fl_frac:        resq 1              ; digitos depois do ponto
fl_neg:         resq 1
fl_E10:         resq 1              ; expoente decimal efetivo
fl_top:         resq 1              ; 64 bits superiores normalizados
fl_stk:         resq 1              ; sticky: algum bit abaixo de fl_top era 1
fl_rnz:         resq 1              ; resto da divisao diferente de zero
fl_shs:         resq 1              ; sticky de bi_shr
fl_E:           resq 1              ; expoente binario do bit superior
fl_P:           resq 1              ; bits de mantissa (53 ou 24)
fl_emin:        resq 1
fl_emax:        resq 1              ; tambem e o vies do expoente
fl_sgn:         resq 1              ; posicao do bit de sinal (63 ou 31)

section .data
as_e_flt_fmt:   db "literal de ponto flutuante invalido", 0
as_e_flt_grd:   db "literal de ponto flutuante grande demais", 0
as_e_flt_fx:    db "float fora da faixa normal de dq/dd (subnormal ou overflow)", 0
as_e_flt_tam:   db "float exige dq ou dd", 0

section .text

; ---------- bi_zero: rdi = inteiro -> zera ------------------------------------------------
bi_zero:
    xor eax, eax
    mov ecx, FL_W
    rep stosq
    ret

; ---------- bi_copy: rdi = destino, rsi = origem ------------------------------------------
bi_copy:
    mov ecx, FL_W
    rep movsq
    ret

; ---------- bi_is_zero: rsi = inteiro -> eax = 1 se zero ----------------------------------
bi_is_zero:
    xor eax, eax
    xor ecx, ecx
.l:
    cmp rcx, FL_W
    jae .z
    cmp qword [rsi+rcx*8], 0
    jne .nz
    inc rcx
    jmp .l
.z:
    mov eax, 1
.nz:
    ret

; ---------- bi_bitlen: rsi = inteiro -> rax = numero de bits (0 se zero) -------------------
bi_bitlen:
    mov rcx, FL_W
.l:
    dec rcx
    mov rax, [rsi+rcx*8]
    test rax, rax
    jnz .achou
    test rcx, rcx
    jnz .l
    xor eax, eax
    ret
.achou:
    bsr rdx, rax
    shl rcx, 6
    lea rax, [rcx+rdx+1]
    ret

; ---------- bi_cmp: rsi = a, rdi = b -> rax = -1, 0, 1 ------------------------------------
bi_cmp:
    mov rcx, FL_W
.l:
    dec rcx
    mov rax, [rsi+rcx*8]
    cmp rax, [rdi+rcx*8]
    ja .maior
    jb .menor
    test rcx, rcx
    jnz .l
    xor eax, eax
    ret
.maior:
    mov eax, 1
    ret
.menor:
    mov rax, -1
    ret

; ---------- bi_sub: rdi -= rsi (exige rdi >= rsi) -----------------------------------------
bi_sub:
    xor r8d, r8d                    ; emprestimo (0 ou 1)
    xor r10d, r10d
.l:
    cmp r10, FL_W
    jae .f
    mov rax, [rdi+r10*8]
    mov rdx, [rsi+r10*8]
    sub rax, rdx
    setc r9b
    sub rax, r8
    setc dl
    or r9b, dl
    movzx r8, r9b
    mov [rdi+r10*8], rax
    inc r10
    jmp .l
.f:
    ret

; ---------- bi_mul_small: rdi = inteiro, rax = multiplicador -> rax = carry de saida ------
bi_mul_small:
    mov r8, rax
    xor r9d, r9d                    ; carry
    xor r10d, r10d
.l:
    cmp r10, FL_W
    jae .f
    mov rax, [rdi+r10*8]
    mul r8                          ; rdx:rax = palavra * multiplicador
    add rax, r9
    adc rdx, 0
    mov [rdi+r10*8], rax
    mov r9, rdx
    inc r10
    jmp .l
.f:
    mov rax, r9
    ret

; ---------- bi_add_small: rdi = inteiro, rax = valor -> rax = carry de saida --------------
bi_add_small:
    xor r10d, r10d
.l:
    add [rdi+r10*8], rax
    jnc .ok
    mov eax, 1                      ; o carry passa para a proxima palavra
    inc r10
    cmp r10, FL_W
    jb .l
    mov eax, 1
    ret
.ok:
    xor eax, eax
    ret

; ---------- bi_shl: rdi = inteiro, rax = n bits (o chamador garante que cabe) --------------
bi_shl:
    push rbx
    mov r8, rax
    shr r8, 6                       ; w = n / 64
    mov rbx, rax
    and rbx, 63                     ; b = n % 64
    mov r10, FL_W-1                 ; destino, de cima para baixo
.l:
    xor r11d, r11d
    mov rdx, r10
    sub rdx, r8                     ; origem = destino - w
    js .grava
    mov r11, [rdi+rdx*8]
    mov rcx, rbx
    shl r11, cl
    test rbx, rbx
    jz .grava
    test rdx, rdx
    jz .grava
    mov rax, [rdi+rdx*8-8]
    mov rcx, 64
    sub rcx, rbx
    shr rax, cl
    or r11, rax
.grava:
    mov [rdi+r10*8], r11
    dec r10
    jns .l
    pop rbx
    ret

; ---------- bi_shr: rdi = inteiro, rax = n -> rax = sticky (1 se algum bit perdido era 1) --
bi_shr:
    push rbx
    mov r8, rax
    shr r8, 6                       ; w = n / 64
    mov rbx, rax
    and rbx, 63                     ; b = n % 64
    mov qword [fl_shs], 0
    xor edx, edx
.st:
    cmp rdx, FL_W
    jae .st_b
    cmp rdx, r8
    jae .st_b
    cmp qword [rdi+rdx*8], 0
    jne .st_sim
    inc rdx
    jmp .st
.st_b:
    test rbx, rbx
    jz .desl
    cmp r8, FL_W
    jae .desl
    mov r9, 1
    mov rcx, rbx
    shl r9, cl
    dec r9                          ; mascara dos b bits baixos de X[w]
    test [rdi+r8*8], r9
    jz .desl
.st_sim:
    mov qword [fl_shs], 1
.desl:
    xor r10d, r10d                  ; destino, de baixo para cima
.mv:
    cmp r10, FL_W
    jae .fim
    xor r11d, r11d
    lea rdx, [r10+r8]               ; origem = destino + w
    cmp rdx, FL_W
    jae .grava
    mov r11, [rdi+rdx*8]
    mov rcx, rbx
    shr r11, cl
    test rbx, rbx
    jz .grava
    lea rdx, [r10+r8+1]
    cmp rdx, FL_W
    jae .grava
    mov r9, [rdi+rdx*8]
    mov rcx, 64
    sub rcx, rbx
    shl r9, cl
    or r11, r9
.grava:
    mov [rdi+r10*8], r11
    inc r10
    jmp .mv
.fim:
    mov rax, [fl_shs]
    pop rbx
    ret

; ---------- bi_setbit: rdi = inteiro, rax = posicao do bit ---------------------------------
bi_setbit:
    mov r9, rax
    shr r9, 6
    and eax, 63
    mov rcx, rax
    mov r8, 1
    shl r8, cl
    or [rdi+r9*8], r8
    ret

; ---------- fl_top64: fl_Q -> fl_top (64 bits superiores), fl_stk, rax = bitlen(Q) -------
fl_top64:
    push rbx
    lea rsi, [fl_Q]
    call bi_bitlen
    mov rbx, rax                    ; L = bitlen(Q)
    lea rsi, [fl_Q]
    lea rdi, [fl_T]
    call bi_copy
    mov qword [fl_stk], 0
    cmp rbx, 64
    jbe .menor
    lea rdi, [fl_T]
    lea rax, [rbx-64]
    call bi_shr
    mov [fl_stk], rax
    jmp .pega
.menor:
    lea rdi, [fl_T]
    mov rax, 64
    sub rax, rbx
    call bi_shl
.pega:
    mov rax, [fl_T]
    mov [fl_top], rax
    mov rax, rbx
    pop rbx
    ret

; ---------- fl_round: r8 = bits de mantissa P -> rax = mantissa arredondada (P bits) ------
; Usa fl_top (bit 63 = 1) e fl_stk. Se o arredondamento estoura, ajusta fl_E.
fl_round:
    push rbx
    mov rbx, r8
    mov rdx, [fl_top]
    mov r9, rdx
    mov rcx, rbx
    shl r9, cl                      ; resto (bits abaixo da mantissa) alinhado no topo
    mov rax, rdx
    mov rcx, 64
    sub rcx, rbx
    shr rax, cl                     ; mantissa sem arredondar
    mov r10, 0x8000000000000000
    cmp r9, r10
    ja .sobe
    jb .fim
    cmp qword [fl_stk], 0           ; empate exato no bit de meio
    jne .sobe
    test al, 1
    jz .fim
.sobe:
    inc rax
    mov rdx, 1
    mov rcx, rbx
    shl rdx, cl
    cmp rax, rdx
    jb .fim
    shr rax, 1
    inc qword [fl_E]
.fim:
    pop rbx
    ret

; ---------- as_flt_parse: rax = bits do literal em as_lp (dl_size = 8 ou 4) ---------------
as_flt_parse:
    push rbx
    push r12
    push r13
    mov qword [fl_P], 53
    mov qword [fl_emin], -1022
    mov qword [fl_emax], 1023
    mov qword [fl_sgn], 63
    cmp qword [dl_size], 8
    je .tam_ok
    mov qword [fl_P], 24
    mov qword [fl_emin], -126
    mov qword [fl_emax], 127
    mov qword [fl_sgn], 31
    cmp qword [dl_size], 4
    jne .erro_tam
.tam_ok:
    lea rdi, [fl_M]
    call bi_zero
    mov qword [fl_neg], 0
    mov qword [fl_nd], 0
    mov qword [fl_frac], 0
    mov qword [fl_E10], 0
    mov qword [fl_rnz], 0
    mov rbx, [as_lp]
    cmp byte [rbx], '-'
    jne .nao_menos
    mov qword [fl_neg], 1
    inc rbx
    jmp .mant
.nao_menos:
    cmp byte [rbx], '+'
    jne .mant
    inc rbx
.mant:
    xor r12d, r12d                  ; 1 depois do ponto decimal
.dig:
    movzx eax, byte [rbx]
    sub eax, '0'
    cmp eax, 9
    ja .fim_mant
    mov [fl_cnt], rax               ; digito, preservado pelas chamadas
    lea rdi, [fl_M]
    mov eax, 10
    call bi_mul_small
    test rax, rax
    jnz .erro_grd
    lea rdi, [fl_M]
    mov rax, [fl_cnt]
    call bi_add_small
    test rax, rax
    jnz .erro_grd
    inc qword [fl_nd]
    test r12, r12
    jz .prox
    inc qword [fl_frac]
.prox:
    inc rbx
    jmp .dig
.fim_mant:
    cmp byte [rbx], '.'
    jne .expo
    test r12, r12
    jnz .expo
    mov r12d, 1
    inc rbx
    jmp .dig
.expo:
    cmp qword [fl_nd], 0
    je .erro_fmt
    cmp byte [rbx], 'e'
    je .e_inicio
    cmp byte [rbx], 'E'
    jne .ajusta
.e_inicio:
    inc rbx
    xor r13d, r13d                  ; 1 se o expoente e negativo
    cmp byte [rbx], '-'
    jne .e_mais
    mov r13d, 1
    inc rbx
    jmp .e_dig
.e_mais:
    cmp byte [rbx], '+'
    jne .e_dig
    inc rbx
.e_dig:
    xor ecx, ecx                    ; valor do expoente
    xor edx, edx                    ; digitos lidos
.e_l:
    movzx eax, byte [rbx]
    sub eax, '0'
    cmp eax, 9
    ja .e_fim
    imul rcx, rcx, 10
    add rcx, rax
    cmp rcx, 100000
    ja .erro_grd
    inc rbx
    inc edx
    jmp .e_l
.e_fim:
    test edx, edx
    jz .erro_fmt
    test r13d, r13d
    jz .e_pos
    neg rcx
.e_pos:
    mov [fl_E10], rcx
.ajusta:
    mov rax, [fl_E10]
    sub rax, [fl_frac]
    mov [fl_E10], rax
    mov [as_lp], rbx
    lea rsi, [fl_M]
    call bi_is_zero
    test eax, eax
    jz .nao_zero
    mov rax, [fl_neg]
    mov rcx, [fl_sgn]
    shl rax, cl
    jmp .fim

.nao_zero:
    cmp qword [fl_E10], 0
    jl .expo_neg
    ; valor inteiro: Q = M * 10^E10, sem fracao (s = 0)
    lea rsi, [fl_M]
    lea rdi, [fl_Q]
    call bi_copy
    mov qword [fl_s], 0
    mov rax, [fl_E10]
    mov [fl_cnt], rax
.pot:
    cmp qword [fl_cnt], 0
    je .calc
    lea rdi, [fl_Q]
    mov eax, 10
    call bi_mul_small
    test rax, rax
    jnz .erro_grd
    dec qword [fl_cnt]
    jmp .pot

.expo_neg:
    ; D = 10^(-E10)
    lea rdi, [fl_D]
    call bi_zero
    mov qword [fl_D], 1
    mov rax, [fl_E10]
    neg rax
    mov [fl_k], rax
.dpot:
    cmp qword [fl_k], 0
    je .dpot_fim
    lea rdi, [fl_D]
    mov eax, 10
    call bi_mul_small
    test rax, rax
    jnz .erro_grd
    dec qword [fl_k]
    jmp .dpot
.dpot_fim:
    ; s = max(0, bitlen(D) + 56 - bitlen(M)): quociente com pelo menos 56 bits
    lea rsi, [fl_D]
    call bi_bitlen
    add rax, 56
    mov [fl_cnt], rax
    lea rsi, [fl_M]
    call bi_bitlen
    mov rcx, [fl_cnt]
    sub rcx, rax
    jns .s_ok
    xor ecx, ecx
.s_ok:
    mov [fl_s], rcx
    lea rsi, [fl_M]
    call bi_bitlen
    add rax, [fl_s]
    cmp rax, FL_BITS-1
    ja .erro_grd
    ; N = M << s (em fl_R, que sera o resto)
    lea rsi, [fl_M]
    lea rdi, [fl_R]
    call bi_copy
    lea rdi, [fl_R]
    mov rax, [fl_s]
    call bi_shl
    ; quociente por subtracao com deslocamento: Q = R / D, R = resto
    lea rdi, [fl_Q]
    call bi_zero
    lea rsi, [fl_R]
    call bi_bitlen
    mov [fl_cnt], rax               ; bitlen(N)
    lea rsi, [fl_D]
    call bi_bitlen
    mov rcx, [fl_cnt]
    sub rcx, rax
    mov [fl_k], rcx                 ; maior deslocamento possivel
.div:
    cmp qword [fl_k], 0
    jl .div_fim
    lea rsi, [fl_D]
    lea rdi, [fl_T]
    call bi_copy
    lea rdi, [fl_T]
    mov rax, [fl_k]
    call bi_shl                     ; T = D << k
    lea rsi, [fl_R]
    lea rdi, [fl_T]
    call bi_cmp
    cmp rax, 0
    jl .prox_k
    lea rdi, [fl_R]
    lea rsi, [fl_T]
    call bi_sub                     ; R -= T
    lea rdi, [fl_Q]
    mov rax, [fl_k]
    call bi_setbit                  ; Q |= 1 << k
.prox_k:
    dec qword [fl_k]
    jmp .div
.div_fim:
    lea rsi, [fl_R]
    call bi_is_zero
    xor eax, 1
    mov [fl_rnz], rax
.calc:
    call fl_top64                   ; rax = L = bitlen(Q)
    mov rcx, rax
    dec rcx
    sub rcx, [fl_s]
    mov [fl_E], rcx                 ; expoente binario do bit superior
    mov rax, [fl_rnz]
    or [fl_stk], rax
    mov rax, [fl_E]
    cmp rax, [fl_emax]
    jg .erro_fx
    cmp rax, [fl_emin]
    jl .subnormal                   ; abaixo do menor normal
    mov r8, [fl_P]
    call fl_round                   ; rax = mantissa (P bits); pode subir o expoente
    mov rdx, [fl_E]
    cmp rdx, [fl_emax]
    jg .erro_fx
    ; empacota: fracao (sem bit implicito) | (E + vies) << (P-1) | sinal
    mov rcx, [fl_P]
    dec rcx                         ; bits de fracao
    mov r9, 1
    shl r9, cl
    dec r9
    and rax, r9
    mov rdx, [fl_E]
    add rdx, [fl_emax]
    shl rdx, cl
    or rax, rdx
.sinal:
    cmp qword [fl_neg], 0
    je .fim
    mov rcx, [fl_sgn]
    bts rax, rcx
.fim:
    pop r13
    pop r12
    pop rbx
    ret
.subnormal:
    ; m = arredonda(top >> drop), drop = 64 - P + (emin - E). O padrao de bits e o proprio
    ; m: se o arredondamento chega a 2^(P-1), o bit cai no expoente e vira o menor normal.
    mov rcx, [fl_emin]
    sub rcx, [fl_E]
    add rcx, 64
    sub rcx, [fl_P]                 ; drop
    mov rdx, [fl_top]
    cmp rcx, 64
    ja .sub_zero                    ; menor que meio subnormal minimo: zero
    je .sub_64
    mov rax, rdx
    shr rax, cl                     ; m sem arredondar
    mov r9, rdx
    mov r10, rcx
    mov ecx, 64
    sub rcx, r10
    shl r9, cl                      ; bits perdidos alinhados no bit 63
    mov r10, 0x8000000000000000
    cmp r9, r10
    ja .sub_sobe
    jb .sinal
    cmp qword [fl_stk], 0           ; empate exato: sobe so se impar
    jne .sub_sobe
    test al, 1
    jz .sinal
.sub_sobe:
    inc rax
    jmp .sinal
.sub_64:
    xor eax, eax                    ; m = 0; o resto e o proprio top (meio = 2^63)
    mov r10, 0x8000000000000000
    cmp rdx, r10
    ja .sub_um
    cmp qword [fl_stk], 0
    je .sinal                       ; empate exato: 0 (par)
.sub_um:
    mov eax, 1
    jmp .sinal
.sub_zero:
    xor eax, eax
    jmp .sinal
.erro_tam:
    lea rsi, [as_e_flt_tam]
    jmp as_fail_plain
.erro_fmt:
    lea rsi, [as_e_flt_fmt]
    jmp as_fail_plain
.erro_grd:
    lea rsi, [as_e_flt_grd]
    jmp as_fail_plain
.erro_fx:
    lea rsi, [as_e_flt_fx]
    jmp as_fail_plain

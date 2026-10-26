default rel
; ============ NUCLEO TRANSFORMER (por bytes, float32): produtos de matriz ============
; Matrizes em ordem de linha (row-major), float32, dimensoes multiplas de 8.
; Argumentos no bloco de contexto da thread (r15): mm_a, mm_b, mm_c, mm_m, mm_k, mm_n.
; Todas ACUMULAM em C (quem chama zera C quando precisa).
;   mm_nn: C[m x n] += A[m x k] . B[k x n]
;   mm_nt: C[m x n] += A[m x k] . B[n x k]^T   (transpoe B para mm_tb e usa mm_nn)
;   mm_tn: C[m x n] += A[k x m]^T . B[k x n]
; Kernel com bloqueio em registradores: cada linha de C fica em ate 4 acumuladores
; ymm (32 colunas); para cada k, um elemento de A (broadcast) e ate 4 FMAs.

; deslocamentos das variaveis de trabalho dos produtos de matriz no bloco de contexto (r15)
%define TX_mm_a   0
%define TX_mm_b   8
%define TX_mm_c   16
%define TX_mm_m   24
%define TX_mm_k   32
%define TX_mm_n   40
%define TX_mm_i   48
%define TX_mm_j   56
%define TX_mm_kk  64
%define TX_mm_tb  248                ; ponteiro para o buffer de transposicao da thread

section .text

; ---------- mm_ker: C[m][n] += A'(i,k) . B[k][n] --------------------------------------
; r8 = A, r9 = passo de A por linha i (bytes), r10 = passo de A por k (bytes), r11 = B.
; m, k, n, C vem do contexto. n multiplo de 8.
; Bloco principal: 4 linhas de C x 16 colunas (8 acumuladores ymm); cada par de vetores
; de B lido serve as 4 linhas. Colunas que sobram (8) usam 4 linhas x 8; linhas que
; sobram (m nao multiplo de 4) usam o laco de 1 linha (mm_ker1).
mm_ker:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 56
    mov [rsp], r8
    mov [rsp+8], r9
    mov [rsp+16], r10
    mov [rsp+24], r11
    mov r12, [r15+TX_mm_n]
    shl r12, 2                       ; bytes por linha de B e de C
    mov rbx, [r15+TX_mm_k]
    lea r13, [r9+r9*2]               ; 3 x passo de A por linha
    mov rax, [r15+TX_mm_m]
    and rax, -4
    mov [rsp+32], rax                ; linhas em blocos de 4
    xor eax, eax
    mov [rsp+40], rax                ; coluna inicial do bloco (bytes)
.jb:
    mov rax, [rsp+40]
    mov rcx, r12
    sub rcx, rax
    cmp rcx, 64
    jb .j8
    xor r14d, r14d                   ; i
.i16:
    cmp r14, [rsp+32]
    jae .j16n
    mov rsi, r14
    imul rsi, [rsp+8]
    add rsi, [rsp]                   ; A(i, 0)
    mov rdx, r14
    imul rdx, r12
    add rdx, [r15+TX_mm_c]
    add rdx, [rsp+40]                ; C(i, j)
    lea r8, [rdx+r12*2]              ; C(i+2, j)
    mov rdi, [rsp+24]
    add rdi, [rsp+40]                ; B(0, j)
    vmovups ymm0, [rdx]
    vmovups ymm1, [rdx+32]
    vmovups ymm2, [rdx+r12]
    vmovups ymm3, [rdx+r12+32]
    vmovups ymm4, [r8]
    vmovups ymm5, [r8+32]
    vmovups ymm6, [r8+r12]
    vmovups ymm7, [r8+r12+32]
    mov r10, [rsp+16]
    mov rcx, rbx
.k16:
    vmovups ymm8, [rdi]
    vmovups ymm9, [rdi+32]
    vbroadcastss ymm10, [rsi]
    vfmadd231ps ymm0, ymm10, ymm8
    vfmadd231ps ymm1, ymm10, ymm9
    vbroadcastss ymm11, [rsi+r9]
    vfmadd231ps ymm2, ymm11, ymm8
    vfmadd231ps ymm3, ymm11, ymm9
    vbroadcastss ymm10, [rsi+r9*2]
    vfmadd231ps ymm4, ymm10, ymm8
    vfmadd231ps ymm5, ymm10, ymm9
    vbroadcastss ymm11, [rsi+r13]
    vfmadd231ps ymm6, ymm11, ymm8
    vfmadd231ps ymm7, ymm11, ymm9
    add rsi, r10
    add rdi, r12
    dec rcx
    jnz .k16
    vmovups [rdx], ymm0
    vmovups [rdx+32], ymm1
    vmovups [rdx+r12], ymm2
    vmovups [rdx+r12+32], ymm3
    vmovups [r8], ymm4
    vmovups [r8+32], ymm5
    vmovups [r8+r12], ymm6
    vmovups [r8+r12+32], ymm7
    add r14, 4
    jmp .i16
.j16n:
    add qword [rsp+40], 64
    jmp .jb
.j8:
    cmp rcx, 32
    jb .resto
    xor r14d, r14d
.i8:
    cmp r14, [rsp+32]
    jae .j8n
    mov rsi, r14
    imul rsi, [rsp+8]
    add rsi, [rsp]
    mov rdx, r14
    imul rdx, r12
    add rdx, [r15+TX_mm_c]
    add rdx, [rsp+40]
    lea r8, [rdx+r12*2]
    mov rdi, [rsp+24]
    add rdi, [rsp+40]
    vmovups ymm0, [rdx]
    vmovups ymm2, [rdx+r12]
    vmovups ymm4, [r8]
    vmovups ymm6, [r8+r12]
    mov r10, [rsp+16]
    mov rcx, rbx
.k8b:
    vmovups ymm8, [rdi]
    vbroadcastss ymm10, [rsi]
    vfmadd231ps ymm0, ymm10, ymm8
    vbroadcastss ymm11, [rsi+r9]
    vfmadd231ps ymm2, ymm11, ymm8
    vbroadcastss ymm10, [rsi+r9*2]
    vfmadd231ps ymm4, ymm10, ymm8
    vbroadcastss ymm11, [rsi+r13]
    vfmadd231ps ymm6, ymm11, ymm8
    add rsi, r10
    add rdi, r12
    dec rcx
    jnz .k8b
    vmovups [rdx], ymm0
    vmovups [rdx+r12], ymm2
    vmovups [r8], ymm4
    vmovups [r8+r12], ymm6
    add r14, 4
    jmp .i8
.j8n:
    add qword [rsp+40], 32
    jmp .jb
.resto:
    ; linhas que sobraram (m nao multiplo de 4): laco de 1 linha a partir da linha [rsp+32]
    mov r13, [rsp+32]
    mov r8, [rsp]
    mov r9, [rsp+8]
    mov r10, [rsp+16]
    mov r11, [rsp+24]
    vzeroupper
    add rsp, 56
    jmp mm_ker1

; ---------- mm_ker1: o laco de 1 linha (linhas r13 .. m-1) ----------------------------------
; Entra com rbx, r12, r13, r14 ja salvos na pilha por mm_ker.
mm_ker1:
    sub rsp, 40
    mov [rsp], r8
    mov [rsp+8], r9
    mov [rsp+16], r10
    mov [rsp+24], r11
.li:
    cmp r13, [r15+TX_mm_m]
    jae .fim
    mov rsi, r13
    imul rsi, [rsp+8]
    add rsi, [rsp]                   ; A da linha i (k = 0)
    mov rdx, r13
    imul rdx, r12
    add rdx, [r15+TX_mm_c]           ; C da linha i
    mov rdi, [rsp+24]                ; B na coluna 0
    mov r14, [r15+TX_mm_n]           ; colunas restantes
    mov r8, [rsp+16]
.cb:
    cmp r14, 32
    jb .c16
    vmovups ymm0, [rdx]
    vmovups ymm1, [rdx+32]
    vmovups ymm2, [rdx+64]
    vmovups ymm3, [rdx+96]
    mov r10, rsi
    mov r11, rdi
    mov rcx, rbx
.k32:
    vbroadcastss ymm4, [r10]
    vfmadd231ps ymm0, ymm4, [r11]
    vfmadd231ps ymm1, ymm4, [r11+32]
    vfmadd231ps ymm2, ymm4, [r11+64]
    vfmadd231ps ymm3, ymm4, [r11+96]
    add r10, r8
    add r11, r12
    dec rcx
    jnz .k32
    vmovups [rdx], ymm0
    vmovups [rdx+32], ymm1
    vmovups [rdx+64], ymm2
    vmovups [rdx+96], ymm3
    add rdx, 128
    add rdi, 128
    sub r14, 32
    jmp .cb
.c16:
    cmp r14, 16
    jb .c8
    vmovups ymm0, [rdx]
    vmovups ymm1, [rdx+32]
    mov r10, rsi
    mov r11, rdi
    mov rcx, rbx
.k16:
    vbroadcastss ymm4, [r10]
    vfmadd231ps ymm0, ymm4, [r11]
    vfmadd231ps ymm1, ymm4, [r11+32]
    add r10, r8
    add r11, r12
    dec rcx
    jnz .k16
    vmovups [rdx], ymm0
    vmovups [rdx+32], ymm1
    add rdx, 64
    add rdi, 64
    sub r14, 16
    jmp .cb
.c8:
    cmp r14, 8
    jb .ci
    vmovups ymm0, [rdx]
    mov r10, rsi
    mov r11, rdi
    mov rcx, rbx
.k8:
    vbroadcastss ymm4, [r10]
    vfmadd231ps ymm0, ymm4, [r11]
    add r10, r8
    add r11, r12
    dec rcx
    jnz .k8
    vmovups [rdx], ymm0
    add rdx, 32
    add rdi, 32
    sub r14, 8
    jmp .cb
.ci:
    inc r13
    jmp .li
.fim:
    vzeroupper
    add rsp, 40
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------- mm_nn: A(i,k) = A[i*k + k] -----------------------------------------------------
mm_nn:
    mov r8, [r15+TX_mm_a]
    mov r9, [r15+TX_mm_k]
    shl r9, 2
    mov r10d, 4
    mov r11, [r15+TX_mm_b]
    jmp mm_ker

; ---------- mm_tn: A e [k][m]: A(i,k) = A[k*m + i] -----------------------------------------
mm_tn:
    mov r8, [r15+TX_mm_a]
    mov r9d, 4
    mov r10, [r15+TX_mm_m]
    shl r10, 2
    mov r11, [r15+TX_mm_b]
    jmp mm_ker

; ---------- mm_nt: transpoe B [n][k] para T [k][n] (mm_tb) e faz C += A . T -----------------
mm_nt:
    mov rsi, [r15+TX_mm_b]
    mov rdi, [r15+TX_mm_tb]
    mov r8, [r15+TX_mm_n]
    mov r9, [r15+TX_mm_k]
    lea r10, [r8*4]                  ; passo de T por kk
    xor ecx, ecx                     ; j
.tj:
    cmp rcx, r8
    jae .tok
    lea rdx, [rdi+rcx*4]             ; T[0][j]
    mov r11, r9
.tk:
    mov eax, [rsi]                   ; B[j][kk] (B lido em sequencia)
    mov [rdx], eax                   ; T[kk][j]
    add rsi, 4
    add rdx, r10
    dec r11
    jnz .tk
    inc rcx
    jmp .tj
.tok:
    mov r8, [r15+TX_mm_a]
    mov r9, [r15+TX_mm_k]
    shl r9, 2
    mov r10d, 4
    mov r11, [r15+TX_mm_tb]
    jmp mm_ker

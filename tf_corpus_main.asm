bits 64
default rel
; ============ TREINO DO TRANSFORMER SOBRE O CORPUS (em fluxo, com Adam) ============
; Le o corpus em blocos e treina em sequencias de TT+1 bytes com passo TT (cada byte
; e alvo uma vez). A cada SEQLOTE sequencias aplica um passo do Adam. Salva pesos,
; estado do Adam e posicao a cada CKPT bytes (escrita atomica) e retoma do byte salvo.
; Arquivos proprios (dados/modelo_tf.*): nao mexe no modelo da MLP. -DNOVO recomeca,
; mas so apaga um modelo existente com -DSOBRESCREVER.
%include "tf_model.asm"

%define CHUNK     1048576
%ifndef CKPT
%define CKPT      67108864
%endif
%ifndef NTRAIN
%define NTRAIN    0x7FFFFFFFFFFFFFF0
%endif
%ifndef NTH
%define NTH       8                  ; threads de treino
%endif
%ifndef SEQLOTE
%define SEQLOTE   8                  ; sequencias por passo do otimizador (multiplo de NTH);
                                     ; 8 x 256 bytes: em 16 MB deu P 0,314 contra 0,251 com 32
%endif
%define TX_STRIDE (((TX_SIZE + 63) / 64) * 64)  ; bloco de contexto de cada thread
%ifndef LR
%define LR        1.0e-3
%endif
%ifndef AQUEC
%define AQUEC     500                ; passos de aquecimento da taxa de aprendizado
%endif
%ifndef LRMIN
%define LRMIN     0.1                ; fracao final da taxa (so com -DPASSOS_TOTAL=n)
%endif
%ifndef CORTE
%define CORTE     25.0               ; maior norma do gradiente medio por passo (a norma
                                     ; tipica e 6-10: o corte so pega picos)
%endif
%ifndef CORPUS
%define CORPUS    "dados/corpus-ptbr-v1.tsv"
%endif
%ifndef MODELO
%define MODELO    "dados/modelo_tf.bin"
%endif
%ifndef MODELO_TMP
%define MODELO_TMP "dados/modelo_tf.tmp"
%endif
%ifndef OTIM
%define OTIM      "dados/modelo_tf.otim"
%endif
%ifndef OTIM_TMP
%define OTIM_TMP  "dados/modelo_tf.otim.tmp"
%endif
%ifndef POSICAO
%define POSICAO   "dados/modelo_tf.pos"
%endif
%ifndef POSICAO_TMP
%define POSICAO_TMP "dados/modelo_tf.pos.tmp"
%endif

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ReadFile
extern __imp_CreateFileA
extern __imp_CloseHandle
extern __imp_GetTickCount64
extern __imp_MoveFileExA
extern __imp_SetFilePointerEx
extern __imp_GetFileSizeEx
extern __imp_GetFileAttributesA
extern __imp_ExitProcess
extern __imp_CreateEventA
extern __imp_CreateThread
extern __imp_SetEvent
extern __imp_WaitForSingleObject
extern __imp_WaitForMultipleObjects

global main

%include "tf_sistema.asm"

section .data
align 8
path_corpus: db CORPUS, 0
path_model:  db MODELO, 0
path_mtmp:   db MODELO_TMP, 0
path_otim:   db OTIM, 0
path_otmp:   db OTIM_TMP, 0
path_pos:    db POSICAO, 0
path_ptmp:   db POSICAO_TMP, 0
c_lr:        dq LR
c_b1:        dq 0.9
c_b2:        dq 0.999
c_1mb1:      dd 0.1
c_1mb2:      dd 0.001
c_b1f:       dd 0.9
c_b2f:       dd 0.999
c_epsf:      dd 1.0e-8
c_one_d:     dq 1.0
c_mil:       dq 1000.0
c_lrmin:     dq LRMIN
c_corte:     dd CORTE
msg_ckpt:    db "checkpoint: bytes "
msg_ckpt_len equ $ - msg_ckpt
msg_pal:     db "  P(alvo) medio x1000: "
msg_pal_len  equ $ - msg_pal
msg_gn:      db "  |grad| x1000: "
msg_gn_len   equ $ - msg_gn
msg_cor:     db "  passos cortados: "
msg_cor_len  equ $ - msg_cor
msg_fim:     db "tokens treinados: "
msg_fim_len  equ $ - msg_fim
msg_tempo:   db "  tempo (ms): "
msg_tempo_len equ $ - msg_tempo
msg_vel:     db "  velocidade (tokens/s): "
msg_vel_len  equ $ - msg_vel
%ifdef BASE
path_base:   db BASE, 0
msg_base:    db "erro: modelo BASE ausente ou de tamanho errado", 13, 10
msg_base_len equ $ - msg_base
%endif
msg_ep:      db "nova passada pelo corpus, tokens ate aqui: "
msg_ep_len   equ $ - msg_ep
msg_ret:     db "retomando do byte "
msg_ret_len  equ $ - msg_ret
msg_nl:      db 13, 10
msg_ecorp:   db "erro ao abrir o corpus", 13, 10
msg_ecorp_len equ $ - msg_ecorp
msg_novo:    db "-DNOVO, mas ja existe um modelo no destino: recusando para nao apagar o treino (use -DSOBRESCREVER)", 13, 10
msg_novo_len equ $ - msg_novo
msg_sempos:  db "existe um modelo sem arquivo de posicao: recusando (use -DNOVO -DSOBRESCREVER)", 13, 10
msg_sempos_len equ $ - msg_sempos
msg_estado:  db "arquivos de modelo, otimizador ou posicao incompletos", 13, 10
msg_estado_len equ $ - msg_estado

section .bss
alignb 32
AM:          resd TNP                ; Adam: primeiro momento
AV:          resd TNP                ; Adam: segundo momento
alignb 64
twk_ptr:      resq 1                  ; blocos de contexto das threads (VirtualAlloc, nth x TX_STRIDE)
ev_ini:      resq MAXTH
ev_fim:      resq MAXTH
wsum:        resq MAXTH                ; soma de P(alvo) de cada thread no lote
seqptr:      resq SEQLOTE            ; inicio de cada sequencia do lote
blote_n:     resq 1
cbuf:        resb CHUNK + (TT+1)*TB + 16
hout:        resq 1
hfile:       resq 1
hsave:       resq 1
wrote:       resd 1
bytesread:   resd 1
numbuf:      resb 24
have:        resq 1                  ; bytes validos em cbuf
cpos:        resq 1                  ; inicio da proxima sequencia em cbuf
nlote:       resq 1                  ; sequencias acumuladas no lote atual
ckpt_next:   resq 1
inicio:      resq 1
t0:          resq 1
t1:          resq 1
; estado salvo em POSICAO: bytes, soma de P(alvo), passos do Adam, b1^t, b2^t
estado:
treinados:   resq 1
soma_pal:    resq 1
passos:      resq 1
b1t:         resq 1
b2t:         resq 1
ga_tmp:      resq 1
ga_dst:      resq 1
ga_ptr:      resq 1
ga_len:      resq 1
ga_ok:       resd 1
re_ok:       resd 1
re_dst:      resq 1
re_len:      resq 1
re_h:        resq 1
lr_t:        resd 1
inv_n:       resd 1
fsize:       resq 1                  ; tamanho do corpus (bytes)
tok_ep:      resq 1                  ; tokens treinados por passada completa
gnorm:       resd 1                  ; norma do ultimo gradiente medio
ncortes:     resq 1                  ; passos com o gradiente cortado

section .text

say:
    sub rsp, 56
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [hout]
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 56
    ret
print_u:
    push rsi                         ; rsi e rdi sao preservados pela convencao x64
    push rdi
    sub rsp, 88
    lea rdi, [numbuf+20]
    mov rcx, 10
.p:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .p
    lea rax, [numbuf+20]
    sub rax, rdi
    mov rcx, rax
    mov rsi, rdi
    call say
    add rsp, 88
    pop rdi
    pop rsi
    ret

; grava_atomico: rcx = temporario, rdx = destino, r8 = dados, r9 = tamanho
grava_atomico:
    sub rsp, 88
    mov [ga_tmp], rcx
    mov [ga_dst], rdx
    mov [ga_ptr], r8
    mov [ga_len], r9
    mov edx, 0x40000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 2
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .fim
    mov [hsave], rax
    mov rcx, rax
    mov rdx, [ga_ptr]
    mov r8, [ga_len]
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    mov [ga_ok], eax
    mov rcx, [hsave]
    call [__imp_CloseHandle]
    cmp dword [ga_ok], 0
    je .fim
    mov eax, [wrote]
    cmp rax, [ga_len]
    jne .fim
    mov rcx, [ga_tmp]
    mov rdx, [ga_dst]
    mov r8d, 1
    call [__imp_MoveFileExA]
.fim:
    add rsp, 88
    ret

open_read:
    sub rsp, 56
    mov edx, 0x80000000
    mov r8d, 1
    xor r9d, r9d
    mov qword [rsp+32], 3
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    add rsp, 56
    ret

; read_exact: rcx = caminho, rdx = destino, r8 = tamanho -> eax = 1 se o arquivo tem
; exatamente esse tamanho (pede tamanho+1 ao ReadFile: arquivo maior vem com wrote > len
; e e recusado; os destinos sempre tem folga de ao menos 1 byte depois de si)
read_exact:
    sub rsp, 56
    mov [re_dst], rdx
    mov [re_len], r8
    call open_read
    cmp rax, -1
    je .falha
    mov [re_h], rax
    mov rcx, rax
    mov rdx, [re_dst]
    mov r8, [re_len]
    inc r8
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    mov [re_ok], eax
    mov rcx, [re_h]
    call [__imp_CloseHandle]
    cmp dword [re_ok], 0
    je .falha
    mov eax, [wrote]
    cmp rax, [re_len]
    jne .falha
    mov eax, 1
    add rsp, 56
    ret
.falha:
    xor eax, eax
    add rsp, 56
    ret

; salva: pesos, otimizador e posicao (nesta ordem; cada um atomico)
salva:
    sub rsp, 40
    lea rcx, [path_mtmp]
    lea rdx, [path_model]
    lea r8, [TPAR]
    mov r9d, TNP*4
    call grava_atomico
    lea rcx, [path_otmp]
    lea rdx, [path_otim]
    lea r8, [AM]
    mov r9d, TNP*8                   ; AM e AV sao contiguos
    call grava_atomico
    lea rcx, [path_ptmp]
    lea rdx, [path_pos]
    lea r8, [estado]
    mov r9d, 40
    call grava_atomico
    add rsp, 40
    ret

; carrega: eax = 1 se retomou; 0 se comeca do zero (sem arquivos)
carrega:
    sub rsp, 40
    lea rcx, [path_pos]
    call [__imp_GetFileAttributesA]
    cmp eax, -1
    je .sem_pos
    lea rcx, [path_pos]
    lea rdx, [estado]
    mov r8d, 40
    call read_exact
    test eax, eax
    jz .incompleto
    lea rcx, [path_model]
    lea rdx, [TPAR]
    mov r8d, TNP*4
    call read_exact
    test eax, eax
    jz .incompleto
    lea rcx, [path_otim]
    lea rdx, [AM]
    mov r8d, TNP*8
    call read_exact
    test eax, eax
    jz .incompleto
    mov eax, 1
    add rsp, 40
    ret
.sem_pos:
    lea rcx, [path_model]
    call [__imp_GetFileAttributesA]
    cmp eax, -1
    jne .modelo_sem_pos
    xor eax, eax
    add rsp, 40
    ret
.modelo_sem_pos:
    lea rsi, [msg_sempos]
    mov ecx, msg_sempos_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]
.incompleto:
    lea rsi, [msg_estado]
    mov ecx, msg_estado_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]

recusa_se_existe:
    sub rsp, 40
    lea rcx, [path_model]
    call [__imp_GetFileAttributesA]
    cmp eax, -1
    je .ok
    lea rsi, [msg_novo]
    mov ecx, msg_novo_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]
.ok:
    add rsp, 40
    ret

; adam: aplica um passo com o gradiente medio de nlote sequencias (TG) e zera TG
adam:
    sub rsp, 40
    inc qword [passos]
    movsd xmm0, [b1t]
    mulsd xmm0, [c_b1]
    movsd [b1t], xmm0
    movsd xmm1, [b2t]
    mulsd xmm1, [c_b2]
    movsd [b2t], xmm1
    ; lr_t = lr * sqrt(1 - b2^t) / (1 - b1^t)
    movsd xmm2, [c_one_d]
    subsd xmm2, xmm1
    sqrtsd xmm2, xmm2
    movsd xmm3, [c_one_d]
    subsd xmm3, xmm0
    divsd xmm2, xmm3
    mulsd xmm2, [c_lr]
    ; agendamento: aquecimento linear nos AQUEC primeiros passos; com -DPASSOS_TOTAL,
    ; depois cai linearmente ate LRMIN x LR no passo PASSOS_TOTAL
    movsd xmm4, [c_one_d]
    mov rax, [passos]
    cmp rax, AQUEC
    jae .pos_aq
    cvtsi2sd xmm4, rax
    mov ecx, AQUEC
    cvtsi2sd xmm5, ecx
    divsd xmm4, xmm5
    jmp .fat
.pos_aq:
%ifdef PASSOS_TOTAL
    mov rcx, PASSOS_TOTAL
    cmp rax, rcx
    jae .lrmin
    sub rax, AQUEC
    cvtsi2sd xmm5, rax
    sub rcx, AQUEC
    cvtsi2sd xmm6, rcx
    divsd xmm5, xmm6                 ; fracao do decaimento
    movsd xmm6, [c_one_d]
    subsd xmm6, [c_lrmin]
    mulsd xmm5, xmm6
    subsd xmm4, xmm5
    jmp .fat
.lrmin:
    movsd xmm4, [c_lrmin]
%endif
.fat:
    mulsd xmm2, xmm4
    cvtsd2ss xmm2, xmm2
    movss [lr_t], xmm2
    mov rax, [nlote]
    cvtsi2ss xmm0, rax
    movss xmm1, [tf_one]
    divss xmm1, xmm0
    movss [inv_n], xmm1
    ; corte do gradiente: se |g| > CORTE, g *= CORTE/|g|  (g = TG/nlote)
    lea r9, [r15+TX_TG]
    vxorps ymm0, ymm0, ymm0
    xor ecx, ecx
.nq:
    cmp rcx, TNP
    jae .nqd
    vmovups ymm1, [r9+rcx*4]
    vfmadd231ps ymm0, ymm1, ymm1
    add rcx, 8
    jmp .nq
.nqd:
    vextractf128 xmm1, ymm0, 1
    vaddps xmm0, xmm0, xmm1
    vhaddps xmm0, xmm0, xmm0
    vhaddps xmm0, xmm0, xmm0
    vzeroupper
    sqrtss xmm0, xmm0
    mulss xmm0, [inv_n]              ; norma do gradiente medio
    movss [gnorm], xmm0
    comiss xmm0, [c_corte]
    jbe .sem_corte
    movss xmm1, [c_corte]
    divss xmm1, xmm0
    mulss xmm1, [inv_n]
    movss [inv_n], xmm1
    inc qword [ncortes]
.sem_corte:
    lea r8, [TPAR]
    lea r9, [r15+TX_TG]
    lea r10, [AM]
    lea r11, [AV]
    xor ecx, ecx
.l:
    cmp rcx, TNP
    jae .f
    movss xmm0, [r9+rcx*4]
    mulss xmm0, [inv_n]              ; g
    movss xmm1, [r10+rcx*4]
    mulss xmm1, [c_b1f]
    movss xmm2, xmm0
    mulss xmm2, [c_1mb1]
    addss xmm1, xmm2
    movss [r10+rcx*4], xmm1          ; m
    movss xmm2, [r11+rcx*4]
    mulss xmm2, [c_b2f]
    movss xmm3, xmm0
    mulss xmm3, xmm0
    mulss xmm3, [c_1mb2]
    addss xmm2, xmm3
    movss [r11+rcx*4], xmm2          ; v
    sqrtss xmm2, xmm2
    addss xmm2, [c_epsf]
    divss xmm1, xmm2
    mulss xmm1, [lr_t]
    movss xmm0, [r8+rcx*4]
    subss xmm0, xmm1
    movss [r8+rcx*4], xmm0           ; w -= lr_t * m / (sqrt(v) + eps)
    mov dword [r9+rcx*4], 0          ; zera o gradiente
    inc rcx
    jmp .l
.f:
    mov qword [nlote], 0
    add rsp, 40
    ret

; aloca_twk: um bloco de contexto por thread, alocado conforme nth_v (zerado pelo sistema)
aloca_twk:
    sub rsp, 40
    xor ecx, ecx
    mov eax, [nth_v]
    imul rax, rax, TX_STRIDE
    mov rdx, rax
    mov r8d, 0x3000                  ; MEM_COMMIT | MEM_RESERVE
    mov r9d, 4                       ; PAGE_READWRITE
    call [__imp_VirtualAlloc]
    test rax, rax
    jz .falha
    mov [twk_ptr], rax
    add rsp, 40
    ret
.falha:
    mov ecx, 1
    call [__imp_ExitProcess]
; ---------- threads ---------------------------------------------------------------------
; tf_worker: rcx = indice. Cada thread tem seu bloco de contexto (r15) e seu gradiente.
; Processa as sequencias indice, indice+NTH, ... do lote atual e avisa o fim.
tf_worker:
    push rbx
    push r12
    push r15
    sub rsp, 32
    mov rbx, rcx
    imul rax, rbx, TX_STRIDE
    mov r15, [twk_ptr]
    add r15, rax
    db 0x0F, 0xAE, 0x1C, 0x24        ; stmxcsr [rsp]
    or dword [rsp], 0x8040           ; FTZ e DAZ
    db 0x0F, 0xAE, 0x14, 0x24        ; ldmxcsr [rsp]
.loop:
    lea rax, [ev_ini]
    mov rcx, [rax+rbx*8]
    mov edx, 0xFFFFFFFF
    call [__imp_WaitForSingleObject]
    lea rax, [wsum]
    mov qword [rax+rbx*8], 0
    mov r12, rbx
.s:
    cmp r12, [blote_n]
    jae .d
    lea rax, [seqptr]
    mov rax, [rax+r12*8]
    mov [r15+TX_tf_tok], rax
    call tf_forward
    call tf_backward
    lea rax, [wsum]
    movsd xmm0, [rax+rbx*8]
    addsd xmm0, [r15+TX_tf_pal]
    movsd [rax+rbx*8], xmm0
    mov eax, [nth_v]
    add r12, rax
    jmp .s
.d:
    lea rax, [ev_fim]
    mov rcx, [rax+rbx*8]
    call [__imp_SetEvent]
    jmp .loop

; init_workers: cria os eventos e as NTH threads (uma vez)
init_workers:
    push rbx
    sub rsp, 48
    xor ebx, ebx
.l:
    cmp ebx, [nth_v]
    jae .f
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_CreateEventA]        ; inicio (auto-reset)
    lea rdx, [ev_ini]
    mov [rdx+rbx*8], rax
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_CreateEventA]        ; fim (auto-reset)
    lea rdx, [ev_fim]
    mov [rdx+rbx*8], rax
    xor ecx, ecx
    xor edx, edx
    lea r8, [tf_worker]
    mov r9, rbx
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0
    call [__imp_CreateThread]
    inc ebx
    jmp .l
.f:
    add rsp, 48
    pop rbx
    ret

; lote: processa as nlote sequencias de seqptr nas threads, soma os gradientes
; das threads no TG da thread principal (zerando os delas) e aplica o Adam
lote:
    push rbx
    sub rsp, 32
    mov rax, [nlote]
    mov [blote_n], rax
    xor ebx, ebx
.ini:
    cmp ebx, [nth_v]
    jae .esp
    lea rax, [ev_ini]
    mov rcx, [rax+rbx*8]
    call [__imp_SetEvent]
    inc ebx
    jmp .ini
.esp:
    mov ecx, [nth_v]
    lea rdx, [ev_fim]
    mov r8d, 1                       ; espera todas
    mov r9d, 0xFFFFFFFF
    call [__imp_WaitForMultipleObjects]
    ; TG principal = soma dos TG das threads (8 floats por vez); zera os das threads
    lea rdi, [r15+TX_TG]
    xor ecx, ecx
.r:
    cmp rcx, TNP
    jae .rd
    vxorps ymm0, ymm0, ymm0
    vxorps ymm1, ymm1, ymm1
    xor ebx, ebx
.rw:
    cmp ebx, [nth_v]
    jae .rwd
    imul rax, rbx, TX_STRIDE
    mov rsi, [twk_ptr]
    add rsi, rax
    lea rsi, [rsi+TX_TG]
    vaddps ymm0, ymm0, [rsi+rcx*4]
    vmovups [rsi+rcx*4], ymm1
    inc ebx
    jmp .rw
.rwd:
    vmovups [rdi+rcx*4], ymm0
    add rcx, 8
    jmp .r
.rd:
    vzeroupper
    xor ebx, ebx
.ps:
    cmp ebx, [nth_v]
    jae .psd
    lea rax, [wsum]
    movsd xmm0, [soma_pal]
    addsd xmm0, [rax+rbx*8]
    movsd [soma_pal], xmm0
    inc ebx
    jmp .ps
.psd:
    call adam
    add rsp, 32
    pop rbx
    ret

; relatorio: rsi/ecx = rotulo; imprime bytes e P(alvo) media
relatorio:
    sub rsp, 40
    call say
    mov rax, [treinados]
    call print_u
    lea rsi, [msg_pal]
    mov ecx, msg_pal_len
    call say
    mov rax, [treinados]
    test rax, rax
    jz .zero
    movsd xmm0, [soma_pal]
    mulsd xmm0, [c_mil]
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    cvttsd2si rax, xmm0
    jmp .p
.zero:
    xor eax, eax
.p:
    call print_u
    lea rsi, [msg_gn]
    mov ecx, msg_gn_len
    call say
    movss xmm0, [gnorm]
    cvtss2sd xmm0, xmm0
    mulsd xmm0, [c_mil]
    cvttsd2si rax, xmm0
    call print_u
    lea rsi, [msg_cor]
    mov ecx, msg_cor_len
    call say
    mov rax, [ncortes]
    call print_u
    lea rsi, [msg_nl]
    mov ecx, 2
    call say
    add rsp, 40
    ret

main:
    sub rsp, 88
    call sis_inicia                  ; CPU, threads e pasta do projeto
    ; respeita o contrato "SEQLOTE multiplo de NTH": nunca mais que NTH threads de trabalho
    mov eax, [nth_v]
    cmp eax, NTH
    jbe .nth_ok
    mov eax, NTH
.nth_ok:
    mov [nth_v], eax
    call aloca_twk
    lea r15, [TCTX]                 ; bloco de contexto da thread principal
    sub rsp, 8
    db 0x0F, 0xAE, 0x1C, 0x24        ; stmxcsr [rsp]
    or dword [rsp], 0x8040           ; FTZ e DAZ: denormais viram zero
    db 0x0F, 0xAE, 0x14, 0x24        ; ldmxcsr [rsp]
    add rsp, 8
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout], rax
    lea rcx, [path_corpus]
    call open_read
    cmp rax, -1
    je .erro_corpus
    mov [hfile], rax
    ; tokens treinados por passada completa: as sequencias comecam em 0, TT, 2TT, ...
    ; enquanto cabem TT+1 tokens, entao E = floor((N-1)/TT)*TT
    mov rcx, rax
    lea rdx, [fsize]
    call [__imp_GetFileSizeEx]
    mov rax, [fsize]
    xor edx, edx
    mov ecx, TB
    div rcx                          ; N tokens
    xor ecx, ecx
    cmp rax, TT+1
    jb .ep_ok
    dec rax
    xor edx, edx
    mov ecx, TT
    div rcx
    imul rcx, rax, TT
.ep_ok:
    mov [tok_ep], rcx
    ; estado inicial
    mov qword [tf_seed], 1
    call tf_init_params
    lea rdi, [AM]
    mov ecx, TNP*2
    xor eax, eax
    rep stosd
    lea rdi, [r15+TX_TG]
    mov ecx, TNP
    xor eax, eax
    rep stosd
    mov qword [treinados], 0
    mov qword [soma_pal], 0
    mov qword [passos], 0
    mov rax, [c_one_d]
    mov [b1t], rax
    mov [b2t], rax
%ifndef NOVO
    call carrega
    test eax, eax
    jz .comeca
    lea rsi, [msg_ret]
    mov ecx, msg_ret_len
    call say
    mov rax, [treinados]
    call print_u
    lea rsi, [msg_nl]
    mov ecx, 2
    call say
    mov rax, [treinados]
%ifdef MULTIEPOCA
    ; depois de varias passadas, a posicao no arquivo e o resto por passada
    mov rcx, [tok_ep]
    test rcx, rcx
    jz .pos_ok
    xor edx, edx
    div rcx
    mov rax, rdx
.pos_ok:
%endif
    mov rcx, [hfile]
    imul rdx, rax, TB                ; tokens -> bytes no arquivo
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_SetFilePointerEx]
%else
%ifndef SOBRESCREVER
    call recusa_se_existe
%endif
%ifdef BASE
    ; ajuste fino (so com -DNOVO): parte dos pesos de BASE (so leitura), com otimizador e
    ; posicao novos
    lea rcx, [path_base]
    lea rdx, [TPAR]
    mov r8d, TNP*4
    call read_exact
    test eax, eax
    jnz .comeca
    lea rsi, [msg_base]
    mov ecx, msg_base_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]
%endif
%endif
.comeca:
    mov rax, [treinados]
    mov [inicio], rax
    xor edx, edx
    mov rcx, CKPT
    div rcx
    inc rax
    imul rax, rax, CKPT
    mov [ckpt_next], rax
    call init_workers
    mov qword [have], 0
    mov qword [cpos], 0
    mov qword [nlote], 0
    call [__imp_GetTickCount64]
    mov [t0], rax
.le:
    mov rax, NTRAIN
    cmp [treinados], rax
    jae .fim
    mov rcx, [hfile]
    lea rdx, [cbuf]
    add rdx, [have]
    mov r8d, CHUNK
    lea r9, [bytesread]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    test eax, eax
    jz .fim_arq
    mov eax, [bytesread]
    test eax, eax
    jz .fim_arq
    add [have], rax
    jmp .seq
.fim_arq:
%ifdef MULTIEPOCA
    ; fim do corpus: descarta o resto (menos de TT+1 tokens) e volta ao comeco
    cmp qword [tok_ep], 0
    je .fim
    mov qword [have], 0
    mov qword [cpos], 0
    mov rcx, [hfile]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_SetFilePointerEx]
    lea rsi, [msg_ep]
    mov ecx, msg_ep_len
    call relatorio
    jmp .le
%else
    jmp .fim
%endif
.seq:
    mov rax, [have]
    sub rax, [cpos]
    cmp rax, (TT+1)*TB
    jb .move
    mov rax, NTRAIN
    cmp [treinados], rax
    jae .fim
    ; guarda a sequencia no lote; as threads processam o lote inteiro de uma vez
    lea rax, [cbuf]
    add rax, [cpos]
    mov rcx, [nlote]
    lea rdx, [seqptr]
    mov [rdx+rcx*8], rax
    add qword [cpos], TT*TB
    add qword [treinados], TT
    inc qword [nlote]
    cmp qword [nlote], SEQLOTE
    jb .seq
    call lote
    mov rax, [treinados]
    cmp rax, [ckpt_next]
    jb .seq
    call salva
    lea rsi, [msg_ckpt]
    mov ecx, msg_ckpt_len
    call relatorio
    add qword [ckpt_next], CKPT
    jmp .seq
.move:
    ; o lote incompleto aponta para o buffer: processa antes de mover os bytes
    cmp qword [nlote], 0
    je .move2
    call lote
.move2:
    ; leva o resto (menos de TT+1 bytes) para o inicio do buffer
    mov rcx, [have]
    sub rcx, [cpos]
    lea rsi, [cbuf]
    add rsi, [cpos]
    lea rdi, [cbuf]
    mov [have], rcx
    rep movsb
    mov qword [cpos], 0
    jmp .le
.fim:
    cmp qword [nlote], 0
    je .fim2
    call lote
.fim2:
    call salva
    call [__imp_GetTickCount64]
    sub rax, [t0]
    mov [t1], rax
    mov rcx, [hfile]
    call [__imp_CloseHandle]
    lea rsi, [msg_fim]
    mov ecx, msg_fim_len
    call relatorio
    lea rsi, [msg_tempo]
    mov ecx, msg_tempo_len
    call say
    mov rax, [t1]
    call print_u
    lea rsi, [msg_vel]
    mov ecx, msg_vel_len
    call say
    mov rax, [treinados]
    sub rax, [inicio]
    imul rax, rax, 1000
    xor edx, edx
    mov rcx, [t1]
    test rcx, rcx
    jz .v0
    div rcx
    jmp .vp
.v0:
    xor eax, eax
.vp:
    call print_u
    lea rsi, [msg_nl]
    mov ecx, 2
    call say
    xor ecx, ecx
    call [__imp_ExitProcess]
.erro_corpus:
    lea rsi, [msg_ecorp]
    mov ecx, msg_ecorp_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]

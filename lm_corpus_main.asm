bits 64
default rel
; ============ TREINO EM FLUXO SOBRE O CORPUS PT-BR (arquivo grande) ============
; Le o arquivo em blocos (nao carrega tudo na memoria), mantendo NCTX bytes de
; contexto entre blocos. Treina ate NTRAIN bytes do corpus (contagem absoluta,
; incluindo o que ja foi treinado antes) e informa a velocidade desta execucao.
; Retomada: se POSICAO existe, carrega os pesos de MODELO e continua do byte salvo
; (com o mesmo contexto). Se existe MODELO sem POSICAO, recusa para nao sobrescrever
; um treino de origem desconhecida. -DNOVO recomeca do zero, mas so apaga um modelo
; existente se -DSOBRESCREVER tambem for dado.
%include "lm_core.asm"

%define CHUNK     1048576            ; bloco de leitura (1 MB)
%ifndef CKPT
%define CKPT      67108864           ; intervalo de checkpoint dos pesos (64 MB)
%endif
%ifndef NTRAIN
%define NTRAIN    0x7FFFFFFFFFFFFFF0 ; padrao: o arquivo inteiro (medicao: -dNTRAIN=1048576)
%endif
%ifndef BATCH
%define BATCH     256                ; amostras por lote (divididas entre os workers)
%endif
%ifndef CORPUS
%define CORPUS    "dados/corpus-ptbr-v1.tsv"   ; relativo a pasta de execucao (raiz do projeto)
%endif
%ifndef MODELO
%define MODELO    "dados/modelo_lm.bin"
%endif
%ifndef MODELO_TMP
%define MODELO_TMP "dados/modelo_lm.tmp"
%endif
%ifndef POSICAO
%define POSICAO   "dados/modelo_lm.pos"        ; bytes treinados (u64) + soma de P(alvo) (f64)
%endif
%ifndef POSICAO_TMP
%define POSICAO_TMP "dados/modelo_lm.pos.tmp"
%endif

extern __imp_GetStdHandle
extern __imp_SetFilePointerEx
extern __imp_GetFileAttributesA
extern __imp_WriteFile
extern __imp_ReadFile
extern __imp_CreateFileA
extern __imp_CloseHandle
extern __imp_GetTickCount64
extern __imp_ExitProcess
extern __imp_MoveFileExA

global main

section .data
align 8
path_corpus: db CORPUS, 0
path_model:  db MODELO, 0
path_tmp:    db MODELO_TMP, 0
path_pos:    db POSICAO, 0
path_postmp: db POSICAO_TMP, 0
msg_retoma:  db "retomando do byte "
msg_retoma_len equ $ - msg_retoma
msg_sempos:  db "existe um modelo sem arquivo de posicao: recusando para nao sobrescrever (use -DNOVO -DSOBRESCREVER para recomecar)", 13, 10
msg_novo:    db "-DNOVO, mas ja existe um modelo no destino: recusando para nao apagar o treino (use -DSOBRESCREVER)", 13, 10
msg_novo_len equ $ - msg_novo
msg_sempos_len equ $ - msg_sempos
msg_estado:  db "arquivo de posicao ou de modelo incompleto", 13, 10
msg_estado_len equ $ - msg_estado
msg_ckpt:    db "checkpoint: bytes "
msg_ckpt_len equ $ - msg_ckpt
msg_sep:     db "  "
msg_fluxo:   db "bytes treinados: "
msg_fluxo_len equ $ - msg_fluxo
msg_tempo:   db "  tempo (ms): "
msg_tempo_len equ $ - msg_tempo
msg_vel:     db "  velocidade (bytes/s): "
msg_vel_len equ $ - msg_vel
msg_nl2:     db 13, 10
msg_erro_c:  db "erro ao abrir o corpus", 13, 10
msg_erro_c_len equ $ - msg_erro_c
msg_avx:     db "CPU sem AVX2/FMA: o treino exige AVX2 e FMA", 13, 10
msg_avx_len  equ $ - msg_avx
msg_perda:   db "P(alvo) medio x1000: "
msg_perda_len equ $ - msg_perda
c_mil:       dq 1000.0

section .bss
alignb 16
hout_c:     resq 1
hfile_c:    resq 1
cbuf:       resb CHUNK + NCTX        ; [0..NCTX) = contexto, [NCTX..) = dados
bytesread:  resd 1
treinados:  resq 1
lote_n:     resq 1
ckpt_next:  resq 1
hsave_c:    resq 1
t0:         resq 1
t1:         resq 1
numbuf_c:   resb 24
wrote_c:    resd 1
inicio_c:   resq 1                   ; bytes ja treinados quando esta execucao comecou
estado:     resq 2                   ; [0] bytes treinados, [1] soma de P(alvo) (double)
ga_tmp:     resq 1
ga_dst:     resq 1
ga_ptr:     resq 1
ga_len:     resq 1
ga_ok:      resd 1
re_ok:      resd 1
re_dst:     resq 1
re_len:     resq 1
re_h:       resq 1

section .text

; ---------- say_c: rsi = texto, rcx = tamanho -> stdout ----------------------
say_c:
    sub rsp, 88
    mov r8, rcx
    mov rdx, rsi
    mov rcx, [hout_c]
    lea r9, [wrote_c]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 88
    ret

; ---------- print_u_c: rax -> stdout ----------------------------------------
print_u_c:
    push rsi                         ; rsi e rdi sao preservados pela convencao x64
    push rdi
    sub rsp, 88
    lea rdi, [numbuf_c+20]
    mov rcx, 10
.pu:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .pu
    lea rax, [numbuf_c+20]
    sub rax, rdi
    mov rcx, rax
    mov rsi, rdi
    call say_c
    add rsp, 88
    pop rdi
    pop rsi
    ret

; ---------- grava_atomico: rcx = temporario, rdx = destino, r8 = dados, r9 = tamanho ----
; Grava no temporario e so renomeia por cima do destino se a escrita foi completa.
grava_atomico:
    sub rsp, 88
    mov [ga_tmp], rcx
    mov [ga_dst], rdx
    mov [ga_ptr], r8
    mov [ga_len], r9
    mov edx, 0x40000000             ; GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 2           ; CREATE_ALWAYS
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]        ; rcx = temporario
    cmp rax, -1
    je .fim
    mov [hsave_c], rax
    mov rcx, rax
    mov rdx, [ga_ptr]
    mov r8, [ga_len]
    lea r9, [wrote_c]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    mov [ga_ok], eax
    mov rcx, [hsave_c]
    call [__imp_CloseHandle]
    cmp dword [ga_ok], 0
    je .fim
    mov eax, [wrote_c]
    cmp rax, [ga_len]
    jne .fim                        ; escrita incompleta: mantem o destino anterior
    mov rcx, [ga_tmp]
    mov rdx, [ga_dst]
    mov r8d, 1                      ; MOVEFILE_REPLACE_EXISTING
    call [__imp_MoveFileExA]
.fim:
    add rsp, 88
    ret

; ---------- save_model: grava os pesos (MODELO) e depois a posicao (POSICAO) ----------
save_model:
    sub rsp, 40
    lea rcx, [path_tmp]
    lea rdx, [path_model]
    lea r8, [PAR]
    mov r9d, NP*4
    call grava_atomico
    mov rax, [treinados]
    mov [estado], rax
    mov rax, [loss_total]
    mov [estado+8], rax
    lea rcx, [path_postmp]
    lea rdx, [path_pos]
    lea r8, [estado]
    mov r9d, 16
    call grava_atomico
    add rsp, 40
    ret

; ---------- open_read: rcx = caminho -> rax = handle ou -1 ------------------------------
open_read:
    sub rsp, 56
    mov edx, 0x80000000             ; GENERIC_READ
    mov r8d, 1                      ; FILE_SHARE_READ
    xor r9d, r9d
    mov qword [rsp+32], 3           ; OPEN_EXISTING
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    add rsp, 56
    ret

; ---------- read_exact: rcx = caminho, rdx = destino, r8 = tamanho -> eax = 1 se leu tudo
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
    lea r9, [wrote_c]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    mov [re_ok], eax
    mov rcx, [re_h]
    call [__imp_CloseHandle]
    cmp dword [re_ok], 0
    je .falha
    mov eax, [wrote_c]
    cmp rax, [re_len]
    jne .falha
    mov eax, 1
    add rsp, 56
    ret
.falha:
    xor eax, eax
    add rsp, 56
    ret

; ---------- recusa_se_existe: sai com erro se MODELO ja existe (protege o treino salvo) ----
recusa_se_existe:
    sub rsp, 40
    lea rcx, [path_model]
    call [__imp_GetFileAttributesA]
    cmp eax, -1
    je .ok
    lea rsi, [msg_novo]
    mov ecx, msg_novo_len
    call say_c
    mov ecx, 1
    call [__imp_ExitProcess]
.ok:
    add rsp, 40
    ret

; ---------- load_state: eax = 1 se carregou pesos e posicao, 0 se comeca do zero --------
load_state:
    sub rsp, 40
    lea rcx, [path_pos]
    call [__imp_GetFileAttributesA]
    cmp eax, -1
    je .sem_pos
    lea rcx, [path_pos]
    lea rdx, [estado]
    mov r8d, 16
    call read_exact
    test eax, eax
    jz .incompleto
    lea rcx, [path_model]
    lea rdx, [PAR]
    mov r8d, NP*4
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
    call say_c
    mov ecx, 1
    call [__imp_ExitProcess]
.incompleto:
    lea rsi, [msg_estado]
    mov ecx, msg_estado_len
    call say_c
    mov ecx, 1
    call [__imp_ExitProcess]

; ---------- retoma: aplica o estado carregado e posiciona o corpus com o contexto ------
retoma:
    sub rsp, 40
    mov rax, [estado]
    mov [treinados], rax
    mov rax, [estado+8]
    mov [loss_total], rax
    lea rsi, [msg_retoma]
    mov ecx, msg_retoma_len
    call say_c
    mov rax, [treinados]
    call print_u_c
    lea rsi, [msg_nl2]
    mov ecx, 2
    call say_c
    ; contexto: os NCTX bytes antes da posicao (o primeiro byte retomado ve o mesmo contexto)
    mov rdx, [treinados]
    cmp rdx, NCTX
    jb .sem_ctx
    sub rdx, NCTX
    mov rcx, [hfile_c]
    xor r8d, r8d
    xor r9d, r9d                    ; FILE_BEGIN
    call [__imp_SetFilePointerEx]
    mov rcx, [hfile_c]
    lea rdx, [cbuf]
    mov r8d, NCTX
    lea r9, [bytesread]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    jmp .fim
.sem_ctx:
    mov rcx, [hfile_c]
    xor r8d, r8d
    xor r9d, r9d
    call [__imp_SetFilePointerEx]   ; rdx = treinados (contexto inicial fica zerado)
.fim:
    add rsp, 40
    ret

; ---------- checkpoint: salva os pesos e informa o progresso -------------------
checkpoint:
    sub rsp, 88
    call save_model
    lea rsi, [msg_ckpt]
    mov ecx, msg_ckpt_len
    call say_c
    mov rax, [treinados]
    call print_u_c
    lea rsi, [msg_sep]
    mov ecx, 2
    call say_c
    lea rsi, [msg_perda]
    mov ecx, msg_perda_len
    call say_c
    mov rax, [treinados]
    movsd xmm0, [loss_total]
    mulsd xmm0, [c_mil]
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    cvttsd2si rax, xmm0
    call print_u_c
    lea rsi, [msg_nl2]
    mov ecx, 2
    call say_c
    add rsp, 88
    ret

main:
    call set_ftz
    sub rsp, 88
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout_c], rax

    ; abre o corpus
    lea rcx, [path_corpus]
    mov edx, 0x80000000             ; GENERIC_READ
    mov r8d, 1                      ; FILE_SHARE_READ
    xor r9d, r9d
    mov qword [rsp+32], 3           ; OPEN_EXISTING
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .erro
    mov [hfile_c], rax

    call check_avx2
    test eax, eax
    jz .sem_avx
    call init_params_lm
    call init_workers
    xor eax, eax
    mov [treinados], rax
    lea rax, [cbuf]                 ; zera o contexto inicial
    xor ecx, ecx
    mov rdi, rax
    mov ecx, NCTX
    xor eax, eax
    rep stosb
%ifndef NOVO
    call load_state
    test eax, eax
    jz .comeca
    call retoma
%else
%ifndef SOBRESCREVER
    call recusa_se_existe           ; -DNOVO nao apaga um modelo existente sem -DSOBRESCREVER
%endif
%endif
.comeca:
    mov rax, [treinados]
    mov [inicio_c], rax
    xor edx, edx                    ; proximo checkpoint: multiplo de CKPT apos a posicao
    mov rcx, CKPT
    div rcx
    inc rax
    imul rax, rax, CKPT
    mov [ckpt_next], rax
    call [__imp_GetTickCount64]
    mov [t0], rax

.bloco:
    mov rax, NTRAIN                 ; imediato de 64 bits (NTRAIN nao cabe em 32)
    cmp [treinados], rax
    jae .fim
    ; le ate CHUNK bytes apos o contexto
    mov rcx, [hfile_c]
    lea rdx, [cbuf+NCTX]
    mov r8d, CHUNK
    lea r9, [bytesread]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    test eax, eax
    jz .fim
    mov eax, [bytesread]
    test eax, eax
    jz .fim
    mov r12d, eax                   ; r12 = bytes lidos neste bloco
    xor r13d, r13d                  ; r13 = inicio do proximo lote no bloco
.lote:
    cmp r13, r12
    jae .fim_bloco
    mov rax, NTRAIN
    sub rax, [treinados]            ; amostras de treino restantes
    jbe .fim
    mov rdx, r12
    sub rdx, r13                    ; amostras restantes no bloco
    cmp rdx, BATCH
    jbe .n1
    mov rdx, BATCH
.n1:
    cmp rdx, rax
    jbe .n2
    mov rdx, rax
.n2:
    mov [lote_n], rdx
    lea rcx, [cbuf]
    add rcx, r13                    ; base: amostra i tem contexto em base+i
    call train_batch                ; rcx = base, rdx = n (ja em rdx)
    mov rax, [lote_n]
    add [treinados], rax
    add r13, rax
    mov rax, [treinados]
    cmp rax, [ckpt_next]
    jb .lote
    call checkpoint
    add qword [ckpt_next], CKPT
    jmp .lote
.fim_bloco:
    ; carrega os ultimos NCTX bytes do bloco para o inicio (novo contexto)
    mov ecx, NCTX
    lea rsi, [cbuf+NCTX]
    mov eax, r12d
    add rsi, rax
    sub rsi, NCTX
    lea rdi, [cbuf]
    rep movsb
    jmp .bloco

.fim:
    call save_model
    call [__imp_GetTickCount64]
    mov [t1], rax
    mov rcx, [hfile_c]
    call [__imp_CloseHandle]

    lea rsi, [msg_fluxo]
    mov ecx, msg_fluxo_len
    call say_c
    mov rax, [treinados]
    call print_u_c
    lea rsi, [msg_tempo]
    mov ecx, msg_tempo_len
    call say_c
    mov rax, [t1]
    sub rax, [t0]
    mov [t1], rax                   ; tempo em ms
    call print_u_c
    lea rsi, [msg_vel]
    mov ecx, msg_vel_len
    call say_c
    mov rax, [treinados]
    sub rax, [inicio_c]             ; so os bytes desta execucao
    imul rax, rax, 1000
    xor edx, edx
    mov rcx, [t1]
    test rcx, rcx
    jz .vel0
    div rcx
    call print_u_c
    jmp .fim_linha
.vel0:
    xor eax, eax
    call print_u_c
.fim_linha:
    lea rsi, [msg_nl2]
    mov ecx, 2
    call say_c
    lea rsi, [msg_perda]
    mov ecx, msg_perda_len
    call say_c
    mov rax, [treinados]
    test rax, rax
    jz .perda0
    movsd xmm0, [loss_total]
    mulsd xmm0, [c_mil]
    cvtsi2sd xmm1, rax
    divsd xmm0, xmm1
    cvttsd2si rax, xmm0
    call print_u_c
    jmp .perda_fim
.perda0:
    xor eax, eax
    call print_u_c
.perda_fim:
    lea rsi, [msg_nl2]
    mov ecx, 2
    call say_c
    xor ecx, ecx
    call [__imp_ExitProcess]

.sem_avx:
    lea rsi, [msg_avx]
    mov ecx, msg_avx_len
    call say_c
    mov ecx, 1
    call [__imp_ExitProcess]
.erro:
    lea rsi, [msg_erro_c]
    mov ecx, msg_erro_c_len
    call say_c
    mov ecx, 1
    call [__imp_ExitProcess]

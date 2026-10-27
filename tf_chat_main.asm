bits 64
default rel
; ============ CHAT COM O TRANSFORMER, COM APRENDIZADO CONTINUO ============
; Carrega MODELO (base, nunca alterado) e, se existir, o modelo vivo VIVO.bin/.otim.
; Cada mensagem vira "P: <mensagem>\nR:" no historico e o modelo escreve a resposta.
; Depois de cada resposta, ha um passo de Adam (forward + backward) sobre os ultimos
; TT+1 tokens do historico, e os pesos vivos sao gravados. Assim o modelo evolui com o uso.
; Digite /sair para encerrar. Opcoes de amostragem: ver tf_gen_core.asm.
%include "tf_gen_core.asm"

%define INMAX     8192               ; entrada pendente
%define LMAX      1024               ; maior mensagem (o resto e cortado)
%ifndef RMAX
%define RMAX      400                ; maior resposta (tokens)
%endif
%define HMAX      65536              ; historico (tokens)
%ifndef VIVO
%define VIVO      "dados/modelo_vivo"
%endif
%ifndef LRVIVO
%define LRVIVO    1.0e-4             ; taxa do aprendizado continuo (bem menor que a do treino)
%endif

global main

extern __imp_MoveFileExA
extern __imp_DeleteFileA

section .data
align 8
msg_ola:     db "Satiro-IA (transformer em assembly). Digite /sair para encerrar.", 13, 10
msg_ola_len  equ $ - msg_ola
msg_prompt:  db "> "
msg_ia:      db "IA:"
msg_crlf:    db 13, 10
cmd_sair:    db "/sair"
tag_p:       db "P: "
tag_r:       db 10, "R:"
p_bin:       db VIVO, ".bin", 0
p_bin_tmp:   db VIVO, ".bin.tmp", 0
p_otim:      db VIVO, ".otim", 0
p_otim_tmp:  db VIVO, ".otim.tmp", 0
c_b1d:       dq 0.9
c_b2d:       dq 0.999
c_one_dv:    dq 1.0
c_lrv:       dq LRVIVO
c_b1f:       dd 0.9
c_b2f:       dd 0.999
c_1mb1:      dd 0.1
c_1mb2:      dd 0.001
c_epsf:      dd 1.0e-8

section .bss
alignb 16
inn:        resq 1                   ; bytes pendentes em inb
ifim:       resq 1                   ; 1 = fim da entrada
lenl:       resq 1
hlen:       resq 1                   ; tokens no historico
rtam:       resq 1                   ; bytes da resposta
vg_tmp:     resq 1
vg_dst:     resq 1
vg_buf:     resq 1
vg_len:     resq 1
vg_h:       resq 1
vg_ok:      resd 1
v_lrt:      resd 1
inb:        resb INMAX
lin:        resb LMAX + 8
msgb:       resb LMAX + 16
resp:       resb RMAX * 64 + 16
hist:       resb (HMAX + 16) * TB
    ; estado do modelo vivo: Adam (AM, AV) e passos; gravado num unico arquivo .otim
vivo_blk:   resd TNP*2
v_passos:   resq 1
v_b1t:      resq 1
v_b2t:      resq 1
v_folga:    resb 8                   ; recebe o byte excedente do le tamanho+1 do .otim
desc:       resq 1                   ; 1 = descartando o resto de uma linha maior que INMAX

section .text

; ---------- le_linha: proxima linha da entrada em lin/lenl (sem CR/LF) ------------------
; eax = 0 quando a entrada acabou e nao ha mais nada.
le_linha:
    push rbx
    sub rsp, 48
.procura:
    lea rdx, [inb]
    xor ecx, ecx
.b:
    cmp rcx, [inn]
    jae .sem_lf
    cmp byte [rdx+rcx], 10
    je .achou
    inc rcx
    jmp .b
.sem_lf:
    cmp qword [inn], INMAX
    jae .tudo                        ; linha maior que o buffer: descarta ate o LF
    cmp qword [ifim], 0
    jne .fim_entrada
    mov rcx, [gc_hin]
    lea rdx, [inb]
    add rdx, [inn]
    mov r8d, INMAX
    sub r8, [inn]
    lea r9, [gc_wrote]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    test eax, eax
    jz .marca_fim
    mov eax, [gc_wrote]
    test eax, eax
    jz .marca_fim
    add [inn], rax
    jmp .procura
.marca_fim:
    mov qword [ifim], 1
    jmp .procura
.fim_entrada:
    cmp qword [inn], 0
    jne .tudo
    xor eax, eax
    add rsp, 48
    pop rbx
    ret
.tudo:
    ; linha maior que o buffer: joga fora o que veio e segue descartando ate o LF
    ; (senao o resto da linha voltaria como varias mensagens falsas)
    mov qword [desc], 1
    mov qword [inn], 0
    jmp .procura
.achou:
    lea rbx, [rcx+1]                 ; consome o LF
    cmp qword [desc], 0
    je .copia
    ; era o fim de uma linha comprida em descarte: nao emite nada
    mov qword [desc], 0
    mov rcx, [inn]
    sub rcx, rbx
    mov [inn], rcx
    lea rsi, [inb]
    add rsi, rbx
    lea rdi, [inb]
    rep movsb
    jmp .procura
.copia:
    lea rsi, [inb]
    test rcx, rcx
    jz .cr_ok
    cmp byte [rsi+rcx-1], 13
    jne .cr_ok
    dec rcx
.cr_ok:
    ; tira a marca BOM do UTF-8, se houver
    cmp rcx, 3
    jb .bom_ok
    cmp byte [rsi], 0xEF
    jne .bom_ok
    cmp byte [rsi+1], 0xBB
    jne .bom_ok
    cmp byte [rsi+2], 0xBF
    jne .bom_ok
    add rsi, 3
    sub rcx, 3
.bom_ok:
    cmp rcx, LMAX
    jbe .tam_ok
    mov ecx, LMAX
.tam_ok:
    mov [lenl], rcx
    lea rdi, [lin]
    rep movsb
    ; tira a linha consumida do buffer
    mov rcx, [inn]
    sub rcx, rbx
    mov [inn], rcx
    lea rsi, [inb]
    add rsi, rbx
    lea rdi, [inb]
    rep movsb
    mov eax, 1
    add rsp, 48
    pop rbx
    ret

; poe_tok: eax = token -> fim do historico
poe_tok:
    mov rcx, [hlen]
    lea rdx, [hist]
%ifdef TOK16
    mov [rdx+rcx*2], ax
%else
    mov [rdx+rcx], al
%endif
    inc qword [hlen]
    ret

; ---------- adam do modelo vivo: um passo com o gradiente em TG (r15) -------------------
vivo_adam:
    sub rsp, 40
    inc qword [v_passos]
    movsd xmm0, [v_b1t]
    mulsd xmm0, [c_b1d]
    movsd [v_b1t], xmm0
    movsd xmm1, [v_b2t]
    mulsd xmm1, [c_b2d]
    movsd [v_b2t], xmm1
    ; lr_t = lr * sqrt(1 - b2^t) / (1 - b1^t)
    movsd xmm2, [c_one_dv]
    subsd xmm2, xmm1
    sqrtsd xmm2, xmm2
    movsd xmm3, [c_one_dv]
    subsd xmm3, xmm0
    divsd xmm2, xmm3
    mulsd xmm2, [c_lrv]
    cvtsd2ss xmm2, xmm2
    movss [v_lrt], xmm2
    lea r8, [TPAR]
    lea r9, [r15+TX_TG]
    lea r10, [vivo_blk]
    lea r11, [vivo_blk+TNP*4]
    xor ecx, ecx
.l:
    cmp rcx, TNP
    jae .f
    movss xmm0, [r9+rcx*4]           ; g
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
    mulss xmm1, [v_lrt]
    movss xmm0, [r8+rcx*4]
    subss xmm0, xmm1
    movss [r8+rcx*4], xmm0           ; w -= lr_t * m / (sqrt(v) + eps)
    mov dword [r9+rcx*4], 0          ; zera o gradiente
    inc rcx
    jmp .l
.f:
    add rsp, 40
    ret

; ---------- vivo_passo: rcx = TT+1 tokens; forward, backward e um passo do Adam -------------
vivo_passo:
    sub rsp, 40
    mov [r15+TX_tf_tok], rcx
    call tf_forward
    call tf_backward
    call vivo_adam
    add rsp, 40
    ret

; ---------- vivo_grava: rcx = tmp, rdx = destino, r8 = dados, r9 = tamanho (troca atomica) --
vivo_grava:
    sub rsp, 72
    mov [vg_tmp], rcx
    mov [vg_dst], rdx
    mov [vg_buf], r8
    mov [vg_len], r9
    mov edx, 0x40000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 2            ; CREATE_ALWAYS
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .fim
    mov [vg_h], rax
    mov rcx, rax
    mov rdx, [vg_buf]
    mov r8, [vg_len]
    lea r9, [gc_wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    mov [vg_ok], eax
    mov rcx, [vg_h]
    call [__imp_CloseHandle]
    ; so troca o arquivo bom se o temporario ficou completo; senao, apaga o tmp
    ; e mantem o anterior (um .tmp truncado nunca vira modelo vivo)
    cmp dword [vg_ok], 0
    je .falha
    mov eax, [gc_wrote]
    cmp rax, [vg_len]
    jne .falha
    mov rcx, [vg_tmp]
    mov rdx, [vg_dst]
    mov r8d, 1                       ; MOVEFILE_REPLACE_EXISTING
    call [__imp_MoveFileExA]
    jmp .fim
.falha:
    mov rcx, [vg_tmp]
    call [__imp_DeleteFileA]
.fim:
    add rsp, 72
    ret

; ---------- vivo_salva: grava os pesos vivos e o estado do Adam -------------------------------
vivo_salva:
    sub rsp, 40
    lea rcx, [p_bin_tmp]
    lea rdx, [p_bin]
    lea r8, [TPAR]
    mov r9d, TNP*4
    call vivo_grava
    lea rcx, [p_otim_tmp]
    lea rdx, [p_otim]
    lea r8, [vivo_blk]
    mov r9d, TNP*8+24
    call vivo_grava
    add rsp, 40
    ret

; ---------- vivo_zera: estado do Adam do zero (pesos ja estao em TPAR) ----------------------
vivo_zera:
    lea rdi, [vivo_blk]
    mov ecx, TNP*2
    xor eax, eax
    rep stosd
    mov qword [v_passos], 0
    mov rax, 0x3FF0000000000000      ; 1.0
    mov [v_b1t], rax
    mov [v_b2t], rax
    ret

; ---------- vivo_carrega: pesos vivos se existirem; senao, parte do base ---------------------
vivo_carrega:
    sub rsp, 40
    lea rcx, [p_bin]
    lea rdx, [TPAR]
    mov r8d, TNP*4+1
    call gc_le_arq
    cmp rax, TNP*4
    jne .sem_vivo                    ; sem modelo vivo: TPAR ja tem o base
    lea rcx, [p_otim]
    lea rdx, [vivo_blk]
    mov r8d, TNP*8+25
    call gc_le_arq
    cmp rax, TNP*8+24
    je .fim
    call vivo_zera                   ; pesos sem estado do Adam: recomeca o Adam
    jmp .fim
.sem_vivo:
    call vivo_zera
.fim:
    add rsp, 40
    ret

; ---------- vivo_aprende: depois de cada resposta, um passo com a janela recente -------------
vivo_aprende:
    sub rsp, 40
    mov rax, [hlen]
    cmp rax, TT+1
    jb .fim                          ; historico curto demais para uma janela inteira
    mov rcx, [hlen]
    sub rcx, TT+1
    imul rcx, rcx, TB
    lea rax, [hist]
    add rcx, rax
    call vivo_passo
    call vivo_salva
.fim:
    add rsp, 40
    ret

main:
    sub rsp, 88
    call gc_inicia
    call vivo_carrega
    mov qword [inn], 0
    mov qword [ifim], 0
    mov qword [hlen], 0
    mov qword [desc], 0
    lea rsi, [msg_ola]
    mov ecx, msg_ola_len
    call gc_say
.loop:
    lea rsi, [msg_prompt]
    mov ecx, 2
    call gc_say
    call le_linha
    test eax, eax
    jz .sair
    mov rcx, [lenl]
    test rcx, rcx
    jz .loop
    cmp rcx, 5
    jne .msg
    lea rsi, [lin]
    lea rdi, [cmd_sair]
    mov ecx, 5
    repe cmpsb
    je .sair
.msg:
    ; espaco no historico: se faltar, guarda so os ultimos TT tokens
    mov rax, [hlen]
    add rax, LMAX + RMAX + 16
    cmp rax, HMAX
    jbe .cabe
    lea rsi, [hist]
    mov rax, [hlen]
    sub rax, TT
    jae .orig_ok
    xor eax, eax                     ; hlen < TT (so com HMAX pequeno): origem e 0
.orig_ok:
    imul rax, rax, TB
    add rsi, rax
    lea rdi, [hist]
    mov ecx, TT*TB
    rep movsb
    mov qword [hlen], TT
.cabe:
    ; "P: " + mensagem + "\nR:" codificados juntos (como no texto do ajuste fino)
    lea rdi, [msgb]
    lea rsi, [tag_p]
    mov ecx, 3
    rep movsb
    lea rsi, [lin]
    mov rcx, [lenl]
    rep movsb
    lea rsi, [tag_r]
    mov ecx, 3
    rep movsb
    lea rsi, [msgb]
    mov rcx, rdi
    sub rcx, rsi
    lea rdi, [hist]
    mov rax, [hlen]
    imul rax, rax, TB
    add rdi, rax
    call gc_codifica
    add [hlen], rax
    mov qword [rtam], 0
    ; tamanho maximo da resposta: -n (ate RMAX), ou RMAX
    mov r12, RMAX
    mov rax, [gc_ngen]
    test rax, rax
    jz .resp_tam
    cmp rax, RMAX
    ja .resp_tam
    mov r12, rax
.resp_tam:
.gera:
    lea rsi, [hist]
    mov rcx, [hlen]
    call tf_proximo
    mov r13d, eax
    call poe_tok
    ; texto do token; para na primeira quebra de linha
    mov ecx, r13d
    lea rdi, [resp]
    add rdi, [rtam]
    mov r14, rdi
    call gc_decodifica
    xor ecx, ecx
.nl:
    cmp rcx, rax
    jae .nl_nao
    cmp byte [r14+rcx], 10
    je .nl_sim
    inc rcx
    jmp .nl
.nl_sim:
    add [rtam], rcx
    jmp .resp_ok
.nl_nao:
    add [rtam], rax
    dec r12d
    jnz .gera
    mov eax, 10                      ; resposta longa demais: fecha a linha
    call poe_tok
.resp_ok:
    mov eax, 10                      ; separador entre os pares
    call poe_tok
    call vivo_aprende                ; a conversa vira treino: o modelo vivo evolui
    lea rsi, [msg_ia]
    mov ecx, 3
    call gc_say
    lea rsi, [resp]
    mov rcx, [rtam]
    call gc_say_utf8
    lea rsi, [msg_crlf]
    mov ecx, 2
    call gc_say
    jmp .loop
.sair:
    xor ecx, ecx
    call [__imp_ExitProcess]

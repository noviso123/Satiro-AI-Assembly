bits 64
default rel
; ============ DADOS DO AJUSTE FINO (pergunta/resposta) ============
; Le ENTRADA (TSV do Pira: id, contexto, pergunta, resposta, SemResposta) e grava em
; SAIDA o texto no formato do chat, EPOCAS vezes:
;     P: <pergunta>\nR: <resposta>\n\n
; So grava SAIDA se ela ainda nao existir (nao sobrescreve nada).
%ifndef ENTRADA
%define ENTRADA   "dados/pira_train.tsv"
%endif
%ifndef SAIDA
%define SAIDA     "build/sft_pr.txt"
%endif
%ifndef EPOCAS
%define EPOCAS    8
%endif
%define IMAX      16777216
%define OMAX      8388608

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ReadFile
extern __imp_CreateFileA
extern __imp_CloseHandle
extern __imp_ExitProcess

global main

section .data
path_in:     db ENTRADA, 0
path_out:    db SAIDA, 0
tag_p:       db "P: "
tag_r:       db 10, "R: "
msg_ok:      db "pares: "
msg_ok_len   equ $ - msg_ok
msg_by:      db "  bytes por epoca: "
msg_by_len   equ $ - msg_by
msg_nl:      db 13, 10
msg_erri:    db "erro: entrada ausente ou grande demais", 13, 10
msg_erri_len equ $ - msg_erri
msg_erro:    db "erro: SAIDA ja existe ou nao pode ser criada", 13, 10
msg_erro_len equ $ - msg_erro
msg_omax:    db "erro: saida maior que o buffer interno (8 MB); use uma entrada menor", 13, 10
msg_omax_len equ $ - msg_omax
msg_erro_g:  db "erro: gravacao incompleta (disco cheio?)", 13, 10
msg_erro_g_len equ $ - msg_erro_g

section .bss
alignb 16
hout:       resq 1
hfile:      resq 1
wrote:      resd 1
numbuf:     resb 24
ilen:       resq 1
olen:       resq 1
npares:     resq 1
campo:      resq 1
f2s:        resq 1
f2e:        resq 1
f3s:        resq 1
f3e:        resq 1
ibuf:       resb IMAX
obuf:       resb OMAX
ob_perdeu:  resd 1                   ; 1 = algum pedaco nao coube em obuf

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

; poe: rsi = bytes, rcx = quantidade -> acrescenta em obuf (sem passar de OMAX)
poe:
    mov rax, [olen]
    add rax, rcx
    cmp rax, OMAX
    ja .cheio
    lea rdi, [obuf]
    add rdi, [olen]
    mov [olen], rax
    rep movsb
    ret
.cheio:
    mov dword [ob_perdeu], 1
    ret

; fecha_linha: se a linha tem pergunta e resposta nao vazias, grava o par
fecha_linha:
    cmp qword [campo], 4
    jb .nao
    mov rax, [f2e]
    cmp rax, [f2s]
    jbe .nao
    mov rax, [f3e]
    cmp rax, [f3s]
    jbe .nao
    ; o par inteiro tem que caber no buffer: sai partido e pior que nada
    mov rax, [f2e]
    sub rax, [f2s]
    add rax, [f3e]
    sub rax, [f3s]
    add rax, 9                      ; "P: " + "\nR: " + \n + \n
    add rax, [olen]
    cmp rax, OMAX
    ja .nao
    lea rsi, [tag_p]
    mov ecx, 3
    call poe
    mov rsi, [f2s]
    mov rcx, [f2e]
    sub rcx, rsi
    call poe
    lea rsi, [tag_r]
    mov ecx, 4
    call poe
    mov rsi, [f3s]
    mov rcx, [f3e]
    sub rcx, rsi
    call poe
    lea rsi, [msg_nl+1]              ; \n
    mov ecx, 1
    call poe
    lea rsi, [msg_nl+1]
    mov ecx, 1
    call poe
    inc qword [npares]
.nao:
    ret

main:
    sub rsp, 88
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout], rax
    lea rcx, [path_in]
    mov edx, 0x80000000
    mov r8d, 1
    xor r9d, r9d
    mov qword [rsp+32], 3
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .erro_i
    mov [hfile], rax
    mov rcx, rax
    lea rdx, [ibuf]
    mov r8d, IMAX
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    mov rcx, [hfile]
    call [__imp_CloseHandle]
    mov eax, [wrote]
    cmp rax, IMAX
    jae .erro_i
    mov [ilen], rax
    mov qword [olen], 0
    mov qword [npares], 0
    ; percorre o TSV: campos separados por TAB, linhas por LF (CR e ignorado)
    lea rbx, [ibuf]
    xor r12d, r12d                   ; posicao
    mov qword [campo], 0
    mov [f2s], rbx
    mov [f2e], rbx
    mov [f3s], rbx
    mov [f3e], rbx
    mov r13, rbx                     ; inicio do campo atual
.byte:
    cmp r12, [ilen]
    jae .fim_texto
    movzx eax, byte [rbx+r12]
    cmp eax, 9
    je .tab
    cmp eax, 10
    je .lf
    inc r12
    jmp .byte
.tab:
    lea rdx, [rbx+r12]
    call marca_campo
    inc qword [campo]
    inc r12
    lea r13, [rbx+r12]
    jmp .byte
.lf:
    lea rdx, [rbx+r12]
    call marca_campo
    inc qword [campo]
    call fecha_linha
    mov qword [campo], 0
    mov [f2s], rbx
    mov [f2e], rbx
    mov [f3s], rbx
    mov [f3e], rbx
    inc r12
    lea r13, [rbx+r12]
    jmp .byte
.fim_texto:
    lea rdx, [rbx+r12]
    call marca_campo
    inc qword [campo]
    call fecha_linha
    ; se algo nao coube, a saida ficaria incompleta: erro em vez de sucesso mudo
    cmp dword [ob_perdeu], 0
    je .sem_perda
    lea rsi, [msg_omax]
    mov ecx, msg_omax_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]
.sem_perda:
    ; uma epoca pronta em obuf; grava EPOCAS vezes
    lea rcx, [path_out]
    mov edx, 0x40000000
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 1            ; CREATE_NEW: falha se ja existe
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    cmp rax, -1
    je .erro_o
    mov [hfile], rax
    mov r14d, EPOCAS
    test r14d, r14d
    jz .ep_fim                      ; EPOCAS=0: nao entra no laco (evita underflow)
.ep:
    mov rcx, [hfile]
    lea rdx, [obuf]
    mov r8, [olen]
    lea r9, [wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    mov eax, [wrote]
    cmp rax, [olen]
    jne .erro_g
    dec r14d
    jnz .ep
.ep_fim:
    mov rcx, [hfile]
    call [__imp_CloseHandle]
    lea rsi, [msg_ok]
    mov ecx, msg_ok_len
    call say
    mov rax, [npares]
    call print_u
    lea rsi, [msg_by]
    mov ecx, msg_by_len
    call say
    mov rax, [olen]
    call print_u
    lea rsi, [msg_nl]
    mov ecx, 2
    call say
    xor ecx, ecx
    call [__imp_ExitProcess]
.erro_i:
    lea rsi, [msg_erri]
    mov ecx, msg_erri_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]
.erro_o:
    lea rsi, [msg_erro]
    mov ecx, msg_erro_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]
.erro_g:
    lea rsi, [msg_erro_g]
    mov ecx, msg_erro_g_len
    call say
    mov ecx, 1
    call [__imp_ExitProcess]

; marca_campo: r13 = inicio, rdx = fim (sem o separador; tira um CR final)
marca_campo:
    cmp rdx, r13
    jbe .m
    cmp byte [rdx-1], 13
    jne .m
    dec rdx
.m:
    cmp qword [campo], 2
    jne .n3
    mov [f2s], r13
    mov [f2e], rdx
    ret
.n3:
    cmp qword [campo], 3
    jne .x
    mov [f3s], r13
    mov [f3e], rdx
.x:
    ret

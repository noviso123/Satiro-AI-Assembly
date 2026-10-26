; ============ ASM: montador x86-64 (driver) ============
; Uso: asm <entrada.asm> <saida.obj>
; Fases: pre-processador -> passagem 1 (rotulos/tamanhos) -> passagem 2 (dados,
; relocacoes) -> escritor COFF.
bits 64
default rel

%include "tools/asm/as_base.asm"
%include "tools/asm/as_pre.asm"
%include "tools/asm/as_asm.asm"
%include "tools/asm/as_expr.asm"
%include "tools/asm/as_regs.asm"
%include "tools/asm/as_opnd.asm"
%include "tools/asm/as_enc.asm"
%include "tools/asm/as_stmt.asm"
%include "tools/asm/as_flt.asm"
%include "tools/asm/as_coff.asm"

global main

section .text

; ---------- as_run_pass: processa todas as linhas de as_exbuf
as_run_pass:
    AS_ENTER
    mov qword [as_cur], 1
    mov qword [as_off+8], 0
    mov qword [as_off+16], 0
    mov qword [as_off+24], 0
    mov qword [as_rel_n], 0
    mov qword [as_rel_n+8], 0
    mov qword [as_rel_n+16], 0
    mov qword [as_lastglen], 0
    mov qword [as_lineno], 0
    mov qword [as_ifdep], 0
    lea rax, [as_exbuf]
    mov [rl_pos], rax               ; inicio da linha atual
    mov rax, [as_exlen]
    lea rdx, [as_exbuf]
    add rax, rdx
    mov [rl_end], rax               ; fim do texto expandido
.linha:
    mov rax, [rl_pos]
    cmp rax, [rl_end]
    jae .fim
    ; procura o fim da linha (\n) ou do texto
    mov rdx, rax
.acha:
    cmp rdx, [rl_end]
    jae .achou
    cmp byte [rdx], 10
    je .achou
    inc rdx
    jmp .acha
.achou:
    mov [as_lp], rax
    mov [as_le], rdx
    inc qword [as_lineno]
    mov [rl_next], rdx
    call as_cond_line
    test eax, eax
    jz .pulada
    call as_stmt
.pulada:
    mov rax, [rl_next]
    inc rax
    mov [rl_pos], rax
    jmp .linha
.fim:
    AS_LEAVE
    ret

; ---------- as_cond_line: diretivas %if/%else/%endif/%error emitidas pelo pre-processador
; (condicoes com simbolos, avaliadas aqui, na passagem) e pulo de linhas inativas.
; -> eax = 1 se a linha deve ser assemblada; 0 se e diretiva ou esta inativa.
as_cond_line:
    AS_ENTER
    mov rsi, [as_lp]
.sp:
    cmp rsi, [as_le]
    jae .normal
    cmp byte [rsi], ' '
    jne .sp2
    inc rsi
    jmp .sp
.sp2:
    cmp byte [rsi], '%'
    jne .normal
    inc rsi
    mov [as_cl_pos], rsi
    lea rdi, [as_w_if]
    call as_cl_match
    test eax, eax
    jnz .d_if
    mov rsi, [as_cl_pos]
    lea rdi, [as_w_else]
    call as_cl_match
    test eax, eax
    jnz .d_else
    mov rsi, [as_cl_pos]
    lea rdi, [as_w_endif]
    call as_cl_match
    test eax, eax
    jnz .d_endif
    mov rsi, [as_cl_pos]
    lea rdi, [as_w_error]
    call as_cl_match
    test eax, eax
    jnz .d_error
    lea rsi, [as_e_dirdesc]
    jmp as_fail_plain
.d_if:
    call as_cl_ativo
    mov [as_pai], rax
    mov rsi, [as_cl_pos]
    add rsi, 2                      ; depois de "if"
    mov [as_lp], rsi
    call as_if_expr                 ; eax = condicao
    and rax, [as_pai]               ; bloco ativo = condicao e pai ativo
    mov rdx, [as_ifdep]
    lea rcx, [as_ifcur]
    mov [rcx+rdx*8], rax
    lea rcx, [as_ifpar]
    mov rax, [as_pai]
    mov [rcx+rdx*8], rax
    inc qword [as_ifdep]
    jmp .nao_asm
.d_else:
    mov rdx, [as_ifdep]
    test rdx, rdx
    jz .nao_asm
    dec rdx
    lea rcx, [as_ifpar]
    cmp qword [rcx+rdx*8], 0
    je .nao_asm
    lea rcx, [as_ifcur]
    xor qword [rcx+rdx*8], 1
    jmp .nao_asm
.d_endif:
    cmp qword [as_ifdep], 0
    je .nao_asm
    dec qword [as_ifdep]
    jmp .nao_asm
.d_error:
    call as_cl_ativo
    test eax, eax
    jz .nao_asm
    mov rsi, [as_cl_pos]
    add rsi, 5                      ; depois de "error"
    lea rdi, [as_errbuf]
    xor ecx, ecx
.cp:
    cmp rsi, [as_le]
    jae .cp_fim
    cmp ecx, 500
    jae .cp_fim
    mov al, [rsi]
    mov [rdi+rcx], al
    inc rsi
    inc rcx
    jmp .cp
.cp_fim:
    mov byte [rdi+rcx], 0
    lea rsi, [as_errbuf]
    jmp as_fail_plain
.normal:
    call as_cl_ativo
    AS_LEAVE
    ret
.nao_asm:
    xor eax, eax
    AS_LEAVE
    ret

; as_cl_ativo: eax = 1 se o trecho atual esta ativo (sem bloco aberto ou bloco ativo)
as_cl_ativo:
    mov rdx, [as_ifdep]
    test rdx, rdx
    jz .sim
    dec rdx
    lea rcx, [as_ifcur]
    cmp qword [rcx+rdx*8], 0
    je .nao
.sim:
    mov eax, 1
    ret
.nao:
    xor eax, eax
    ret

; as_cl_match: rsi = texto, rdi = palavra (zero-terminada) -> eax = 1 se casa e nao segue letra
as_cl_match:
    mov rdx, rsi
.l:
    mov cl, [rdi]
    test cl, cl
    jz .fim_palavra
    cmp [rdx], cl
    jne .nao
    inc rdx
    inc rdi
    jmp .l
.fim_palavra:
    mov cl, [rdx]
    cmp cl, '_'
    je .nao
    cmp cl, '0'
    jb .ok
    cmp cl, '9'
    jbe .nao
    cmp cl, 'A'
    jb .ok
    cmp cl, 'Z'
    jbe .nao
    cmp cl, 'a'
    jb .ok
    cmp cl, 'z'
    jbe .nao
.ok:
    mov eax, 1
    ret
.nao:
    xor eax, eax
    ret

; as_if_expr: le "expressao OP expressao" a partir de as_lp -> eax = 1 se verdadeiro.
; Os dois lados precisam estar definidos nesta passagem (senao erro).
as_if_expr:
    AS_ENTER
    call as_skipsp
    call ex_expr
    cmp qword [E_U], 0
    jne .indef
    mov rax, [E_V]
    mov [as_ifa], rax
    call as_skipsp
    mov rsi, [as_lp]
    mov al, [rsi]
    cmp al, '<'
    je .lt
    cmp al, '>'
    je .gt
    cmp al, '='
    je .eq
    cmp al, '!'
    je .ne
    jmp .erro_op
.lt:
    inc rsi
    xor ecx, ecx
    cmp byte [rsi], '='
    jne .op_ok
    inc rsi
    mov ecx, 1
    jmp .op_ok
.gt:
    inc rsi
    mov ecx, 2
    cmp byte [rsi], '='
    jne .op_ok
    inc rsi
    mov ecx, 3
    jmp .op_ok
.eq:
    inc rsi
    mov ecx, 4
    jmp .op_ok
.ne:
    inc rsi
    cmp byte [rsi], '='
    jne .erro_op
    inc rsi
    mov ecx, 5
.op_ok:
    mov [as_ifop], rcx
    mov [as_lp], rsi
    call as_skipsp
    call ex_expr
    cmp qword [E_U], 0
    jne .indef
    mov rcx, [as_ifop]
    cmp rcx, 0
    je .c0
    cmp rcx, 1
    je .c1
    cmp rcx, 2
    je .c2
    cmp rcx, 3
    je .c3
    cmp rcx, 4
    je .c4
    jmp .c5
.c0:
    mov rdx, [as_ifa]
    cmp rdx, [E_V]
    setl al
    jmp .out
.c1:
    mov rdx, [as_ifa]
    cmp rdx, [E_V]
    setle al
    jmp .out
.c2:
    mov rdx, [as_ifa]
    cmp rdx, [E_V]
    setg al
    jmp .out
.c3:
    mov rdx, [as_ifa]
    cmp rdx, [E_V]
    setge al
    jmp .out
.c4:
    mov rdx, [as_ifa]
    cmp rdx, [E_V]
    sete al
    jmp .out
.c5:
    mov rdx, [as_ifa]
    cmp rdx, [E_V]
    setne al
.out:
    movzx eax, al
    AS_LEAVE
    ret
.indef:
    lea rsi, [as_e_ifind]
    jmp as_fail_plain
.erro_op:
    lea rsi, [as_e_ifop]
    jmp as_fail_plain

; ---------- as_defs_cmdline: cada -DNOME na linha de comando vira %define NOME 1 ------------
as_defs_cmdline:
    AS_ENTER
    call [__imp_GetCommandLineA]
    mov rsi, rax
.tok:
    cmp byte [rsi], 0
    je .fim
    cmp byte [rsi], ' '
    je .esp
    cmp byte [rsi], 9
    jne .le
.esp:
    inc rsi
    jmp .tok
.le:
    ; extrai o token em as_tokbuf
    lea rdi, [as_tokbuf]
    xor ecx, ecx
    cmp byte [rsi], '"'
    jne .cru
    ; token entre aspas (forma usada pelo bash/msys): \" vira ", termina na aspa de fecho
    inc rsi
.q:
    mov al, [rsi]
    test al, al
    jz .tok_fim
    cmp al, '\'
    jne .q_aspa
    cmp byte [rsi+1], '"'
    jne .q_copia
    mov al, '"'
    inc rsi
    jmp .q_copia
.q_aspa:
    cmp al, '"'
    jne .q_copia
    inc rsi
    jmp .tok_fim
.q_copia:
    cmp ecx, 510
    jae .q_pula
    mov [rdi+rcx], al
    inc rcx
.q_pula:
    inc rsi
    jmp .q
.cru:
    ; token sem aspas (forma do cmd/.bat): copia como esta, aspas internas incluidas
    mov al, [rsi]
    test al, al
    jz .tok_fim
    cmp al, ' '
    je .tok_fim
    cmp al, 9
    je .tok_fim
    cmp ecx, 510
    jae .c_pula
    mov [rdi+rcx], al
    inc rcx
.c_pula:
    inc rsi
    jmp .cru
.tok_fim:
    mov byte [rdi+rcx], 0
    cmp byte [as_tokbuf], '-'
    jne .tok
    cmp byte [as_tokbuf+1], 'D'
    jne .tok
    push rsi
    lea rsi, [as_tokbuf+2]
    lea rdi, [as_dname]
    xor ecx, ecx
.copia:
    mov al, [rsi]
    test al, al
    jz .copiou
    cmp al, '='
    je .copiou
    cmp ecx, 255
    jae .copiou
    mov [rdi+rcx], al
    inc rcx
    inc rsi
    jmp .copia
.copiou:
    mov byte [rdi+rcx], 0
    ; -DNOME=valor; sem '=' o valor e 1
    lea rdi, [as_dvalor]
    mov edx, 1
    cmp byte [rsi], '='
    jne .define
    inc rsi
    lea rdi, [as_dvbuf]
    xor edx, edx
.valor:
    mov al, [rsi]
    test al, al
    jz .define
    cmp edx, 255
    jae .define
    mov [rdi+rdx], al
    inc rdx
    inc rsi
    jmp .valor
.define:
    mov byte [rdi+rdx], 0
    lea rsi, [as_dname]
    call pre_define                 ; pre_define(nome, valor, tamanho)
    pop rsi
    jmp .tok
.fim:
    AS_LEAVE
    ret

section .data
as_dvalor:  db "1", 0
as_w_if:    db "if", 0
as_w_else:  db "else", 0
as_w_endif: db "endif", 0
as_w_error: db "error", 0
as_e_dirdesc: db "diretiva desconhecida", 0
as_e_ifind: db "%if: simbolo indefinido (precisa estar definido antes)", 0
as_e_ifop:  db "%if: operador desconhecido", 0

section .bss
as_dname:   resb 256
as_dvbuf:   resb 256
as_tokbuf:  resb 512
as_ifcur:   resq AS_COND_MAX        ; bloco %if ativo (ja considerando o pai)
as_ifpar:   resq AS_COND_MAX        ; pai ativo quando o bloco abriu
as_ifdep:   resq 1
as_pai:     resq 1
as_cl_pos:  resq 1
as_ifa:     resq 1
as_ifop:    resq 1
as_errbuf:  resb 512
rl_pos:     resq 1
rl_end:     resq 1
rl_next:    resq 1

section .text
; ---------- main ------------------------------------------------------------------------
main:
    AS_ENTER
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [as_hout], rax
    call as_cmdline
    test eax, eax
    jnz .args_ok
    lea rsi, [as_s_usage]
    call as_say
    mov ecx, 2
    call [__imp_ExitProcess]
.args_ok:
    call as_defs_cmdline
    ; 1) pre-processador: le o arquivo e os %include
    mov qword [pre_level], 0
    lea rsi, [as_srcpath]
    call pre_file
    ; 2) duas passagens
    mov qword [as_pass], 1
    call as_run_pass
    mov qword [as_pass], 2
    call as_run_pass
    ; 3) objeto COFF
    call as_write_coff
    xor ecx, ecx
    call [__imp_ExitProcess]

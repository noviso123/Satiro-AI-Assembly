; ============ ASM: codificador de instrucoes x86-64 ============
; Fase 1 (validada byte a byte contra o NASM): registradores e imediatos em ALU
; (add/or/adc/sbb/and/sub/xor/cmp), mov, push, pop, ret.
; Fase 2: operandos de memoria [base+indice*escala+deslocamento], RIP-relativo com
; relocacao, lea, push/pop de memoria, call/jmp (rel32 e [memoria]), jcc.
; As demais instrucoes sao rejeitadas com mensagem clara.
; Validacao: tests/as_enc_check.ps1 compara os bytes com o NASM.

section .bss
alignb 16
ib_body:        resb 40                 ; opcode, ModRM, SIB, deslocamento, imediato
ib_blen:        resq 1
ib_pfx66:       resq 1                  ; 1 = prefixo 66
ib_rex:         resq 1                  ; bits W,R,X,B (0 = sem REX)
ib_rexf:        resq 1                  ; 1 = forca REX (registradores byte spl..dil)
ib_size:        resq 1                  ; tamanho da operacao (1,2,4,8)
ib_mn:          resq 1                  ; classe do mnemonico
ib_base:        resq 1                  ; parametro do mnemonico
ib_ext:         resq 1                  ; extra do mnemonico (prefixo, mapa, W)
ib_tmp:         resq 4
ib_itmp:        resq 3
ib_rep:         resq 1                  ; prefixo rep (0, F2 ou F3)
ib_nops:        resq 1
ib_immv:       resq 1
ib_out:         resb 64
ib_outlen:      resq 1
ib_regf:        resq 1                  ; campo reg do ModRM (0..15)
ib_rmi:         resq 1                  ; operando r/m (indice)
ins_start:      resq 1                  ; deslocamento da instrucao na secao atual
; memoria do operando r/m
mm_b:           resq 1
mm_i:           resq 1
mm_s:           resq 1
mm_d:           resq 1
mm_dk:          resq 1
mm_ds:          resq 1
mm_du:          resq 1
; fixup pendente (campo de 4 bytes relativo ou de 8 bytes absoluto)
fx_on:          resq 1
fx_at:          resq 1                  ; posicao do campo no corpo
fx_rip:         resq 1                  ; 1 = rel32 (RIP/salto), 0 = abs64
fx_v:           resq 1
fx_k:           resq 1
fx_s:           resq 1
fx_u:           resq 1

section .data
align 8
as_e_ins:       db "instrucao ainda nao suportada pelo montador", 0
as_e_nsz:       db "tamanho de operacao indefinido", 0
as_e_nimmsym:   db "imediato simbolico ainda nao suportado", 0
as_e_nform:     db "combinacao de operandos nao suportada", 0
as_e_nmemsym:   db "deslocamento simbolico com base nao suportado", 0
as_e_nrel:      db "salto para simbolo externo nao suportado", 0

; tabela de mnemonicos: nome ZT, classe, parametro
as_mntab1:
    db "add", 0, 1, 0x00, 0
    db "or", 0, 1, 0x08, 0
    db "adc", 0, 1, 0x10, 0
    db "sbb", 0, 1, 0x18, 0
    db "and", 0, 1, 0x20, 0
    db "sub", 0, 1, 0x28, 0
    db "xor", 0, 1, 0x30, 0
    db "cmp", 0, 1, 0x38, 0
    db "mov", 0, 2, 0x00, 0
    db "lea", 0, 3, 0x00, 0
    db "push", 0, 8, 0x00, 0
    db "pop", 0, 9, 0x00, 0
    db "call", 0, 10, 0x00, 0
    db "jmp", 0, 11, 0x00, 0
    db "ret", 0, 13, 0x00, 0
    db "jo", 0, 12, 0x00, 0
    db "jno", 0, 12, 0x01, 0
    db "jb", 0, 12, 0x02, 0
    db "jc", 0, 12, 0x02, 0
    db "jnae", 0, 12, 0x02, 0
    db "jae", 0, 12, 0x03, 0
    db "jnb", 0, 12, 0x03, 0
    db "jnc", 0, 12, 0x03, 0
    db "je", 0, 12, 0x04, 0
    db "jz", 0, 12, 0x04, 0
    db "jne", 0, 12, 0x05, 0
    db "jnz", 0, 12, 0x05, 0
    db "jbe", 0, 12, 0x06, 0
    db "jna", 0, 12, 0x06, 0
    db "ja", 0, 12, 0x07, 0
    db "jnbe", 0, 12, 0x07, 0
    db "js", 0, 12, 0x08, 0
    db "jns", 0, 12, 0x09, 0
    db "jp", 0, 12, 0x0A, 0
    db "jnp", 0, 12, 0x0B, 0
    db "jl", 0, 12, 0x0C, 0
    db "jnge", 0, 12, 0x0C, 0
    db "jge", 0, 12, 0x0D, 0
    db "jnl", 0, 12, 0x0D, 0
    db "jle", 0, 12, 0x0E, 0
    db "jng", 0, 12, 0x0E, 0
    db "jg", 0, 12, 0x0F, 0
    db "jnle", 0, 12, 0x0F, 0
    db "test", 0, 4, 0x84, 0
    db "not", 0, 5, 0x02, 0
    db "neg", 0, 5, 0x03, 0
    db "mul", 0, 5, 0x04, 0
    db "imul1", 0, 5, 0x05, 0
    db "div", 0, 5, 0x06, 0
    db "idiv", 0, 5, 0x07, 0
    db "inc", 0, 6, 0x00, 0
    db "dec", 0, 6, 0x01, 0
    db "shl", 0, 7, 0x04, 0
    db "sal", 0, 7, 0x04, 0
    db "shr", 0, 7, 0x05, 0
    db "sar", 0, 7, 0x07, 0
    db "rol", 0, 7, 0x00, 0
    db "ror", 0, 7, 0x01, 0
    db "rcl", 0, 7, 0x02, 0
    db "rcr", 0, 7, 0x03, 0
    db "movzx", 0, 14, 0xB6, 0
    db "movsx", 0, 14, 0xBE, 0
    db "movsxd", 0, 15, 0x00, 0
    db "imul", 0, 16, 0x00, 0
    db "bsr", 0, 60, 0x00, 0
    db "bsf", 0, 61, 0x00, 0
    db "bt", 0, 62, 0xA3, 0
    db "bts", 0, 62, 0xAB, 0
    db "btr", 0, 62, 0xB3, 0
    db "btc", 0, 62, 0xBB, 0
    db "nop", 0, 19, 0x00, 0
    db "cpuid", 0, 20, 0x00, 0
    db "xgetbv", 0, 21, 0x00, 0
    db "cqo", 0, 22, 0x00, 0
    db "stosb", 0, 18, 0xAA, 0
    db "movsb", 0, 18, 0xA4, 0
    db "cmpsb", 0, 18, 0xA6, 0
    db "stosq", 0, 26, 0xAB, 0
    db "movsq", 0, 26, 0xA5, 0
    db "movsd_s", 0, 27, 0xA5, 0
    db "stosd", 0, 27, 0xAB, 0
    db "stosw", 0, 28, 0xAB, 0
    db "sete", 0, 17, 4, 0
    db "setc", 0, 17, 2, 0
    db "setae", 0, 17, 3, 0
    db "setnle", 0, 17, 15, 0
    db "setge", 0, 17, 13, 0
    db "setnae", 0, 17, 2, 0
    db "setno", 0, 17, 1, 0
    db "setl", 0, 17, 12, 0
    db "setnl", 0, 17, 13, 0
    db "setnge", 0, 17, 12, 0
    db "setnc", 0, 17, 3, 0
    db "setg", 0, 17, 15, 0
    db "setnz", 0, 17, 5, 0
    db "seta", 0, 17, 7, 0
    db "setns", 0, 17, 9, 0
    db "setng", 0, 17, 14, 0
    db "setle", 0, 17, 14, 0
    db "seto", 0, 17, 0, 0
    db "setna", 0, 17, 6, 0
    db "sets", 0, 17, 8, 0
    db "setbe", 0, 17, 6, 0
    db "setne", 0, 17, 5, 0
    db "setz", 0, 17, 4, 0
    db "setnbe", 0, 17, 7, 0
    db "setnb", 0, 17, 3, 0
    db "setb", 0, 17, 2, 0
    db "movsd", 0, 41, 0x10, 7
    db "addsd", 0, 40, 0x58, 7
    db "mulsd", 0, 40, 0x59, 7
    db "subsd", 0, 40, 0x5C, 7
    db "divsd", 0, 40, 0x5E, 7
    db "sqrtsd", 0, 40, 0x51, 7
    db "minsd", 0, 40, 0x5D, 7
    db "maxsd", 0, 40, 0x5F, 7
    db "comisd", 0, 40, 0x2F, 5
    db "xorpd", 0, 40, 0x57, 5
    db "andpd", 0, 40, 0x54, 5
    db "cvtsi2sd", 0, 42, 0x2A, 7
    db "cvttsd2si", 0, 43, 0x2C, 7
    db "cvtsd2si", 0, 43, 0x2D, 7
    db "vmovupd", 0, 31, 0x10, 5
    db "vmovapd", 0, 31, 0x28, 5
    db "vaddpd", 0, 30, 0x58, 5
    db "vsubpd", 0, 30, 0x5C, 5
    db "vmulpd", 0, 30, 0x59, 5
    db "vdivpd", 0, 30, 0x5E, 5
    db "vmaxpd", 0, 30, 0x5F, 5
    db "vminpd", 0, 30, 0x5D, 5
    db "vxorpd", 0, 30, 0x57, 5
    db "vhaddpd", 0, 30, 0x7C, 5
    db "vfmadd231pd", 0, 30, 0xB8, 25
    db "vbroadcastsd", 0, 31, 0x19, 9
    db "vextractf128", 0, 32, 0x19, 13
    db "vpermilpd", 0, 33, 0x05, 13
    db "vzeroupper", 0, 34, 0x00, 0
    db "vmaxsd", 0, 30, 0x5F, 7
    db "movss", 0, 41, 0x10, 6
    db "addss", 0, 40, 0x58, 6
    db "mulss", 0, 40, 0x59, 6
    db "subss", 0, 40, 0x5C, 6
    db "divss", 0, 40, 0x5E, 6
    db "sqrtss", 0, 40, 0x51, 6
    db "maxss", 0, 40, 0x5F, 6
    db "minss", 0, 40, 0x5D, 6
    db "comiss", 0, 40, 0x2F, 4
    db "xorps", 0, 40, 0x57, 4
    db "addps", 0, 40, 0x58, 4
    db "mulps", 0, 40, 0x59, 4
    db "cvtsi2ss", 0, 42, 0x2A, 6
    db "cvttss2si", 0, 43, 0x2C, 6
    db "vmovups", 0, 31, 0x10, 4
    db "vmovaps", 0, 31, 0x28, 4
    db "vaddps", 0, 30, 0x58, 4
    db "vsubps", 0, 30, 0x5C, 4
    db "vmulps", 0, 30, 0x59, 4
    db "vdivps", 0, 30, 0x5E, 4
    db "vmaxps", 0, 30, 0x5F, 4
    db "vminps", 0, 30, 0x5D, 4
    db "vxorps", 0, 30, 0x57, 4
    db "vfmadd231ps", 0, 30, 0xB8, 9
    db "vbroadcastss", 0, 31, 0x18, 9
    db "vhaddps", 0, 30, 0x7C, 7
    db "vpermilps", 0, 33, 0x04, 13
    db "vmaxss", 0, 30, 0x5F, 6
    db "cvtss2sd", 0, 40, 0x5A, 6
    db "cvtsd2ss", 0, 40, 0x5A, 7
    db "movaps", 0, 40, 0x28, 4
    db 0

section .data
align 8
as_s_rep_e:  db "rep", 0
as_s_repe_e: db "repe", 0
as_s_repne_e: db "repne", 0
as_s_rep_f: db 0

section .text

; ---------- as_insn: mnemonico em as_mn; operandos a partir de as_lp -------------------
as_insn:
    mov qword [ib_rep], 0
    lea rsi, [as_mn]
    lea rdi, [as_s_repne_e]
    call as_streq
    test eax, eax
    jnz .rep_f2
    lea rsi, [as_mn]
    lea rdi, [as_s_repe_e]
    call as_streq
    test eax, eax
    jnz .rep_f3
    lea rsi, [as_mn]
    lea rdi, [as_s_rep_e]
    call as_streq
    test eax, eax
    jz .sem_rep_ins
.rep_f3:
    mov qword [ib_rep], 0xF3
    jmp .rep_next
.rep_f2:
    mov qword [ib_rep], 0xF2
.rep_next:
    call as_ident
    test rcx, rcx
    jz .erro_ins
    mov rsi, rax
    lea rdi, [as_mn]
    call as_lower_copy
.sem_rep_ins:
    mov rax, [as_cur]
    lea rdx, [as_off]
    mov rax, [rdx+rax*8]
    mov [ins_start], rax
    mov qword [op_n], 0
.ops:
    call as_peek
    test al, al
    jz .ops_fim
    call as_opnd
    inc qword [op_n]
    call as_peek
    cmp al, ','
    jne .ops_fim
    inc qword [as_lp]
    jmp .ops
.ops_fim:
    mov rax, [op_n]
    mov [ib_nops], rax
    ; "movsd" sem operandos e a instrucao de string (A5), nao o SSE movsd
    cmp qword [op_n], 0
    jne .busca
    mov rax, [as_mn]
    mov rdx, 0xFFFFFFFFFFFF
    and rax, rdx
    mov rdx, 0x006473766F6D
    cmp rax, rdx
    jne .busca
    mov rax, 0x00735F6473766F6D     ; "movsd_s", 0
    mov [as_mn], rax
.busca:
    call enc_busca
    cmp rax, -1
    je .erro_ins
    mov rax, [ib_mn]
    cmp rax, 4
    je enc_test
    cmp rax, 5
    je enc_grp
    cmp rax, 6
    je enc_incdec
    cmp rax, 7
    je enc_shift
    cmp rax, 14
    je enc_movx
    cmp rax, 15
    je enc_movsxd
    cmp rax, 16
    je enc_imul
    cmp rax, 60
    je enc_bitscan
    cmp rax, 61
    je enc_bitscan
    cmp rax, 62
    je enc_bt
    cmp rax, 17
    je enc_setcc
    cmp rax, 18
    je enc_str
    cmp rax, 26
    je enc_str
    cmp rax, 27
    je enc_str
    cmp rax, 28
    je enc_str
    cmp rax, 19
    je enc_nop
    cmp rax, 20
    je enc_cpuid
    cmp rax, 21
    je enc_xgetbv
    cmp rax, 22
    je enc_cqo
    cmp rax, 1
    je enc_alu
    cmp rax, 2
    je enc_mov
    cmp rax, 3
    je enc_lea
    cmp rax, 8
    je enc_push
    cmp rax, 9
    je enc_pop
    cmp rax, 10
    je enc_call
    cmp rax, 11
    je enc_jmp
    cmp rax, 12
    je enc_jcc
    cmp rax, 13
    je enc_ret
    cmp rax, 30
    je enc_vex3
    cmp rax, 31
    je enc_vex2
    cmp rax, 32
    je enc_vex_ext
    cmp rax, 33
    je enc_vex_perm
    cmp rax, 34
    je enc_vzero
    cmp rax, 40
    je enc_sse
    cmp rax, 41
    je enc_movsd_sse
    cmp rax, 42
    je enc_cvt_xg
    cmp rax, 43
    je enc_cvt_gx
    jmp .erro_ins
.erro_ins:
    lea rsi, [as_e_ins]
    jmp as_fail_plain

; ---------- enc_busca: acha as_mn na tabela -> ib_mn, ib_base; rax = 0 ou -1 ---------------
enc_busca:
    lea rdi, [as_mntab1]
.entrada:
    cmp byte [rdi], 0
    je .nao
    lea rsi, [as_mn]
    xor ecx, ecx
.cmp:
    mov al, [rsi+rcx]
    cmp al, [rdi+rcx]
    jne .prox
    test al, al
    jz .achou
    inc rcx
    jmp .cmp
.prox:
    cmp byte [rdi], 0
    je .pulou
    inc rdi
    jmp .prox
.pulou:
    add rdi, 4                      ; NUL + classe + parametro + extra
    jmp .entrada
.achou:
    add rdi, rcx                    ; rdi aponta para o NUL do nome
    movzx eax, byte [rdi+1]
    mov [ib_mn], rax
    movzx eax, byte [rdi+2]
    mov [ib_base], rax
    movzx eax, byte [rdi+3]
    mov [ib_ext], rax
    xor eax, eax
    ret
.nao:
    mov rax, -1
    ret

; ---------- ib_put: al -> corpo ----------------------------------------------------------
ib_put:
    mov rcx, [ib_blen]
    lea rdx, [ib_body]
    mov [rdx+rcx], al
    inc qword [ib_blen]
    ret

; ---------- ib_imm: rax = valor, rcx = bytes -> corpo (little endian) ---------------------
ib_imm:
    mov [ib_itmp], rax              ; temporario proprio (nao usa ib_tmp do imediato)
    mov [ib_itmp+8], rcx
    mov qword [ib_itmp+16], 0
.l:
    mov rcx, [ib_itmp+8]
    mov rdx, [ib_itmp+16]
    cmp rdx, rcx
    jae .f
    mov rax, [ib_itmp]
    call ib_put
    mov rax, [ib_itmp]
    shr rax, 8
    mov [ib_itmp], rax
    inc qword [ib_itmp+16]
    jmp .l
.f:
    ret

; ---------- ib_inicio: zera o estado da instrucao ------------------------------------------
ib_inicio:
    mov qword [ib_blen], 0
    mov qword [ib_pfx66], 0
    mov qword [ib_rex], 0
    mov qword [ib_rexf], 0
    mov qword [fx_on], 0
    mov qword [fx_at], 0
    mov qword [fx_rip], 0
    mov qword [fx_v], 0
    mov qword [fx_k], 0
    mov qword [fx_s], 0
    mov qword [fx_u], 0
    ret

; ---------- ib_tam: tamanho da operacao: registrador (rsz) ou memoria (msz) ----------------
; Usa o operando i (0 ou 1) que tiver tamanho. Marca 66 (tamanho 2) e REX.W (tamanho 8).
ib_tam:
    xor ecx, ecx
    call ib_tam_op
    test rax, rax
    jnz .ok
    mov ecx, 1
    call ib_tam_op
    test rax, rax
    jz .erro
.ok:
    mov [ib_size], rax
    cmp rax, 2
    jne .n2
    mov qword [ib_pfx66], 1
.n2:
    cmp rax, 8
    jne .n8
    or qword [ib_rex], 8
.n8:
    ret
.erro:
    lea rsi, [as_e_nsz]
    jmp as_fail_plain

; ib_tam_op: rcx = operando -> rax = tamanho (0 se nao tiver)
ib_tam_op:
    lea rdx, [op_t]
    mov rax, [rdx+rcx*8]
    cmp rax, 1
    je .reg
    cmp rax, 3
    je .mem
    xor eax, eax
    ret
.reg:
    lea rdx, [op_rsz]
    mov rax, [rdx+rcx*8]
    ret
.mem:
    lea rdx, [op_msz]
    mov rax, [rdx+rcx*8]
    ret

; ---------- ib_rex_b / ib_rex_r: registrador >= 8 -> bit B ou R ---------------------------
ib_rex_b:
    cmp rax, 8
    jb .f
    or qword [ib_rex], 1
.f:
    ret
ib_rex_r:
    cmp rax, 8
    jb .f
    or qword [ib_rex], 4
.f:
    ret

; ---------- ib_forca: registrador byte 4..7 (spl..dil) exige REX ----------------------------
ib_forca:
    cmp qword [ib_size], 1
    jne .f
    cmp rax, 4
    jb .f
    cmp rax, 7
    ja .f
    mov qword [ib_rexf], 1
.f:
    ret

; ---------- ib_fim: prefixos + REX + corpo -> ib_out; grava na secao via enc_grava ----------
ib_fim:
    xor ecx, ecx
    lea rdi, [ib_out]
    cmp qword [ib_rep], 0
    je .sem_rep
    mov rax, [ib_rep]
    mov [rdi], al
    inc ecx
.sem_rep:
    cmp qword [ib_pfx66], 0
    je .sem66
    mov byte [rdi], 0x66
    inc ecx
.sem66:
    cmp qword [ib_rex], 0
    jne .com_rex
    cmp qword [ib_rexf], 0
    je .sem_rex
.com_rex:
    mov rax, [ib_rex]
    or rax, 0x40
    mov [rdi+rcx], al
    inc ecx
.sem_rex:
    ; posicao do corpo em ib_out = prefixos (rcx)
    mov [ib_tmp+24], rcx            ; base do corpo dentro de ib_out
    xor edx, edx
    lea rsi, [ib_body]
.copia:
    cmp rdx, [ib_blen]
    jae .resolve
    mov al, [rsi+rdx]
    mov [rdi+rcx], al
    inc rcx
    inc rdx
    jmp .copia
.resolve:
    mov [ib_outlen], rcx
    ; fixup: posicao no ib_out = fx_at + base do corpo
    cmp qword [fx_on], 0
    je .sem_fixup
    mov rax, [fx_at]
    add rax, [ib_tmp+24]            ; posicao do campo em ib_out
    mov [fx_at], rax
    ; bytes depois do campo: (fim) - (campo + 4)
    mov rdx, [ib_outlen]
    sub rdx, rax
    sub rdx, 4                      ; imediato depois do campo
    mov [ib_tmp+16], rdx
    cmp qword [fx_rip], 0
    je .abs64
    ; rel32: resolve ja para o mesmo segmento; senao relocacao (fx_k 1 ou 2)
    cmp qword [fx_u], 0
    jne .rel_zero
    cmp qword [fx_k], 1
    jne .rel_reloc
    mov rax, [fx_s]
    cmp rax, [as_cur]
    jne .rel_reloc
    ; mesma secao: deslocamento = alvo - (inicio + campo + 4 + imediato)
    mov rax, [fx_v]
    mov rcx, [ins_start]
    add rcx, [fx_at]
    add rcx, 4
    add rcx, [ib_tmp+16]
    sub rax, rcx
    mov rdx, [fx_at]
    lea rdi, [ib_out]
    mov [rdi+rdx], eax
    jmp .sem_fixup
.rel_zero:
    mov rdx, [fx_at]
    lea rdi, [ib_out]
    mov dword [rdi+rdx], 0
    jmp .sem_fixup
.rel_reloc:
    ; relocacao REL32 + k (k = bytes depois do campo) com A = alvo
    mov rdx, [fx_at]
    lea rdi, [ib_out]
    mov rax, [fx_v]
    mov [rdi+rdx], eax
    mov rax, [ib_tmp+16]
    add rax, 4                      ; tipo COFF: 4 + k
    mov [ib_tmp], rax
    jmp .com_reloc
.abs64:
    mov rdx, [fx_at]
    lea rdi, [ib_out]
    mov rax, [fx_v]
    mov [rdi+rdx], rax
    mov qword [ib_tmp], 1           ; ADDR64
    cmp qword [fx_u], 0
    jne .sem_fixup
.com_reloc:
    cmp qword [fx_u], 0
    jne .sem_fixup
    ; registra a relocacao (somente passagem 2; as_addrel ignora na passagem 1)
    mov rax, [fx_at]
    mov [ar_extra], rax
    mov r8, [ib_tmp]
    mov r9, [fx_k]
    mov r10, [fx_s]
    call as_addrel
.sem_fixup:
    lea rsi, [ib_out]
    mov rcx, [ib_outlen]
    call as_emit
    ret

; ---------- enc_mem_load: carrega o operando de memoria rmi em mm_* ----------------------------
enc_mem_load:
    mov rax, [ib_rmi]
    lea rdx, [op_base]
    mov rcx, [rdx+rax*8]
    mov [mm_b], rcx
    lea rdx, [op_index]
    mov rcx, [rdx+rax*8]
    mov [mm_i], rcx
    lea rdx, [op_scale]
    mov rcx, [rdx+rax*8]
    mov [mm_s], rcx
    lea rdx, [op_v]
    mov rcx, [rdx+rax*8]
    mov [mm_d], rcx
    lea rdx, [op_k]
    mov rcx, [rdx+rax*8]
    mov [mm_dk], rcx
    lea rdx, [op_s]
    mov rcx, [rdx+rax*8]
    mov [mm_ds], rcx
    lea rdx, [op_u]
    mov rcx, [rdx+rax*8]
    mov [mm_du], rcx
    ret

; ---------- ib_modrm: ModRM (+SIB, deslocamento) do operando ib_rmi, campo ib_regf -------------
; Registrador: mod 11. Memoria: ver enc_mem_load. Ajusta REX.R/X/B e o fixup.
ib_modrm:
    mov rax, [ib_regf]
    cmp rax, 8
    jb .r_ok
    or qword [ib_rex], 4
.r_ok:
    mov rax, [ib_rmi]
    lea rdx, [op_t]
    cmp qword [rdx+rax*8], 1
    je .reg
    call enc_mem_load
    ; base/indice sem registrador: RIP (simbolo ou indefinido) ou absoluto
    cmp qword [mm_b], AS_NOREG
    jne .com_base
    cmp qword [mm_i], AS_NOREG
    jne .com_base
    cmp qword [mm_dk], 0
    jne .rip
    cmp qword [mm_du], 0
    jne .rip
    ; absoluto de 32 bits: ModRM rm=100, SIB 0x25
    mov rax, [ib_regf]
    and rax, 7
    shl rax, 3
    or rax, 4
    call ib_put
    mov al, 0x25
    call ib_put
    mov rax, [mm_d]
    mov rcx, 4
    call ib_imm
    ret
.rip:
    mov rax, [ib_regf]
    and rax, 7
    shl rax, 3
    or rax, 5                       ; mod 00, rm 101 (RIP)
    call ib_put
    mov qword [fx_on], 1
    mov qword [fx_rip], 1
    mov rax, [ib_blen]
    mov [fx_at], rax
    mov rax, [mm_d]
    mov [fx_v], rax
    mov rax, [mm_dk]
    mov [fx_k], rax
    mov rax, [mm_ds]
    mov [fx_s], rax
    mov rax, [mm_du]
    mov [fx_u], rax
    xor eax, eax
    mov rcx, 4
    call ib_imm
    ret
.com_base:
    ; base e/ou indice
    cmp qword [mm_dk], 0
    jne .sim_base
    cmp qword [mm_du], 0
    jne .sim_base
    ; bits B/X
    cmp qword [mm_b], AS_NOREG
    je .sem_b
    mov rax, [mm_b]
    cmp rax, 8
    jb .sem_b
    or qword [ib_rex], 1
.sem_b:
    cmp qword [mm_i], AS_NOREG
    je .sem_x
    mov rax, [mm_i]
    cmp rax, 8
    jb .sem_x
    or qword [ib_rex], 2
.sem_x:
    ; SIB necessario: indice, ou base rsp/r12, ou base ausente
    mov qword [enc_sib], 0
    cmp qword [mm_i], AS_NOREG
    jne .usa_sib
    cmp qword [mm_b], AS_NOREG
    je .usa_sib
    mov rax, [mm_b]
    and rax, 7
    cmp rax, 4
    je .usa_sib
    jmp .sem_sib
.usa_sib:
    mov qword [enc_sib], 1
.sem_sib:
    ; mod
    mov qword [enc_mod], 2
    cmp qword [mm_b], AS_NOREG
    je .mod_fixo
    cmp qword [mm_d], 0
    jne .mod_disp
    mov rax, [mm_b]
    and rax, 7
    cmp rax, 5
    je .mod_disp
    mov qword [enc_mod], 0
    jmp .mod_fixo
.mod_disp:
    mov rax, [mm_d]
    cmp rax, 127
    jg .mod_32
    cmp rax, -128
    jl .mod_32
    mov qword [enc_mod], 1
    jmp .mod_fixo
.mod_32:
    mov qword [enc_mod], 2
.mod_fixo:
    cmp qword [mm_b], AS_NOREG
    jne .mod_ok
    mov qword [enc_mod], 0          ; so indice: mod 00 com base 101 e disp32
.mod_ok:
    ; ModRM
    mov rax, [enc_mod]
    shl rax, 6
    mov rcx, [ib_regf]
    and rcx, 7
    shl rcx, 3
    or rax, rcx
    cmp qword [enc_sib], 0
    je .rm_base
    or rax, 4
    jmp .rm_ok
.rm_base:
    mov rcx, [mm_b]
    and rcx, 7
    or rax, rcx
.rm_ok:
    call ib_put
    cmp qword [enc_sib], 0
    je .sem_sib_bytes
    ; SIB: escala, indice (100 = nenhum), base (101 = sem base)
    mov rax, [mm_s]
    cmp rax, 2
    je .s2
    cmp rax, 4
    je .s4
    cmp rax, 8
    je .s8
    xor eax, eax
    jmp .sc
.s2:
    mov eax, 1
    jmp .sc
.s4:
    mov eax, 2
    jmp .sc
.s8:
    mov eax, 3
.sc:
    shl rax, 6
    mov rcx, 4                      ; sem indice
    cmp qword [mm_i], AS_NOREG
    je .sib_i
    mov rcx, [mm_i]
    and rcx, 7
.sib_i:
    shl rcx, 3
    or rax, rcx
    mov rcx, 5                      ; sem base
    cmp qword [mm_b], AS_NOREG
    je .sib_b
    mov rcx, [mm_b]
    and rcx, 7
.sib_b:
    or rax, rcx
    call ib_put
.sem_sib_bytes:
    ; deslocamento
    mov rax, [enc_mod]
    cmp rax, 1
    je .d8
    cmp rax, 2
    je .d32
    ; mod 00: sem base (so indice) -> disp32
    cmp qword [mm_b], AS_NOREG
    jne .fim_mem
    mov rax, [mm_d]
    mov rcx, 4
    call ib_imm
    ret
.d8:
    mov rax, [mm_d]
    mov rcx, 1
    call ib_imm
    ret
.d32:
    mov rax, [mm_d]
    mov rcx, 4
    call ib_imm
    ret
.fim_mem:
    ret
.sim_base:
    ; deslocamento simbolico com base: sem ADDR32 -> erro
    lea rsi, [as_e_nmemsym]
    jmp as_fail_plain
.reg:
    ; registrador r/m: mod 11
    mov rax, [rdx+rax*8]            ; (rdx = op_t, nao usado)
    mov rax, [ib_rmi]
    lea rdx, [op_reg]
    mov rax, [rdx+rax*8]            ; registrador do operando r/m
    push rax
    call ib_rex_b
    pop rax
    push rax
    and rax, 7
    mov [ib_tmp+8], rax
    pop rax
    mov rax, [ib_regf]
    and rax, 7
    shl rax, 3
    mov rcx, [ib_tmp+8]
    or rax, rcx
    or rax, 0xC0
    call ib_put
    ret

section .bss
enc_mod:        resq 1
enc_sib:        resq 1
ar_base_dummy: resq 1
section .text

; ---------- helpers de registrador (ModRM tipo registrador/registrador) ----------------
; ib_regreg: op i = campo reg, op j = rm: ajusta REX e grava ModRM (validado na fase 1)

; ---------- enc_alu: ALU (reg,reg), (reg,imm), (reg,mem), (mem,reg), (mem,imm) ---------------
enc_alu:
    call ib_inicio
    call ib_tam
    mov rax, [op_t]                 ; tipo do destino
    cmp rax, 3
    je .dst_mem
    ; destino registrador
    cmp qword [op_t+8], 1
    je .rr
    cmp qword [op_t+8], 2
    je .ri
    cmp qword [op_t+8], 3
    je .rm
    lea rsi, [as_e_nform]
    jmp as_fail_plain
.dst_mem:
    cmp qword [op_t+8], 1
    je .mr
    cmp qword [op_t+8], 2
    je .mi
    lea rsi, [as_e_nform]
    jmp as_fail_plain
.rr:
    ; reg (origem) no campo reg, destino no rm (reg)
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    call ib_forca
    mov rax, [rdx]
    call ib_forca
    mov rax, [rdx+8]
    call ib_rex_r
    mov rax, [rdx]
    call ib_rex_b
    mov rax, [ib_base]
    cmp qword [ib_size], 1
    je .rr_op
    or rax, 1
.rr_op:
    call ib_put
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    and rax, 7
    shl rax, 3
    mov rcx, [rdx]
    and rcx, 7
    or rax, rcx
    or rax, 0xC0
    call ib_put
    call ib_fim
    ret
.rm:
    ; destino reg, origem memoria: opcode base+2/3, campo reg = destino
    mov qword [ib_rmi], 1
    lea rdx, [op_reg]
    mov rax, [rdx]
    call ib_forca
    mov rax, [rdx]
    mov [ib_regf], rax
    mov rax, [ib_base]
    add rax, 2
    cmp qword [ib_size], 1
    je .rm_op
    or rax, 1
.rm_op:
    call ib_put
    call ib_modrm
    call ib_fim
    ret
.mr:
    ; destino memoria, origem registrador: opcode base+0/1, campo reg = origem
    mov qword [ib_rmi], 0
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    call ib_forca
    mov rax, [rdx+8]
    mov [ib_regf], rax
    mov rax, [ib_base]
    cmp qword [ib_size], 1
    je .mr_op
    or rax, 1
.mr_op:
    call ib_put
    call ib_modrm
    call ib_fim
    ret
.ri:
    ; destino registrador, origem imediato
    cmp qword [op_k+8], 0
    jne .sym
    cmp qword [op_u+8], 0
    jne .sym
    lea rdx, [op_reg]
    mov rax, [rdx]
    call ib_forca
    mov rax, [rdx]
    call ib_rex_b
    mov rax, [op_v+8]
    mov [ib_tmp], rax
    ; forma curta do acumulador (al/ax/eax/rax): 04 ib, ou 05 imediato (sem ModRM)
    lea rdx, [op_reg]
    cmp qword [rdx], 0
    jne .ri_nao_acc
    cmp qword [ib_size], 1
    je .ri_acc8
    mov rax, [ib_tmp]
    cmp rax, 127
    jg .ri_acc
    cmp rax, -128
    jl .ri_acc
    jmp .ri_nao_acc
.ri_acc8:
    mov rax, [ib_base]
    add rax, 4
    call ib_put
    mov rax, [ib_tmp]
    mov rcx, 1
    call ib_imm
    call ib_fim
    ret
.ri_acc:
    mov rax, [ib_base]
    add rax, 5
    call ib_put
    mov rax, [ib_tmp]
    mov rcx, [ib_size]
    cmp rcx, 8
    jne .ri_acc_sz
    mov rcx, 4
.ri_acc_sz:
    call ib_imm
    call ib_fim
    ret
.ri_nao_acc:
    mov rax, [ib_base]
    shr rax, 3                      ; extensao /n
    mov [ib_tmp+8], rax
    cmp qword [ib_size], 1
    je .ri_byte
    mov rax, [ib_tmp]
    cmp rax, 127
    jg .ri_81
    cmp rax, -128
    jl .ri_81
    mov rax, 0x83
    call ib_put
    mov rax, [ib_tmp+8]
    call ri_modrm
    mov rax, [ib_tmp]
    mov rcx, 1
    call ib_imm
    call ib_fim
    ret
.ri_81:
    mov rax, 0x81
    call ib_put
    mov rax, [ib_tmp+8]
    call ri_modrm
    mov rax, [ib_tmp]
    mov rcx, [ib_size]
    cmp rcx, 8
    jne .ri81_sz
    mov rcx, 4
.ri81_sz:
    call ib_imm
    call ib_fim
    ret
.ri_byte:
    mov rax, 0x80
    call ib_put
    mov rax, [ib_tmp+8]
    call ri_modrm
    mov rax, [ib_tmp]
    mov rcx, 1
    call ib_imm
    call ib_fim
    ret
.mi:
    ; destino memoria, origem imediato: 80/81/83 /n com o rm = memoria
    cmp qword [op_k+8], 0
    jne .sym
    cmp qword [op_u+8], 0
    jne .sym
    mov qword [ib_rmi], 0
    mov rax, [op_v+8]
    mov [ib_tmp], rax
    mov rax, [ib_base]
    shr rax, 3
    mov [ib_regf], rax
    cmp qword [ib_size], 1
    je .mi8
    mov rax, [ib_tmp]
    cmp rax, 127
    jg .mi81
    cmp rax, -128
    jl .mi81
    mov rax, 0x83
    call ib_put
    call ib_modrm
    mov rax, [ib_tmp]
    mov rcx, 1
    call ib_imm
    call ib_fim
    ret
.mi81:
    mov rax, 0x81
    call ib_put
    call ib_modrm
    mov rax, [ib_tmp]
    mov rcx, [ib_size]
    cmp rcx, 8
    jne .mi81sz
    mov rcx, 4
.mi81sz:
    call ib_imm
    call ib_fim
    ret
.mi8:
    mov rax, 0x80
    call ib_put
    call ib_modrm
    mov rax, [ib_tmp]
    mov rcx, 1
    call ib_imm
    call ib_fim
    ret
.sym:
    lea rsi, [as_e_nimmsym]
    jmp as_fail_plain

; ri_modrm: rax = extensao /n -> ModRM (mod 11, rm = registrador de destino op0)
ri_modrm:
    shl rax, 3
    lea rdx, [op_reg]
    mov rcx, [rdx]
    and rcx, 7
    or rax, rcx
    or rax, 0xC0
    call ib_put
    ret

; ---------- enc_mov: reg,reg ; reg,imm ; reg,mem ; mem,reg ; mem,imm ----------------------
enc_mov:
    call ib_inicio
    call ib_tam
    mov rax, [op_t]
    cmp rax, 3
    je .dst_mem
    cmp qword [op_t+8], 1
    je .rr
    cmp qword [op_t+8], 2
    je .ri
    cmp qword [op_t+8], 3
    je .rm
    lea rsi, [as_e_nform]
    jmp as_fail_plain
.dst_mem:
    cmp qword [op_t+8], 1
    je .mr
    cmp qword [op_t+8], 2
    je .mi
    lea rsi, [as_e_nform]
    jmp as_fail_plain
.rr:
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    call ib_forca
    mov rax, [rdx]
    call ib_forca
    mov rax, [rdx+8]
    call ib_rex_r
    mov rax, [rdx]
    call ib_rex_b
    mov rax, 0x88
    cmp qword [ib_size], 1
    je .rr_op
    mov rax, 0x89
.rr_op:
    call ib_put
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    and rax, 7
    shl rax, 3
    mov rcx, [rdx]
    and rcx, 7
    or rax, rcx
    or rax, 0xC0
    call ib_put
    call ib_fim
    ret
.rm:
    ; reg <- mem: 8A/8B, campo reg = destino
    mov qword [ib_rmi], 1
    lea rdx, [op_reg]
    mov rax, [rdx]
    call ib_forca
    mov rax, [rdx]
    mov [ib_regf], rax
    mov rax, 0x8A
    cmp qword [ib_size], 1
    je .rm_op
    mov rax, 0x8B
.rm_op:
    call ib_put
    call ib_modrm
    call ib_fim
    ret
.mr:
    ; mem <- reg: 88/89, campo reg = origem
    mov qword [ib_rmi], 0
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    call ib_forca
    mov rax, [rdx+8]
    mov [ib_regf], rax
    mov rax, 0x88
    cmp qword [ib_size], 1
    je .mr_op
    mov rax, 0x89
.mr_op:
    call ib_put
    call ib_modrm
    call ib_fim
    ret
.ri:
    ; reg <- imediato (fase 1, validado)
    cmp qword [op_k+8], 0
    jne .ri_sym
    cmp qword [op_u+8], 0
    jne .ri_sym
    lea rdx, [op_reg]
    mov rax, [rdx]
    call ib_forca
    mov rax, [rdx]
    call ib_rex_b
    mov rax, [op_v+8]
    mov [ib_tmp], rax
    lea rdx, [op_reg]
    mov rax, [rdx]
    and rax, 7
    mov [ib_tmp+8], rax
    cmp qword [ib_size], 1
    je .r8
    cmp qword [ib_size], 2
    je .r16
    cmp qword [ib_size], 4
    je .r32
    ; tamanho 8: 0 .. 2^32-1 -> B8 sem REX.W; com sinal de 32 bits -> REX.W C7; senao B8 io
    mov rax, [ib_tmp]
    cmp rax, 0
    jl .r64_s
    mov rcx, 0xFFFFFFFF
    cmp rax, rcx
    jbe .r32_b8
.r64_s:
    mov rax, [ib_tmp]
    cmp rax, 0x7FFFFFFF
    jg .r64_full
    cmp rax, -0x80000000
    jl .r64_full
    or qword [ib_rex], 8
    mov rax, 0xC7
    call ib_put
    mov rax, 0xC0
    or rax, [ib_tmp+8]
    call ib_put
    mov rax, [ib_tmp]
    mov rcx, 4
    call ib_imm
    call ib_fim
    ret
.r64_full:
    or qword [ib_rex], 8
    mov rax, 0xB8
    or rax, [ib_tmp+8]
    call ib_put
    mov rax, [ib_tmp]
    mov rcx, 8
    call ib_imm
    call ib_fim
    ret
.r32_b8:
    and qword [ib_rex], -9          ; B8 sem REX.W (valor de 32 bits sem sinal)
    mov rax, 0xB8
    or rax, [ib_tmp+8]
    call ib_put
    mov rax, [ib_tmp]
    mov rcx, 4
    call ib_imm
    call ib_fim
    ret
.r32:
    mov rax, 0xB8
    or rax, [ib_tmp+8]
    call ib_put
    mov rax, [ib_tmp]
    mov rcx, 4
    call ib_imm
    call ib_fim
    ret
.r16:
    mov rax, 0xB8
    or rax, [ib_tmp+8]
    call ib_put
    mov rax, [ib_tmp]
    mov rcx, 2
    call ib_imm
    call ib_fim
    ret
.r8:
    mov rax, 0xB0
    or rax, [ib_tmp+8]
    call ib_put
    mov rax, [ib_tmp]
    mov rcx, 1
    call ib_imm
    call ib_fim
    ret
.mi:
    ; mem <- imediato: C6 /0 (8 bits), C7 /0 (32 bits com sinal)
    cmp qword [op_k+8], 0
    jne .sym
    cmp qword [op_u+8], 0
    jne .sym
    mov qword [ib_rmi], 0
    mov qword [ib_regf], 0
    mov rax, [op_v+8]
    mov [ib_tmp], rax
    cmp qword [ib_size], 1
    je .mi8
    mov rax, 0xC7
    call ib_put
    call ib_modrm
    mov rax, [ib_tmp]
    mov rcx, [ib_size]
    cmp rcx, 8
    jne .mi_sz
    mov rcx, 4
.mi_sz:
    call ib_imm
    call ib_fim
    ret
.mi8:
    mov rax, 0xC6
    call ib_put
    call ib_modrm
    mov rax, [ib_tmp]
    mov rcx, 1
    call ib_imm
    call ib_fim
    ret
.sym:
    lea rsi, [as_e_nimmsym]
    jmp as_fail_plain
.ri_sym:
    ; mov r64, simbolo: REX.W B8+r com imm64 e relocacao ADDR64 no campo (apos REX e opcode)
    cmp qword [ib_size], 8
    jne .sym
    lea rdx, [op_reg]
    mov rax, [rdx]
    call ib_forca
    mov rax, [rdx]
    call ib_rex_b
    or qword [ib_rex], 8
    lea rdx, [op_reg]
    mov rax, [rdx]
    and rax, 7
    or rax, 0xB8
    call ib_put
    mov qword [ar_extra], 2
    mov r8, 1                       ; ADDR64
    mov r9, [op_k+8]
    mov r10, [op_s+8]
    call as_addrel
    mov rax, [op_v+8]
    mov rcx, 8
    call ib_imm
    call ib_fim
    ret

; ---------- enc_lea: reg <- mem (8D /r) --------------------------------------------------
enc_lea:
    call ib_inicio
    cmp qword [op_t], 1
    jne .erro
    cmp qword [op_t+8], 3
    jne .erro
    mov qword [ib_size], 8
    mov rax, [op_rsz]
    cmp rax, 8
    jne .l4
    or qword [ib_rex], 8
    jmp .l_op
.l4:
    cmp rax, 4
    jne .erro
.l_op:
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    call ib_rex_r_regf
    mov qword [ib_rmi], 1
    mov rax, 0x8D
    call ib_put
    call ib_modrm
    call ib_fim
    ret
.erro:
    lea rsi, [as_e_nform]
    jmp as_fail_plain

; ib_rex_r_regf: ajusta REX.R pelo campo reg ja em ib_regf (>= 8)
ib_rex_r_regf:
    mov rax, [ib_regf]
    call ib_rex_r
    ret

; ---------- enc_push / enc_pop: registrador (50/58) ou memoria (FF /6, 8F /0) -----------------
enc_push:
    call ib_inicio
    cmp qword [op_t], 3
    je .mem
    lea rdx, [op_reg]
    mov rax, [rdx]
    call ib_rex_b
    mov qword [ib_size], 8
    lea rdx, [op_reg]
    mov rax, [rdx]
    and rax, 7
    or rax, 0x50
    call ib_put
    call ib_fim
    ret
.mem:
    mov qword [ib_rmi], 0
    mov qword [ib_regf], 6
    mov rax, 0xFF
    call ib_put
    call ib_modrm
    call ib_fim
    ret

enc_pop:
    call ib_inicio
    cmp qword [op_t], 3
    je .mem
    lea rdx, [op_reg]
    mov rax, [rdx]
    call ib_rex_b
    mov qword [ib_size], 8
    lea rdx, [op_reg]
    mov rax, [rdx]
    and rax, 7
    or rax, 0x58
    call ib_put
    call ib_fim
    ret
.mem:
    mov qword [ib_rmi], 0
    mov qword [ib_regf], 0
    mov rax, 0x8F
    call ib_put
    call ib_modrm
    call ib_fim
    ret

; ---------- enc_call / enc_jmp: rel32 (E8/E9) ou [memoria] (FF /2, FF /4) -----------------------
enc_call:
    call ib_inicio
    cmp qword [op_t], 2
    je .rel
    cmp qword [op_t], 3
    je .mem
    lea rsi, [as_e_nform]
    jmp as_fail_plain
.rel:
    mov rax, 0xE8
    call ib_put
    jmp enc_rel32
.mem:
    mov qword [ib_rmi], 0
    mov qword [ib_regf], 2
    mov rax, 0xFF
    call ib_put
    call ib_modrm
    call ib_fim
    ret

enc_jmp:
    call ib_inicio
    cmp qword [op_t], 2
    je .rel
    cmp qword [op_t], 3
    je .mem
    lea rsi, [as_e_nform]
    jmp as_fail_plain
.rel:
    mov rax, 0xE9
    call ib_put
    jmp enc_rel32
.mem:
    mov qword [ib_rmi], 0
    mov qword [ib_regf], 4
    mov rax, 0xFF
    call ib_put
    call ib_modrm
    call ib_fim
    ret

; enc_jcc: 0F 80+cc rel32
enc_jcc:
    call ib_inicio
    mov rax, 0x0F
    call ib_put
    mov rax, [ib_base]
    add rax, 0x80
    call ib_put
    jmp enc_rel32

; enc_rel32: campo rel32 do operando 0 (op_v/op_k/op_s/op_u) -> fixup relativo
enc_rel32:
    cmp qword [op_k], 2
    je .externo
    mov qword [fx_on], 1
    mov qword [fx_rip], 1
    mov qword [fx_at], 0
    mov rax, [ib_blen]
    mov [fx_at], rax
    mov rax, [op_v]
    mov [fx_v], rax
    mov rax, [op_k]
    mov [fx_k], rax
    mov rax, [op_s]
    mov [fx_s], rax
    mov rax, [op_u]
    mov [fx_u], rax
    xor eax, eax
    mov rcx, 4
    call ib_imm
    call ib_fim
    ret
.externo:
    lea rsi, [as_e_nrel]
    jmp as_fail_plain

; ---------- enc_ret: C3 ------------------------------------------------------------------
enc_ret:
    call ib_inicio
    mov rax, 0xC3
    call ib_put
    call ib_fim
    ret

; ============ fase 3 ============================================================
; rm_forca: operando rmi (ib_rmi): registrador byte 4..7 exige REX (independe de ib_size)
rm_forca:
    mov rax, [ib_rmi]
    lea rdx, [op_t]
    cmp qword [rdx+rax*8], 1
    jne .f
    lea rdx, [op_rsz]
    cmp qword [rdx+rax*8], 1
    jne .f
    lea rdx, [op_reg]
    mov rax, [rdx+rax*8]
    cmp rax, 4
    jb .f
    cmp rax, 7
    ja .f
    mov qword [ib_rexf], 1
.f:
    ret

; ib_tam_do_op: rcx = operando -> ib_size = tamanho dele (rsz ou msz)
ib_tam_do_op:
    call ib_tam_op
    mov [ib_size], rax
    cmp rax, 2
    jne .n2
    mov qword [ib_pfx66], 1
.n2:
    cmp rax, 8
    jne .n8
    or qword [ib_rex], 8
.n8:
    ret

; ---------- enc_test: test rm,reg (84/85) ; test rm,imm (F6/F7 /0) ------------------------
enc_test:
    call ib_inicio
    call ib_tam
    cmp qword [op_t+8], 2
    je .imm
    cmp qword [op_t+8], 1
    jne .erro
    mov qword [ib_rmi], 0
    mov rax, [op_reg+8]
    mov [ib_regf], rax
    mov rax, [ib_regf]
    call ib_forca
    mov rax, [ib_regf]
    call ib_rex_r
    call rm_forca
    cmp qword [ib_size], 1
    je .r8
    mov rax, 0x85
    jmp .rr_op
.r8:
    mov rax, 0x84
.rr_op:
    call ib_put
    call ib_modrm
    call ib_fim
    ret
.imm:
    ; forma curta do acumulador: A8 ib (al) / A9 id (eax/rax/ax)
    cmp qword [op_reg], 0
    jne .imm_modrm
    cmp qword [op_t], 1
    jne .imm_modrm
    mov rax, [op_v+8]
    mov [ib_immv], rax
    cmp qword [ib_size], 1
    je .acc8
    mov rax, 0xA9
    call ib_put
    mov rax, [ib_immv]
    mov rcx, [ib_size]
    cmp rcx, 8
    jne .acc_sz
    mov rcx, 4
.acc_sz:
    call ib_imm
    call ib_fim
    ret
.acc8:
    mov rax, 0xA8
    call ib_put
    mov rax, [ib_immv]
    mov rcx, 1
    call ib_imm
    call ib_fim
    ret
.imm_modrm:
    mov qword [ib_rmi], 0
    mov qword [ib_regf], 0
    mov rax, [op_v+8]
    mov [ib_immv], rax
    call rm_forca
    cmp qword [ib_size], 1
    je .i8
    mov rax, 0xF7
    call ib_put
    call ib_modrm
    mov rax, [ib_immv]
    mov rcx, [ib_size]
    cmp rcx, 8
    jne .i_sz
    mov rcx, 4
.i_sz:
    call ib_imm
    call ib_fim
    ret
.i8:
    mov rax, 0xF6
    call ib_put
    call ib_modrm
    mov rax, [ib_immv]
    mov rcx, 1
    call ib_imm
    call ib_fim
    ret
.erro:
    lea rsi, [as_e_nform]
    jmp as_fail_plain

; ---------- enc_grp: F6/F7 /ext com um operando (not, neg, mul, div, idiv, imul1) ------------
enc_grp:
    call ib_inicio
    call ib_tam
    mov qword [ib_rmi], 0
    mov rax, [ib_base]
    mov [ib_regf], rax
    call rm_forca
    cmp qword [ib_size], 1
    je .b8
    mov rax, 0xF7
    jmp .op
.b8:
    mov rax, 0xF6
.op:
    call ib_put
    call ib_modrm
    call ib_fim
    ret

; ---------- enc_incdec: FE/FF /0 (inc), /1 (dec) ---------------------------------------
enc_incdec:
    call ib_inicio
    call ib_tam
    mov qword [ib_rmi], 0
    mov rax, [ib_base]
    mov [ib_regf], rax
    call rm_forca
    cmp qword [ib_size], 1
    je .b8
    mov rax, 0xFF
    jmp .op
.b8:
    mov rax, 0xFE
.op:
    call ib_put
    call ib_modrm
    call ib_fim
    ret

; ---------- enc_shift: C0/C1 /n ib ; D0/D1 /n (1) ; D2/D3 /n (cl) --------------------------
enc_shift:
    call ib_inicio
    call ib_tam
    mov qword [ib_rmi], 0
    mov rax, [ib_base]
    mov [ib_regf], rax
    call rm_forca
    cmp qword [op_t+8], 2
    je .imm
    ; contagem em cl
    cmp qword [ib_size], 1
    je .cl8
    mov rax, 0xD3
    jmp .cl_op
.cl8:
    mov rax, 0xD2
.cl_op:
    call ib_put
    call ib_modrm
    call ib_fim
    ret
.imm:
    mov rax, [op_v+8]
    mov [ib_immv], rax
    cmp rax, 1
    jne .imm_n
    cmp qword [ib_size], 1
    je .d0
    mov rax, 0xD1
    jmp .d_op
.d0:
    mov rax, 0xD0
.d_op:
    call ib_put
    call ib_modrm
    call ib_fim
    ret
.imm_n:
    cmp qword [ib_size], 1
    je .c0
    mov rax, 0xC1
    jmp .c_op
.c0:
    mov rax, 0xC0
.c_op:
    call ib_put
    call ib_modrm
    mov rax, [ib_immv]
    mov rcx, 1
    call ib_imm
    call ib_fim
    ret

; ---------- enc_movx: movzx/movsx reg, rm(8/16) : 0F B6/B7 ; 0F BE/BF -----------------------
enc_movx:
    call ib_inicio
    mov qword [ib_size], 0
    ; destino (op0) define o tamanho e os prefixos
    xor ecx, ecx
    call ib_tam_do_op
    ; origem (op1): tamanho para escolher a variante
    mov qword [ib_rmi], 1
    mov rcx, 1
    call ib_tam_op
    mov [ib_immv], rax              ; tamanho da origem (ib_put altera rcx)
    mov rax, 0x0F
    call ib_put
    mov rax, [ib_base]
    mov rcx, [ib_immv]
    cmp rcx, 2
    jne .v8
    inc rax
.v8:
    call ib_put
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    call rm_forca
    call ib_modrm
    call ib_fim
    ret

; ---------- enc_movsxd: REX.W 63 /r (reg64 <- rm32) ---------------------------------------
enc_movsxd:
    call ib_inicio
    mov qword [ib_size], 8
    or qword [ib_rex], 8
    mov qword [ib_rmi], 1
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    mov rax, 0x63
    call ib_put
    call ib_modrm
    call ib_fim
    ret

; ---------- enc_imul: 1 op (F7 /5), 2 ops (0F AF /r), 3 ops (6B /r ib ; 69 /r id) ------------
; enc_bt: bt/bts/btr/btc r/m, r (0F A3/AB/B3/BB /r), so a forma registrador-registrador
enc_bt:
    call ib_inicio
    call ib_tam
    cmp qword [op_t], 1
    jne .forma
    cmp qword [op_t+8], 1
    jne .forma
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    call ib_forca
    mov rax, [rdx]
    call ib_forca
    mov rax, [rdx+8]
    call ib_rex_r
    mov rax, [rdx]
    call ib_rex_b
    mov rax, 0x0F
    call ib_put
    mov rax, [ib_base]
    call ib_put
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    and rax, 7
    shl rax, 3
    mov rcx, [rdx]
    and rcx, 7
    or rax, rcx
    or rax, 0xC0
    call ib_put
    call ib_fim
    ret
.forma:
    lea rsi, [as_e_nform]
    jmp as_fail_plain

; enc_bitscan: bsr r, r/m (0F BD) e bsf r, r/m (0F BC)
enc_bitscan:
    call ib_inicio
    call ib_tam
    mov qword [ib_rmi], 1
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    mov rax, 0x0F
    call ib_put
    mov rax, 0xBC
    cmp qword [ib_mn], 60
    jne .put
    mov rax, 0xBD
.put:
    call ib_put
    call ib_modrm
    call ib_fim
    ret

enc_imul:
    cmp qword [ib_nops], 1
    jne .multi
    mov qword [ib_base], 5
    jmp enc_grp
.multi:
    call ib_inicio
    call ib_tam
    mov qword [ib_rmi], 1
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    cmp qword [ib_nops], 3
    je .tres
    mov rax, 0x0F
    call ib_put
    mov rax, 0xAF
    call ib_put
    call ib_modrm
    call ib_fim
    ret
.tres:
    mov rax, [op_v+16]
    mov [ib_immv], rax
    mov rax, [ib_immv]
    cmp rax, 127
    jg .t69
    cmp rax, -128
    jl .t69
    mov rax, 0x6B
    call ib_put
    call ib_modrm
    mov rax, [ib_immv]
    mov rcx, 1
    call ib_imm
    call ib_fim
    ret
.t69:
    mov rax, 0x69
    call ib_put
    call ib_modrm
    mov rax, [ib_immv]
    mov rcx, [ib_size]
    cmp rcx, 8
    jne .t69s
    mov rcx, 4
.t69s:
    call ib_imm
    call ib_fim
    ret

; ---------- enc_setcc: 0F 90+cc /0 (rm8) ----------------------------------------------------
enc_setcc:
    call ib_inicio
    mov qword [ib_size], 1
    mov qword [ib_rmi], 0
    mov qword [ib_regf], 0
    call rm_forca
    mov rax, 0x0F
    call ib_put
    mov rax, [ib_base]
    add rax, 0x90
    call ib_put
    call ib_modrm
    call ib_fim
    ret

; ---------- enc_str: stosb/movsb/cmpsb (A4/AA/A6), stosq/movsq (REX.W), stosd (32), stosw (66)
enc_str:
    call ib_inicio
    mov rax, [ib_mn]
    cmp rax, 26
    jne .s_d
    or qword [ib_rex], 8
    jmp .s_op
.s_d:
    cmp rax, 28
    jne .s_op
    mov qword [ib_pfx66], 1
.s_op:
    mov rax, [ib_base]
    call ib_put
    call ib_fim
    ret

; ---------- enc_nop / enc_cpuid / enc_xgetbv / enc_cqo ------------------------------------
enc_nop:
    call ib_inicio
    mov rax, 0x90
    call ib_put
    call ib_fim
    ret
enc_cpuid:
    call ib_inicio
    mov rax, 0x0F
    call ib_put
    mov rax, 0xA2
    call ib_put
    call ib_fim
    ret
enc_xgetbv:
    call ib_inicio
    mov rax, 0x0F
    call ib_put
    mov rax, 0x01
    call ib_put
    mov rax, 0xD0
    call ib_put
    call ib_fim
    ret
enc_cqo:
    call ib_inicio
    or qword [ib_rex], 8
    mov rax, 0x99
    call ib_put
    call ib_fim
    ret

; ============ fase 4: SSE escalar e VEX ==========================================
section .bss
vx_vvvv:        resq 1
vx_L:           resq 1
vx_r:           resq 1
vx_x:           resq 1
vx_bb:          resq 1
vx_w:           resq 1
vx_map:         resq 1
vx_pp:          resq 1
vx_p0:          resq 1
vx_p1:          resq 1
vx_p2:          resq 1
vx_plen:        resq 1

section .text

; ib_sse_pfx: prefixo obrigatorio do SSE (pp de ib_ext): 1 = 66, 2 = F3, 3 = F2
ib_sse_pfx:
    mov rax, [ib_ext]
    and rax, 3
    cmp rax, 1
    je .p66
    cmp rax, 2
    je .pf3
    cmp rax, 3
    je .pf2
    ret
.p66:
    mov qword [ib_pfx66], 1
    ret
.pf3:
    mov qword [ib_rep], 0xF3
    ret
.pf2:
    mov qword [ib_rep], 0xF2
    ret

; ib_0f: emite 0F e o opcode base (ib_base)
ib_0f:
    mov rax, 0x0F
    call ib_put
    mov rax, [ib_base]
    call ib_put
    ret

; ---------- enc_sse: op0 xmm (reg), op1 xmm/mem (rm) : prefixo, 0F, opcode, ModRM ----------
enc_sse:
    call ib_inicio
    call ib_sse_pfx
    call ib_0f
    mov qword [ib_rmi], 1
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    call ib_modrm
    call ib_fim
    ret

; ---------- enc_movsd_sse: movsd xmm,xmm/m64 (0F 10) ; movsd m64,xmm (0F 11) -------------
enc_movsd_sse:
    call ib_inicio
    call ib_sse_pfx
    cmp qword [op_t], 3
    je .store
    mov qword [ib_rmi], 1
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    mov qword [ib_base], 0x10
    call ib_0f
    call ib_modrm
    call ib_fim
    ret
.store:
    mov qword [ib_rmi], 0
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    mov [ib_regf], rax
    mov qword [ib_base], 0x11
    call ib_0f
    call ib_modrm
    call ib_fim
    ret

; ---------- enc_cvt_xg: cvtsi2sd xmm, r/m32|64 (0F 2A) ---------------------------------
enc_cvt_xg:
    call ib_inicio
    call ib_sse_pfx
    mov rcx, 1
    call ib_tam_op
    cmp rax, 8
    jne .n8
    or qword [ib_rex], 8
.n8:
    call ib_0f
    mov qword [ib_rmi], 1
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    call ib_modrm
    call ib_fim
    ret

; ---------- enc_cvt_gx: cvttsd2si / cvtsd2si r32|64, xmm/m64 ------------------------------
enc_cvt_gx:
    call ib_inicio
    call ib_sse_pfx
    xor ecx, ecx
    call ib_tam_op
    cmp rax, 8
    jne .n8
    or qword [ib_rex], 8
.n8:
    call ib_0f
    mov qword [ib_rmi], 1
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    call ib_modrm
    call ib_fim
    ret

; ---------- ib_vex_finish: monta o prefixo VEX (C5/C4) e o coloca antes do corpo ---------
; entrada: vx_vvvv (0..15), vx_L (0/1), ib_ext (pp, mapa, W), ib_rex (R,X,B), corpo pronto
ib_vex_finish:
    ; W = (ib_ext>>4)&1 ; mapa = (ib_ext>>2)&3 ; pp = ib_ext&3
    mov rax, [ib_ext]
    shr rax, 4
    and rax, 1
    mov [vx_w], rax
    mov rax, [ib_ext]
    shr rax, 2
    and rax, 3
    mov [vx_map], rax
    mov rax, [ib_ext]
    and rax, 3
    mov [vx_pp], rax
    ; bits R, X, B do REX acumulado
    mov rax, [ib_rex]
    mov rcx, rax
    and rcx, 4
    shr rcx, 2
    mov [vx_r], rcx
    mov rcx, rax
    and rcx, 2
    shr rcx, 1
    mov [vx_x], rcx
    and rax, 1
    mov [vx_bb], rax
    ; vvvv invertido (4 bits)
    mov rax, [vx_vvvv]
    xor rax, 0xF
    and rax, 0xF
    mov [vx_vvvv], rax
    ; C5 quando mapa=1, X=0, B=0 e W=0; senao C4
    cmp qword [vx_map], 1
    jne .c4
    cmp qword [vx_x], 0
    jne .c4
    cmp qword [vx_bb], 0
    jne .c4
    cmp qword [vx_w], 0
    jne .c4
    ; C5: byte1 = (~R)<<7 | vvvv<<3 | L<<2 | pp
    mov rax, [vx_r]
    xor rax, 1
    shl rax, 7
    mov rcx, [vx_vvvv]
    shl rcx, 3
    or rax, rcx
    mov rcx, [vx_L]
    shl rcx, 2
    or rax, rcx
    or rax, [vx_pp]
    mov [vx_p1], rax
    mov qword [vx_p0], 0xC5
    mov qword [vx_plen], 2
    jmp .monta
.c4:
    ; C4: byte1 = (~R)<<7 | (~X)<<6 | (~B)<<5 | mapa ; byte2 = W<<7 | vvvv<<3 | L<<2 | pp
    mov rax, [vx_r]
    xor rax, 1
    shl rax, 7
    mov rcx, [vx_x]
    xor rcx, 1
    shl rcx, 6
    or rax, rcx
    mov rcx, [vx_bb]
    xor rcx, 1
    shl rcx, 5
    or rax, rcx
    or rax, [vx_map]
    mov [vx_p1], rax
    mov rax, [vx_w]
    shl rax, 7
    mov rcx, [vx_vvvv]
    shl rcx, 3
    or rax, rcx
    mov rcx, [vx_L]
    shl rcx, 2
    or rax, rcx
    or rax, [vx_pp]
    mov [vx_p2], rax
    mov qword [vx_p0], 0xC4
    mov qword [vx_plen], 3
.monta:
    ; desloca o corpo pelo tamanho do prefixo e grava C5/C4 [byte2]
    mov rcx, [vx_plen]
    mov rdx, [ib_blen]
.desl:
    test rdx, rdx
    jz .grava
    dec rdx
    lea rsi, [ib_body]
    mov al, [rsi+rdx]
    lea rdi, [rsi+rdx]
    mov [rdi+rcx], al
    jmp .desl
.grava:
    lea rdi, [ib_body]
    mov rax, [vx_p0]
    mov [rdi], al
    mov rax, [vx_p1]
    mov [rdi+1], al
    cmp qword [vx_plen], 3
    jne .sem_p2
    mov rax, [vx_p2]
    mov [rdi+2], al
.sem_p2:
    mov rax, [vx_plen]
    add [ib_blen], rax
    cmp qword [fx_on], 0
    je .ret
    add [fx_at], rax
.ret:
    ret
; ---------- enc_vex3: op0 xmm/ymm (reg), op1 (vvvv), op2 xmm/mem (rm) ----------------------
enc_vex3:
    call ib_inicio
    mov qword [ib_size], 0
    mov rax, [ib_base]
    call ib_put
    mov qword [ib_rmi], 2
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    call ib_modrm
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    mov [vx_vvvv], rax
    mov qword [vx_L], 0
    lea rdx, [op_rsz]
    cmp qword [rdx], 32
    jne .l0
    mov qword [vx_L], 1
.l0:
    call ib_vex_finish
    call ib_vex_fim
    ret

; ---------- enc_vex2: load (op0 reg, op1 rm) ou store (op0 mem, op1 reg) ---------------
enc_vex2:
    call ib_inicio
    mov qword [vx_vvvv], 0
    mov qword [vx_L], 0
    lea rdx, [op_rsz]
    cmp qword [rdx], 32
    jne .l1
    mov qword [vx_L], 1
.l1:
    cmp qword [op_t], 3
    je .store
    mov rax, [ib_base]
    call ib_put
    mov qword [ib_rmi], 1
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    call ib_modrm
    jmp .fim
.store:
    mov rax, [ib_base]
    add rax, 1
    call ib_put
    mov qword [ib_rmi], 0
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    mov [ib_regf], rax
    lea rdx, [op_rsz]
    cmp qword [rdx+8], 32
    jne .s1
    mov qword [vx_L], 1
.s1:
    call ib_modrm
.fim:
    call ib_vex_finish
    call ib_vex_fim
    ret

; ---------- enc_vex_ext: vextractf128 xmm/m128, ymm, imm8 (rm = op0, reg = op1) -----------
enc_vex_ext:
    call ib_inicio
    mov qword [vx_vvvv], 0
    mov qword [vx_L], 1
    mov rax, [ib_base]
    call ib_put
    mov qword [ib_rmi], 0
    lea rdx, [op_reg]
    mov rax, [rdx+8]
    mov [ib_regf], rax
    call ib_modrm
    mov rax, [op_v+16]
    mov rcx, 1
    call ib_imm
    call ib_vex_finish
    call ib_vex_fim
    ret

; ---------- enc_vex_perm: vpermilpd ymm, ymm/m, imm8 -------------------------------------
enc_vex_perm:
    call ib_inicio
    mov qword [vx_vvvv], 0
    mov qword [vx_L], 0
    lea rdx, [op_rsz]
    cmp qword [rdx], 32
    jne .l0
    mov qword [vx_L], 1
.l0:
    mov rax, [ib_base]
    call ib_put
    mov qword [ib_rmi], 1
    lea rdx, [op_reg]
    mov rax, [rdx]
    mov [ib_regf], rax
    call ib_modrm
    mov rax, [op_v+16]
    mov rcx, 1
    call ib_imm
    call ib_vex_finish
    call ib_vex_fim
    ret

; ---------- enc_vzero: C5 F8 77 ----------------------------------------------------------
enc_vzero:
    call ib_inicio
    mov qword [vx_vvvv], 0
    mov qword [vx_L], 0
    mov qword [ib_ext], 4           ; mapa 0F, pp 0, W 0 (VEX C5)
    mov rax, 0x77
    call ib_put
    call ib_vex_finish
    call ib_vex_fim
    ret

; ib_vex_fim: envia o corpo (ja com prefixo VEX) para a secao; sem outros prefixos
ib_vex_fim:
    mov qword [ib_pfx66], 0
    mov qword [ib_rep], 0
    mov qword [ib_rex], 0
    mov qword [ib_rexf], 0
    call ib_fim
    ret

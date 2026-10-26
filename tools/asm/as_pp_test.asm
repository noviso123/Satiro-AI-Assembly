; Driver de teste do pre-processador: asm_pp <entrada> <saida>
; Grava o codigo expandido (apos %include/%define/%if) em <saida>.
bits 64
default rel
%include "tools/asm/as_base.asm"
%include "tools/asm/as_pre.asm"

global main

section .text
main:
    AS_ENTER
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [as_hout], rax
    call as_cmdline
    test eax, eax
    jz .uso
    lea rsi, [as_srcpath]
    call pre_file
    lea rdi, [as_outpath]
    lea rsi, [as_exbuf]
    mov rdx, [as_exlen]
    call as_write_file
    test eax, eax
    jz .escreve_erro
    xor ecx, ecx
    call [__imp_ExitProcess]
.uso:
    lea rsi, [as_s_usage]
    call as_say
    mov ecx, 2
    call [__imp_ExitProcess]
.escreve_erro:
    mov ecx, 1
    call [__imp_ExitProcess]

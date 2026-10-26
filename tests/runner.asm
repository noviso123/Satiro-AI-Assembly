; ============ RUNNER DE TESTES EM ASSEMBLY ============
; Monta os programas (montador proprio + pelink, chamados por CreateProcessA),
; executa cada um com entrada e saida redirecionadas para arquivos em build\,
; e aplica os checks. Executar a partir da pasta do projeto: build\runner.exe
;
; Bootstrap (unico passo fora do runner): build\asm.exe tests\runner.asm build\runner.obj
;   e depois build\pelink.exe build\runner.obj build\runner.exe
bits 64
default rel

extern __imp_GetStdHandle
extern __imp_WriteFile
extern __imp_ReadFile
extern __imp_CreateFileA
extern __imp_CloseHandle
extern __imp_CreateProcessA
extern __imp_WaitForSingleObject
extern __imp_GetExitCodeProcess
extern __imp_CopyFileA
extern __imp_CreateDirectoryA
extern __imp_GetTempPathA
extern __imp_GetCurrentDirectoryA
extern __imp_GetFileAttributesA
extern __imp_FindFirstFileA
extern __imp_FindClose
extern __imp_ExitProcess

global main

%define MAXOUT       1048576        ; saida de um programa
%define MAXIN        1048576        ; entrada (stdin) de um programa
%define BIGMAX       8388608        ; arquivo grande gerado no teste
%define GENERIC_READ  0x80000000
%define GENERIC_WRITE 0x40000000

section .data
align 8
; --- ferramentas (caminhos completos) ---
s_asm:     db 'build\asm.exe', 0
s_dump:     db '"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\dumpbin.exe"', 0
s_space:    db ' ', 0
s_oo:       db ' -o build\', 0
s_dotobj:   db '.obj', 0
s_dotexe:   db '.exe', 0
s_lobj:     db ' build\', 0
s_pelink:   db 'build\pelink.exe', 0
s_nopel:    db 'build\pelink.exe nao encontrado: monte-o manualmente (ver tools\pelink.asm)', 13, 10, 0
s_imports:  db ' /IMPORTS ', 0
s_bsl:      db 'build\', 0
s_in:       db 'build\in.txt', 0
s_out:      db 'build\out.txt', 0
s_cdrive:   db 'C:\', 0
s_empty:    db 0
s_mutname:  db 'lm_grad_mut', 0
s_mutflag:  db '-DMUTANT_SIGN', 0
s_nodata:   db 'satiro_nodata.exe', 0
s_bigdir:   db 'satiro_big', 0
s_dados:    db '\dados', 0
s_barra:    db '\', 0
s_chatbin:  db 'build\chat_pira.exe', 0
s_chatname: db 'chat_pira.exe', 0
s_trsrc:    db 'dados\pira_train.tsv', 0
s_vsrc:     db 'dados\pira_valid.tsv', 0
s_tsrc:     db 'dados\pira_test.tsv', 0
s_trname:   db 'pira_train.tsv', 0
s_vname:    db 'pira_valid.tsv', 0
s_tname:    db 'pira_test.tsv', 0

; --- nomes dos programas (fonte, nome do executavel) ---
n_chat:     db 'chat_pira', 0
n_deep:     db 'deep_nn', 0
n_xor:      db 'xor_nn', 0
n_exp:      db 'test_exp', 0
n_xorg:     db 'test_xor_grad', 0
n_lmt:      db 'lm_train', 0
n_lmg:      db 'lm_grad', 0
n_eval:     db 'eval_trechos', 0
f_chat:     db 'chat_pira.asm', 0
f_deep:     db 'deep_nn.asm', 0
f_xor:      db 'xor_nn.asm', 0
f_exp:      db 'tests\exp_test.asm', 0
f_xorg:     db 'tests\xor_grad.asm', 0
f_lmt:      db 'lm_train_main.asm', 0
f_lmg:      db 'lm_grad_main.asm', 0
f_eval:     db 'eval_trechos.asm', 0
n_bc:       db 'batch_check', 0
f_bc:       db 'tests\batch_check.asm', 0

; --- caminhos dos executaveis (relativos a pasta do projeto) ---
p_deep:     db 'build\deep_nn.exe', 0
p_xor:      db 'build\xor_nn.exe', 0
p_exp:      db 'build\test_exp.exe', 0
p_xorg:     db 'build\test_xor_grad.exe', 0
p_lmg:      db 'build\lm_grad.exe', 0
p_lmt:      db 'build\lm_train.exe', 0
p_eval:     db 'build\eval_trechos.exe', 0
p_bc:       db 'build\batch_check.exe', 0
p_chat:     db 'build\chat_pira.exe', 0
p_mut:      db 'build\lm_grad_mut.exe', 0
; executaveis que devem importar so KERNEL32
e_list:     dq e_1, e_2, e_3, e_4, e_5, e_6, e_7, e_8
e_1:        db 'chat_pira.exe', 0
e_2:        db 'deep_nn.exe', 0
e_3:        db 'xor_nn.exe', 0
e_4:        db 'lm_train.exe', 0
e_5:        db 'lm_grad.exe', 0
e_6:        db 'eval_trechos.exe', 0
e_7:        db 'test_exp.exe', 0
e_8:        db 'test_xor_grad.exe', 0
c_list:     dq c_i1, c_i2, c_i3, c_i4, c_i5, c_i6, c_i7, c_i8
c_i1:       db 'chat_pira importa apenas KERNEL32.dll (sem CRT)', 0
c_i2:       db 'deep_nn importa apenas KERNEL32.dll (sem CRT)', 0
c_i3:       db 'xor_nn importa apenas KERNEL32.dll (sem CRT)', 0
c_i4:       db 'lm_train importa apenas KERNEL32.dll (sem CRT)', 0
c_i5:       db 'lm_grad importa apenas KERNEL32.dll (sem CRT)', 0
c_i6:       db 'eval_trechos importa apenas KERNEL32.dll (sem CRT)', 0
c_i7:       db 'test_exp importa apenas KERNEL32.dll (sem CRT)', 0
c_i8:       db 'test_xor_grad importa apenas KERNEL32.dll (sem CRT)', 0

; --- entradas (stdin) ---
in_pergunta: db 'O que ', 0xC3, 0xA9, ' a Plataforma Norte do Brasil?', 13, 10, '/sair', 13, 10, 0
in_sorvete:  db 'qual o sabor preferido de sorvete?', 13, 10, '/sair', 13, 10, 0
in_lf:       db 'Plataforma Norte do Brasil', 10, '/sair', 10, 0
in_vazias:   db 13, 10, 13, 10, '/sair', 13, 10, 0
in_x:        db 'x', 13, 10, 0
in_acento:   db 'Qual ', 0xC3, 0xA9, ' o tamanho da plataforma norte?', 13, 10, '/sair', 13, 10, 0
in_bytes:    db 0xFF, 0xFE, 0xC3, 0x28, ' ruido', 13, 10, '/sair', 13, 10, 0
in_sair:     db '/sair', 13, 10, 0
in_longa:    db 'plataforma norte brasil ', 0
in_longa_fim: db 13, 10, '/sair', 13, 10, 0

; --- textos de saida ---
t_ok:       db '  [OK]     ', 0
t_fail:     db '  [FALHA]  ', 0
t_nl:       db 13, 10, 0
t_res1:     db 'RESULTADO: ', 0
t_res2:     db ' passaram, ', 0
t_res3:     db ' falharam', 13, 10, 0

; --- rotulos da saida dos programas ---
l_trecho:   db 'Trecho do corpus:', 0
l_chat:     db 'Chat Pir', 0
l_encont:   db 'encontrei', 0
l_erro:     db 'Erro ao carregar', 0
l_acertos:  db 'acertos: 16 de 16', 0
l_geracao:  db 'geracao: ', 0
l_nvis:     db '--- texto nao visto', 0
l_argmax:   db 'acerto argmax x1000: ', 0
l_exp:      db 'exp max erro relativo (x1e12): ', 0
l_sig:      db 'sigmoide max erro absoluto (x1e12): ', 0
l_xorg:     db 'xor gradiente: erro max (x1e9) / grad max (x1e3): ', 0
l_lmg:      db 'erro max gradiente (x1e9): ', 0
l_bc:       db 'lote vs sequencial (x1e12): ', 0
l_dll:      db '.dll', 0
l_k32:      db 'KERNEL32.dll', 0
l_p01:      db '0 0 -> 0.0', 0
l_p02:      db '0 1 -> 0.9', 0
l_p03:      db '1 0 -> 0.9', 0
l_p04:      db '1 1 -> 0.0', 0
l_pt:       db 'perguntas de teste: ', 0
l_resp:     db 'respondidas: ', 0
l_nh:       db 'gold no trecho recuperado: ', 0
l_nc:       db 'gold em algum trecho do corpus (teto): ', 0

; --- nomes dos checks ---
c_mchat:    db 'chat_pira monta e linka', 0
c_mdeep:    db 'deep_nn monta e linka', 0
c_mxor:     db 'xor_nn monta e linka', 0
c_mexp:     db 'teste exp/sigmoide monta', 0
c_mxorg:    db 'teste gradiente XOR monta', 0
c_mlmt:     db 'lm_train monta', 0
c_mlmg:     db 'lm_grad monta', 0
c_meval:    db 'avaliacao de trechos monta', 0
c_deep:     db 'deep_nn: 16 de 16 acertos', 0
c_xor:      db 'xor_nn: aprende XOR (4 saidas corretas)', 0
c_exp:      db 'exp em [-30,30]: erro relativo max <= 10e-12', 0
c_sig:      db 'sigmoide em [-30,30]: erro absoluto max <= 10e-12', 0
c_xorg2:    db 'gradiente XOR bate com diferencas finitas (erro x1e9 <= 100)', 0
c_lmg2:     db 'gradiente do modelo de linguagem, float32 (erro x1e9 <= 1000000)', 0
c_mbc:      db 'lote com threads monta', 0
c_bc:       db 'lote com threads bate com a soma sequencial, float32 (erro x1e12 <= 100000)', 0
c_treino:   db 'treino: acerto argmax no fluxo >= 350 por mil', 0
c_nvis2:    db 'texto nao visto: acerto argmax >= 300 por mil', 0
c_gera:     db 'geracao produz uma linha de texto', 0
c_det:      db 'treino deterministico (duas execucoes identicas)', 0
c_eval4:    db 'avaliacao executa e imprime as 4 metricas', 0
c_inv1:     db 'invariante: respondidas <= perguntas', 0
c_inv2:     db 'invariante: gold no trecho <= teto', 0
c_inv3:     db 'invariante: teto <= perguntas de teste', 0
c_ch1:      db 'chat: pergunta do corpus devolve trecho', 0
c_ch2:      db 'chat: saudacao inicial impressa', 0
c_ch3:      db 'chat: /sair encerra com codigo 0', 0
c_ch4:      db "chat: pergunta fora do assunto recebe 'nao encontrei'", 0
c_ch5:      db 'chat: aceita LF sem CR', 0
c_ch6:      db 'chat: linhas vazias nao quebram o programa', 0
c_ch7:      db 'chat: encerra com codigo 0 ao fim da entrada (EOF)', 0
c_ch8:      db 'chat: pergunta longa (~2,9 KB) gera exatamente uma resposta', 0
c_ch9:      db 'chat: bytes UTF-8 invalidos nao derrubam o programa', 0
c_ch10:     db 'chat: acentos na entrada (UTF-8) sao normalizados', 0
c_ch11:     db 'chat: sem a pasta dados/ imprime erro e sai com codigo 1', 0
c_ch12:     db 'chat: arquivo maior que o buffer e recusado com erro', 0
c_ch13:     db 'chat: encontra dados/ pelo caminho do executavel', 0
c_ch14:     db 'chat: linha de ~90 KB nao trava e termina com codigo 0', 0
c_mut:      db 'mutante de sinal e detectado (erro x1e9 > 1000000)', 0
c_proib:    db 'nenhum arquivo de linguagem proibida no projeto', 0

; --- padroes de busca (auditoria de linguagens) ---
pat_list:   dq pt1, pt2, pt3, pt4, pt5, pt6, pt7, pt8, pt9, pt10
pt1:        db '*.c', 0
pt2:        db '*.py', 0
pt3:        db '*.sh', 0
pt4:        db '*.js', 0
pt5:        db '*.awk', 0
pt6:        db '*.cpp', 0
pt7:        db 'tests\*.sh', 0
pt8:        db 'tests\*.py', 0
pt9:        db 'tests\*.awk', 0
pt10:       db 'tests\*.js', 0

section .bss
alignb 16
cmd1:       resb 2048
cmd2:       resb 2048
cmdexe:     resb 1024
stdinbuf:   resb MAXIN
stdinlen:   resq 1
outbuf:     resb MAXOUT
outlen:     resq 1
outcopy:    resb MAXOUT
outcopylen: resq 1
bigbuf:     resb BIGMAX
biglen:     resq 1
tmpdir:     resb 300
pathA:      resb 400
pathB:      resb 400
pathC:      resb 400
pathD:      resb 400
abs_root:   resb 300
hout:       resq 1
pass:       resq 1
fail:       resq 1
lastrc:     resq 1
runcwd:     resq 1
sa:         resb 24
sinfo:      resb 104
pi:         resb 24
hin:        resq 1
hout2:      resq 1
hfile:      resq 1
rdcnt:      resd 1
wrcnt:      resd 1
rccode:     resd 1
fdbuf:      resb 600
numbuf:     resb 24
b_src:      resq 1
b_name:     resq 1
b_flags:    resq 1
cnt_pat:    resq 1
tmp_ptr:    resq 1
tmp_len:    resq 1
tmp_res:    resq 1
num_v:      resq 1
chk_name:   resq 1
ev_nt:      resq 1
ev_na:      resq 1
ev_nh:      resq 1
ev_nc:      resq 1
loop_i:     resq 1

section .text

; ---------- slen: rsi = texto zero-terminado -> rax = tamanho -----------
slen:
    xor eax, eax
.l:
    cmp byte [rsi+rax], 0
    je .d
    inc rax
    jmp .l
.d:
    ret

; ---------- cat: rdi = fim atual, rsi = texto -> rdi = novo fim (zero) --
cat:
.c:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .d
    inc rsi
    inc rdi
    jmp .c
.d:
    ret

; ---------- find: rdi = texto, rsi = tamanho, rdx = agulha, rcx = inicio
;             -> rax = indice ou -1 ---------------------------------------
find:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi                    ; texto
    mov r13, rsi                    ; tamanho do texto
    mov rbx, rcx                    ; posicao atual
    mov r14, rdx                    ; agulha
    mov rsi, rdx
    call slen
    mov r9, rax                     ; tamanho da agulha
.f:
    lea rax, [rbx+r9]
    cmp rax, r13
    ja .nao
    xor r10d, r10d
.cmp:
    cmp r10, r9
    jae .sim
    mov rdx, rbx
    add rdx, r10
    movzx ecx, byte [r12+rdx]
    cmp cl, [r14+r10]
    jne .prox
    inc r10
    jmp .cmp
.prox:
    inc rbx
    jmp .f
.sim:
    mov rax, rbx
    jmp .fim
.nao:
    mov rax, -1
.fim:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------- parse_at: rdi = texto, rsi = posicao -> rax = inteiro ou -1 ---
parse_at:
    xor eax, eax
    xor r8d, r8d
    mov rcx, rsi
.p:
    movzx edx, byte [rdi+rcx]
    cmp dl, '0'
    jb .fim
    cmp dl, '9'
    ja .fim
    imul rax, rax, 10
    sub edx, '0'
    add rax, rdx
    mov r8d, 1
    inc rcx
    jmp .p
.fim:
    test r8d, r8d
    jnz .ok
    mov rax, -1
.ok:
    ret

; ---------- num_first: rsi = rotulo -> numero apos a 1a ocorrencia ------
num_first:
    sub rsp, 88
    mov [tmp_ptr], rsi
    lea rdi, [outbuf]
    mov rsi, [outlen]
    mov rdx, [tmp_ptr]
    xor ecx, ecx
    call find
    cmp rax, -1
    je .nf_no
    mov [tmp_res], rax
    mov rsi, [tmp_ptr]
    call slen
    add rax, [tmp_res]
    mov rsi, rax
    lea rdi, [outbuf]
    call parse_at
    add rsp, 88
    ret
.nf_no:
    mov rax, -1
    add rsp, 88
    ret

; ---------- num_after: rsi = marcador, rdx = rotulo -> numero apos o
;            marcador (primeira ocorrencia do rotulo depois dele) ----------
num_after:
    sub rsp, 88
    mov [tmp_ptr], rdx
    mov [tmp_len], rsi
    lea rdi, [outbuf]
    mov rsi, [outlen]
    mov rdx, [tmp_len]
    xor ecx, ecx
    call find
    cmp rax, -1
    je .na_no
    mov [tmp_res], rax
    mov rsi, [tmp_len]
    call slen
    add rax, [tmp_res]
    mov rcx, rax
    lea rdi, [outbuf]
    mov rsi, [outlen]
    mov rdx, [tmp_ptr]
    call find
    cmp rax, -1
    je .na_no
    mov [tmp_res], rax
    mov rsi, [tmp_ptr]
    call slen
    add rax, [tmp_res]
    mov rsi, rax
    lea rdi, [outbuf]
    call parse_at
    add rsp, 88
    ret
.na_no:
    mov rax, -1
    add rsp, 88
    ret

; ---------- num_before: rsi = marcador, rdx = rotulo -> ultimo rotulo
;            antes da primeira ocorrencia do marcador -------------------
num_before:
    sub rsp, 88
    mov [tmp_ptr], rdx
    mov [tmp_len], rsi
    lea rdi, [outbuf]
    mov rsi, [outlen]
    mov rdx, [tmp_len]
    xor ecx, ecx
    call find
    cmp rax, -1
    je .nb_no
    mov [num_v], rax                ; posicao do marcador
    mov qword [tmp_res], -1         ; ultima ocorrencia do rotulo
    mov qword [loop_i], 0
.nb_loop:
    lea rdi, [outbuf]
    mov rsi, [outlen]
    mov rdx, [tmp_ptr]
    mov rcx, [loop_i]
    call find
    cmp rax, -1
    je .nb_fim
    cmp rax, [num_v]
    jae .nb_fim
    mov [tmp_res], rax
    lea rax, [rax+1]
    mov [loop_i], rax
    jmp .nb_loop
.nb_fim:
    cmp qword [tmp_res], -1
    je .nb_no
    mov rsi, [tmp_ptr]
    call slen
    add rax, [tmp_res]
    mov rsi, rax
    lea rdi, [outbuf]
    call parse_at
    add rsp, 88
    ret
.nb_no:
    mov rax, -1
    add rsp, 88
    ret

; ---------- has: rsi = agulha -> eax = 1 se aparece na saida -------------
has:
    sub rsp, 88
    mov rdx, rsi
    lea rdi, [outbuf]
    mov rsi, [outlen]
    xor ecx, ecx
    call find
    cmp rax, -1
    setne al
    movzx eax, al
    add rsp, 88
    ret

; ---------- count: rsi = agulha -> rax = ocorrencias na saida -----------
count:
    sub rsp, 88
    mov [tmp_ptr], rsi
    mov qword [cnt_pat], 0
    mov qword [tmp_res], 0
.c_loop:
    lea rdi, [outbuf]
    mov rsi, [outlen]
    mov rdx, [tmp_ptr]
    mov rcx, [tmp_res]
    call find
    cmp rax, -1
    je .c_fim
    inc qword [cnt_pat]
    lea rcx, [rax+1]
    mov [tmp_res], rcx
    jmp .c_loop
.c_fim:
    mov rax, [cnt_pat]
    add rsp, 88
    ret

; ---------- say: rsi = texto zero-terminado -> stdout --------------------
say:
    sub rsp, 88
    mov [tmp_ptr], rsi
    call slen
    mov r8, rax
    mov rcx, [hout]
    mov rdx, [tmp_ptr]
    lea r9, [wrcnt]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    add rsp, 88
    ret

; ---------- check: rsi = nome, eax = 1 se passou ------------------------
check:
    sub rsp, 88
    mov [chk_name], rsi
    test eax, eax
    jz .ck_falha
    lea rsi, [t_ok]
    call say
    mov rsi, [chk_name]
    call say
    lea rsi, [t_nl]
    call say
    inc qword [pass]
    add rsp, 88
    ret
.ck_falha:
    lea rsi, [t_fail]
    call say
    mov rsi, [chk_name]
    call say
    lea rsi, [t_nl]
    call say
    inc qword [fail]
    add rsp, 88
    ret

; ---------- set_in: rsi = texto -> stdin (substitui) --------------------
set_in:
    xor ecx, ecx                    ; conta em registrador; grava em stdinlen no fim
    lea rdi, [stdinbuf]
.si:
    mov al, [rsi]
    test al, al
    jz .si_fim
    mov [rdi], al
    inc rsi
    inc rdi
    inc rcx
    jmp .si
.si_fim:
    mov [stdinlen], rcx
    ret
; ---------- append_in: rsi = texto -> stdin (acrescenta) ----------------
append_in:
    mov rcx, [stdinlen]
    lea rdi, [stdinbuf]
    add rdi, rcx
.ai:
    mov al, [rsi]
    test al, al
    jz .ai_fim
    mov [rdi], al
    inc rsi
    inc rdi
    inc rcx
    jmp .ai
.ai_fim:
    mov [stdinlen], rcx
    ret
; ---------- repeat_in: rsi = texto, rdx = vezes -> stdin ----------------
repeat_in:
    sub rsp, 88
    mov qword [stdinlen], 0
    mov [tmp_len], rdx
    mov [tmp_ptr], rsi
.ri:
    cmp qword [tmp_len], 0
    je .ri_fim
    mov rsi, [tmp_ptr]
    call append_in
    dec qword [tmp_len]
    jmp .ri
.ri_fim:
    add rsp, 88
    ret

; ---------- run_full: rdi = caminho completo do executavel -> eax = codigo
;            (stdin = build\in.txt, stdout/stderr = build\out.txt) ---------
run_full:
    sub rsp, 88
    mov [tmp_ptr], rdi
    ; grava a entrada em build\in.txt
    lea rcx, [s_in]
    mov edx, GENERIC_WRITE
    xor r8d, r8d
    lea r9, [sa]
    mov qword [rsp+32], 2           ; CREATE_ALWAYS
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    mov [hfile], rax
    cmp rax, -1
    je .rf_erro
    mov rcx, [hfile]
    lea rdx, [stdinbuf]
    mov r8, [stdinlen]
    lea r9, [wrcnt]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    mov rcx, [hfile]
    call [__imp_CloseHandle]
    ; entrada herdavel
    lea rcx, [s_in]
    mov edx, GENERIC_READ
    mov r8d, 3
    lea r9, [sa]
    mov qword [rsp+32], 3           ; OPEN_EXISTING
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    mov [hin], rax
    ; saida herdavel
    lea rcx, [s_out]
    mov edx, GENERIC_WRITE
    mov r8d, 3
    lea r9, [sa]
    mov qword [rsp+32], 2           ; CREATE_ALWAYS
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    mov [hout2], rax
    ; STARTUPINFOA zerado com os handles
    lea rdi, [sinfo]
    xor eax, eax
    mov ecx, 104
    rep stosb
    mov dword [sinfo], 104
    mov dword [sinfo+60], 0x100        ; STARTF_USESTDHANDLES
    mov rax, [hin]
    mov [sinfo+80], rax
    mov rax, [hout2]
    mov [sinfo+88], rax
    mov [sinfo+96], rax
    lea rdi, [pi]
    xor eax, eax
    mov ecx, 24
    rep stosb
    ; CreateProcessA
    xor ecx, ecx
    mov rdx, [tmp_ptr]
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 1           ; bInheritHandles
    mov qword [rsp+40], 0x08000000  ; CREATE_NO_WINDOW
    mov qword [rsp+48], 0
    mov rax, [runcwd]
    mov [rsp+56], rax
    lea rax, [sinfo]
    mov [rsp+64], rax
    lea rax, [pi]
    mov [rsp+72], rax
    call [__imp_CreateProcessA]
    test eax, eax
    jz .rf_erro_fecha
    mov rcx, [pi]
    mov edx, 0xFFFFFFFF
    call [__imp_WaitForSingleObject]
    mov rcx, [pi]
    lea rdx, [rccode]
    call [__imp_GetExitCodeProcess]
    mov rcx, [pi]
    call [__imp_CloseHandle]
    mov rcx, [pi+8]
    call [__imp_CloseHandle]
    mov rcx, [hin]
    call [__imp_CloseHandle]
    mov rcx, [hout2]
    call [__imp_CloseHandle]
    ; le a saida
    mov qword [outlen], 0
    lea rcx, [s_out]
    mov edx, GENERIC_READ
    mov r8d, 3
    xor r9d, r9d
    mov qword [rsp+32], 3
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    mov [hfile], rax
    cmp rax, -1
    je .rf_sem_saida
.rf_le:
    mov rcx, [hfile]
    lea rdx, [outbuf]
    add rdx, [outlen]
    mov r8, MAXOUT
    sub r8, [outlen]
    lea r9, [rdcnt]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    test eax, eax
    jz .rf_le_fim
    mov eax, [rdcnt]
    test eax, eax
    jz .rf_le_fim
    add [outlen], rax
    jmp .rf_le
.rf_le_fim:
    mov rcx, [hfile]
    call [__imp_CloseHandle]
.rf_sem_saida:
    mov eax, [rccode]
    mov [lastrc], rax
    add rsp, 88
    ret
.rf_erro_fecha:
    mov rcx, [hin]
    call [__imp_CloseHandle]
    mov rcx, [hout2]
    call [__imp_CloseHandle]
.rf_erro:
    mov qword [lastrc], -1
    mov qword [outlen], 0
    mov rax, -1
    add rsp, 88
    ret

; ---------- run_exe: rsi = caminho relativo (ex.: build\chat_pira.exe) --
;            monta caminho absoluto em cmdexe e executa --------------------
run_exe:
    sub rsp, 88
    mov [tmp_ptr], rsi
    lea rdi, [cmdexe]
    mov byte [rdi], 0
    lea rsi, [abs_root]
    call cat
    mov byte [rdi], '\'
    inc rdi
    mov byte [rdi], 0
    mov rsi, [tmp_ptr]
    call cat
    lea rdi, [cmdexe]
    call run_full
    add rsp, 88
    ret

; ---------- build_one: rdi = fonte, rsi = nome, rdx = flags -> eax = 1 ---
build_one:
    sub rsp, 88
    mov [b_src], rdi
    mov [b_name], rsi
    mov [b_flags], rdx
    ; comando do montador proprio: build\asm.exe <fonte> build\<nome>.obj <flags>
    lea rdi, [cmd1]
    mov byte [rdi], 0
    lea rsi, [s_asm]
    call cat
    lea rsi, [s_space]
    call cat
    mov rsi, [b_src]
    call cat
    lea rsi, [s_lobj]
    call cat
    mov rsi, [b_name]
    call cat
    lea rsi, [s_dotobj]
    call cat
    lea rsi, [s_space]
    call cat
    mov rsi, [b_flags]
    call cat
    lea rdi, [cmd1]
    call run_full
    cmp eax, 0
    jne .bo_falha
    ; comando do linker: pelink
    lea rdi, [cmd2]
    mov byte [rdi], 0
    ; build\pelink.exe build\<nome>.obj build\<nome>.exe
    lea rsi, [s_pelink]
    call cat
    lea rsi, [s_lobj]
    call cat
    mov rsi, [b_name]
    call cat
    lea rsi, [s_dotobj]
    call cat
    lea rsi, [s_lobj]
    call cat
    mov rsi, [b_name]
    call cat
    lea rsi, [s_dotexe]
    call cat
.bo_run:
    lea rdi, [cmd2]
    call run_full
    cmp eax, 0
    jne .bo_falha
    mov eax, 1
    add rsp, 88
    ret
.bo_falha:
    xor eax, eax
    add rsp, 88
    ret

; ---------- imports_ok: rsi = nome do exe (em build\) -> eax = 1 se so
;            importa KERNEL32.dll --------------------------------------------
imports_ok:
    sub rsp, 88
    mov [tmp_ptr], rsi
    lea rdi, [cmd1]
    mov byte [rdi], 0
    lea rsi, [s_dump]
    call cat
    lea rsi, [s_imports]
    call cat
    lea rsi, [s_bsl]
    call cat
    mov rsi, [tmp_ptr]
    call cat
    lea rdi, [cmd1]
    call run_full
    lea rsi, [l_k32]
    call has
    test eax, eax
    jz .io_no
    lea rsi, [l_dll]
    call count
    cmp rax, 1
    jne .io_no
    mov eax, 1
    add rsp, 88
    ret
.io_no:
    xor eax, eax
    add rsp, 88
    ret

; ---------- join: rdi = destino, rsi = parte1, rdx = parte2 -------------
join:
    sub rsp, 88
    mov [tmp_ptr], rdx
    mov byte [rdi], 0
    call cat
    mov rsi, [tmp_ptr]
    call cat
    add rsp, 88
    ret

; ---------- no_foreign: nenhum arquivo de linguagem proibida ------------
no_foreign:
    sub rsp, 88
    mov qword [loop_i], 0
.nf_loop:
    mov rax, [loop_i]
    cmp rax, 10
    jae .nf_ok
    lea rbx, [pat_list]
    mov rdx, [rbx+rax*8]
    lea rcx, [fdbuf]
    call [__imp_FindFirstFileA]
    cmp rax, -1
    je .nf_prox
    mov rcx, rax
    call [__imp_FindClose]
    jmp .nf_no
.nf_prox:
    inc qword [loop_i]
    jmp .nf_loop
.nf_ok:
    mov eax, 1
    add rsp, 88
    ret
.nf_no:
    xor eax, eax
    add rsp, 88
    ret

; ---------- test_missing: exe copiado para o temporario, sem dados -------
; resultado em eax = 1 se saiu com codigo 1 e imprimiu erro de carregamento
test_missing:
    sub rsp, 88
    ; pasta temporaria
    mov ecx, 300
    lea rdx, [tmpdir]
    call [__imp_GetTempPathA]
    ; origem: build\chat_pira.exe (relativa a raiz) -> temporario
    lea rdi, [pathA]
    lea rsi, [tmpdir]
    lea rdx, [s_nodata]
    call join
    lea rcx, [s_chatbin]
    lea rdx, [pathA]
    xor r8d, r8d
    call [__imp_CopyFileA]
    ; entrada e execucao a partir do temporario
    lea rsi, [in_sair]
    call set_in
    lea rax, [tmpdir]
    mov [runcwd], rax
    lea rdi, [pathA]
    call run_full
    mov qword [runcwd], 0
    lea rsi, [l_erro]
    call has
    mov r12d, eax
    xor eax, eax
    cmp qword [lastrc], 1
    jne .tm_fim
    mov eax, r12d
.tm_fim:
    add rsp, 88
    ret

; ---------- test_big: pasta com dados maiores que o buffer (7 MB) -------
test_big:
    sub rsp, 88
    mov ecx, 300
    lea rdx, [tmpdir]
    call [__imp_GetTempPathA]
    ; tmpdir\satiro_big
    lea rdi, [pathA]
    lea rsi, [tmpdir]
    lea rdx, [s_bigdir]
    call join
    lea rcx, [pathA]
    xor edx, edx
    call [__imp_CreateDirectoryA]
    ; tmpdir\satiro_big\dados
    lea rdi, [pathB]
    lea rsi, [pathA]
    lea rdx, [s_dados]
    call join
    lea rcx, [pathB]
    xor edx, edx
    call [__imp_CreateDirectoryA]
    ; exe copiado para tmpdir\satiro_big\chat_pira.exe
    lea rdi, [pathC]
    lea rsi, [pathA]
    lea rdx, [s_barra]
    call join
    lea rdi, [pathD]
    lea rsi, [pathC]
    lea rdx, [s_chatname]
    call join
    lea rcx, [s_chatbin]
    lea rdx, [pathD]
    xor r8d, r8d
    call [__imp_CopyFileA]
    ; valid e test copiados
    lea rdi, [pathC]
    lea rsi, [pathB]
    lea rdx, [s_barra]
    call join
    lea rdi, [pathD]
    lea rsi, [pathC]
    lea rdx, [s_vname]
    call join
    lea rcx, [s_vsrc]
    lea rdx, [pathD]
    xor r8d, r8d
    call [__imp_CopyFileA]
    lea rdi, [pathD]
    lea rsi, [pathC]
    lea rdx, [s_tname]
    call join
    lea rcx, [s_tsrc]
    lea rdx, [pathD]
    xor r8d, r8d
    call [__imp_CopyFileA]
    ; train: le o original e grava duas vezes (7,3 MB)
    lea rcx, [s_trsrc]
    call read_big
    lea rdi, [pathD]
    lea rsi, [pathC]
    lea rdx, [s_trname]
    call join
    lea rcx, [pathD]
    call write_big2
    ; executa a partir de satiro_big
    lea rsi, [in_sair]
    call set_in
    lea rax, [pathA]
    mov [runcwd], rax
    lea rdi, [pathC]
    lea rsi, [pathB]
    lea rdx, [s_empty]
    call join
    lea rdi, [pathD]
    lea rsi, [pathA]
    lea rdx, [s_barra]
    call join
    lea rdi, [cmdexe]
    lea rsi, [pathD]
    lea rdx, [s_chatname]
    call join
    lea rdi, [cmdexe]
    call run_full
    mov qword [runcwd], 0
    lea rsi, [l_erro]
    call has
    mov r12d, eax
    xor eax, eax
    cmp qword [lastrc], 1
    jne .tb_fim
    mov eax, r12d
.tb_fim:
    add rsp, 88
    ret

; ---------- read_big: rcx = caminho -> bigbuf (biglen) -------------------
read_big:
    sub rsp, 88
    mov [tmp_ptr], rcx
    mov qword [biglen], 0
    mov rcx, [tmp_ptr]
    mov edx, GENERIC_READ
    mov r8d, 3
    xor r9d, r9d
    mov qword [rsp+32], 3
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    mov [hfile], rax
    cmp rax, -1
    je .rb_fim
.rb_l:
    mov rcx, [hfile]
    lea rdx, [bigbuf]
    add rdx, [biglen]
    mov r8, BIGMAX
    sub r8, [biglen]
    lea r9, [rdcnt]
    mov qword [rsp+32], 0
    call [__imp_ReadFile]
    test eax, eax
    jz .rb_fecha
    mov eax, [rdcnt]
    test eax, eax
    jz .rb_fecha
    add [biglen], rax
    jmp .rb_l
.rb_fecha:
    mov rcx, [hfile]
    call [__imp_CloseHandle]
.rb_fim:
    add rsp, 88
    ret

; ---------- write_big2: rcx = caminho -> grava bigbuf duas vezes ---------
write_big2:
    sub rsp, 88
    mov [tmp_ptr], rcx
    mov edx, GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp+32], 2
    mov qword [rsp+40], 0x80
    mov qword [rsp+48], 0
    call [__imp_CreateFileA]
    mov [hfile], rax
    cmp rax, -1
    je .wb_fim
    mov rcx, [hfile]
    lea rdx, [bigbuf]
    mov r8, [biglen]
    lea r9, [wrcnt]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    mov rcx, [hfile]
    lea rdx, [bigbuf]
    mov r8, [biglen]
    lea r9, [wrcnt]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    mov rcx, [hfile]
    call [__imp_CloseHandle]
.wb_fim:
    add rsp, 88
    ret

; ---------- say_num: rax = numero -> stdout ------------------------------
say_num:
    sub rsp, 88
    lea rdi, [numbuf+20]
    mov byte [rdi], 0
    mov rcx, 10
.sn:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    test rax, rax
    jnz .sn
    mov rsi, rdi
    call say
    add rsp, 88
    ret

; ---------- cond_le: rax = valor, rcx = limite -> eax = 0 <= valor <= limite
cond_le:
    xor edx, edx
    test rax, rax
    js .cl_no
    cmp rax, rcx
    ja .cl_no
    mov eax, 1
    ret
.cl_no:
    xor eax, eax
    ret

; ---------- cond_ge: rax = valor, rcx = limite -> eax = valor >= limite --
cond_ge:
    cmp rax, rcx                    ; valor >= limite (rax = valor)
    jl .cg_no
    mov rax, 1
    ret
.cg_no:
    xor eax, eax
    ret

; ---------- main --------------------------------------------------------
main:
    sub rsp, 88
    mov qword [pass], 0
    mov qword [fail], 0
    mov qword [runcwd], 0
    mov dword [sa], 24              ; SECURITY_ATTRIBUTES com heranca
    mov qword [sa+8], 0
    mov dword [sa+16], 1
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov [hout], rax
    lea rdx, [abs_root]
    mov ecx, 300
    call [__imp_GetCurrentDirectoryA]

    ; 1. auditoria
    call no_foreign
    lea rsi, [c_proib]
    call check_eax

    ; 2. construcao: tudo e linkado pelo pelink (sem link.exe). Sem build\pelink.exe
    ; o teste nao roda: o bootstrap e feito manualmente (ver tools/pelink.asm).
    lea rcx, [s_pelink]
    call [__imp_GetFileAttributesA]
    cmp eax, -1
    jne .pel_pronto
    lea rsi, [s_nopel]
    call say
    mov ecx, 1
    call [__imp_ExitProcess]
.pel_pronto:
    lea rdi, [f_chat]
    lea rsi, [n_chat]
    lea rdx, [s_empty]
    call build_one
    lea rsi, [c_mchat]
    call check_eax
    lea rdi, [f_deep]
    lea rsi, [n_deep]
    lea rdx, [s_empty]
    call build_one
    lea rsi, [c_mdeep]
    call check_eax
    lea rdi, [f_xor]
    lea rsi, [n_xor]
    lea rdx, [s_empty]
    call build_one
    lea rsi, [c_mxor]
    call check_eax
    lea rdi, [f_exp]
    lea rsi, [n_exp]
    lea rdx, [s_empty]
    call build_one
    lea rsi, [c_mexp]
    call check_eax
    lea rdi, [f_xorg]
    lea rsi, [n_xorg]
    lea rdx, [s_empty]
    call build_one
    lea rsi, [c_mxorg]
    call check_eax
    lea rdi, [f_lmt]
    lea rsi, [n_lmt]
    lea rdx, [s_empty]
    call build_one
    lea rsi, [c_mlmt]
    call check_eax
    lea rdi, [f_lmg]
    lea rsi, [n_lmg]
    lea rdx, [s_empty]
    call build_one
    lea rsi, [c_mlmg]
    call check_eax
    lea rdi, [f_eval]
    lea rsi, [n_eval]
    lea rdx, [s_empty]
    call build_one
    lea rsi, [c_meval]
    call check_eax
    lea rdi, [f_bc]
    lea rsi, [n_bc]
    lea rdx, [s_empty]
    call build_one
    lea rsi, [c_mbc]
    call check_eax

    ; 3. importacoes: so KERNEL32.dll (uma checagem por executavel)
    mov qword [loop_i], 0
.imp_loop:
    mov rax, [loop_i]
    cmp rax, 8
    jae .imp_fim
    lea rbx, [e_list]
    mov rsi, [rbx+rax*8]
    call imports_ok
    mov rdx, [loop_i]
    lea rbx, [c_list]
    mov rsi, [rbx+rdx*8]
    call check_eax
    inc qword [loop_i]
    jmp .imp_loop
.imp_fim:

    ; 4. redes e matematica
    lea rsi, [s_empty]
    call set_in
    lea rsi, [p_deep]
    call run_exe
    lea rsi, [l_acertos]
    call has
    lea rsi, [c_deep]
    call check_eax

    lea rsi, [p_xor]
    call run_exe
    lea rsi, [l_p01]
    call has
    mov r12d, eax
    lea rsi, [l_p02]
    call has
    and r12d, eax
    lea rsi, [l_p03]
    call has
    and r12d, eax
    lea rsi, [l_p04]
    call has
    and eax, r12d
    lea rsi, [c_xor]
    call check_eax

    lea rsi, [p_exp]
    call run_exe
    lea rsi, [l_exp]
    call num_first
    mov rcx, 10
    call cond_le
    lea rsi, [c_exp]
    call check_eax
    lea rsi, [l_sig]
    call num_first
    mov rcx, 10
    call cond_le
    lea rsi, [c_sig]
    call check_eax

    lea rsi, [p_xorg]
    call run_exe
    lea rsi, [l_xorg]
    call num_first
    mov rcx, 100
    call cond_le
    lea rsi, [c_xorg2]
    call check_eax

    lea rsi, [p_lmg]
    call run_exe
    lea rsi, [l_lmg]
    call num_first
    mov rcx, 1000000
    call cond_le
    lea rsi, [c_lmg2]
    call check_eax

    ; lote com threads: pesos iguais a soma sequencial dos gradientes
    lea rsi, [p_bc]
    call run_exe
    lea rsi, [l_bc]
    call num_first
    mov rcx, 100000
    call cond_le
    lea rsi, [c_bc]
    call check_eax

    ; 5. modelo de linguagem
    lea rsi, [p_lmt]
    call run_exe
    lea rsi, [l_nvis]
    lea rdx, [l_argmax]
    call num_before
    mov rcx, 350
    call cond_ge
    lea rsi, [c_treino]
    call check_eax
    lea rsi, [l_nvis]
    lea rdx, [l_argmax]
    call num_after
    mov rcx, 300
    call cond_ge
    lea rsi, [c_nvis2]
    call check_eax
    lea rsi, [l_geracao]
    call has
    lea rsi, [c_gera]
    call check_eax

    ; determinismo: segunda execucao igual a primeira
    lea rdi, [outcopy]
    lea rsi, [outbuf]
    mov rcx, [outlen]
    mov [outcopylen], rcx
    rep movsb
    lea rsi, [p_lmt]
    call run_exe
    xor eax, eax
    mov rcx, [outlen]
    cmp rcx, [outcopylen]
    jne .det_fim
    xor edx, edx
.det_cmp:
    cmp rdx, [outlen]
    jae .det_sim
    lea r8, [outbuf]
    mov al, [r8+rdx]
    lea r8, [outcopy]
    cmp al, [r8+rdx]
    jne .det_no
    inc rdx
    jmp .det_cmp
.det_sim:
    mov eax, 1
    jmp .det_fim
.det_no:
    xor eax, eax
.det_fim:
    lea rsi, [c_det]
    call check_eax

    ; 6. avaliacao de trechos (invariantes)
    lea rsi, [p_eval]
    call run_exe
    lea rsi, [l_pt]
    call num_first
    mov [ev_nt], rax
    lea rsi, [l_resp]
    call num_first
    mov [ev_na], rax
    lea rsi, [l_nh]
    call num_first
    mov [ev_nh], rax
    lea rsi, [l_nc]
    call num_first
    mov [ev_nc], rax
    xor eax, eax
    cmp qword [ev_nt], 0
    jl .e4_no
    cmp qword [ev_na], 0
    jl .e4_no
    cmp qword [ev_nh], 0
    jl .e4_no
    cmp qword [ev_nc], 0
    jl .e4_no
    mov eax, 1
.e4_no:
    lea rsi, [c_eval4]
    call check_eax
    mov rax, [ev_na]
    mov rcx, [ev_nt]
    call cond_le
    lea rsi, [c_inv1]
    call check_eax
    mov rax, [ev_nh]
    mov rcx, [ev_nc]
    call cond_le
    lea rsi, [c_inv2]
    call check_eax
    mov rax, [ev_nc]
    mov rcx, [ev_nt]
    call cond_le
    lea rsi, [c_inv3]
    call check_eax

    ; 7. chat
    lea rsi, [in_pergunta]
    call set_in
    lea rsi, [p_chat]
    call run_exe
    lea rsi, [l_trecho]
    call has
    mov r12d, eax
    lea rsi, [l_chat]
    call has
    and r12d, eax
    mov eax, r12d
    lea rsi, [c_ch1]
    call check_eax
    lea rsi, [l_chat]
    call has
    lea rsi, [c_ch2]
    call check_eax
    xor eax, eax
    cmp qword [lastrc], 0
    jne .ch3_no
    mov eax, 1
.ch3_no:
    lea rsi, [c_ch3]
    call check_eax

    lea rsi, [in_sorvete]
    call set_in
    lea rsi, [p_chat]
    call run_exe
    lea rsi, [l_encont]
    call has
    lea rsi, [c_ch4]
    call check_eax

    lea rsi, [in_lf]
    call set_in
    lea rsi, [p_chat]
    call run_exe
    lea rsi, [l_trecho]
    call has
    lea rsi, [c_ch5]
    call check_eax

    lea rsi, [in_vazias]
    call set_in
    lea rsi, [p_chat]
    call run_exe
    xor eax, eax
    cmp qword [lastrc], 0
    jne .ch6_no
    mov eax, 1
.ch6_no:
    lea rsi, [c_ch6]
    call check_eax

    lea rsi, [in_x]
    call set_in
    lea rsi, [p_chat]
    call run_exe
    xor eax, eax
    cmp qword [lastrc], 0
    jne .ch7_no
    mov eax, 1
.ch7_no:
    lea rsi, [c_ch7]
    call check_eax

    ; linha longa (~2,9 KB): exatamente uma resposta
    lea rsi, [in_longa]
    mov edx, 120
    call repeat_in
    lea rsi, [in_longa_fim]
    call append_in
    lea rsi, [p_chat]
    call run_exe
    lea rsi, [l_trecho]
    call count
    xor ecx, ecx
    cmp rax, 1
    jne .ch8_no
    cmp qword [lastrc], 0
    jne .ch8_no
    mov ecx, 1
.ch8_no:
    mov eax, ecx
    lea rsi, [c_ch8]
    call check_eax

    lea rsi, [in_bytes]
    call set_in
    lea rsi, [p_chat]
    call run_exe
    xor eax, eax
    cmp qword [lastrc], 0
    jne .ch9_no
    mov eax, 1
.ch9_no:
    lea rsi, [c_ch9]
    call check_eax

    lea rsi, [in_acento]
    call set_in
    lea rsi, [p_chat]
    call run_exe
    lea rsi, [l_trecho]
    call has
    lea rsi, [c_ch10]
    call check_eax

    ; sem dados ao lado do executavel
    call test_missing
    lea rsi, [c_ch11]
    call check_eax

    ; arquivo maior que o buffer
    call test_big
    lea rsi, [c_ch12]
    call check_eax

    ; caminho dos dados pelo executavel: roda a partir da unidade C (raiz)
    lea rsi, [in_pergunta]          ; mesma entrada: pergunta + /sair (uma so montagem)
    call set_in
    lea rax, [s_cdrive]
    mov [runcwd], rax
    lea rsi, [p_chat]
    call run_exe
    mov qword [runcwd], 0
    lea rsi, [l_trecho]
    call has
    mov r12d, eax
    xor eax, eax
    cmp qword [lastrc], 0
    jne .ch13_no
    mov eax, r12d
.ch13_no:
    lea rsi, [c_ch13]
    call check_eax

    ; linha de ~90 KB: nao trava
    lea rsi, [in_longa]
    mov edx, 3750
    call repeat_in
    lea rsi, [in_longa_fim]
    call append_in
    lea rsi, [p_chat]
    call run_exe
    lea rsi, [l_trecho]
    call has
    mov r12d, eax
    xor eax, eax
    cmp qword [lastrc], 0
    jne .ch14_no
    mov eax, r12d
.ch14_no:
    lea rsi, [c_ch14]
    call check_eax

    ; 8. mutacao: o teste de gradiente precisa detectar erro de sinal
    lea rdi, [f_lmg]
    lea rsi, [s_mutname]
    lea rdx, [s_mutflag]
    call build_one
    lea rsi, [s_empty]
    call set_in
    lea rsi, [p_mut]
    call run_exe
    lea rsi, [l_lmg]
    call num_first
    mov rcx, 1000000
    call cond_ge
    lea rsi, [c_mut]
    call check_eax

    ; resumo
    lea rsi, [t_nl]
    call say
    lea rsi, [t_res1]
    call say
    mov rax, [pass]
    call say_num
    lea rsi, [t_res2]
    call say
    mov rax, [fail]
    call say_num
    lea rsi, [t_res3]
    call say

    xor ecx, ecx
    cmp qword [fail], 0
    je .sair
    mov ecx, 1
.sair:
    call [__imp_ExitProcess]

; ---------- check_eax: rsi = nome; eax = condicao (wrapper de check) -----
check_eax:
    sub rsp, 88
    mov [tmp_res], rax              ; guarda a condicao (eax) antes de check
    call check
    cmp qword [tmp_res], 0
    jnz .ce_ok
    call dump_out
.ce_ok:
    add rsp, 88
    ret

; ---------- dump_out: imprime codigo de saida e o inicio da saida (diagnostico)
dump_out:
    sub rsp, 88
    lea rsi, [t_stdin]
    call say
    mov rax, [stdinlen]
    call say_num
    lea rsi, [t_nl]
    call say
    lea rsi, [t_stdin]
    call say
    mov rsi, stdinbuf
    lea rsi, [stdinbuf]
    mov rcx, [stdinlen]
    cmp rcx, 80
    jbe .ds_ok
    mov rcx, 80
.ds_ok:
    mov r8, rcx
    mov rcx, [hout]
    lea rdx, [stdinbuf]
    lea r9, [wrcnt]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    lea rsi, [t_nl]
    call say
    lea rsi, [t_rc]
    call say
    mov rax, [lastrc]
    call say_num
    lea rsi, [t_nl]
    call say
    mov rcx, [outlen]
    cmp rcx, 300
    jbe .do_ok
    mov rcx, 300
.do_ok:
    mov [tmp_len], rcx
    mov r8, rcx
    mov rcx, [hout]
    lea rdx, [outbuf]
    lea r9, [wrcnt]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    lea rsi, [t_nl]
    call say
    add rsp, 88
    ret

section .data
t_rc:       db '    codigo de saida: ', 0
t_stdin:    db '    tamanho da entrada: ', 0

section .text
section .data

section .text
section .data

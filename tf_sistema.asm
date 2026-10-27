; ============ SISTEMA: CPU, threads e pasta do projeto (comum a todos os programas) ============
; sis_inicia (chamar no inicio de main):
;   1. confere AVX2 e FMA (com suporte do sistema operacional); sem eles, avisa e encerra;
;   2. define nth_v = numero de processadores logicos (entre 1 e MAXTH);
;   3. muda a pasta atual para a raiz do projeto (a pasta acima de build\), para que
;      os caminhos "dados/..." funcionem de qualquer lugar.
; Precisa de: GetStdHandle, WriteFile, ExitProcess ja declarados antes deste include.
%define MAXTH 32

extern __imp_GetSystemInfo
extern __imp_GetModuleFileNameA
extern __imp_SetCurrentDirectoryA
extern __imp_VirtualAlloc
extern __imp_GetFileAttributesA

section .data
align 8
sis_msg:     db "Este programa precisa de CPU com AVX2 e FMA (Intel a partir de 2013, AMD a partir de 2015).", 13, 10
sis_msg_len  equ $ - sis_msg
sis_dados:   db 92, "dados", 0

section .bss
alignb 16
nth_v:       resd 1                  ; threads de trabalho (decidido em sis_inicia)
sis_si:      resb 64                 ; SYSTEM_INFO (48 bytes em x64)
sis_path:    resb 1024               ; caminho do executavel
sis_wrote:   resd 1
sis_len:     resq 1
sis_tmp:     resb 1100

section .text

; ---------- sis_fala: mostra a mensagem de falta de AVX2 e encerra -----------------------------
; ---------- sis_tem_dados: rcx = pasta; eax = 1 se "pasta\dados" existe -----------------------
sis_tem_dados:
    push rsi
    push rdi
    sub rsp, 40
    mov rsi, rcx
    lea rdi, [sis_tmp]
.c1:
    mov al, [rsi]
    test al, al
    jz .c1d
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .c1
.c1d:
    lea rsi, [sis_dados]
.c2:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .c2d
    inc rsi
    inc rdi
    jmp .c2
.c2d:
    lea rcx, [sis_tmp]
    call [__imp_GetFileAttributesA]
    cmp eax, -1
    setne al
    movzx eax, al
    add rsp, 40
    pop rdi
    pop rsi
    ret

sis_falta:
    sub rsp, 56
    mov ecx, -11
    call [__imp_GetStdHandle]
    mov rcx, rax
    lea rdx, [sis_msg]
    mov r8d, sis_msg_len
    lea r9, [sis_wrote]
    mov qword [rsp+32], 0
    call [__imp_WriteFile]
    mov ecx, 1
    call [__imp_ExitProcess]

; ---------- sis_inicia: confere a CPU, define nth_v e a pasta do projeto ---------------------------
sis_inicia:
    push rbx                           ; cpuid destrói rbx; rsi e usado no laco abaixo
    push rsi
    sub rsp, 56
    ; leaf 1: OSXSAVE (bit 27), AVX (bit 28) e FMA (bit 12) em ECX
    mov eax, 1
    xor ecx, ecx
    cpuid
    mov r8d, ecx
    and r8d, 402657280               ; 2^27 + 2^28 + 2^12
    cmp r8d, 402657280
    jne .falta
    ; o sistema precisa salvar os registradores YMM: XCR0 bits 1 e 2
    xor ecx, ecx
    db 0x0F, 0x01, 0xD0              ; xgetbv -> edx:eax
    and eax, 6
    cmp eax, 6
    jne .falta
    ; leaf 7, subfolha 0: AVX2 (bit 5 de EBX)
    mov eax, 7
    xor ecx, ecx
    cpuid
    test ebx, 32
    jz .falta
    ; threads = processadores logicos (dwNumberOfProcessors, offset 32), entre 1 e MAXTH
    lea rcx, [sis_si]
    call [__imp_GetSystemInfo]
    mov eax, [sis_si+32]
    test eax, eax
    jnz .n_ok
    mov eax, 1
.n_ok:
    cmp eax, MAXTH
    jbe .n_fim
    mov eax, MAXTH
.n_fim:
    mov [nth_v], eax
    ; raiz do projeto: sobe a partir do executavel ate achar a pasta "dados" (ate 5 niveis).
    ; Funciona para o executavel em build\ e para os que ficam em build\alguma-pasta\.
    xor ecx, ecx
    lea rdx, [sis_path]
    mov r8d, 1024
    call [__imp_GetModuleFileNameA]
    mov eax, eax                       ; ABI: os 32 bits altos de RAX vem indefinidos
    mov [sis_len], rax
    mov r11d, 5
.sobe:
    mov r9d, [sis_len]
    lea rsi, [sis_path]
.bs:
    test r9, r9
    jz .nao
    dec r9
    cmp byte [rsi+r9], 92            ; '\'
    jne .bs
    mov byte [rsi+r9], 0             ; corta o ultimo componente do caminho
    mov [sis_len], r9
    lea rcx, [sis_path]
    call sis_tem_dados
    test eax, eax
    jnz .achou
    dec r11d
    jnz .sobe
.nao:
    add rsp, 56
    pop rsi
    pop rbx
    ret
.achou:
    lea rcx, [sis_path]
    call [__imp_SetCurrentDirectoryA]
    add rsp, 56
    pop rsi
    pop rbx
    ret
.falta:
    call sis_falta

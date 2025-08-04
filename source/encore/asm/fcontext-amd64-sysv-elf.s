/** AMD64 Linux/Unix (x86_64 SysV ELF): fiber context implementation
 * 
 *  offset | registers
 * -------------------------------------------
 *   0x00  | fc_mxcsr (MXCSR control/status)
 *   0x04  | fc_x87_cw (x87 FPU control word)
 *   0x08  | R12
 *   0x10  | R13
 *   0x18  | R14
 *   0x20  | R15
 *   0x28  | RBX
 *   0x30  | RBP
 *   0x38  | RIP (return address)
 *   0x40  | EXIT */
.file "fcontext-amd64-sysv-elf.s"
.text

.globl jump_fcontext
.type jump_fcontext,@function
.align 16
jump_fcontext:
    pushq   %rbp /* save RBP */
    pushq   %rbx /* save RBX */
    pushq   %r15 /* save R15 */
    pushq   %r14 /* save R14 */
    pushq   %r13 /* save R13 */
    pushq   %r12 /* save R12 */

    /* prepare stack for FPU */
    leaq    -0x8(%rsp), %rsp

    /* test for flag preserve_fpu */
    cmp     $0, %rcx
    je      1f

    /* save MMX control-word and status-word */
    stmxcsr (%rsp)

    /* save x87 control-word */
    fnstcw  0x4(%rsp)
1:
    /* store RSP (pointing to context-data) in RDI */
    movq    %rsp, (%rdi)

    /* restore RSP (pointing to context-data) from RSI */
    movq    %rsi, %rsp

    /* test for flag preserve_fpu */
    cmp     $0, %rcx
    je      2f

    /* restore MMX control-word and status-word */
    ldmxcsr (%rsp)

    /* restore x87 control-word */
    fldcw   0x4(%rsp)
2:
    /* prepare stack for FPU */
    leaq    0x8(%rsp), %rsp

    popq    %r12 /* restore R12 */
    popq    %r13 /* restore R13 */
    popq    %r14 /* restore R14 */
    popq    %r15 /* restore R15 */
    popq    %rbx /* restore RBX */
    popq    %rbp /* restore RBP */

    /* restore return-address */
    popq    %r8

    /* use third arg as return-value after jump */
    movq    %rdx, %rax

    /* use third arg as first arg in context function */
    movq    %rdx, %rdi

    /* indirect jump to context */
    jmp     *%r8
.size jump_fcontext,.-jump_fcontext

.globl spawn_fcontext
.type spawn_fcontext,@function
.align 16
spawn_fcontext:
    /* first arg of spawn_fcontext() == top of context-stack */
    movq    %rdi, %rax

    /* shift address in %rax to lower 16 byte boundary */
    andq    $-16, %rax

    /* reserve space for context-data on context-stack 
     * size for fc_mxcsr .. RIP + return-address for context-function
     * on context-function entry: (%rsp -0x8) % 16 == 0 */
    leaq    -0x48(%rax), %rax

    /* third arg of spawn_fcontext() == address of context-function */
    movq    %rdx, 0x38(%rax)

    /* save MMX control-word and status-word */
    stmxcsr (%rax)

    /* save x87 control-word */
    fnstcw  0x4(%rax)

    /* compute abs address of label finish */
    leaq    finish(%rip), %rcx

    /* save address of finish as return-address for context-function
     * will be entered after context-function returns */
    movq    %rcx, 0x40(%rax)

    /* return pointer to context-data */
    ret

finish:
    /* exit code is zero */
    xorq    %rdi, %rdi

    /* exit application */
    movq    $231, %rax /* SYS_exit_group */
    syscall
    hlt
.size spawn_fcontext,.-spawn_fcontext

/* mark that we don't need executable stack */
.section .note.GNU-stack,"",%progbits

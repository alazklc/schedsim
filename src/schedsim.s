.bss
# I/O buffers for raw file reading/writing (up to 2048 bytes)
input_buf: .space 2048
output_buf: .space 2048

# Global state variables
out_len: .space 8        # Tracks the current length of the output buffer
process_count: .space 8  # Total number of parsed processes
algo: .space 8           # Enum: 0=FCFS, 1=SJF, 2=SRTF, 3=PF, 4=RR
quantum: .space 8        # Used exclusively for Round Robin
curr_time: .space 8      # Global cycle clock
running_proc: .space 8   # Index of the currently executing process 

# Process Structure layout
# +0 1B ID char
# +4 4B Burst Time 
# +8 4B Remaining Time
# +12 4B Arrival Time 
# +16 4B Priority (lower = higher priority)
# +20 4B Input Index (tie-breaking)
# +24 1B Done flag (1 = finished)

proc_arr: .space 320

# Round Robin specific cyclic queue, defensively to prevent queue overflow edge cases 
rr_queue: .space 800000
rr_head: .space 8        # Index of the front of the queue
rr_tail: .space 8        # Index of the next insertion point

.data
# Empty data section. All initializations handled dynamically in .text to 
# avoid GNU assembler strictness errors regarding non-zero .bss values.

.text
.global _start

_start:
    # Dynamically initialize running_proc to -1 (idle state) 
    # since .bss enforces zero-initialization.
    movq $-1, running_proc(%rip)

# I/O and File Reading
    # Read entire input from stdin into input_buf using syscall 0 (read)
    mov $0, %rax
    mov $0, %rdi
    lea input_buf(%rip), %rsi
    mov $2048, %rdx
    syscall


# Algorithm Parsing

    # Parse the scheduling algorithm keyword 
    lea input_buf(%rip), %rsi
skip_spaces_algo:
    # Skip leading whitespace (Space: 32, Newline: 10, Tab: 9)
    movzbl (%rsi), %eax
    cmp $32, %eax
    je skip_space_algo_inc
    cmp $10, %eax
    je skip_space_algo_inc
    cmp $9, %eax
    je skip_space_algo_inc
    cmp $0, %eax
    je end_parse             # Reached EOF before finding algorithm
    jmp parse_algo_word
skip_space_algo_inc:
    inc %rsi
    jmp skip_spaces_algo

parse_algo_word:
    # Identify algorithm based on the first unique letter
    movzbl (%rsi), %eax
    cmp $'F', %eax
    je is_fcfs               # FCFS
    cmp $'S', %eax
    je is_s_algo             # SJF or SRTF
    cmp $'P', %eax
    je is_pf                 # PF (Priority)
    cmp $'R', %eax
    je is_rr                 # RR (Round Robin)
    jmp end_parse            # Fallback if invalid algorithm

is_fcfs:
    movq $0, algo(%rip)
    add $4, %rsi             # Skip "FCFS"
    jmp parse_procs
is_pf:
    movq $3, algo(%rip)
    add $2, %rsi             # Skip "PF"
    jmp parse_procs
is_rr:
    movq $4, algo(%rip)
    add $2, %rsi             # Skip "RR"
    jmp parse_procs
is_s_algo:
    movzbl 1(%rsi), %eax     # Check second letter to distinguish SJF/SRTF
    cmp $'J', %eax
    je is_sjf
    movq $2, algo(%rip)      # SRTF
    add $4, %rsi             # Skip "SRTF"
    jmp parse_procs
is_sjf:
    movq $1, algo(%rip)
    add $3, %rsi             # Skip "SJF"
    jmp parse_procs

# Process Parsing
parse_procs:
skip_spaces_procs:
    # Skip delimiters between process descriptors, treating newlines as spaces so multi-line process lists parse correctly.
    movzbl (%rsi), %eax
    cmp $32, %eax
    je skip_space_procs_inc
    cmp $10, %eax
    je skip_space_procs_inc  # Edge case prevention: Treat \n as space for multi line inputs
    cmp $0, %eax
    je end_parse             # EOF reached, parsing finished
    cmp $9, %eax
    je skip_space_procs_inc
    jmp parse_token
skip_space_procs_inc:
    inc %rsi
    jmp skip_spaces_procs

parse_token:
    # Edge case prevention: If algorithm is RR, we must determine if the current token is a process or the isolated quantum value
    movq algo(%rip), %rax
    cmp $4, %rax
    jne parse_proc_desc      # If not RR, it is definitely a process descriptor

    mov %rsi, %rdi
check_hyphen:
    # Scan token forward to check for a hyphen. If no hyphen exists, it must be the Round Robin quantum integer.
    movzbl (%rdi), %eax
    cmp $32, %al
    je is_quantum
    cmp $10, %al
    je is_quantum
    cmp $0, %al
    je is_quantum
    cmp $'-', %al
    je parse_proc_desc       # Hyphen found then it's a process descriptor
    inc %rdi
    jmp check_hyphen

is_quantum:
    call parse_int
    movq %rax, quantum(%rip)
    jmp parse_procs          # Continue parsing remaining processes if any

parse_proc_desc:
    # Calculate offset in proc_arr: process_count * 32 bytes
    mov process_count(%rip), %rcx
    mov %rcx, %rdx
    imul $32, %rdx
    lea proc_arr(%rip), %rdi
    add %rdx, %rdi

    # Read Process ID
    movzbl (%rsi), %eax
    movb %al, 0(%rdi)
    inc %rsi                 # Skip ID char
    inc %rsi                 # Skip '-'

    # Parse Burst Time and initialize Remaining time to match
    call parse_int
    movl %eax, 4(%rdi)
    movl %eax, 8(%rdi)       

    # Initialize default values (Arrival=0, Priority=0)
    movl $0, 12(%rdi)
    movl $0, 16(%rdi)

    # Save original input order index for tie breaking 
    movq process_count(%rip), %rax
    movl %eax, 20(%rdi)
    movb $0, 24(%rdi)        # Done flag = false

    # Determine which extra attributes to parse based on algorithm
    movq algo(%rip), %rax
    cmp $0, %rax
    je parse_arr             # FCFS: ID-Burst-Arrival
    cmp $2, %rax
    je parse_arr             # SRTF: ID-Burst-Arrival
    cmp $3, %rax
    je parse_arr_prio        # PF: ID-Burst-Arrival-Priority
    jmp proc_desc_done       # SJF/RR: ID-Burst only

parse_arr:
    inc %rsi                 # Skip '-'
    call parse_int
    movl %eax, 12(%rdi)
    jmp proc_desc_done

parse_arr_prio:
    inc %rsi                 # Skip '-'
    call parse_int
    movl %eax, 12(%rdi)      # Parse Arrival
    inc %rsi                 # Skip '-'
    call parse_int
    movl %eax, 16(%rdi)      # Parse Priority
    jmp proc_desc_done

proc_desc_done:
    incq process_count(%rip) # Increment total process count
    jmp parse_procs          # Loop back for next descriptor

end_parse:
    # Routing logic to redirect to the correct simulation loop
    movq algo(%rip), %rax
    cmp $4, %rax
    je run_rr


# Unified Simulation Loop (FCFS, SJF, SRTF, PF)
# Cycle-by-cycle simulation for non-RR algorithms.

run_unified:
unified_loop:
    # Break condition: Exit if all processes have completed
    call check_all_done
    cmp $1, %rax
    je sim_done

    # Check if algorithm is preemptive (SRTF/PF) or non-preemptive (FCFS/SJF)
    movq algo(%rip), %rax
    cmp $0, %rax
    je check_running         # FCFS (non-preemptive)
    cmp $1, %rax
    je check_running         # SJF (non-preemptive)
    
    # For preemptive algorithms, we reset running_proc every cycle 
    # to force a re-evaluation of the best candidate.
    movq $-1, running_proc(%rip) 
    jmp pick_best

check_running:
    # For non-preemptive algorithms, if a process is already running, keep running it unless it has finished execution.
    movq running_proc(%rip), %rcx
    cmp $-1, %rcx
    je pick_best
    
    # Calculate offset of currently running process
    mov %rcx, %rdx
    imul $32, %rdx
    lea proc_arr(%rip), %rdi
    add %rdx, %rdi
    movzbl 24(%rdi), %eax    # Check Done flag
    cmp $1, %eax
    je running_is_done
    jmp execute_running
running_is_done:
    # Process finished, free the CPU in order to pick a new one
    movq $-1, running_proc(%rip)

# Candidate Selection & Tie-Breaking
# Evaluates all processes to find the single best candidate to execute this cycle.

pick_best:
    movq $-1, %r12           # r12 holds index of current best candidate
    movq $0, %r13            # r13 is loop iterator (current evaluating index)

scan_loop:
    cmpq process_count(%rip), %r13
    jge scan_done

    # Get pointer to evaluating process
    mov %r13, %rcx
    imul $32, %rcx
    lea proc_arr(%rip), %rdi
    add %rcx, %rdi

    # Skip process if already marked done
    movzbl 24(%rdi), %eax
    cmp $1, %eax
    je scan_next

    # Skip process if it hasn't arrived yet (Arrival > curr_time)
    movl 12(%rdi), %eax
    movq curr_time(%rip), %rdx
    cmp %edx, %eax
    jg scan_next

    # If no best candidate exists yet, auto-select this valid process
    cmp $-1, %r12
    je update_best

    # Get pointer to current best process for tie-break comparison
    mov %r12, %rcx
    imul $32, %rcx
    lea proc_arr(%rip), %rsi
    add %rcx, %rsi

    # Route to specific algorithm comparison logic
    movq algo(%rip), %rax
    cmp $0, %rax
    je cmp_fcfs
    cmp $1, %rax
    je cmp_sjf
    cmp $2, %rax
    je cmp_srtf
    cmp $3, %rax
    je cmp_pf

# Algorithm-specific comparisons (rdi = evaluating process, rsi = best so far)
# "jl update_best" means evaluating process is strictly better
# "jg scan_next" means evaluating process is strictly worse
# "jmp cmp_idx" means primary metric tied; fall back to secondary metric

cmp_fcfs:
    movl 12(%rdi), %eax      # Compare Arrival Time
    movl 12(%rsi), %ebx
    cmp %ebx, %eax
    jl update_best
    jg scan_next
    jmp cmp_idx
cmp_sjf:
    movl 4(%rdi), %eax       # Compare Total Burst Time
    movl 4(%rsi), %ebx
    cmp %ebx, %eax
    jl update_best
    jg scan_next
    jmp cmp_idx              # Secondary tie-breaker: Input Order
cmp_srtf:
    movl 8(%rdi), %eax       # Compare Remaining Burst Time
    movl 8(%rsi), %ebx
    cmp %ebx, %eax
    jl update_best
    jg scan_next
    jmp cmp_idx              # Secondary tie-breaker: Input Order
cmp_pf:
    movl 16(%rdi), %eax      # Compare Priority (lower integer = higher priority)
    movl 16(%rsi), %ebx
    cmp %ebx, %eax
    jl update_best
    jg scan_next
    # Primary tied: Fall back to comparing Remaining Burst Time
    movl 8(%rdi), %eax
    movl 8(%rsi), %ebx
    cmp %ebx, %eax
    jl update_best
    jg scan_next
    jmp cmp_idx              # Tertiary tie-breaker: Input order
cmp_idx:
    # Final tie-breaker for all algorithms: Input Parse Order
    movl 20(%rdi), %eax
    movl 20(%rsi), %ebx
    cmp %ebx, %eax
    jl update_best
    jmp scan_next

update_best:
    mov %r13, %r12           # Replace best candidate index

scan_next:
    inc %r13
    jmp scan_loop

scan_done:
    movq %r12, running_proc(%rip) # Assign winner to CPU

# Execution & Time Advancement
execute_running:
    movq running_proc(%rip), %rcx
    cmp $-1, %rcx
    je exec_idle             # CPU is idle if no process was selectable

    # Print the executing process ID to output buffer
    mov %rcx, %rdx
    imul $32, %rdx
    lea proc_arr(%rip), %rdi
    add %rdx, %rdi
    movzbl 0(%rdi), %eax
    call append_out

    # Decrement Remaining Time
    movl 8(%rdi), %eax
    dec %eax
    movl %eax, 8(%rdi)
    
    # Check if process just finished
    cmp $0, %eax
    jg advance_time
    movb $1, 24(%rdi)        # Mark process as Done
    jmp advance_time

exec_idle:
    # Print 'X' to represent an idle CPU cycle
    mov $'X', %al
    call append_out

advance_time:
    incq curr_time(%rip)     # Tick clock
    jmp unified_loop         # Loop next cycle

# Round Robin Simulation
# Employs a macroscopic simulation strategy: it processes an entire quantum slice at once rather than evaluating cycle-by-cycle.

run_rr:
    movq $0, %rcx
rr_init_loop:
    # Initially enqueue all processes in their parsed order
    cmp process_count(%rip), %rcx
    jge rr_loop
    movq rr_tail(%rip), %rdx
    lea rr_queue(%rip), %rdi
    movq %rcx, (%rdi, %rdx, 8)
    incq rr_tail(%rip)
    inc %rcx
    jmp rr_init_loop

rr_loop:
    # Break condition: Queue is empty (Head pointer catches up to Tail)
    movq rr_head(%rip), %rax
    cmp rr_tail(%rip), %rax
    jge sim_done

    # Pop next process from head of queue
    lea rr_queue(%rip), %rdi
    movq (%rdi, %rax, 8), %rcx
    incq rr_head(%rip)

    # Locate process struct
    mov %rcx, %rdx
    imul $32, %rdx
    lea proc_arr(%rip), %rsi
    add %rdx, %rsi

    # Determine execution duration: min(Remaining Time, Quantum)
    movl 8(%rsi), %eax
    movq quantum(%rip), %rbx
    cmp %rbx, %rax
    jl rr_run_rem
    
    # Remaining Time >= Quantum: It will run for full Quantum, 0 padding needed
    mov %rbx, %r12           # r12 = execution cycles
    mov $0, %r13             # r13 = padding cycles (idle)
    jmp rr_do_run
rr_run_rem:
    # Remaining Time < Quantum: It finishes early. We must pad the remaining quantum time with 'X's per assignment rules.
    mov %rax, %r12           # r12 = execution cycles
    sub %rax, %rbx
    mov %rbx, %r13           # r13 = padding cycles (idle)

rr_do_run:
    mov %r12, %r14
rr_run_loop:
    # Output the Process ID for the duration of its execution
    cmp $0, %r14
    jle rr_pad
    movzbl 0(%rsi), %eax
    call append_out
    dec %r14
    jmp rr_run_loop

rr_pad:
    # Reduce actual Remaining Time in process struct
    movl 8(%rsi), %eax
    sub %r12d, %eax
    movl %eax, 8(%rsi)

    # Output 'X's for the wasted quantum padding
    mov %r13, %r14
rr_pad_loop:
    cmp $0, %r14
    jle rr_check_requeue
    mov $'X', %al
    call append_out
    dec %r14
    jmp rr_pad_loop

rr_check_requeue:
    # If the process still has time remaining, preempt it by pushing it to the back of the queue
    movl 8(%rsi), %eax
    cmp $0, %eax
    jle rr_loop_next
    movq rr_tail(%rip), %rdx
    lea rr_queue(%rip), %rdi
    movq %rcx, (%rdi, %rdx, 8)
    incq rr_tail(%rip)

rr_loop_next:
    jmp rr_loop


# Termination & OS Exit

sim_done:
    # Append required trailing newline formatting
    mov $10, %al
    call append_out

    # Write formatted buffer to stdout via syscall 1 (write)
    mov $1, %rax
    mov $1, %rdi
    lea output_buf(%rip), %rsi
    mov out_len(%rip), %rdx
    syscall

    # Exit program cleanly via syscall 60 (exit)
    mov $60, %rax
    xor %rdi, %rdi
    syscall


# UTILITY HELPER FUNCTIONS

# Scans all processes to determine if simulation is complete
# Returns rax = 1 (all done), rax = 0 (still pending)
check_all_done:
    mov $0, %rcx
cad_loop:
    cmp process_count(%rip), %rcx
    jge cad_true
    mov %rcx, %rdx
    imul $32, %rdx
    lea proc_arr(%rip), %rdi
    add %rdx, %rdi
    movzbl 24(%rdi), %eax
    cmp $0, %eax
    je cad_false
    inc %rcx
    jmp cad_loop
cad_true:
    mov $1, %rax
    ret
cad_false:
    mov $0, %rax
    ret

# Parses an ASCII string into an integer (stops at first non-digit).
# Edge Case Prevention: Pushes rdx and rcx to stack to prevent dangerous 
# register clobbering since the `mul` instruction inherently overwrites rdx.

parse_int:
    push %rdx
    push %rcx
    mov $0, %rax
    mov $10, %r8
pi_loop:
    movzbl (%rsi), %ecx
    cmp $'0', %ecx
    jl pi_done
    cmp $'9', %ecx
    jg pi_done
    sub $'0', %ecx
    mul %r8                  # rdx:rax = rax * 10
    add %rcx, %rax
    inc %rsi
    jmp pi_loop
pi_done:
    pop %rcx
    pop %rdx
    ret

# Appends a single character (in %al) to the global output_buf
# Uses defensive register preservation to prevent overwriting the caller's rcx state.

append_out:
    push %rcx
    push %rdx
    mov out_len(%rip), %rcx
    lea output_buf(%rip), %rdx
    movb %al, (%rdx, %rcx)
    incq out_len(%rip)
    pop %rdx
    pop %rcx
    ret
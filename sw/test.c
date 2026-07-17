
unsigned long long main()
{
    unsigned long long sum = 0;

    for (int i = 0; i < 100; i++) {
        asm volatile ("addi %0, %0, 1\n" 
                : "+r"(sum) : : "memory");
    }
    return sum;
}

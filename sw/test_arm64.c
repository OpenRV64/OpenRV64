
unsigned long long main()
{
    unsigned long long sum = 0, sum2 = 120;
    volatile unsigned long long test, test2;

    for (int i = 0; i < 100; i++) {
        asm volatile ("add %0, %0, #1\n"
                      //"sub %1, %1, #1\n"
                      "str %0, %2\n"
                : "+r"(sum), "+r"(sum2), "=m"(test), "=m"(test2) : : "memory");
    }
    return sum;
}

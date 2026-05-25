/*
 * Deliberately non-reproducible source — used by the
 * reproducibility-check harness as the "Round 1" iteration example.
 *
 * __DATE__ and __TIME__ are gcc preprocessor macros that expand to
 * the wall-clock date and time of compilation. They embed into the
 * .rodata section of the resulting binary, so two builds done one
 * second apart produce two byte-different binaries even when every
 * other input (source, compiler, flags, env) is identical.
 *
 * The fix (demonstrated in the Makefile's "fixed" target) is to set
 * SOURCE_DATE_EPOCH and use the gcc -Wdate-time / build-system
 * substitution patterns that the Reproducible Builds project
 * documents. For inline __DATE__/__TIME__ in source the canonical
 * upstream fix is to delete them and read the timestamp from an
 * env var at build time, but for this demo we use the simpler
 * `-Wno-builtin-macro-redefined -D__DATE__=...` override that gcc
 * already supports.
 */
#include <stdio.h>

int main(void) {
    printf("hello, world\n");
    printf("built on %s at %s\n", __DATE__, __TIME__);
    return 0;
}

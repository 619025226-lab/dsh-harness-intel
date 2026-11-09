/* Replacement for the bundled arm64 link-entry helper.
   Contract: link-entry <absolute source> <absolute destination>
   Moves the staged entry into place atomically. */
#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: link-entry <source> <destination>\n");
        return 2;
    }
    if (argv[1][0] != '/' || argv[2][0] != '/') {
        fprintf(stderr, "Command entry paths must be absolute.\n");
        return 2;
    }
    if (rename(argv[1], argv[2]) != 0) {
        fprintf(stderr, "Cannot link command entry: %s\n", strerror(errno));
        return 1;
    }
    return 0;
}

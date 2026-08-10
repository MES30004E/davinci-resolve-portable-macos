#include <errno.h>
#include <stdio.h>
#include <string.h>

int resolve_redirect_rewrite(const char *path, char *out, size_t size);

static int failures = 0;

static void expect_rewrite(const char *input, const char *expected)
{
    char output[1024];
    int result = resolve_redirect_rewrite(input, output, sizeof(output));
    if (result != 1 || strcmp(output, expected) != 0) {
        fprintf(stderr, "rewrite failed: %s -> %s (result %d), expected %s\n",
                input, output, result, expected);
        failures++;
    }
}

static void expect_passthrough(const char *input)
{
    char output[1024] = "unchanged";
    int result = resolve_redirect_rewrite(input, output, sizeof(output));
    if (result != 0 || strcmp(output, "unchanged") != 0) {
        fprintf(stderr, "unexpected rewrite: %s (result %d)\n", input, result);
        failures++;
    }
}

int main(void)
{
    char tiny[4];
    const char *prefix = "/Library/Application Support/Blackmagic Design";
    const char *destination = "/Volumes/Test Drive/Portable Root/Application Support/Blackmagic Design";

    expect_rewrite(prefix, destination);
    expect_rewrite("/Library/Application Support/Blackmagic Design/DaVinci Resolve",
                   "/Volumes/Test Drive/Portable Root/Application Support/Blackmagic Design/DaVinci Resolve");
    expect_passthrough("/Library/Application Support/Blackmagic Designer");
    expect_passthrough("/Library/Application Support/Other Vendor");
    expect_passthrough(NULL);

    errno = 0;
    if (resolve_redirect_rewrite(prefix, tiny, sizeof(tiny)) != -1 || errno != ENAMETOOLONG) {
        fprintf(stderr, "overflow did not return ENAMETOOLONG\n");
        failures++;
    }
    return failures == 0 ? 0 : 1;
}


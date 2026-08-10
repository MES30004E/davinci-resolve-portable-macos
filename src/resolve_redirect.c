#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <errno.h>

#ifndef RESOLVE_REDIRECT_DESTINATION
#error "Compile with RESOLVE_REDIRECT_DESTINATION set to the portable support path"
#endif

static const char *const OLDROOT =
    "/Library/Application Support/Blackmagic Design";
static const char *const NEWROOT = RESOLVE_REDIRECT_DESTINATION;

/* Match the prefix only at a path-component boundary. */
int resolve_redirect_rewrite(const char *path, char *out, size_t size)
{
    size_t old_len;
    int written;

    if (path == NULL || out == NULL || size == 0)
        return 0;

    old_len = strlen(OLDROOT);
    if (strncmp(path, OLDROOT, old_len) != 0)
        return 0;
    if (path[old_len] != '\0' && path[old_len] != '/')
        return 0;

    written = snprintf(out, size, "%s%s", NEWROOT, path + old_len);
    if (written < 0 || (size_t)written >= size) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 1;
}

#ifndef RESOLVE_REDIRECT_TESTING
static int redirected_mkdir(const char *path, mode_t mode)
{
    char rewritten[PATH_MAX];
    int result = resolve_redirect_rewrite(path, rewritten, sizeof(rewritten));
    if (result < 0)
        return -1;
    return mkdirat(AT_FDCWD, result ? rewritten : path, mode);
}

static int redirected_stat(const char *path, struct stat *buffer)
{
    char rewritten[PATH_MAX];
    int result = resolve_redirect_rewrite(path, rewritten, sizeof(rewritten));
    if (result < 0)
        return -1;
    return fstatat(AT_FDCWD, result ? rewritten : path, buffer, 0);
}

static int redirected_lstat(const char *path, struct stat *buffer)
{
    char rewritten[PATH_MAX];
    int result = resolve_redirect_rewrite(path, rewritten, sizeof(rewritten));
    if (result < 0)
        return -1;
    return fstatat(AT_FDCWD, result ? rewritten : path, buffer,
                   AT_SYMLINK_NOFOLLOW);
}

static int redirected_access(const char *path, int mode)
{
    char rewritten[PATH_MAX];
    int result = resolve_redirect_rewrite(path, rewritten, sizeof(rewritten));
    if (result < 0)
        return -1;
    return faccessat(AT_FDCWD, result ? rewritten : path, mode, 0);
}

struct interpose_entry {
    const void *replacement;
    const void *replacee;
};

__attribute__((used))
static const struct interpose_entry interposers[]
__attribute__((section("__DATA,__interpose"))) = {
    { (const void *)redirected_mkdir,  (const void *)mkdir  },
    { (const void *)redirected_stat,   (const void *)stat   },
    { (const void *)redirected_lstat,  (const void *)lstat  },
    { (const void *)redirected_access, (const void *)access }
};
#endif


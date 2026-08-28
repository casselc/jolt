/* Linux target ABI/runtime witness for jolt.publish.
 *
 * Compile on the target, not as a cross-layout table.  _GNU_SOURCE exposes the
 * glibc renameat2 declaration; assigning it to renameat2_sig makes the C
 * compiler check the exact non-variadic function type.  The program then
 * verifies the kernel-visible no-replace result and snapshots errno before any
 * cleanup can overwrite the calling thread's slot.
 */
#define _GNU_SOURCE 1

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

typedef int (*renameat2_sig)(int, const char *, int, const char *, unsigned int);
typedef int (*link_sig)(const char *, const char *);
typedef int (*unlink_sig)(const char *);

static int fail(const char *what) {
  fprintf(stderr, "ATOMIC-PUBLISH-ABI-PROBE FAIL: %s\n", what);
  return 1;
}

static int write_file(const char *path, const char *bytes) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
  size_t n = strlen(bytes);
  if (fd < 0) return -1;
  if (write(fd, bytes, n) != (ssize_t)n || close(fd) != 0) return -1;
  return 0;
}

static int equals_file(const char *path, const char *want) {
  char got[64] = {0};
  int fd = open(path, O_RDONLY);
  ssize_t n;
  if (fd < 0) return 0;
  n = read(fd, got, sizeof(got) - 1);
  (void)close(fd);
  return n >= 0 && strcmp(got, want) == 0;
}

int main(void) {
  renameat2_sig checked_renameat2 = renameat2;
  link_sig checked_link = link;
  unlink_sig checked_unlink = unlink;
  char root[] = "/tmp/jolt-publish-abi-XXXXXX";
  char old_one[PATH_MAX], old_two[PATH_MAX], old_three[PATH_MAX];
  char target[PATH_MAX], link_target[PATH_MAX];
  int saved_errno;

  if (sizeof(int) != 4 || sizeof(unsigned int) != 4 || sizeof(char *) != 8)
    return fail("unexpected target scalar or pointer width");
  if (AT_FDCWD != -100 || RENAME_NOREPLACE != 1)
    return fail("target header constants differ from the binding");
  if (mkdtemp(root) == NULL) return fail("mkdtemp");
  if (snprintf(old_one, sizeof(old_one), "%s/old-one", root) >= (int)sizeof(old_one) ||
      snprintf(old_two, sizeof(old_two), "%s/old-two", root) >= (int)sizeof(old_two) ||
      snprintf(old_three, sizeof(old_three), "%s/old-three", root) >= (int)sizeof(old_three) ||
      snprintf(target, sizeof(target), "%s/target", root) >= (int)sizeof(target) ||
      snprintf(link_target, sizeof(link_target), "%s/link-target", root) >= (int)sizeof(link_target))
    return fail("temporary path overflow");
  if (write_file(old_one, "winner") != 0 || write_file(old_two, "loser") != 0)
    return fail("create source");

  if (checked_renameat2(AT_FDCWD, old_one, AT_FDCWD, target,
                        RENAME_NOREPLACE) != 0)
    return fail("renameat2 absent or first no-replace publication failed");
  if (access(old_one, F_OK) == 0 || !equals_file(target, "winner"))
    return fail("first publication postcondition");

  if (checked_renameat2(AT_FDCWD, old_two, AT_FDCWD, target,
                        RENAME_NOREPLACE) != -1)
    return fail("second no-replace publication unexpectedly succeeded");
  saved_errno = errno; /* Before unlink/rmdir/stdio can overwrite errno. */
  if (saved_errno != EEXIST) return fail("second publication did not report EEXIST");
  if (!equals_file(target, "winner") || !equals_file(old_two, "loser"))
    return fail("EEXIST preserved target and caller-owned losing source");

  if (write_file(old_three, "link-winner") != 0 ||
      checked_link(old_three, link_target) != 0 ||
      !equals_file(old_three, "link-winner") ||
      !equals_file(link_target, "link-winner"))
    return fail("link fallback runtime postcondition");

  (void)checked_unlink(old_two);
  (void)checked_unlink(old_three);
  (void)checked_unlink(link_target);
  (void)checked_unlink(target);
  (void)rmdir(root);
  puts("ATOMIC-PUBLISH-ABI-PROBE OK");
  return 0;
}

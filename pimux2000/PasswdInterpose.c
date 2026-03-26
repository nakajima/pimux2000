#include <dispatch/dispatch.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

// ssh_cmd embeds OpenSSH, which calls getpwuid(getuid()) at startup.
// In iOS app contexts there is often no passwd database entry for the app uid,
// so ssh exits with "No user exists for uid ...". We interpose the passwd lookup
// with a synthetic local user backed by the app sandbox home directory.

typedef struct {
    struct passwd record;
    char name[64];
    char password[8];
    char gecos[64];
    char directory[PATH_MAX];
    char shell[32];
#if defined(__APPLE__)
    char userClass[8];
#endif
} PiSyntheticPasswd;

static PiSyntheticPasswd syntheticPasswd;

static void initializeSyntheticPasswdOnce(void *__unused context) {
    const char *user = getenv("LOGNAME");
    if (user == NULL || user[0] == '\0') {
        user = getenv("USER");
    }
    if (user == NULL || user[0] == '\0') {
        user = "mobile";
    }

    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        home = "/var/mobile";
    }

    memset(&syntheticPasswd, 0, sizeof(syntheticPasswd));
    snprintf(syntheticPasswd.name, sizeof(syntheticPasswd.name), "%s", user);
    snprintf(syntheticPasswd.password, sizeof(syntheticPasswd.password), "x");
    snprintf(syntheticPasswd.gecos, sizeof(syntheticPasswd.gecos), "%s", syntheticPasswd.name);
    snprintf(syntheticPasswd.directory, sizeof(syntheticPasswd.directory), "%s", home);
    snprintf(syntheticPasswd.shell, sizeof(syntheticPasswd.shell), "/bin/sh");
#if defined(__APPLE__)
    syntheticPasswd.userClass[0] = '\0';
#endif

    syntheticPasswd.record.pw_name = syntheticPasswd.name;
    syntheticPasswd.record.pw_passwd = syntheticPasswd.password;
    syntheticPasswd.record.pw_uid = getuid();
    syntheticPasswd.record.pw_gid = getgid();
#if defined(__APPLE__)
    syntheticPasswd.record.pw_change = 0;
    syntheticPasswd.record.pw_class = syntheticPasswd.userClass;
    syntheticPasswd.record.pw_gecos = syntheticPasswd.gecos;
#endif
    syntheticPasswd.record.pw_dir = syntheticPasswd.directory;
    syntheticPasswd.record.pw_shell = syntheticPasswd.shell;
#if defined(__APPLE__)
    syntheticPasswd.record.pw_expire = 0;
#endif
}

static void ensureSyntheticPasswd(void) {
    static dispatch_once_t onceToken;
    dispatch_once_f(&onceToken, NULL, initializeSyntheticPasswdOnce);
}

static struct passwd *pi_getpwuid(uid_t uid) {
    ensureSyntheticPasswd();
    if (uid == syntheticPasswd.record.pw_uid) {
        return &syntheticPasswd.record;
    }
    return NULL;
}

static struct passwd *pi_getpwnam(const char *name) {
    ensureSyntheticPasswd();
    if (name == NULL || name[0] == '\0') {
        return NULL;
    }
    return &syntheticPasswd.record;
}

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

DYLD_INTERPOSE(pi_getpwuid, getpwuid)
DYLD_INTERPOSE(pi_getpwnam, getpwnam)

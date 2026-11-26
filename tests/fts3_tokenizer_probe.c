/*
 * Probe the sqlite3 library this package compiles.
 *
 * An attacker-controlled SQL text literal must not be able to register a
 * tokenizer module and have this process call that module. The probe never
 * calls sqlite3_db_config() to turn the tokenizer on, and it never binds
 * the pointer: the pointer bytes are inside the SQL text, which is the
 * input an SQL injection supplies. sqlite3_value_frombind() is zero for
 * that kind of value.
 *
 * The process exits 0 when none of those statements call the module, and
 * exits 1 when any of them do. While the package defines the FTS3 tokenizer
 * compile flag, this probe is expected to exit 1.
 */
#include "sqlite3.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
  HIT_CREATE = 1,
  HIT_DESTROY = 2,
  HIT_OPEN = 4,
  HIT_CLOSE = 8,
  HIT_NEXT = 16
};

static int g_hits;
static int g_failures;

typedef struct PwTokenizer {
  const void *pModule;
} PwTokenizer;

typedef struct PwCursor {
  void *pTokenizer;
} PwCursor;

typedef struct PwModule {
  int iVersion;
  int (*xCreate)(int, const char *const *, PwTokenizer **);
  int (*xDestroy)(PwTokenizer *);
  int (*xOpen)(PwTokenizer *, const char *, int, PwCursor **);
  int (*xClose)(PwCursor *);
  int (*xNext)(PwCursor *, const char **, int *, int *, int *, int *);
} PwModule;

static int pw_create(int argc, const char *const *argv, PwTokenizer **pp) {
  (void)argc;
  (void)argv;
  g_hits |= HIT_CREATE;
  *pp = calloc(1, sizeof(**pp));
  return *pp ? SQLITE_OK : SQLITE_NOMEM;
}

static int pw_destroy(PwTokenizer *p) {
  g_hits |= HIT_DESTROY;
  free(p);
  return SQLITE_OK;
}

static int pw_open(PwTokenizer *p, const char *input, int n, PwCursor **pp) {
  (void)p;
  (void)input;
  (void)n;
  g_hits |= HIT_OPEN;
  *pp = calloc(1, sizeof(**pp));
  return *pp ? SQLITE_OK : SQLITE_NOMEM;
}

static int pw_close(PwCursor *p) {
  g_hits |= HIT_CLOSE;
  free(p);
  return SQLITE_OK;
}

static int pw_next(PwCursor *p, const char **token, int *n, int *start,
                   int *end, int *pos) {
  (void)p;
  (void)token;
  (void)n;
  (void)start;
  (void)end;
  (void)pos;
  g_hits |= HIT_NEXT;
  return SQLITE_DONE;
}

static PwModule g_module = {
    0, pw_create, pw_destroy, pw_open, pw_close, pw_next,
};

static void pointer_hex(char *out) {
  const void *ptr = &g_module;
  unsigned char bytes[sizeof(ptr)];
  size_t i;
  memcpy(bytes, &ptr, sizeof(bytes));
  for (i = 0; i < sizeof(bytes); i++) {
    sprintf(out + (i * 2), "%02X", bytes[i]);
  }
  out[sizeof(bytes) * 2] = '\0';
}

static void exec_sql(sqlite3 *db, const char *sql) {
  char *err = 0;
  int rc = sqlite3_exec(db, sql, 0, 0, &err);
  printf("  rc=%d hits=0x%x sql=%s err=%s\n", rc, g_hits, sql,
         err ? err : "");
  sqlite3_free(err);
}

static void expect_quiet(const char *name) {
  if (g_hits) {
    printf("FAIL %s: tokenizer module was called (hits=0x%x)\n", name, g_hits);
    g_failures++;
  } else {
    printf("ok %s\n", name);
  }
  g_hits = 0;
}

static sqlite3 *open_memory(void) {
  sqlite3 *db = 0;
  int rc = sqlite3_open(":memory:", &db);
  int enabled = -1;
  if (rc != SQLITE_OK) {
    fprintf(stderr, "sqlite3_open failed: %d\n", rc);
    exit(2);
  }
  /* Query only. A negative value does not change the connection flag. */
  sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER, -1, &enabled);
  printf("connection tokenizer flag=%d (app did not enable it)\n", enabled);
  return db;
}

static void register_literal(sqlite3 *db, const char *hex, const char *name) {
  char *sql = sqlite3_mprintf("SELECT fts3_tokenizer('%s', X'%s')", name, hex);
  g_hits = 0;
  exec_sql(db, sql);
  sqlite3_free(sql);
  /* Registration stores the pointer. It must not call the module yet. */
  expect_quiet("register literal does not call module");
}

static void direct_sql(const char *hex) {
  sqlite3 *db = open_memory();

  register_literal(db, hex, "pwattack");

  g_hits = 0;
  exec_sql(db, "CREATE VIRTUAL TABLE t_fts3 USING fts3(body, tokenize=pwattack)");
  expect_quiet("fts3 create");

  g_hits = 0;
  exec_sql(db, "INSERT INTO t_fts3(body) VALUES('owned')");
  expect_quiet("fts3 insert");

  g_hits = 0;
  exec_sql(db, "SELECT rowid FROM t_fts3 WHERE body MATCH '(owned)'");
  expect_quiet("fts3 parenthesized match");

  g_hits = 0;
  exec_sql(db, "CREATE VIRTUAL TABLE t_fts4 USING fts4(body, tokenize=pwattack)");
  expect_quiet("fts4 create");

  g_hits = 0;
  exec_sql(db, "INSERT INTO t_fts4(body) VALUES('owned')");
  expect_quiet("fts4 insert");

  g_hits = 0;
  exec_sql(db, "SELECT rowid FROM t_fts4 WHERE body MATCH '(owned OR other)'");
  expect_quiet("fts4 parenthesized match");

  g_hits = 0;
  exec_sql(db, "CREATE VIRTUAL TABLE t_tok USING fts3tokenize(pwattack)");
  expect_quiet("fts3tokenize create");

  g_hits = 0;
  exec_sql(db, "SELECT token FROM t_tok WHERE input = 'owned'");
  expect_quiet("fts3tokenize query");

  g_hits = 0;
  sqlite3_close(db);

  db = open_memory();
  register_literal(db, hex, "simple");
  g_hits = 0;
  exec_sql(db, "CREATE VIRTUAL TABLE t_default USING fts3(body)");
  expect_quiet("fts3 default tokenizer");

  g_hits = 0;
  exec_sql(db, "INSERT INTO t_default(body) VALUES('owned')");
  expect_quiet("fts3 default insert");

  g_hits = 0;
  exec_sql(db, "CREATE VIRTUAL TABLE t_default4 USING fts4(body)");
  expect_quiet("fts4 default tokenizer");
  g_hits = 0;
  sqlite3_close(db);
}

static void database_file(const char *hex) {
  sqlite3 *db = 0;
  g_hits = 0;
  char *trig;
  char *ins;
  char *err = 0;
  const char *path = "/tmp/pixiewood-fts3-tokenizer-attack.db";
  int rc;

  remove(path);
  rc = sqlite3_open(path, &db);
  if (rc != SQLITE_OK) {
    fprintf(stderr, "open craft db failed: %d\n", rc);
    exit(2);
  }
  exec_sql(db, "CREATE TABLE victim(x)");
  trig = sqlite3_mprintf(
      "CREATE TRIGGER evil AFTER INSERT ON victim BEGIN "
      "SELECT fts3_tokenizer('pwattack', X'%s'); END",
      hex);
  ins = sqlite3_mprintf(
      "PRAGMA writable_schema=ON;"
      "INSERT INTO sqlite_master(type,name,tbl_name,rootpage,sql) "
      "VALUES('trigger','evil','victim',0,%Q)",
      trig);
  exec_sql(db, ins);
  sqlite3_free(trig);
  sqlite3_free(ins);
  sqlite3_close(db);

  g_hits = 0;
  rc = sqlite3_open(path, &db);
  if (rc != SQLITE_OK) {
    fprintf(stderr, "reopen attack db failed: %d\n", rc);
    exit(2);
  }
  expect_quiet("open attacker database");

  g_hits = 0;
  exec_sql(db, "INSERT INTO victim VALUES(1)");
  expect_quiet("insert fires attacker trigger");

  g_hits = 0;
  exec_sql(db, "CREATE VIRTUAL TABLE t_fromtrig USING fts3(body, tokenize=pwattack)");
  expect_quiet("use tokenizer a trigger tried to register");
  sqlite3_close(db);
  remove(path);
  sqlite3_free(err);
}

int main(void) {
  char hex[sizeof(void *) * 2 + 1];
  setvbuf(stdout, 0, _IOLBF, 0);
  setvbuf(stderr, 0, _IOLBF, 0);
  pointer_hex(hex);
  printf("sqlite %s\n", sqlite3_libversion());
  direct_sql(hex);
  database_file(hex);
  if (g_failures) {
    fprintf(stderr, "%d attacker SQL path(s) called the native tokenizer\n",
            g_failures);
    return 1;
  }
  printf("attacker SQL did not call a native tokenizer\n");
  return 0;
}

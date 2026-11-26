#include <gio/gio.h>
#include <gio/giomodule.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

void g_io_openssl_load (GIOModule *module);

typedef struct {
  GTlsInteraction parent;
  GByteArray **expected;
  gsize n_expected;
  gboolean saw;
  gboolean matched;
  char *detail;
} CasInteraction;

typedef struct {
  GTlsInteractionClass parent_class;
} CasInteractionClass;

static GType cas_interaction_get_type (void);
G_DEFINE_TYPE (CasInteraction, cas_interaction, G_TYPE_TLS_INTERACTION)

static void
cas_interaction_init (CasInteraction *self)
{
}

static void
cas_interaction_class_init (CasInteractionClass *klass)
{
}

static int
der_equal (GByteArray *got, GByteArray *expect)
{
  guint i;
  unsigned char acc;

  if (got->len != expect->len)
    return 0;
  /* Read every advertised byte. The vulnerable getter points past the
   * allocation, so this is the out-of-bounds read. */
  acc = 0;
  for (i = 0; i < got->len; i++)
    acc |= got->data[i];
  (void) acc;
  return memcmp (got->data, expect->data, expect->len) == 0;
}

static GTlsInteractionResult
cas_request_certificate (GTlsInteraction *interaction,
                         GTlsConnection *connection,
                         GTlsCertificateRequestFlags flags,
                         GCancellable *cancellable,
                         GError **error)
{
  CasInteraction *self = (CasInteraction *) interaction;
  GList *cas;
  GList *l;
  gsize seen = 0;
  gboolean *used;

  (void) flags;
  (void) cancellable;
  (void) error;

  fprintf (stderr, "client certificate request: reading accepted-cas\n");
  cas = g_tls_client_connection_get_accepted_cas (G_TLS_CLIENT_CONNECTION (connection));
  self->saw = TRUE;
  used = g_new0 (gboolean, self->n_expected);

  for (l = cas; l != NULL; l = l->next)
    {
      GByteArray *got = l->data;
      gsize i;

      seen++;
      fprintf (stderr, "accepted-cas entry len=%u\n", got->len);
      for (i = 0; i < self->n_expected; i++)
        {
          if (!used[i] && der_equal (got, self->expected[i]))
            {
              used[i] = TRUE;
              break;
            }
        }
      /* Documented owner of each element frees it. The vulnerable getter
       * stored the pointer i2d_X509_NAME already advanced, so this frees
       * an interior pointer. */
      g_byte_array_unref (got);
    }
  g_list_free (cas);

  self->matched = seen == self->n_expected;
  for (seen = 0; seen < self->n_expected; seen++)
    {
      if (!used[seen])
        self->matched = FALSE;
    }
  g_free (used);
  if (!self->matched)
    self->detail = g_strdup ("accepted-cas bytes are not the certificate_authorities DER");
  return G_TLS_INTERACTION_UNHANDLED;
}

static gboolean
accept_certificate (GTlsConnection *conn,
                    GTlsCertificate *cert,
                    GTlsCertificateFlags errors,
                    gpointer data)
{
  (void) conn;
  (void) cert;
  (void) errors;
  (void) data;
  return TRUE;
}

typedef struct {
  int fd;
  const char *cert;
  const char *key;
  char **ca_paths;
  int n_ca;
  int tls12;
  int accept_rc;
} ServerArgs;

static void
load_expected (const char *path, GByteArray ***out, gsize *n)
{
  FILE *fp;
  X509 *cert;
  unsigned char *der = NULL;
  int len;
  GByteArray *bytes;

  fp = fopen (path, "r");
  if (!fp)
    {
      perror (path);
      exit (2);
    }
  cert = PEM_read_X509 (fp, NULL, NULL, NULL);
  fclose (fp);
  if (!cert)
    {
      fprintf (stderr, "could not read CA certificate %s\n", path);
      exit (2);
    }
  len = i2d_X509_NAME (X509_get_subject_name (cert), NULL);
  if (len <= 0)
    exit (2);
  der = g_malloc (len);
  {
    unsigned char *p = der;
    if (i2d_X509_NAME (X509_get_subject_name (cert), &p) != len)
      exit (2);
  }
  bytes = g_byte_array_new_take (der, len);
  *out = g_renew (GByteArray *, *out, *n + 1);
  (*out)[*n] = bytes;
  (*n)++;
  X509_free (cert);
}

static void *
server_thread (void *arg)
{
  ServerArgs *args = arg;
  SSL_CTX *ctx;
  SSL *ssl;
  STACK_OF (X509_NAME) *names;
  int i;

  ctx = SSL_CTX_new (TLS_server_method ());
  if (!ctx)
    return NULL;
  SSL_CTX_set_min_proto_version (ctx, TLS1_2_VERSION);
  if (args->tls12)
    SSL_CTX_set_max_proto_version (ctx, TLS1_2_VERSION);
  if (SSL_CTX_use_certificate_file (ctx, args->cert, SSL_FILETYPE_PEM) != 1 ||
      SSL_CTX_use_PrivateKey_file (ctx, args->key, SSL_FILETYPE_PEM) != 1)
    {
      fprintf (stderr, "server certificate load failed\n");
      return NULL;
    }
  names = sk_X509_NAME_new_null ();
  for (i = 0; i < args->n_ca; i++)
    {
      FILE *fp = fopen (args->ca_paths[i], "r");
      X509 *ca = fp ? PEM_read_X509 (fp, NULL, NULL, NULL) : NULL;
      if (fp)
        fclose (fp);
      if (!ca)
        {
          fprintf (stderr, "server could not read %s\n", args->ca_paths[i]);
          return NULL;
        }
      sk_X509_NAME_push (names, X509_NAME_dup (X509_get_subject_name (ca)));
      X509_free (ca);
    }
  SSL_CTX_set_client_CA_list (ctx, names);
  SSL_CTX_set_verify (ctx, SSL_VERIFY_PEER, NULL);

  ssl = SSL_new (ctx);
  SSL_set_fd (ssl, args->fd);
  args->accept_rc = SSL_accept (ssl);
  fprintf (stderr, "server SSL_accept -> %d\n", args->accept_rc);
  SSL_free (ssl);
  SSL_CTX_free (ctx);
  close (args->fd);
  return NULL;
}

static void
handshake_done (GObject *source, GAsyncResult *result, gpointer data)
{
  GError *error = NULL;
  GMainLoop *loop = data;

  if (!g_tls_connection_handshake_finish (G_TLS_CONNECTION (source), result, &error))
    fprintf (stderr, "handshake finished with error: %s\n", error->message);
  else
    fprintf (stderr, "handshake finished cleanly\n");
  g_clear_error (&error);
  g_main_loop_quit (loop);
}

int
main (int argc, char **argv)
{
  int fds[2];
  int i;
  int tls12;
  GError *error = NULL;
  GSocket *sock;
  GSocketConnection *base;
  GSocketConnectable *identity;
  GTlsClientConnection *client;
  GMainLoop *loop;
  pthread_t thread;
  ServerArgs args;
  CasInteraction *interaction;
  GByteArray **expected = NULL;
  gsize n_expected = 0;
  char *empty_dir;

  if (argc < 5)
    {
      fprintf (stderr, "usage: %s tls12|tls13 server.pem server.key ca.pem...\n", argv[0]);
      return 2;
    }
  tls12 = strcmp (argv[1], "tls12") == 0;
  if (!tls12 && strcmp (argv[1], "tls13") != 0)
    return 2;

  for (i = 4; i < argc; i++)
    load_expected (argv[i], &expected, &n_expected);

  empty_dir = g_dir_make_tmp ("gio-modules-XXXXXX", &error);
  if (!empty_dir)
    {
      fprintf (stderr, "%s\n", error->message);
      return 2;
    }
  g_setenv ("GIO_MODULE_DIR", empty_dir, TRUE);
  g_setenv ("GIO_USE_TLS", "openssl", TRUE);
  /* Static apps link libgioopenssl.a and call this with a NULL module.
   * Since GLib 2.56 that registers the backend types without dlopen. */
  g_io_openssl_load (NULL);

  if (socketpair (AF_UNIX, SOCK_STREAM, 0, fds) != 0)
    {
      perror ("socketpair");
      return 2;
    }

  args.fd = fds[0];
  args.cert = argv[2];
  args.key = argv[3];
  args.ca_paths = &argv[4];
  args.n_ca = argc - 4;
  args.tls12 = tls12;
  args.accept_rc = -1;
  if (pthread_create (&thread, NULL, server_thread, &args) != 0)
    return 2;

  sock = g_socket_new_from_fd (fds[1], &error);
  if (!sock)
    {
      fprintf (stderr, "socket: %s\n", error->message);
      return 2;
    }
  base = g_socket_connection_factory_create_connection (sock);
  identity = g_network_address_new ("localhost", 443);
  client = G_TLS_CLIENT_CONNECTION (g_tls_client_connection_new (G_IO_STREAM (base), identity, &error));
  if (!client)
    {
      fprintf (stderr, "client: %s\n", error->message);
      return 2;
    }
  g_tls_client_connection_set_validation_flags (client, 0);
  g_signal_connect (client, "accept-certificate", G_CALLBACK (accept_certificate), NULL);

  interaction = g_object_new (cas_interaction_get_type (), NULL);
  interaction->expected = expected;
  interaction->n_expected = n_expected;
  G_TLS_INTERACTION_GET_CLASS (interaction)->request_certificate = cas_request_certificate;
  g_tls_connection_set_interaction (G_TLS_CONNECTION (client), G_TLS_INTERACTION (interaction));

  loop = g_main_loop_new (NULL, FALSE);
  g_tls_connection_handshake_async (G_TLS_CONNECTION (client),
                                    G_PRIORITY_DEFAULT,
                                    NULL,
                                    handshake_done,
                                    loop);
  alarm (20);
  g_main_loop_run (loop);
  pthread_join (thread, NULL);

  if (!interaction->saw)
    {
      fprintf (stderr, "server certificate_authorities list never reached accepted-cas\n");
      return 1;
    }
  if (!interaction->matched)
    {
      fprintf (stderr, "%s\n", interaction->detail ? interaction->detail : "accepted-cas mismatch");
      return 1;
    }
  fprintf (stderr, "accepted-cas matched the server certificate_authorities DER\n");
  return 0;
}

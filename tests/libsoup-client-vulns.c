/* Behavioral checks for the libsoup client this repository builds.
 *
 * A remote peer supplies the response body and the redirect. The client
 * reads that body and, for a multipart response, parses it with
 * soup_multipart_new_from_message(). A cross-origin redirect must not
 * carry Proxy-Authorization to the next host.
 *
 * These checks exit 0 when that handling is safe. AddressSanitizer
 * aborts the process on the out-of-bounds reads in libsoup 3.6.5.
 */
#include <libsoup/soup.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	const char *content_type;
	const char *body;
	gsize body_len;
	char *redirect_to;
	gboolean saw_request;
	gboolean saw_authorization;
	gboolean saw_proxy_authorization;
} Route;

static void
on_request (SoupServer *server,
	    SoupServerMessage *msg,
	    const char *path,
	    GHashTable *query,
	    gpointer user_data)
{
	Route *route = user_data;
	SoupMessageHeaders *request_headers;

	(void) server;
	(void) query;
	route->saw_request = TRUE;
	request_headers = soup_server_message_get_request_headers (msg);
	if (soup_message_headers_get_one (request_headers, "Authorization") != NULL)
		route->saw_authorization = TRUE;
	if (soup_message_headers_get_one (request_headers, "Proxy-Authorization") != NULL)
		route->saw_proxy_authorization = TRUE;

	if (route->redirect_to != NULL) {
		soup_server_message_set_redirect (msg, SOUP_STATUS_FOUND, route->redirect_to);
		return;
	}

	soup_server_message_set_response (msg,
					  route->content_type,
					  SOUP_MEMORY_COPY,
					  route->body,
					  route->body_len);
	soup_server_message_set_status (msg, SOUP_STATUS_OK, NULL);
	(void) path;
}

typedef struct {
	Route *route;
	guint16 port;
	GThread *thread;
	GMainLoop *loop;
	GMutex mutex;
	GCond cond;
	gboolean ready;
} ServerRun;

static gpointer
server_thread (gpointer user_data)
{
	ServerRun *run = user_data;
	GMainContext *context;
	SoupServer *server;
	GSocketAddress *address;
	GError *error = NULL;
	GSList *uris;
	GUri *uri;
	guint16 port;

	context = g_main_context_new ();
	g_main_context_push_thread_default (context);
	run->loop = g_main_loop_new (context, FALSE);

	server = soup_server_new ("server-header", "client-vulns", NULL);
	soup_server_add_handler (server, NULL, on_request, run->route, NULL);
	address = g_inet_socket_address_new_from_string ("127.0.0.1", 0);
	if (!soup_server_listen (server, address, 0, &error)) {
		g_printerr ("listen failed: %s\n", error != NULL ? error->message : "unknown");
		exit (1);
	}
	g_object_unref (address);
	uris = soup_server_get_uris (server);
	uri = uris->data;
	port = (guint16) g_uri_get_port (uri);
	g_slist_free_full (uris, (GDestroyNotify) g_uri_unref);

	g_mutex_lock (&run->mutex);
	run->port = port;
	run->ready = TRUE;
	g_cond_signal (&run->cond);
	g_mutex_unlock (&run->mutex);

	g_main_loop_run (run->loop);
	g_object_unref (server);
	g_main_loop_unref (run->loop);
	g_main_context_pop_thread_default (context);
	g_main_context_unref (context);
	return NULL;
}

static ServerRun *
serve (Route *route)
{
	ServerRun *run = g_new0 (ServerRun, 1);

	run->route = route;
	g_mutex_init (&run->mutex);
	g_cond_init (&run->cond);
	run->thread = g_thread_new ("soup-peer", server_thread, run);
	g_mutex_lock (&run->mutex);
	while (!run->ready)
		g_cond_wait (&run->cond, &run->mutex);
	g_mutex_unlock (&run->mutex);
	return run;
}

static void
serve_stop (ServerRun *run)
{
	g_main_loop_quit (run->loop);
	g_thread_join (run->thread);
	g_cond_clear (&run->cond);
	g_mutex_clear (&run->mutex);
	g_free (run);
}

static GBytes *
exact_body (GInputStream *stream)
{
	GByteArray *raw;
	guint8 scratch[512];
	gssize n;
	void *copy;

	raw = g_byte_array_new ();
	while ((n = g_input_stream_read (stream, scratch, sizeof (scratch), NULL, NULL)) > 0)
		g_byte_array_append (raw, scratch, (guint) n);
	copy = g_malloc (raw->len);
	memcpy (copy, raw->data, raw->len);
	n = (gssize) raw->len;
	g_byte_array_unref (raw);
	return g_bytes_new_take (copy, (gsize) n);
}

static int
parse_served_multipart (const char *content_type, const char *body, gsize body_len)
{
	Route route = {
		.content_type = content_type,
		.body = body,
		.body_len = body_len,
	};
	ServerRun *server;
	SoupSession *session;
	SoupMessage *msg;
	char *uri;
	GInputStream *stream;
	GBytes *response;
	SoupMessageHeaders *headers;
	SoupMultipart *multipart;
	GError *error = NULL;

	server = serve (&route);
	session = soup_session_new ();
	uri = g_strdup_printf ("http://127.0.0.1:%u/part", server->port);
	msg = soup_message_new (SOUP_METHOD_GET, uri);
	stream = soup_session_send (session, msg, NULL, &error);
	if (stream == NULL) {
		g_printerr ("multipart fetch failed: %s\n", error->message);
		return 1;
	}
	response = exact_body (stream);
	g_object_unref (stream);

	headers = soup_message_headers_new (SOUP_MESSAGE_HEADERS_RESPONSE);
	soup_message_headers_append (headers, "Content-Type", content_type);
	multipart = soup_multipart_new_from_message (headers, response);
	if (multipart != NULL)
		soup_multipart_free (multipart);
	soup_message_headers_unref (headers);
	g_bytes_unref (response);
	g_object_unref (msg);
	g_object_unref (session);
	serve_stop (server);
	g_free (uri);
	return 0;
}

/* find_boundary() in 3.6.5 reads two bytes before a '-' that sits one
 * byte into the body. */
static int
multipart_underflow (void)
{
	static const char body[] = "\n--b\r\nYYYYYYYY";

	return parse_served_multipart ("multipart/form-data; boundary=b",
				       body, sizeof (body) - 1);
}

/* 3.6.5 searches for the header break with strstr(), which does not
 * stop at the end of the response body. */
static int
multipart_strstr (void)
{
	static const char body[] = "--b\r\nX\r\n--b--\r\n";

	return parse_served_multipart ("multipart/form-data; boundary=b",
				       body, sizeof (body) - 1);
}

/* Cross-origin redirect (different port). Authorization is removed.
 * Proxy-Authorization must be removed as well, or the next host
 * receives it. */
static int
proxy_redirect (void)
{
	Route target = {
		.content_type = "text/plain",
		.body = "ok",
		.body_len = 2,
	};
	Route redirector = { 0 };
	ServerRun *target_server;
	ServerRun *redirect_server;
	SoupSession *session;
	SoupMessage *msg;
	char *start_uri;
	GInputStream *stream;
	GError *error = NULL;
	char sink[32];

	target_server = serve (&target);
	redirector.redirect_to = g_strdup_printf ("http://127.0.0.1:%u/land", target_server->port);
	redirect_server = serve (&redirector);

	session = soup_session_new ();
	start_uri = g_strdup_printf ("http://127.0.0.1:%u/start", redirect_server->port);
	msg = soup_message_new (SOUP_METHOD_GET, start_uri);
	soup_message_headers_append (soup_message_get_request_headers (msg),
				     "Authorization", "placeholder");
	soup_message_headers_append (soup_message_get_request_headers (msg),
				     "Proxy-Authorization", "placeholder");
	stream = soup_session_send (session, msg, NULL, &error);
	if (stream == NULL) {
		g_printerr ("redirect fetch failed: %s\n", error->message);
		return 1;
	}
	while (g_input_stream_read (stream, sink, sizeof (sink), NULL, NULL) > 0)
		;
	g_object_unref (stream);
	g_object_unref (msg);
	g_object_unref (session);

	if (!redirector.saw_request || !target.saw_request) {
		g_printerr ("redirect was not followed\n");
		return 1;
	}
	if (target.saw_authorization) {
		g_printerr ("Authorization reached the redirect target\n");
		return 1;
	}
	if (target.saw_proxy_authorization) {
		g_printerr ("Proxy-Authorization reached the redirect target\n");
		return 1;
	}

	g_free (redirector.redirect_to);
	g_free (start_uri);
	serve_stop (redirect_server);
	serve_stop (target_server);
	return 0;
}

int
main (int argc, char **argv)
{
	if (argc != 2)
		return 2;
	if (strcmp (argv[1], "multipart-underflow") == 0)
		return multipart_underflow ();
	if (strcmp (argv[1], "multipart-strstr") == 0)
		return multipart_strstr ();
	if (strcmp (argv[1], "proxy-redirect") == 0)
		return proxy_redirect ();
	return 2;
}

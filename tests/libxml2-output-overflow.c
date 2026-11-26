/*
 * Regression tests for libxml2 output buffers whose used size does not fit
 * in the signed int length of xmlOutputWriteCallback.
 *
 * A fixed library rejects that buffer before calling the write callback, so
 * fwrite/write never see a wrapped length and the output file stays empty.
 * libxml2 2.15.3 calls the callback. xmlFileWrite then passes the negative
 * int to fwrite, which takes a size_t.
 *
 * Build against the libxml2 named by packages/libxml2/libxml2.wrap.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/xmlIO.h>
#include <libxml/xmlsave.h>

size_t __real_fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);
ssize_t __real_write(int fd, const void *buf, size_t count);
void *__real_malloc(size_t size);
void *__real_realloc(void *ptr, size_t size);

static size_t overflow_io_calls;
static size_t max_alloc;
static int failures;
static int inconclusive;

size_t
__wrap_fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream)
{
    if (size != 0 && nmemb > (size_t) INT_MAX / size) {
        overflow_io_calls++;
        errno = EFBIG;
        return 0;
    }
    return __real_fwrite(ptr, size, nmemb, stream);
}

ssize_t
__wrap_write(int fd, const void *buf, size_t count)
{
    if (count > (size_t) INT_MAX) {
        overflow_io_calls++;
        errno = EFBIG;
        return -1;
    }
    return __real_write(fd, buf, count);
}

void *
__wrap_malloc(size_t size)
{
    void *ptr = __real_malloc(size);

    if (ptr != NULL && size > max_alloc)
        max_alloc = size;
    return ptr;
}

void *
__wrap_realloc(void *ptr, size_t size)
{
    void *next = __real_realloc(ptr, size);

    if (next != NULL && size > max_alloc)
        max_alloc = size;
    return next;
}

static char *text_map;
static size_t text_span;

static int
map_text(void)
{
    size_t chunk = 1u << 20;
    size_t span = (size_t) INT_MAX + 1u;
    size_t chunks = span / chunk;
    size_t i;
    int fd_fill = -1;
    int fd_tail = -1;
    char *page = MAP_FAILED;
    char *base = MAP_FAILED;

    if (span % chunk != 0)
        return -1;

    fd_fill = memfd_create("xml-fill", 0);
    fd_tail = memfd_create("xml-tail", 0);
    if (fd_fill < 0 || fd_tail < 0)
        goto fail;
    if (ftruncate(fd_fill, (off_t) chunk) != 0 ||
        ftruncate(fd_tail, (off_t) chunk) != 0)
        goto fail;

    page = mmap(NULL, chunk, PROT_READ | PROT_WRITE, MAP_SHARED, fd_fill, 0);
    if (page == MAP_FAILED)
        goto fail;
    memset(page, 'A', chunk);
    munmap(page, chunk);

    page = mmap(NULL, chunk, PROT_READ | PROT_WRITE, MAP_SHARED, fd_tail, 0);
    if (page == MAP_FAILED)
        goto fail;
    memset(page, 'A', chunk);
    page[chunk - 1] = '\0';
    munmap(page, chunk);
    page = MAP_FAILED;

    base = mmap(NULL, span, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED)
        goto fail;
    for (i = 0; i < chunks - 1; i++) {
        if (mmap(base + i * chunk, chunk, PROT_READ,
                 MAP_FIXED | MAP_PRIVATE, fd_fill, 0) == MAP_FAILED)
            goto fail;
    }
    if (mmap(base + (chunks - 1) * chunk, chunk, PROT_READ,
             MAP_FIXED | MAP_PRIVATE, fd_tail, 0) == MAP_FAILED)
        goto fail;

    close(fd_fill);
    close(fd_tail);
    text_map = base;
    text_span = span;
    return 0;

fail:
    if (page != MAP_FAILED)
        munmap(page, chunk);
    if (base != MAP_FAILED)
        munmap(base, span);
    if (fd_fill >= 0)
        close(fd_fill);
    if (fd_tail >= 0)
        close(fd_tail);
    return -1;
}

static long
file_size(FILE *file)
{
    long pos;

    if (fflush(file) != 0)
        return -1;
    pos = ftell(file);
    return pos;
}

static void
reset_case(void)
{
    overflow_io_calls = 0;
    max_alloc = 0;
}

/*
 * Reaching the overflow check requires a buffer of at least INT_MAX bytes.
 * An error without that allocation is an out-of-memory failure, not a fix.
 */
static void
expect_rejected(const char *name, int rc, long nbytes)
{
    printf("%s: rc=%d overflow_io=%zu max_alloc=%zu file_bytes=%ld\n",
           name, rc, overflow_io_calls, max_alloc, nbytes);

    if (overflow_io_calls != 0) {
        fprintf(stderr, "%s: write callback received a length above INT_MAX\n",
                name);
        failures++;
        return;
    }
    if (max_alloc < (size_t) INT_MAX) {
        fprintf(stderr, "%s: buffer never reached INT_MAX (allocation failed)\n",
                name);
        inconclusive++;
        return;
    }
    if (rc >= 0) {
        fprintf(stderr, "%s: oversized output was accepted\n", name);
        failures++;
        return;
    }
    if (nbytes != 0) {
        fprintf(stderr, "%s: wrote %ld bytes before refusing\n", name, nbytes);
        failures++;
        return;
    }
    printf("%s: refused before an oversized write\n", name);
}

static void
expect_no_overflow_io(const char *name, int rc, long nbytes)
{
    printf("%s: rc=%d overflow_io=%zu max_alloc=%zu file_bytes=%ld\n",
           name, rc, overflow_io_calls, max_alloc, nbytes);
    if (overflow_io_calls != 0) {
        fprintf(stderr, "%s: file write size does not fit in a signed int\n",
                name);
        failures++;
        return;
    }
    if (max_alloc < (size_t) INT_MAX) {
        fprintf(stderr, "%s: buffer never reached INT_MAX (allocation failed)\n",
                name);
        inconclusive++;
        return;
    }
    if (nbytes < 0) {
        fprintf(stderr, "%s: could not read the output size\n", name);
        failures++;
        return;
    }
    if (nbytes > INT_MAX) {
        fprintf(stderr, "%s: output file grew past INT_MAX\n", name);
        failures++;
        return;
    }
    printf("%s: no oversized file write\n", name);
}

static xmlDocPtr
document_with_text(void)
{
    xmlDocPtr doc;
    xmlNodePtr root;
    xmlNodePtr text;

    doc = xmlNewDoc(BAD_CAST "1.0");
    if (doc == NULL)
        return NULL;
    root = xmlNewDocNode(doc, NULL, BAD_CAST "r", NULL);
    if (root == NULL) {
        xmlFreeDoc(doc);
        return NULL;
    }
    xmlDocSetRootElement(doc, root);

    text = xmlNewText(NULL);
    if (text == NULL) {
        xmlFreeDoc(doc);
        return NULL;
    }
    text->doc = doc;
    text->content = (xmlChar *) text_map;
    if (xmlAddChild(root, text) == NULL) {
        text->content = NULL;
        xmlFreeNode(text);
        xmlFreeDoc(doc);
        return NULL;
    }
    return doc;
}

static void
release_document(xmlDocPtr doc)
{
    xmlNodePtr root = xmlDocGetRootElement(doc);
    xmlNodePtr child = root == NULL ? NULL : root->children;

    while (child != NULL) {
        if (child->content == (xmlChar *) text_map)
            child->content = NULL;
        child = child->next;
    }
    xmlFreeDoc(doc);
}

static void
test_doc_dump(void)
{
    char path[] = "/tmp/libxml2-doc-dump-XXXXXX";
    int fd;
    FILE *file;
    xmlDocPtr doc;
    int rc;
    long nbytes;

    reset_case();
    fd = mkstemp(path);
    if (fd < 0) {
        failures++;
        return;
    }
    file = fdopen(fd, "wb+");
    doc = document_with_text();
    if (file == NULL || doc == NULL) {
        fprintf(stderr, "xmlDocDump: setup failed\n");
        failures++;
        if (doc != NULL)
            release_document(doc);
        if (file != NULL)
            fclose(file);
        unlink(path);
        return;
    }

    rc = xmlDocDump(file, doc);
    nbytes = file_size(file);
    release_document(doc);
    fclose(file);
    unlink(path);
    expect_rejected("xmlDocDump", rc, nbytes);
}

static void
test_save_file(void)
{
    char path[] = "/tmp/libxml2-save-file-XXXXXX";
    int fd;
    xmlDocPtr doc;
    int rc;
    struct stat st;
    long nbytes = -1;

    reset_case();
    fd = mkstemp(path);
    if (fd < 0) {
        failures++;
        return;
    }
    close(fd);
    doc = document_with_text();
    if (doc == NULL) {
        fprintf(stderr, "xmlSaveFile: setup failed\n");
        failures++;
        unlink(path);
        return;
    }

    rc = xmlSaveFile(path, doc);
    if (stat(path, &st) == 0)
        nbytes = (long) st.st_size;
    release_document(doc);
    unlink(path);
    /*
     * Filename saves use xmlFdWrite. That writer returns before write()
     * when the truncated length is negative, so this case must not perform
     * an oversized write on either side of the fix. 2.15.4 also rejects
     * before the callback; both outcomes keep the file from growing by an
     * out-of-range read.
     */
    expect_no_overflow_io("xmlSaveFile", rc, nbytes);
}

static void
test_output_buffer_write(void)
{
    char path[] = "/tmp/libxml2-buffer-write-XXXXXX";
    int fd;
    FILE *file;
    xmlOutputBufferPtr out;
    int rc;
    long nbytes;

    reset_case();
    fd = mkstemp(path);
    if (fd < 0) {
        failures++;
        return;
    }
    file = fdopen(fd, "wb+");
    if (file == NULL) {
        failures++;
        unlink(path);
        return;
    }
    out = xmlOutputBufferCreateFile(file, NULL);
    if (out == NULL) {
        fprintf(stderr, "xmlOutputBufferWrite: setup failed\n");
        failures++;
        fclose(file);
        unlink(path);
        return;
    }

    /* Stay under the 4000-byte flush threshold, then add one INT_MAX write. */
    if (xmlOutputBufferWrite(out, 16, "0123456789abcdef") < 0) {
        fprintf(stderr, "xmlOutputBufferWrite: pending write failed\n");
        failures++;
        xmlOutputBufferClose(out);
        fclose(file);
        unlink(path);
        return;
    }
    rc = xmlOutputBufferWrite(out, INT_MAX, text_map);
    nbytes = file_size(file);
    xmlOutputBufferClose(out);
    fclose(file);
    unlink(path);
    expect_rejected("xmlOutputBufferWrite", rc, nbytes);
}

static void
test_output_buffer_flush(void)
{
    char path[] = "/tmp/libxml2-buffer-flush-XXXXXX";
    int fd;
    FILE *file;
    xmlOutputBufferPtr out;
    xmlOutputWriteCallback writer;
    int rc;
    long nbytes;

    reset_case();
    fd = mkstemp(path);
    if (fd < 0) {
        failures++;
        return;
    }
    file = fdopen(fd, "wb+");
    if (file == NULL) {
        failures++;
        unlink(path);
        return;
    }
    out = xmlOutputBufferCreateFile(file, NULL);
    if (out == NULL) {
        fprintf(stderr, "xmlOutputBufferFlush: setup failed\n");
        failures++;
        fclose(file);
        unlink(path);
        return;
    }

    /*
     * xmlOutputBufferWrite drains through the callback once the buffer
     * reaches 4000 bytes. Hold the callback, accumulate past INT_MAX, then
     * flush. The callback pointer is a public field of xmlOutputBuffer.
     */
    writer = out->writecallback;
    out->writecallback = NULL;
    if (xmlOutputBufferWrite(out, 16, "0123456789abcdef") < 0 ||
        xmlOutputBufferWrite(out, INT_MAX, text_map) < 0) {
        fprintf(stderr, "xmlOutputBufferFlush: setup write failed\n");
        failures++;
        out->writecallback = writer;
        xmlOutputBufferClose(out);
        fclose(file);
        unlink(path);
        return;
    }
    out->writecallback = writer;
    rc = xmlOutputBufferFlush(out);
    nbytes = file_size(file);
    xmlOutputBufferClose(out);
    fclose(file);
    unlink(path);
    expect_rejected("xmlOutputBufferFlush", rc, nbytes);
}

int
main(void)
{
    xmlInitParser();
    if (map_text() != 0) {
        fprintf(stderr, "could not map the input text\n");
        return 2;
    }

    test_output_buffer_write();
    test_output_buffer_flush();
    test_doc_dump();
    test_save_file();

    xmlCleanupParser();
    munmap(text_map, text_span);

    if (failures != 0)
        return 1;
    if (inconclusive != 0)
        return 2;
    return 0;
}

#include <gtk/gtk.h>

int
main (int argc, char **argv)
{
  (void) argc;
  (void) argv;
  return gtk_get_major_version () == 0;
}

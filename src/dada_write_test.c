#include "dada.h"
#include "ipcio.h"
#include "multilog.h"
#include "ascii_header.h"

#include <unistd.h>
#include <stdlib.h>
#include <string.h>

void usage()
{
  fprintf (stdout,
	   "dada_write_test [options]\n"
	   " -h filename    ascii header information in file\n"
	   " -g gigabytes   number of gigabytes to write\n");
}

static char* default_header =
"OBS_ID      dada_write_test.0001\n"
"OBS_OFFSET  100\n"
"FILE_SIZE   1073741824\n"
"FILE_NUMBER 3\n";

int main (int argc, char **argv)
{
  /* DADA configuration */
  dada_t dada;

  /* DADA Data Block */
  ipcio_t data_block = IPCIO_INIT;

  /* DADA Header Block */
  ipcbuf_t header_block = IPCBUF_INIT;

  /* DADA Logger */
  multilog_t* log;

  /* number of bytes to write */
  uint64_t bytes_to_write = (uint64_t)(1024 * 1024) * (uint64_t)(534 * 5);

  /* the header to be written to the header block */
  char* header = default_header;

  /* the header sub-block */
  char* header_buf = 0;

  /* the size of the header string */
  unsigned header_strlen = 0;

  /* the size of the header buffer */
  uint64_t header_size = 0;

  /* the size of the data buffer */
  uint64_t data_size = 1024 * 1024;

  /* the data to copy */
  char* data = 0;

  /* Flag set in verbose mode */
  char verbose = 0;

  int arg = 0;
  while ((arg=getopt(argc,argv,"v")) != -1) {
    switch (arg) {

      case 'v':
        verbose=1;
        break;

      default:
	usage ();
	return 0;

    }
  }

  dada_init (&dada);

  log = multilog_open ("dada_write_test", 0);
  multilog_add (log, stderr);

  /* First connect to the shared memory */
  if (ipcbuf_connect (&header_block, dada.hdr_key) < 0) {
    multilog (log, LOG_ERR, "Failed to connect to header block\n");
    return EXIT_FAILURE;
  }

  if (ipcbuf_lock_write (&header_block) < 0) {
    multilog (log, LOG_ERR,"Could not lock designated writer status\n");
    return EXIT_FAILURE;
  }

  if (ipcio_connect (&data_block, dada.data_key) < 0) {
    multilog (log, LOG_ERR, "Failed to connect to data block\n");
    return EXIT_FAILURE;
  }

  if (ipcio_open (&data_block, 'W') < 0) {
    multilog (log, LOG_ERR,"Could not lock designated writer status\n");
    return EXIT_FAILURE;
  }

  data = (char*) malloc (data_size);

  header_strlen = strlen(header);

  header_size = ipcbuf_get_bufsz (&header_block);
  multilog (log, LOG_INFO, "header block size = %llu\n", header_size);

  header_buf = ipcbuf_get_next_write (&header_block);

  if (!header_buf)  {
    multilog (log, LOG_ERR, "Could not get next header block\n");
    return EXIT_FAILURE;
  }

  memcpy (header_buf, header, header_strlen);
  memset (header_buf + header_strlen, '\0', header_size - header_strlen);

  /* Set the header size attribute */ 
  if (ascii_header_set (header_buf, "HDR_SIZE", "%llu", header_size) < 0) {
    multilog (log, LOG_ERR, "Could not write HDR_SIZE to header\n");
    return -1;
  }

  if (ipcbuf_mark_filled (&header_block, header_size) < 0)  {
    multilog (log, LOG_ERR, "Could not mark filled header block\n");
    return EXIT_FAILURE;
  }

  while (bytes_to_write)  {
    //fprintf (stderr, "Writing %llu bytes to data block\n", data_size);
    if (ipcio_write (&data_block, data, data_size) < 0)  {
      multilog (log, LOG_ERR, "Could not write %llu bytes to data block\n",
                data_size);
      return EXIT_FAILURE;
    } 
    bytes_to_write -= data_size;
  }


  /* Disconnect from the shared memory */
  if (ipcio_close (&data_block) < 0) {
    multilog (log, LOG_ERR,"Could not unlock designated writer data\n");
    return EXIT_FAILURE;
  }

  if (ipcio_disconnect (&data_block) < 0) {
    multilog (log, LOG_ERR, "Failed to disconnect from data block\n");
    return EXIT_FAILURE;
  }

  if (ipcbuf_unlock_write (&header_block) < 0) {
    multilog (log, LOG_ERR,"Could not unlock designated writer header\n");
    return EXIT_FAILURE;
  }

  if (ipcbuf_disconnect (&header_block) < 0) {
    multilog (log, LOG_ERR, "Failed to disconnect from header block\n");
    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}

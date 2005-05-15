
#include "puma2_dmadb.h"

static char* default_header =
"OBS_ID      Test.0001\n"
"OBS_OFFSET  0\n"
"FILE_SIZE   1073741824\n"
"FILE_NUMBER 0\n";

void usage()
{
    fprintf (stdout,
	   "puma2_dmadb [options]\n"
	     " -d             run as daemon\n"
             " -H filename    ascii header information in file\n"
	     " -i idstr       observation id string\n"	
	     " -n nbuf        # of buffers to acquire\n"
	     " -s sec         # of seconds to acquire\n"
	     " -v             verbose messages\n"
	     " -S             file size in bytes\n"
	     " -W             flag buffers readable\n"
	     );
    
}

int main (int argc, char **argv)
{
    /* DADA Header plus Data Unit */
    dada_hdu_t* hdu;
    multilog_t* log; /* Logger */

    char* header = default_header; /* header */
    char* header_buf = 0;
    unsigned header_strlen = 0;/* the size of the header string */
    uint64_t header_size = 0;/* size of the header buffer */
    char writemode='w';

    /* flags */
    char daemon = 0; /*daemon mode */
    char verbose = 0;/* verbose mode */

    /* pic stuff */
    pic_t pic;

    /* EDT stuff */
    EdtDev* edt_p;
    char *data;

    struct timeval t;
    int nSecs = 100,nbufs=0, buf=0;
    int wrCount,rdCount;
    char *ObsId = "Test";
    unsigned long fSize=1073741824;

    /* the filename from which the header will be read */
    char* header_file = 0;

    int arg = 0;
    while ((arg=getopt(argc,argv,"dH:i:n:s:vS:W")) != -1) {
	switch (arg) {
	    
	    case 'd':
		daemon=1;
		break;

	    case 'v':
		verbose=1;
		break;

            case 'H':
                header_file = optarg;
                break;

	    case 'i':
		if (verbose) fprintf(stderr,"ObsId is %s \n",optarg);
		if(optarg) {
		    ObsId = strdup (optarg);
                    assert (ObsId != 0);
		}
		else usage();
		break;

	    case 'n':
		if (optarg){
		    nbufs = atoi(optarg);
		    fprintf(stderr,"Acquiring %d buffers\n",nbufs);
		}
		else usage();
		break;
	    
	    case 's':
		if (optarg){
		    nSecs = atoi(optarg);
		    fprintf(stderr,"Will acquire for %d seconds\n",nSecs);
		}
		else usage();
		break;

	   case 'S':
		if (optarg){
		    fSize = (unsigned long)atol(optarg);
		    fprintf(stderr,"File size will be %lu\n",fSize);
		}
		else usage();
		break; 

	    case 'W':
		writemode='W';
		break;
		
	    default:
		usage ();
		return 0;
		
	}
    }
    
    log = multilog_open ("puma2_dmadb", daemon);
    
    /* set up for daemon usage */	  
    if (daemon) {
      be_a_daemon ();
      multilog_serve (log, DADA_DEFAULT_PWC_LOG);
    }
    else
      multilog_add (log, stderr);


    /* connect to the shared memory */

    hdu = dada_hdu_create (log);

    if (dada_hdu_connect (hdu) < 0)
      return EXIT_FAILURE;

    if (dada_hdu_lock_write (hdu) < 0)
      return EXIT_FAILURE;

    header_size = ipcbuf_get_bufsz (hdu->header_block);
    multilog (log, LOG_INFO, "header block size = %llu\n", header_size);
    
    header_buf = ipcbuf_get_next_write (hdu->header_block);
    
    if (!header_buf)  {
	multilog (log, LOG_ERR, "Could not get next header block\n");
	return EXIT_FAILURE;
    }

    if (header_file)  {
      if (fileread (header_file, header_buf, header_size) < 0)  {
        multilog (log, LOG_ERR, "Could not read header from %s\n", header_file);
        return EXIT_FAILURE;
      }
    }
    else {
      header_strlen = strlen(header);
      memcpy (header_buf, header, header_strlen);
      memset (header_buf + header_strlen, '\0', header_size - header_strlen);
    }

    /* Set the header attributes */ 
    if (ascii_header_set (header_buf, "HDR_SIZE", "%llu", header_size) < 0) {
	multilog (log, LOG_ERR, "Could not write HDR_SIZE to header\n");
	return -1;
    }
    
    if (verbose) fprintf(stderr,"Observation ID is %s\n",ObsId);
    if (ascii_header_set (header_buf, "OBS_ID", "%s", ObsId) < 0) {
	multilog (log, LOG_ERR, "Could not write OBS_ID to header\n");
	return -1;
    }

    if (verbose) fprintf(stderr,"File size is %lu\n",fSize);
    if (ascii_header_set (header_buf, "FILE_SIZE", "%lu", fSize) < 0) {
	multilog (log, LOG_ERR, "Could not write FILE_SIZE to header\n");
	return -1;
    }

    if (ipcbuf_mark_filled (hdu->header_block, header_size) < 0)  {
	multilog (log, LOG_ERR, "Could not mark filled header block\n");
	return EXIT_FAILURE;
    }

    
    /* open PiC card - makes the device available for further writes  */

    if (verbose) fprintf(stderr,"opening PiC Device....");

    if ( (pic_open(&pic, 0)) < 0 ){
	multilog(log, LOG_ERR,"PiC open failed\n");
	return EXIT_FAILURE;
    }    
    
    if (verbose) fprintf(stderr,"...done\n");
    
    /* setup EDT DMA Card */
    
    if (verbose) fprintf(stderr,"open EDT device....");
    if ((edt_p = edt_open(EDT_INTERFACE, 0)) == NULL)
    {
	multilog(log,LOG_ERR,"edt_open error\n") ;
	return EXIT_FAILURE;
    }
    if (verbose) fprintf(stderr,"...done\n");


    if (verbose) fprintf(stderr,"Configuring EDT kernel ring buffers....");
    if (edt_configure_ring_buffers(edt_p, bufsize, 16, EDT_READ, NULL) == -1)
    {
	multilog(log,LOG_ERR,"edt_configure_ring_buffers error\n") ;
	return EXIT_FAILURE;
    }
    if (verbose) fprintf(stderr,"...done\n");

    /* flush stale buffers in the EDT card */
    edt_flush_fifo(edt_p) ;     

    /* start the transfers in free running mode */
    edt_start_buffers(edt_p, 0) ; 
    
    /* check if we're within the 'allowed window' , if not sleep */
    t.tv_sec=0; 

    if  ( (t.tv_sec % 10 <= 1) | (t.tv_sec % 10 >= 7) ) 
	fprintf(stderr,"Waiting for valid time");
    while ( (t.tv_sec % 10 <= 1) | (t.tv_sec % 10 >= 7) ) {
	usleep(250000);
	fprintf(stderr,"%d .",(int)t.tv_sec % 10);
	if ( (gettimeofday(&t,NULL) != 0) ){
	    multilog(log,LOG_ERR,"Unable to retrive Systime");
	    return EXIT_FAILURE;
	} 
    }
    
    fprintf(stderr,"\n");
    /*PiC is arm'ed now. When the next 10-Sec pulse arrives */
    /*EDT will receive both clock and enable data*/
    if ( (pic_configure(&pic, 1)) < 0 ){
	multilog(log, LOG_ERR,"Cannot configure PiC\n");
	return EXIT_FAILURE;
    }    

    /* The write loop */
    /* repeat the write loop for n buffers */   
    /* if we number of buffers is not specified, */
    /* find it from number of seconds, based on 80 MB/sec sample rate*/
    if (nbufs == 0)  nbufs = (80000000 * nSecs)/bufsize;

    if (verbose) fprintf(stderr,"Number of bufs is %d\n",nbufs);

    buf = edt_done_count(edt_p);

    while(buf < nbufs){

	/* check header, if we need to abort */
	/* wait for EDT buffers to fill up */

	if ( (data = edt_wait_for_buffers(edt_p, 1)) == NULL){
	    edt_perror("edt_wait");
	    multilog(log,LOG_ERR,"edt_wait error\n");
	    return EXIT_FAILURE;
	}
       
	/* check for overflows */
	if ( (edt_ring_buffer_overrun(edt_p)) != 0){
	    fprintf(stderr,"Overrun Error\n");
	    multilog(log,LOG_ERR,"EDT Overrun\n");
	}

	/* get data from EDT and write to datablock */
	if (( ipcio_write(hdu->data_block, data, bufsize) ) < bufsize ){
	    multilog(log, LOG_ERR, "Cannot write requested bytes to SHM\n");
	    return EXIT_FAILURE;
	}
      
        /* find out the number of buffers completed */
	buf = edt_done_count(edt_p);
	wrCount = ipcbuf_get_write_count ((ipcbuf_t*)hdu->data_block);
	rdCount = ipcbuf_get_read_count ((ipcbuf_t*)hdu->data_block);
	fprintf(stderr,"%d %d %d\n",buf,wrCount,rdCount);
 
    }
    

    /* stop the EDT card */
    edt_stop_buffers(edt_p) ; 
    edt_close(edt_p);
    
    /* disarm pic now*/
    if ( (pic_configure(&pic, 2)) < 0 ){
	multilog(log, LOG_ERR,"Cannot configure PiC\n");
	return EXIT_FAILURE;
    }  

    if (dada_hdu_unlock_write (hdu) < 0)
      return EXIT_FAILURE;

    if (dada_hdu_disconnect (hdu) < 0)
      return EXIT_FAILURE;

    return EXIT_SUCCESS;
}


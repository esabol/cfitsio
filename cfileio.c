/*  This file, cfileio.c, contains the low-level file access routines.     */

/*  The FITSIO software was written by William Pence at the High Energy    */
/*  Astrophysic Science Archive Research Center (HEASARC) at the NASA      */
/*  Goddard Space Flight Center.  Users shall not, without prior written   */
/*  permission of the U.S. Government,  establish a claim to statutory     */
/*  copyright.  The Government and others acting on its behalf, shall have */
/*  a royalty-free, non-exclusive, irrevocable,  worldwide license for     */
/*  Government purposes to publish, distribute, translate, copy, exhibit,  */
/*  and perform such material.                                             */

#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <stddef.h>  /* apparently needed to define size_t */
#include "fitsio2.h"

#define MAX_PREFIX_LEN 20  /* max length of file type prefix (e.g. 'http://') */
#define MAX_DRIVERS 15     /* max number of file I/O drivers */

typedef struct    /* structure containing pointers to I/O driver functions */ 
{   char prefix[MAX_PREFIX_LEN];
    int (*init)(void);
    int (*shutdown)(void);
    int (*setoptions)(int option);
    int (*getoptions)(int *options);
    int (*getversion)(int *version);
    int (*checkfile)(char *urltype, char *infile, char *outfile);
    int (*open)(char *filename, int rwmode, int *driverhandle);
    int (*create)(char *filename, int *drivehandle);
    int (*truncate)(int drivehandle, long size);
    int (*close)(int drivehandle);
    int (*remove)(char *filename);
    int (*size)(int drivehandle, long *size);
    int (*flush)(int drivehandle);
    int (*seek)(int drivehandle, long offset);
    int (*read)(int drivehandle, void *buffer, long nbytes);
    int (*write)(int drivehandle, void *buffer, long nbytes);
} fitsdriver;

fitsdriver driverTable[MAX_DRIVERS];  /* allocate driver tables */

int need_to_initialize = 1;    /* true if CFITSIO has not been initialized */
int no_of_drivers = 0;         /* number of currently defined I/O drivers */

/*--------------------------------------------------------------------------*/
int ffomem(fitsfile **fptr,      /* O - FITS file pointer                   */ 
           const char *name,     /* I - name of file to open                */
           int mode,             /* I - 0 = open readonly; 1 = read/write   */
           void **buffptr,       /* I - address of memory pointer           */
           size_t *buffsize,     /* I - size of buffer, in bytes            */
           size_t deltasize,     /* I - increment for future realloc's      */
           void *(*mem_realloc)(void *p, size_t newsize), /* function       */
           int *status)          /* IO - error status                       */
/*
  Open an existing FITS file in core memory.  This is a specialized version
  of ffopen.
*/
{
    int driver, handle, hdutyp, slen, movetotype, extvers, extnum;
    char extname[FLEN_VALUE];
    long filesize;
    char urltype[MAX_PREFIX_LEN], infile[FLEN_FILENAME], outfile[FLEN_FILENAME];
    char extspec[FLEN_FILENAME], rowfilter[FLEN_FILENAME];
    char binspec[FLEN_FILENAME], colspec[FLEN_FILENAME];
    char *url, errmsg[FLEN_ERRMSG];
    char *hdtype[3] = {"IMAGE", "TABLE", "BINTABLE"};

    if (*status > 0)
        return(*status);

    *fptr = 0;                   /* initialize null file pointer */

    if (need_to_initialize)           /* this is called only once */
    {
        *status = fits_init_cfitsio();

        if (*status > 0)
            return(*status);
    }

    url = (char *) name;
    while (*url == ' ')  /* ignore leading spaces in the file spec */
        url++;

        /* parse the input file specification */
    ffiurl(url, urltype, infile, outfile, extspec,
              rowfilter, binspec, colspec, status);

    strcpy(urltype, "memkeep://");   /* URL type for pre-existing memory file */

    *status = urltype2driver(urltype, &driver);

    if (*status > 0)
    {
        ffpmsg("could not find driver for pre-existing memory file: (ffomem)");
        return(*status);
    }

    /* call driver routine to open the memory file */
    *status =   mem_openmem( buffptr, buffsize,deltasize,
                            mem_realloc,  &handle);

    if (*status > 0)
    {
         ffpmsg("failed to open pre-existing memory file: (ffomem)");
         return(*status);
    }

        /* get initial file size */
    *status = (*driverTable[driver].size)(handle, &filesize);

    if (*status > 0)
    {
        (*driverTable[driver].close)(handle);  /* close the file */
        ffpmsg("failed get the size of the memory file: (ffomem)");
        return(*status);
    }

        /* allocate fitsfile structure and initialize = 0 */
    *fptr = (fitsfile *) calloc(1, sizeof(fitsfile));

    if (!(*fptr))
    {
        (*driverTable[driver].close)(handle);  /* close the file */
        ffpmsg("failed to allocate structure for following file: (ffopen)");
        ffpmsg(url);
        return(*status = MEMORY_ALLOCATION);
    }

        /* allocate FITSfile structure and initialize = 0 */
    (*fptr)->Fptr = (FITSfile *) calloc(1, sizeof(FITSfile));

    if (!((*fptr)->Fptr))
    {
        (*driverTable[driver].close)(handle);  /* close the file */
        ffpmsg("failed to allocate structure for following file: (ffopen)");
        ffpmsg(url);
        free(*fptr);
        *fptr = 0;       
        return(*status = MEMORY_ALLOCATION);
    }

    slen = strlen(url) + 1;
    slen = maxvalue(slen, 32); /* reserve at least 32 chars */ 
    ((*fptr)->Fptr)->filename = (char *) malloc(slen); /* mem for file name */

    if ( !(((*fptr)->Fptr)->filename) )
    {
        (*driverTable[driver].close)(handle);  /* close the file */
        ffpmsg("failed to allocate memory for filename: (ffopen)");
        ffpmsg(url);
        free((*fptr)->Fptr);
        free(*fptr);
        *fptr = 0;              /* return null file pointer */
        return(*status = MEMORY_ALLOCATION);
    }

        /* store the parameters describing the file */
    ((*fptr)->Fptr)->filehandle = handle;        /* file handle */
    ((*fptr)->Fptr)->driver = driver;            /* driver number */
    strcpy(((*fptr)->Fptr)->filename, url);      /* full input filename */
    ((*fptr)->Fptr)->filesize = filesize;        /* physical file size */
    ((*fptr)->Fptr)->logfilesize = filesize;     /* logical file size */
    ((*fptr)->Fptr)->writemode = mode;      /* read-write mode    */
    ((*fptr)->Fptr)->datastart = DATA_UNDEFINED; /* unknown start of data */
    ((*fptr)->Fptr)->curbuf = -1;             /* undefined current IO buffer */
    ((*fptr)->Fptr)->open_count = 1;     /* structure is currently used once */
    ((*fptr)->Fptr)->validcode = VALIDSTRUC; /* flag denoting valid structure */

    ffldrc(*fptr, 0, REPORT_EOF, status);     /* load first record */

    if (ffrhdu(*fptr, &hdutyp, status) > 0)  /* determine HDU structure */
    {
        ffpmsg(
          "ffopen could not interpret primary array header of file: (ffomem)");
        ffpmsg(url);

        if (*status == UNKNOWN_REC)
           ffpmsg("This does not look like a FITS file.");

        ffclos(*fptr, status);
        *fptr = 0;              /* return null file pointer */
    }

    /* ---------------------------------------------------------- */
    /* move to desired extension, if specified as part of the URL */
    /* ---------------------------------------------------------- */

    if (*extspec)
    {
       /* parse the extension specifier into individual parameters */
       ffexts(extspec, &extnum, 
                            extname, &extvers, &movetotype, status);

      if (*status > 0)
          return(*status);

      if (extnum)
      {
        ffmahd(*fptr, extnum + 1, &hdutyp, status);
      }
      else if (*extname) /* move to named extension, if specified */
      {
        ffmnhd(*fptr, movetotype, extname, extvers, status);
      }

      if (*status > 0)
      {
        ffpmsg("ffopen could not move to the specified extension:");
        if (extnum > 0)
        {
          sprintf(errmsg,
          " extension number %d doesn't exist or couldn't be opened.",extnum);
          ffpmsg(errmsg);
        }
        else
        {
          sprintf(errmsg,
          " extension with EXTNAME = %s,", extname);
          ffpmsg(errmsg);

          if (extvers)
          {
             sprintf(errmsg,
             "           and with EXTVERS = %d,", extvers);
             ffpmsg(errmsg);
          }

          if (movetotype != ANY_HDU)
          {
             sprintf(errmsg,
             "           and with XTENSION = %s,", hdtype[movetotype]);
             ffpmsg(errmsg);
          }

          ffpmsg(" doesn't exist or couldn't be opened.");
        }
        return(*status);
      }
    }

    return(*status);
}
/*--------------------------------------------------------------------------*/
int ffopen(fitsfile **fptr,      /* O - FITS file pointer                   */ 
           const char *name,     /* I - full name of file to open           */
           int mode,             /* I - 0 = open readonly; 1 = read/write   */
           int *status)          /* IO - error status                       */
/*
  Open an existing FITS file with either readonly or read/write access.
*/
{
    FITSfile *oldFptr;
    int ii, driver, hdutyp, slen;
    long filesize;
    int extnum, extvers, handle, movetotype;
    char urltype[MAX_PREFIX_LEN], infile[FLEN_FILENAME], outfile[FLEN_FILENAME];
    char origurltype[MAX_PREFIX_LEN], extspec[FLEN_FILENAME];
    char extname[FLEN_VALUE], rowfilter[FLEN_FILENAME];
    char binspec[FLEN_FILENAME], colspec[FLEN_FILENAME];
    char wtcol[FLEN_VALUE];
    char minname[4][FLEN_VALUE], maxname[4][FLEN_VALUE];
    char binname[4][FLEN_VALUE];
    char oldurltype[MAX_PREFIX_LEN], oldinfile[FLEN_FILENAME];
    char oldextspec[FLEN_FILENAME], oldoutfile[FLEN_FILENAME];
    char oldrowfilter[FLEN_FILENAME];
    char oldbinspec[FLEN_FILENAME], oldcolspec[FLEN_FILENAME];

    char *url;
    double minin[4], maxin[4], binsizein[4], weight;
    int imagetype, haxis, recip;
    char colname[4][FLEN_VALUE];
    char errmsg[FLEN_ERRMSG];
    char *hdtype[3] = {"IMAGE", "TABLE", "BINTABLE"};

    if (*status > 0)
        return(*status);

    *fptr = 0;              /* initialize null file pointer */

    if (need_to_initialize)           /* this is called only once */
       *status = fits_init_cfitsio();

    if (*status > 0)
        return(*status);

    url = (char *) name;
    while (*url == ' ')  /* ignore leading spaces in the filename */
        url++;

    if (*url == '\0')
    {
        ffpmsg("Name of file to open is blank. (ffopen)");
        return(*status = FILE_NOT_OPENED);
    }

        /* parse the input file specification */
    ffiurl(url, urltype, infile, outfile, extspec,
              rowfilter, binspec, colspec, status);

    if (*status > 0)
    {
        ffpmsg("could not parse the input filename: (ffopen)");
        ffpmsg(url);
        return(*status);
    }

    /* check if this same file is already open, and if so, attach to it */
    for (ii = 0; ii < NIOBUF; ii++)   /* check every buffer */
    {
        ffcurbuf(ii, &oldFptr);  
        if (oldFptr)            /* this is the current buffer of a file */
        {
          ffiurl(oldFptr->filename, oldurltype, 
                    oldinfile, oldoutfile, oldextspec, oldrowfilter, 
                    oldbinspec, oldcolspec, status);

          if (*status > 0)
          {
            ffpmsg("could not parse the previously opened filename: (ffopen)");
            ffpmsg(oldFptr->filename);
            return(*status);
          }

          if (!strcmp(urltype, oldurltype) && !strcmp(infile, oldinfile) )
          {
              /* identical type of file and root file name */

              if ( (!rowfilter[0] && !oldrowfilter[0] &&
                    !binspec[0]   && !oldbinspec[0] &&
                    !colspec[0]   && !oldcolspec[0])

                  /* no filtering or binning specs for either file, so */
                  /* this is a case where the same file is being reopened. */
                  /* It doesn't matter if the extensions are different */

                      ||   /* or */

                  (!strcmp(rowfilter, oldrowfilter) &&
                   !strcmp(binspec, oldbinspec)     &&
                   !strcmp(colspec, oldcolspec)     &&
                   !strcmp(extspec, oldextspec) ) )

                  /* filtering specs are given and are identical, and */
                  /* the same extension is specified */

              {
                  *fptr = (fitsfile *) calloc(1, sizeof(fitsfile));

                  if (!(*fptr))
                  {
          ffpmsg("failed to allocate structure for following file: (ffopen)");
                     ffpmsg(url);
                     return(*status = MEMORY_ALLOCATION);
                  }

                  (*fptr)->Fptr = oldFptr; /* point to the structure */
                  (*fptr)->HDUposition = 0;     /* set initial position */
                (((*fptr)->Fptr)->open_count)++;  /* increment usage counter */

                  if (binspec[0])  /* if binning specified, don't move */
                      extspec[0] = '\0';

                  /* all the filtering has already been applied, so ignore */
                  rowfilter[0] = '\0';
                  binspec[0] = '\0';
                  colspec[0] = '\0';

                  goto move2hdu;  
              }
            }
        }
    }

    *status = urltype2driver(urltype, &driver);

    if (*status > 0)
    {
        ffpmsg("could not find driver for this file: (ffopen)");
        ffpmsg(url);
        return(*status);
    }

    /* deal with all those messy special cases */
    if (driverTable[driver].checkfile)
    {
        strcpy(origurltype,urltype);  /* Save the urltype */

        /* 'checkfile' may modify the urltype, infile and outfile strings */
        *status =  (*driverTable[driver].checkfile)(urltype, infile, outfile);

        if (*status)
        {
            ffpmsg("checkfile failed for this file: (ffopen)");
            ffpmsg(url);
            return(*status);
        }

        if (strcmp(origurltype, urltype))  /* did driver changed on us? */
        {
            *status = urltype2driver(urltype, &driver);
            if (*status > 0)
            {
                ffpmsg("could not change driver for this file: (ffopen)");
                ffpmsg(url);
                ffpmsg(urltype);
                return(*status);
            }
        }
    }

    /* call appropriate driver to open the file */
    if (driverTable[driver].open)
    {
        *status =  (*driverTable[driver].open)(infile, mode, &handle);
        if (*status > 0)
        {
            ffpmsg("failed to find or open the following file: (ffopen)");
            ffpmsg(url);
            return(*status);
       }
    }
    else
    {
        ffpmsg("cannot open an existing file of this type: (ffopen)");
        ffpmsg(url);
        return(*status = FILE_NOT_OPENED);
    }

        /* get initial file size */
    *status = (*driverTable[driver].size)(handle, &filesize);

    if (*status > 0)
    {
        (*driverTable[driver].close)(handle);  /* close the file */
        ffpmsg("failed get the size of the following file: (ffopen)");
        ffpmsg(url);
        return(*status);
    }

        /* allocate fitsfile structure and initialize = 0 */
    *fptr = (fitsfile *) calloc(1, sizeof(fitsfile));

    if (!(*fptr))
    {
        (*driverTable[driver].close)(handle);  /* close the file */
        ffpmsg("failed to allocate structure for following file: (ffopen)");
        ffpmsg(url);
        return(*status = MEMORY_ALLOCATION);
    }

        /* allocate FITSfile structure and initialize = 0 */
    (*fptr)->Fptr = (FITSfile *) calloc(1, sizeof(FITSfile));

    if (!((*fptr)->Fptr))
    {
        (*driverTable[driver].close)(handle);  /* close the file */
        ffpmsg("failed to allocate structure for following file: (ffopen)");
        ffpmsg(url);
        free(*fptr);
        *fptr = 0;       
        return(*status = MEMORY_ALLOCATION);
    }

    slen = strlen(url) + 1;
    slen = maxvalue(slen, 32); /* reserve at least 32 chars */ 
    ((*fptr)->Fptr)->filename = (char *) malloc(slen); /* mem for file name */

    if ( !(((*fptr)->Fptr)->filename) )
    {
        (*driverTable[driver].close)(handle);  /* close the file */
        ffpmsg("failed to allocate memory for filename: (ffopen)");
        ffpmsg(url);
        free((*fptr)->Fptr);
        free(*fptr);
        *fptr = 0;              /* return null file pointer */
        return(*status = MEMORY_ALLOCATION);
    }

        /* store the parameters describing the file */
    ((*fptr)->Fptr)->filehandle = handle;        /* file handle */
    ((*fptr)->Fptr)->driver = driver;            /* driver number */
    strcpy(((*fptr)->Fptr)->filename, url);      /* full input filename */
    ((*fptr)->Fptr)->filesize = filesize;        /* physical file size */
    ((*fptr)->Fptr)->logfilesize = filesize;     /* logical file size */
    ((*fptr)->Fptr)->writemode = mode;           /* read-write mode    */
    ((*fptr)->Fptr)->datastart = DATA_UNDEFINED; /* unknown start of data */
    ((*fptr)->Fptr)->curbuf = -1;            /* undefined current IO buffer */
    ((*fptr)->Fptr)->open_count = 1;      /* structure is currently used once */
    ((*fptr)->Fptr)->validcode = VALIDSTRUC; /* flag denoting valid structure */

    ffldrc(*fptr, 0, REPORT_EOF, status);     /* load first record */

    if (ffrhdu(*fptr, &hdutyp, status) > 0)  /* determine HDU structure */
    {
        ffpmsg(
          "ffopen could not interpret primary array header of file: (ffopen)");
        ffpmsg(url);

        if (*status == UNKNOWN_REC)
           ffpmsg("This does not look like a FITS file.");

        ffclos(*fptr, status);
        *fptr = 0;              /* return null file pointer */
        return(*status);
    }

    /* ---------------------------------------------------------- */
    /* move to desired extension, if specified as part of the URL */
    /* ---------------------------------------------------------- */

move2hdu:

    if (*extspec)
    {
       /* parse the extension specifier into individual parameters */
       ffexts(extspec, &extnum, 
                            extname, &extvers, &movetotype, status);

      if (*status > 0)
          return(*status);

      if (extnum)
      {
        ffmahd(*fptr, extnum + 1, &hdutyp, status);
      }
      else if (*extname) /* move to named extension, if specified */
      {
        ffmnhd(*fptr, movetotype, extname, extvers, status);
      }

      if (*status > 0)
      {
        ffpmsg("ffopen could not move to the specified extension:");
        if (extnum > 0)
        {
          sprintf(errmsg,
          " extension number %d doesn't exist or couldn't be opened.",extnum);
          ffpmsg(errmsg);
        }
        else
        {
          sprintf(errmsg,
          " extension with EXTNAME = %s,", extname);
          ffpmsg(errmsg);

          if (extvers)
          {
             sprintf(errmsg,
             "           and with EXTVERS = %d,", extvers);
             ffpmsg(errmsg);
          }

          if (movetotype != ANY_HDU)
          {
             sprintf(errmsg,
             "           and with XTENSION = %s,", hdtype[movetotype]);
             ffpmsg(errmsg);
          }

          ffpmsg(" doesn't exist or couldn't be opened.");
        }
        return(*status);
      }
    }

    /* ------------------------------------------------------------------- */
    /* select rows from the table, if specified in the URL                 */
    /* ------------------------------------------------------------------- */
 
    if (*rowfilter)
    {
       /* Create new table in memory and open it as the current fptr.  */
       /*              This will close the original table.             */
       if (ffselect_table(fptr, rowfilter, status) > 0)
       {
           ffpmsg("on-the-fly selection of rows in input table failed");
           return(*status);
       }
    }

    /* ------------------------------------------------------------------- */
    /* make an image histogram by binning columns, if specified in the URL */
    /* ------------------------------------------------------------------- */
 
    if (*binspec)
    {
       /* parse the binning specifier into individual parameters */
       ffbins(binspec, &imagetype, &haxis, colname, 
                          minin, maxin, binsizein, 
                          minname, maxname, binname,
                          &weight, wtcol, &recip, status);

       /* Create the histogram in memory and open it as the current fptr.  */
       /* This will close the table that was used to create the histogram. */
       ffhist(fptr, imagetype, haxis, colname, minin, maxin, binsizein,
              status);
    }

    return(*status);
}
/*--------------------------------------------------------------------------*/
int ffreopen(fitsfile *openfptr, /* I - FITS file pointer to open file  */ 
             fitsfile **newfptr,  /* O - pointer to new re opened file   */
             int *status)        /* IO - error status                   */
/*
  Reopen an existing FITS file with either readonly or read/write access.
  The reopened file shares the same FITSfile structure but may point to a
  different HDU within the file.
*/
{
    if (*status > 0)
        return(*status);

    /* check that the open file pointer is valid */
    if (!openfptr)
        return(*status = NULL_INPUT_PTR);
    else if ((openfptr->Fptr)->validcode != VALIDSTRUC) /* check magic value */
        return(*status = BAD_FILEPTR); 

        /* allocate fitsfile structure and initialize = 0 */
    *newfptr = (fitsfile *) calloc(1, sizeof(fitsfile));

    (*newfptr)->Fptr = openfptr->Fptr; /* both point to the same structure */
    (*newfptr)->HDUposition = 0;  /* set initial position to primary array */
    (((*newfptr)->Fptr)->open_count)++;   /* increment the file usage counter */

    return(*status);
}
/*--------------------------------------------------------------------------*/
int ffselect_table(
           fitsfile **fptr,  /* IO - pointer to input table; on output it  */
                             /*      points to the new selected rows table */
           char *expr,       /* I - Boolean expression    */
           int *status)
{
    fitsfile *newptr;
    int ii, hdunum;
    char *cptr;

    /* create new empty file in memory to hold the selected rows */
    if (ffinit(&newptr, "mem://", status) > 0)
    {
        ffpmsg(
         "failed to create memory file for selected rows from input table");
        return(*status);
    }

    fits_get_hdu_num(*fptr, &hdunum);  /* current HDU number in input file */

    /* copy all preceding extensions to the output file */
    for (ii = 1; ii < hdunum; ii++)
    {
        fits_movabs_hdu(*fptr, ii, NULL, status);
        if (fits_copy_hdu(*fptr, newptr, 0, status) > 0)
        {
            ffclos(newptr, status);
            return(*status);
        }
    }

    /* copy all the header keywords from the input to output file */
    fits_movabs_hdu(*fptr, hdunum, NULL, status);
    if (fits_copy_header(*fptr, newptr, status) > 0)
    {
        ffclos(newptr, status);
        return(*status);
    }

    /* set number of rows = 0 */
    fits_modify_key_lng(newptr, "NAXIS2", 0, NULL,status);
    if (ffrdef(*fptr, status) > 0)  /* force the header to be scanned */
    {
        ffclos(newptr, status);
        return(*status);
    }

    /* remove the brackets from around the selection expression */
    cptr = expr + 1;
    ii = strlen(cptr);
    cptr[ii - 1] = '\0';

    /* copy rows which satisfy the selection expression to the output table */
    if (fits_select_rows(*fptr, newptr, cptr, status) > 0)
    {
        ffclos(newptr, status);
        return(*status);
    }

    /* copy any remaining HDUs to the output file */

    for (ii = hdunum + 1; 1; ii++)
    {
        if (fits_movabs_hdu(*fptr, ii, NULL, status) > 0)
            break;

        fits_copy_hdu(*fptr, newptr, 0, status);
    }

    if (*status == END_OF_FILE)   
        *status = 0;              /* got the expected EOF error; reset = 0  */
    else if (*status > 0)
    {
        ffclos(newptr, status);
        return(*status);
    }

    /* close the original file and return ptr to the new image */
    ffclos(*fptr, status);

    *fptr = newptr; /* reset the pointer to the new table */

    /* move back to the selected table HDU */
    fits_movabs_hdu(*fptr, hdunum, NULL, status);

    return(*status);
}
/*--------------------------------------------------------------------------*/
int ffinit(fitsfile **fptr,      /* O - FITS file pointer                   */
           const char *name,     /* I - name of file to create              */
           int *status)          /* IO - error status                       */
/*
  Create and initialize a new FITS file.
*/
{
    int driver, slen, clobber;
    char *url;
    char urltype[MAX_PREFIX_LEN], outfile[FLEN_FILENAME];
    int handle;

    if (*status > 0)
        return(*status);

    *fptr = 0;              /* initialize null file pointer */

    if (need_to_initialize)            /* this is called only once */
       *status = fits_init_cfitsio();

    if (*status > 0)
        return(*status);

    url = (char *) name;
    while (*url == ' ')  /* ignore leading spaces in the filename */
        url++;

    if (*url == '\0')
    {
        ffpmsg("Name of file to create is blank. (ffinit)");
        return(*status = FILE_NOT_CREATED);
    }

    /* check for clobber symbol, i.e,  overwrite existing file */
    if (*url == '!')
    {
        clobber = TRUE;
        url++;
    }
    else
        clobber = FALSE;

        /* parse the output file specification */
    ffourl(url, urltype, outfile, status);

    if (*status > 0)
    {
        ffpmsg("could not parse the output filename: (ffinit)");
        ffpmsg(url);
        return(*status);
    }

        /* find which driver corresponds to the urltype */
    *status = urltype2driver(urltype, &driver);

    if (*status)
    {
        ffpmsg("could not find driver for this file: (ffinit)");
        ffpmsg(url);
        return(*status);
    }

        /* delete pre-existing file, if asked to do so */
    if (clobber)
    {
        if (driverTable[driver].remove)
             (*driverTable[driver].remove)(outfile);
    }

        /* call appropriate driver to create the file */
    if (driverTable[driver].create)
    {
        *status = (*driverTable[driver].create)(outfile, &handle);

        if (*status)
        {
            ffpmsg("failed to create the following file: (ffinit)");
            ffpmsg(url);
            return(*status);
       }
    }
    else
    {
        ffpmsg("cannot create a new file of this type: (ffinit)");
        ffpmsg(url);
        return(*status = FILE_NOT_CREATED);
    }

        /* allocate fitsfile structure and initialize = 0 */
    *fptr = (fitsfile *) calloc(1, sizeof(fitsfile));

    if (!(*fptr))
    {
        (*driverTable[driver].close)(handle);  /* close the file */
        ffpmsg("failed to allocate structure for following file: (ffopen)");
        ffpmsg(url);
        return(*status = MEMORY_ALLOCATION);
    }

        /* allocate FITSfile structure and initialize = 0 */
    (*fptr)->Fptr = (FITSfile *) calloc(1, sizeof(FITSfile));

    if (!((*fptr)->Fptr))
    {
        (*driverTable[driver].close)(handle);  /* close the file */
        ffpmsg("failed to allocate structure for following file: (ffopen)");
        ffpmsg(url);
        free(*fptr);
        *fptr = 0;       
        return(*status = MEMORY_ALLOCATION);
    }

    slen = strlen(url) + 1;
    slen = maxvalue(slen, 32); /* reserve at least 32 chars */ 
    ((*fptr)->Fptr)->filename = (char *) malloc(slen); /* mem for file name */

    if ( !(((*fptr)->Fptr)->filename) )
    {
        (*driverTable[driver].close)(handle);  /* close the file */
        ffpmsg("failed to allocate memory for filename: (ffinit)");
        ffpmsg(url);
        free((*fptr)->Fptr);
        free(*fptr);
        *fptr = 0;              /* return null file pointer */
        return(*status = FILE_NOT_CREATED);
    }

        /* store the parameters describing the file */
    ((*fptr)->Fptr)->filehandle = handle;        /* store the file pointer */
    ((*fptr)->Fptr)->driver = driver;            /*  driver number         */
    strcpy(((*fptr)->Fptr)->filename, url);      /* full input filename    */
    ((*fptr)->Fptr)->filesize = 0;               /* physical file size     */
    ((*fptr)->Fptr)->logfilesize = 0;            /* logical file size      */
    ((*fptr)->Fptr)->writemode = 1;              /* read-write mode        */
    ((*fptr)->Fptr)->datastart = DATA_UNDEFINED; /* unknown start of data  */
    ((*fptr)->Fptr)->curbuf = -1;         /* undefined current IO buffer   */
    ((*fptr)->Fptr)->validcode = VALIDSTRUC; /* flag denoting valid structure */

    ffldrc(*fptr, 0, IGNORE_EOF, status);     /* initialize first record */

    return(*status);                       /* successful return */
}
/*--------------------------------------------------------------------------*/
int fits_init_cfitsio(void)
/*
  initialize anything that is required before using the CFITSIO routines
*/
{
    int status;

    union u_tag {
      short ival;
      char cval[2];
    } u;

    need_to_initialize = 0;

    /*   test for correct byteswapping.   */

    u.ival = 1;
    if  ((BYTESWAPPED && u.cval[0] != 1) ||
         (BYTESWAPPED == FALSE && u.cval[1] != 1) )
    {
      printf ("\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n");
      printf(" Byteswapping is not being done correctly on this system.\n");
      printf(" Check the MACHINE and BYTESWAPPED definitions in fitsio2.h\n");
      printf(" Please report this problem to the author at\n");
      printf("     pence@tetra.gsfc.nasa.gov\n");
      printf(  "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n");
      return(1);
    }

    /* register the standard I/O drivers that are always available */

    /*--------------------disk file driver-----------------------*/
    status = fits_register_driver("file://", 
            file_init,
            file_shutdown,
            file_setoptions,
            file_getoptions, 
            file_getversion,
	    file_checkfile,
            file_open,
            file_create,
#ifdef HAVE_FTRUNCATE
            file_truncate,
#else
            NULL,   /* no file truncate function */
#endif
            file_close,
            file_remove,
            file_size,
            file_flush,
            file_seek,
            file_read,
            file_write);

    if (status)
    {
        ffpmsg("failed to register the file:// driver (init_cfitsio)");
        return(status);
    }

    /*------------ output temporary memory file driver -----------------------*/
    status = fits_register_driver("mem://", 
            mem_init,
            mem_shutdown,
            mem_setoptions,
            mem_getoptions, 
            mem_getversion,
            NULL,            /* checkfile not needed */
            NULL,            /* open function not allowed */
            mem_create, 
            mem_truncate,
            mem_close_free,
            NULL,            /* remove function not required */
            mem_size,
            NULL,            /* flush function not required */
            mem_seek,
            mem_read,
            mem_write);


    if (status)
    {
        ffpmsg("failed to register the mem:// driver (init_cfitsio)");
        return(status);
    }

    /*--------------input pre-existing memory file driver------------------*/
    status = fits_register_driver("memkeep://", 
            mem_init,
            mem_shutdown,
            mem_setoptions,
            mem_getoptions, 
            mem_getversion,
            NULL,            /* checkfile not needed */
            NULL,            /* file open driver function is not used */
            NULL,            /* create function not allowed */
            mem_truncate,
            mem_close_keep,
            NULL,            /* remove function not required */
            mem_size,
            NULL,            /* flush function not required */
            mem_seek,
            mem_read,
            mem_write);


    if (status)
    {
        ffpmsg("failed to register the memkeep:// driver (init_cfitsio)");
        return(status);
    }

   /*-------------------stdin stream driver----------------------*/
    status = fits_register_driver("stdin://", 
            mem_init,
            mem_shutdown,
            mem_setoptions,
            mem_getoptions, 
            mem_getversion,
            NULL,            /* checkfile not needed */ 
            stdin_open,
            NULL,            /* create function not allowed */
            mem_truncate,
            mem_close_free,
            NULL,            /* remove function not required */
            mem_size,
            NULL,            /* flush function not required */
            mem_seek,
            mem_read,
            mem_write);

    if (status)
    {
        ffpmsg("failed to register the stdin:// driver (init_cfitsio)");
        return(status);
    }

    /*-----------------------stdout stream driver------------------*/
    status = fits_register_driver("stdout://",
            mem_init,
            mem_shutdown,
            mem_setoptions,
            mem_getoptions, 
            mem_getversion,
            NULL,            /* checkfile not needed */ 
            NULL,            /* open function not required */
            mem_create, 
            mem_truncate,
            stdout_close,
            NULL,            /* remove function not required */
            mem_size,
            NULL,            /* flush function not required */
            mem_seek,
            mem_read,
            mem_write);

    if (status)
    {
        ffpmsg("failed to register the stdout:// driver (init_cfitsio)");
        return(status);
    }

    /*------------------compressed disk file driver ----------------*/
    status = fits_register_driver("compress://",
            mem_init,
            mem_shutdown,
            mem_setoptions,
            mem_getoptions, 
            mem_getversion,
            NULL,            /* checkfile not needed */ 
            compress_open,
            NULL,            /* create function not required */
            mem_truncate,
            mem_close_free,
            NULL,            /* remove function not required */
            mem_size,
            NULL,            /* flush function not required */
            mem_seek,
            mem_read,
            mem_write);

    if (status)
    {
        ffpmsg("failed to register the compress:// driver (init_cfitsio)");
        return(status);
    }


    /* Register Optional drivers */

#ifdef HAVE_NET_SERVICES

    /*--------------------root driver-----------------------*/

    status = fits_register_driver("root://",
				  root_init,
				  root_shutdown,
				  root_setoptions,
				  root_getoptions, 
				  root_getversion,
				  NULL,            /* checkfile not needed */ 
				  root_open,
				  root_create,
				  NULL,  /* No truncate possible */
				  root_close,
				  NULL,  /* No remove possible */
				  root_size,  /* no size possible */
				  root_flush,
				  root_seek, /* Though will always succeed */
				  root_read,
				  root_write);

    if (status)
    {
        ffpmsg("failed to register the root:// driver (init_cfitsio)");
        return(status);
    }

    /*--------------------http  driver-----------------------*/
    status = fits_register_driver("http://",
            mem_init,
            mem_shutdown,
            mem_setoptions,
            mem_getoptions, 
            mem_getversion,
            http_checkfile,
            http_open,
            NULL,            /* create function not required */
            mem_truncate,
            mem_close_free,
            NULL,            /* remove function not required */
            mem_size,
            NULL,            /* flush function not required */
            mem_seek,
            mem_read,
            mem_write);

    if (status)
    {
        ffpmsg("failed to register the http:// driver (init_cfitsio)");
        return(status);
    }

    /*--------------------http file driver-----------------------*/

    status = fits_register_driver("httpfile://",
            file_init,
            file_shutdown,
            file_setoptions,
            file_getoptions, 
            file_getversion,
            NULL,            /* checkfile not needed */ 
            http_file_open,
            file_create,
#ifdef HAVE_FTRUNCATE
            file_truncate,
#else
            NULL,   /* no file truncate function */
#endif
            file_close,
            file_remove,
            file_size,
            file_flush,
            file_seek,
            file_read,
            file_write);

    if (status)
    {
        ffpmsg("failed to register the httpfile:// driver (init_cfitsio)");
        return(status);
    }

    /*--------------------httpcompress file driver-----------------------*/

    status = fits_register_driver("httpcompress://",
            mem_init,
            mem_shutdown,
            mem_setoptions,
            mem_getoptions, 
            mem_getversion,
            NULL,            /* checkfile not needed */ 
            http_compress_open,
            NULL,            /* create function not required */
            mem_truncate,
            mem_close_free,
            NULL,            /* remove function not required */
            mem_size,
            NULL,            /* flush function not required */
            mem_seek,
            mem_read,
            mem_write);

    if (status)
    {
        ffpmsg("failed to register the httpcompress:// driver (init_cfitsio)");
        return(status);
    }


    /*--------------------ftp driver-----------------------*/
    status = fits_register_driver("ftp://",
            mem_init,
            mem_shutdown,
            mem_setoptions,
            mem_getoptions, 
            mem_getversion,
            ftp_checkfile,
            ftp_open,
            NULL,            /* create function not required */
            mem_truncate,
            mem_close_free,
            NULL,            /* remove function not required */
            mem_size,
            NULL,            /* flush function not required */
            mem_seek,
            mem_read,
            mem_write);

    if (status)
    {
        ffpmsg("failed to register the ftp:// driver (init_cfitsio)");
        return(status);
    }

    /*--------------------ftp file driver-----------------------*/
    status = fits_register_driver("ftpfile://",
            file_init,
            file_shutdown,
            file_setoptions,
            file_getoptions, 
            file_getversion,
            NULL,            /* checkfile not needed */ 
            ftp_file_open,
            file_create,
#ifdef HAVE_FTRUNCATE
            file_truncate,
#else
            NULL,   /* no file truncate function */
#endif
            file_close,
            file_remove,
            file_size,
            file_flush,
            file_seek,
            file_read,
            file_write);

    if (status)
    {
        ffpmsg("failed to register the ftpfile:// driver (init_cfitsio)");
        return(status);
    }

    /*--------------------ftp compressed file driver------------------*/
    status = fits_register_driver("ftpcompress://",
            mem_init,
            mem_shutdown,
            mem_setoptions,
            mem_getoptions, 
            mem_getversion,
            NULL,            /* checkfile not needed */ 
            ftp_compress_open,
            0,            /* create function not required */
            mem_truncate,
            mem_close_free,
            0,            /* remove function not required */
            mem_size,
            0,            /* flush function not required */
            mem_seek,
            mem_read,
            mem_write);

    if (status)
    {
        ffpmsg("failed to register the ftpcompress:// driver (init_cfitsio)");
        return(status);
    }
      /* === End of net drivers section === */  
#endif

/* ==================== SHARED MEMORY DRIVER SECTION ======================= */

#ifdef HAVE_SHMEM_SERVICES

    /*--------------------shared memory driver-----------------------*/
    status = fits_register_driver("shmem://", 
            smem_init,
            smem_shutdown,
            smem_setoptions,
            smem_getoptions, 
            smem_getversion,
            NULL,            /* checkfile not needed */ 
            smem_open,
            smem_create,
            NULL,            /* truncate file not supported yet */ 
            smem_close,
            smem_remove,
            smem_size,
            smem_flush,
            smem_seek,
            smem_read,
            smem_write );

    if (status)
    {
        ffpmsg("failed to register the shmem:// driver (init_cfitsio)");
        return(status);
    }

#endif

/* ==================== END OF SHARED MEMORY DRIVER SECTION ================ */



    return(status);
}
/*--------------------------------------------------------------------------*/
int fits_register_driver(char *prefix,
	int (*init)(void),
	int (*shutdown)(void),
	int (*setoptions)(int option),
	int (*getoptions)(int *options),
	int (*getversion)(int *version),
	int (*checkfile) (char *urltype, char *infile, char *outfile),
	int (*open)(char *filename, int rwmode, int *driverhandle),
	int (*create)(char *filename, int *driverhandle),
	int (*truncate)(int driverhandle, long filesize),
	int (*close)(int driverhandle),
	int (*fremove)(char *filename),
        int (*size)(int driverhandle, long *size),
	int (*flush)(int driverhandle),
	int (*seek)(int driverhandle, long offset),
	int (*read) (int driverhandle, void *buffer, long nbytes),
	int (*write)(int driverhandle, void *buffer, long nbytes) )
/*
  register all the functions needed to support an I/O driver
*/
{
    int status;

    if (no_of_drivers + 1 == MAX_DRIVERS)
        return(TOO_MANY_DRIVERS);

    if (prefix  == NULL)
        return(BAD_URL_PREFIX);
   

    if (init != NULL)		
    { 
        status = (*init)();
        if (status)
            return(status);
    }

    	/*  fill in data in table */
    strncpy(driverTable[no_of_drivers].prefix, prefix, MAX_PREFIX_LEN);
    driverTable[no_of_drivers].prefix[MAX_PREFIX_LEN - 1] = 0;
    driverTable[no_of_drivers].init = init;
    driverTable[no_of_drivers].shutdown = shutdown;
    driverTable[no_of_drivers].setoptions = setoptions;
    driverTable[no_of_drivers].getoptions = getoptions;
    driverTable[no_of_drivers].getversion = getversion;
    driverTable[no_of_drivers].checkfile = checkfile;
    driverTable[no_of_drivers].open = open;
    driverTable[no_of_drivers].create = create;
    driverTable[no_of_drivers].truncate = truncate;
    driverTable[no_of_drivers].close = close;
    driverTable[no_of_drivers].remove = fremove;
    driverTable[no_of_drivers].size = size;
    driverTable[no_of_drivers].flush = flush;
    driverTable[no_of_drivers].seek = seek;
    driverTable[no_of_drivers].read = read;
    driverTable[no_of_drivers].write = write;

    no_of_drivers++;      /* increment the number of drivers */
    return(0);
 }
/*--------------------------------------------------------------------------*/
int ffiurl(char *url, 
                    char *urltype,
                    char *infilex,
                    char *outfile, 
                    char *extspec,
                    char *rowfilterx,
                    char *binspec,
                    char *colspec,
                    int *status)
/*
   parse the input URL into its basic components.
*/

{ 
    int ii, jj, slen, infilelen, plus_ext = 0;
    char *ptr1, *ptr2, *ptr3;

    /* must have temporary variable for these, in case inputs are NULL */
    char *infile;
    char *rowfilter;
    char *tmpstr;

    if (*status > 0)
        return(*status);

    if (infilex)
        *infilex  = '\0';
    if (rowfilterx)
        *rowfilterx = '\0';

    if (urltype)
        *urltype = '\0';
    if (outfile)
        *outfile = '\0';
    if (extspec)
        *extspec = '\0';
    if (binspec)
        *binspec = '\0';
    if (colspec)
        *colspec = '\0';

    slen = strlen(url);

    if (slen == 0)       /* blank filename ?? */
        return(*status);

    /* allocate memory for 3 strings, each as long as the input url */
    infile = (char *) malloc(3 * (slen + 1) );
    if (!infile)
       return(*status = MEMORY_ALLOCATION);

    rowfilter = &infile[slen + 1];
    tmpstr = &rowfilter[slen + 1];

    *infile = '\0';
    *rowfilter = '\0';
    *tmpstr = '\0';

    ptr1 = url;

        /*  get urltype (e.g., file://, ftp://, http://, etc.)  */
    if (*ptr1 == '-')        /* "-" means read file from stdin */
    {
        if (urltype)
            strcat(urltype, "stdin://");
        ptr1++;
    }
    else
    {
        ptr2 = strstr(ptr1, "://");
        if (ptr2)                  /* copy the explicit urltype string */ 
        {
            if (urltype)
                 strncat(urltype, ptr1, ptr2 - ptr1 + 3);
            ptr1 = ptr2 + 3;
        }
        else if (!strncmp(ptr1, "ftp:", 4) )
        {                              /* the 2 //'s are optional */
            if (urltype)
                strcat(urltype, "ftp://");
            ptr1 += 4;
        }
        else if (!strncmp(ptr1, "http:", 5) )
        {                              /* the 2 //'s are optional */
            if (urltype)
                strcat(urltype, "http://");
            ptr1 += 5;
        }
        else if (!strncmp(ptr1, "mem:", 4) )
        {                              /* the 2 //'s are optional */
            if (urltype)
                strcat(urltype, "mem://");
            ptr1 += 4;
        }
        else if (!strncmp(ptr1, "shmem:", 6) )
        {                              /* the 2 //'s are optional */
            if (urltype)
                strcat(urltype, "shmem://");
            ptr1 += 6;
        }
        else if (!strncmp(ptr1, "file:", 5) )
        {                              /* the 2 //'s are optional */
            if (urltype)
                strcat(urltype, "file://");
            ptr1 += 5;
        }
        else                       /* assume file driver    */
        {
            if (urltype)
                strcat(urltype, "file://");
        }
    }
 
       /*  get the input file name  */
    ptr2 = strchr(ptr1, '(');   /* search for opening parenthesis ( */
    ptr3 = strchr(ptr1, '[');   /* search for opening bracket [ */

    if (ptr2 == ptr3)  /* simple case: no [ or ( in the file name */
    {
        strcat(infile, ptr1);
    }
    else if (!ptr3)     /* no bracket, so () enclose output file name */
    {
        strncat(infile, ptr1, ptr2 - ptr1);
        ptr2++;

        ptr1 = strchr(ptr2, ')' );   /* search for closing ) */
        if (!ptr1)
        {
            free(infile);
            return(*status = URL_PARSE_ERROR);  /* error, no closing ) */
        }

        if (outfile)
            strncat(outfile, ptr2, ptr1 - ptr2);
    }
    else if (ptr2 && (ptr2 < ptr3)) /* () enclose output name before bracket */
    {
        strncat(infile, ptr1, ptr2 - ptr1);
        ptr2++;

        ptr1 = strchr(ptr2, ')' );   /* search for closing ) */
        if (!ptr1)
        {
            free(infile);
            return(*status = URL_PARSE_ERROR);  /* error, no closing ) */
        }

        if (outfile)
            strncat(outfile, ptr2, ptr1 - ptr2);
    }
    else    /*   bracket comes first, so there is no output name */
    {
        strncat(infile, ptr1, ptr3 - ptr1);
    }

   /* strip off any trailing blanks in the names */
    slen = strlen(infile);
    for (ii = slen - 1; ii > 0; ii--)   
    {
            if (infile[ii] == ' ')
                infile[ii] = '\0';
            else
                break;
    }

    if (outfile)
    {
        slen = strlen(outfile);
        for (ii = slen - 1; ii > 0; ii--)   
        {
            if (outfile[ii] == ' ')
                outfile[ii] = '\0';
            else
                break;
        }
    }

    /* --------------------------------------------- */
    /* check if the 'filename+n' convention has been */
    /* used to specifiy which HDU number to open     */ 
    /* --------------------------------------------- */

    jj = strlen(infile);

    for (ii = jj - 1; ii >= 0; ii--)
    {
        if (infile[ii] == '+')    /* search backwards for '+' sign */
            break;
    }

    if (ii != 0 && (jj - ii) < 5)  /* limit extension numbers to 4 digits */
    {
        infilelen = ii;
        ii++;
        ptr1 = infile+ii;   /* pointer to start of sequence */

        for (; ii < jj; ii++)
        {
            if (!isdigit( infile[ii] ) ) /* are all the chars digits? */
                break;
        }

        if (ii == jj)      
        {
             /* yes, the '+n' convention was used.  Copy */
             /* the digits to the output extspec string. */
             plus_ext = 1;

             if (extspec)
                 strncpy(extspec, ptr1, jj - infilelen);

             infile[infilelen] = '\0'; /* delete the extension number */
        }
    }

    /* if '*' was given for the output name expand it to the root file name */
    if (outfile && outfile[0] == '*')
    {
        /* scan input name backwards to the first '/' character */
        for (ii = jj - 1; ii >= 0; ii--)
        {
            if (infile[ii] == '/')
            {
                strcpy(outfile, &infile[ii + 1]);
                break;
            }
        }
    }

    /* copy strings from local copy to the output */
    if (infilex)
        strcpy(infilex, infile);

    if (!ptr3)     /* no [ character in the input string? */
    {
        free(infile);
        return(*status);
    }

    /* ------------------------------------------- */
    /* see if [ extension specification ] is given */
    /* ------------------------------------------- */

    if (!plus_ext) /* extension no. not already specified?  Then */
                   /* first brackets must enclose extension name or # */
    {
       ptr1 = ptr3 + 1;    /* pointer to first char after the [ */

       ptr2 = strchr(ptr1, ']' );   /* search for closing ] */
       if (!ptr2)
       {
            ffpmsg("input file URL is missing closing bracket ']'");
            free(infile);
            return(*status = URL_PARSE_ERROR);  /* error, no closing ] */
       }

       /* copy the extension specification */
       if (extspec)
           strncat(extspec, ptr1, ptr2 - ptr1);

       /* copy any remaining chars to filter spec string */
       strcat(rowfilter, ptr2 + 1);
    }
    else   /* copy all remaining input chars to filter spec */
    {
        strcat(rowfilter, ptr3);
    }

    /* strip off any trailing blanks from filter */
    slen = strlen(rowfilter);
    for (ii = slen - 1; ii > 0; ii--)   
    {
        if (rowfilter[ii] == ' ')
            rowfilter[ii] = '\0';
        else
            break;
    }

    if (!rowfilter[0])
    {
        free(infile);
        return(*status);      /* nothing left to parse */
    }

    /* ------------------------------------------------------- */
    /* convert filter to all lowercase to simplify comparisons */
    /* ------------------------------------------------------- */

    ptr1 = rowfilter;
    while (*ptr1)
       *(ptr1++) = tolower( *ptr1);

    /* ------------------------------------------------ */
    /* does the filter contain a binning specification? */
    /* ------------------------------------------------ */

    ptr1 = strstr(rowfilter, "[bin");      /* search for "[bin" */
    if (ptr1)
    {
      ptr2 = ptr1 + 4;     /* end of the '[bin' string */
      if (*ptr2 == 'b' || *ptr2 == 'i' || *ptr2 == 'j' ||
          *ptr2 == 'r' || *ptr2 == 'd')
         ptr2++;  /* skip the datatype code letter */


      if ( *ptr2 != ' ' && *ptr2 != ']')
        ptr1 = NULL;   /* bin string must be followed by space or ] */
    }

    if (ptr1)
    {
        /* found the binning string */
        if (binspec)
        {
            strcpy(binspec, ptr1 + 1);       
            ptr2 = strchr(binspec, ']');

            if (ptr2)      /* terminate the binning filter */
            {
                *ptr2 = '\0';

                if ( *(--ptr2) == ' ')  /* delete trailing spaces */
                    *ptr2 = '\0';
            }
            else
            {
                ffpmsg("input file URL is missing closing bracket ']'");
                ffpmsg(rowfilter);
                free(infile);
                return(*status = URL_PARSE_ERROR);  /* error, no closing ] */
            }
        }

        /* delete the binning spec from the row filter string */
        ptr2 = strchr(ptr1, ']');
        strcpy(tmpstr, ptr2+1);  /* copy any chars after the binspec */
        strcpy(ptr1, tmpstr);    /* overwrite binspec */
    }

    /* --------------------------------------------------------- */
    /* does the filter contain a column selection specification? */
    /* --------------------------------------------------------- */

    ptr1 = strstr(rowfilter, "[col");

    if (ptr1)
    {
        if (colspec)
        {
            strcpy(colspec, ptr1 + 1);       

            ptr2 = strchr(colspec, ']');

            if (ptr2)      /* terminate the binning filter */
            {
                *ptr2 = '\0';

                if ( *(--ptr2) == ' ')  /* delete trailing spaces */
                    *ptr2 = '\0';
            }
            else
            {
                ffpmsg("input file URL is missing closing bracket ']'");
                free(infile);
                return(*status = URL_PARSE_ERROR);  /* error, no closing ] */
            }
        }

        /* delete the column selection spec from the row filter string */
        ptr2 = strchr(ptr1, ']');
        strcpy(tmpstr, ptr2+1);  /* copy any chars after the colspec */
        strcpy(ptr1, tmpstr);    /* overwrite binspec */
    }

    /* copy the local string to the output */
    if (rowfilterx)
        strcpy(rowfilterx, rowfilter);

    free(infile);
    return(*status);
}
/*--------------------------------------------------------------------------*/
int ffrtnm(char *url, 
           char *rootname,
           int *status)
/*
   parse the input URL, returning the root name (filetype://basename).
*/

{ 
    int ii, jj, slen, infilelen;
    char *ptr1, *ptr2, *ptr3;
    char urltype[MAX_PREFIX_LEN];
    char infile[FLEN_FILENAME];

    if (*status > 0)
        return(*status);

    ptr1 = url;
    *rootname = '\0';
    *urltype = '\0';
    *infile  = '\0';

    /*  get urltype (e.g., file://, ftp://, http://, etc.)  */
    if (*ptr1 == '-')        /* "-" means read file from stdin */
    {
        strcat(urltype, "-");
        ptr1++;
    }
    else
    {
        ptr2 = strstr(ptr1, "://");
        if (ptr2)                  /* copy the explicit urltype string */ 
        {
            strncat(urltype, ptr1, ptr2 - ptr1 + 3);
            ptr1 = ptr2 + 3;
        }
        else if (!strncmp(ptr1, "ftp:", 4) )
        {                              /* the 2 //'s are optional */
            strcat(urltype, "ftp://");
            ptr1 += 4;
        }
        else if (!strncmp(ptr1, "http:", 5) )
        {                              /* the 2 //'s are optional */
            strcat(urltype, "http://");
            ptr1 += 5;
        }
        else if (!strncmp(ptr1, "mem:", 4) )
        {                              /* the 2 //'s are optional */
            strcat(urltype, "mem://");
            ptr1 += 4;
        }
        else if (!strncmp(ptr1, "shmem:", 6) )
        {                              /* the 2 //'s are optional */
            strcat(urltype, "shmem://");
            ptr1 += 6;
        }
        else if (!strncmp(ptr1, "file:", 5) )
        {                              /* the 2 //'s are optional */
            ptr1 += 5;
        }

        /* else assume file driver    */
    }
 
       /*  get the input file name  */
    ptr2 = strchr(ptr1, '(');   /* search for opening parenthesis ( */
    ptr3 = strchr(ptr1, '[');   /* search for opening bracket [ */

    if (ptr2 == ptr3)  /* simple case: no [ or ( in the file name */
    {
        strcat(infile, ptr1);
    }
    else if (!ptr3)     /* no bracket, so () enclose output file name */
    {
        strncat(infile, ptr1, ptr2 - ptr1);
        ptr2++;

        ptr1 = strchr(ptr2, ')' );   /* search for closing ) */
        if (!ptr1)
            return(*status = URL_PARSE_ERROR);  /* error, no closing ) */

    }
    else if (ptr2 && (ptr2 < ptr3)) /* () enclose output name before bracket */
    {
        strncat(infile, ptr1, ptr2 - ptr1);
        ptr2++;

        ptr1 = strchr(ptr2, ')' );   /* search for closing ) */
        if (!ptr1)
            return(*status = URL_PARSE_ERROR);  /* error, no closing ) */
    }
    else    /*   bracket comes first, so there is no output name */
    {
        strncat(infile, ptr1, ptr3 - ptr1);
    }

       /* strip off any trailing blanks in the names */
    slen = strlen(infile);
    for (ii = slen - 1; ii > 0; ii--)   
    {
        if (infile[ii] == ' ')
            infile[ii] = '\0';
        else
            break;
    }

    /* --------------------------------------------- */
    /* check if the 'filename+n' convention has been */
    /* used to specifiy which HDU number to open     */ 
    /* --------------------------------------------- */

    jj = strlen(infile);

    for (ii = jj - 1; ii >= 0; ii--)
    {
        if (infile[ii] == '+')    /* search backwards for '+' sign */
            break;
    }

    if (ii != 0 && (jj - ii) < 5)  /* limit extension numbers to 4 digits */
    {
        infilelen = ii;
        ii++;
        ptr1 = infile+ii;   /* pointer to start of sequence */

        for (; ii < jj; ii++)
        {
            if (!isdigit( infile[ii] ) ) /* are all the chars digits? */
                break;
        }

        if (ii == jj)      
        {
             /* yes, the '+n' convention was used.  */

             infile[infilelen] = '\0'; /* delete the extension number */
        }
    }

    strcat(rootname, urltype);  /* construct the root name */
    strcat(rootname, infile);

    return(*status);
}
/*--------------------------------------------------------------------------*/
int ffourl(char *url, 
           char *urltype,
           char *outfile,
           int *status)
/*
   parse the output URL into its basic components.
*/

{ 
    char *ptr1, *ptr2;

    if (*status > 0)
        return(*status);

    ptr1 = url;
    *urltype = '\0';
    *outfile = '\0';

        /*  get urltype (e.g., file://, ftp://, http://, etc.)  */
    if (*ptr1 == '-')        /* "-" means write file to stdout */
    {
        strcpy(urltype, "stdout://");
    }
    else
    {
        ptr2 = strstr(ptr1, "://");
        if (ptr2)                  /* copy the explicit urltype string */ 
        {
            strncat(urltype, ptr1, ptr2 - ptr1 + 3);
            ptr1 = ptr2 + 3;
        }
        else                       /* assume file driver    */
        {
             strcat(urltype, "file://");
        }
       /*  get the output file name  */
        strcpy(outfile, ptr1);
    }
    return(*status);
}
/*--------------------------------------------------------------------------*/
int ffexts(char *extspec, 
                       int *extnum, 
                       char *extname,
                       int *extvers,
                       int *hdutype,
                       int *status)
{
/*
   Parse the input extension specification string, returning either the
   extension number or the values of the EXTNAME, EXTVERS, and XTENSION
   keywords in desired extension.
*/
    char *ptr1;
    int slen, nvals;

    *extnum = 0;
    *extname = '\0';
    *extvers = 0;
    *hdutype = ANY_HDU;

    if (*status > 0)
        return(*status);

    ptr1 = extspec;       /* pointer to first char */

    while (*ptr1 == ' ')  /* skip over any leading blanks */
        ptr1++;

    if (isdigit(*ptr1))  /* is the extension specification a number? */
    {
        sscanf(ptr1, "%d", extnum);
        if (*extnum < 0 || *extnum > 9999)
        {
            *extnum = 0;   /* this is not a reasonable extension number */
            ffpmsg("specified extension number is out of range:");
            ffpmsg(extspec);
            return(*status = URL_PARSE_ERROR); 
        }
    }
    else
    {
           /* not a number, so EXTNAME must be specified, followed by */
           /* optional EXTVERS and XTENSION  values */

           slen = strcspn(ptr1, " ,:");   /* length of EXTNAME */
           strncat(extname, ptr1, slen);  /* EXTNAME value */

           ptr1 += slen;
           slen = strspn(ptr1, " ,:");  /* skip delimiter characters */
           ptr1 += slen;

           slen = strcspn(ptr1, " ,:");   /* length of EXTVERS */
           if (slen)
           {
               nvals = sscanf(ptr1, "%d", extvers);  /* EXTVERS value */
               if (nvals != 1)
               {
                   ffpmsg("illegal EXTVER value in input URL:");
                   ffpmsg(extspec);
                   return(*status = URL_PARSE_ERROR);
               }

               ptr1 += slen;
               slen = strspn(ptr1, " ,:");  /* skip delimiter characters */
               ptr1 += slen;

               slen = strlen(ptr1);   /* length of HDUTYPE */
               if (slen)
               {
                 if (*ptr1 == 'b' || *ptr1 == 'B')
                     *hdutype = BINARY_TBL;  
                 else if (*ptr1 == 't' || *ptr1 == 'T' ||
                          *ptr1 == 'a' || *ptr1 == 'A')
                     *hdutype = ASCII_TBL;
                 else if (*ptr1 == 'i' || *ptr1 == 'I')
                     *hdutype = IMAGE_HDU;
                 else
                 {
                     ffpmsg("unknown type of HDU in input URL:");
                     ffpmsg(extspec);
                     return(*status = URL_PARSE_ERROR);
                 }
               }
           }
    }
    return(*status);
}
/*--------------------------------------------------------------------------*/
int ffextn(char *url,           /* I - input filename/URL  */
           int *extension_num,  /* O - returned extension number */
           int *status)
{
/*
   Parse the input url string and return the number of the extension that
   CFITSIO would automatically move to if CFITSIO were to open this input URL.
   The extension numbers are one's based, so 1 = the primary array, 2 = the
   first extension, etc.

   The extension number that gets returned is determined by the following 
   algorithm:

   1. If the input URL includes a binning specification (e.g.
   'myfile.fits[3][bin X,Y]') then the returned extension number
   will always = 1, since CFITSIO would create a temporary primary
   image on the fly in this case.

   2.  Else if the input URL specifies an extension number (e.g.,
   'myfile.fits[3]' or 'myfile.fits+3') then the specified extension
   number (+ 1) is returned.  

   3.  Else if the extension name is specified in brackets
   (e.g., this 'myfile.fits[EVENTS]') then the file will be opened and searched
   for the extension number.  If the input URL is '-'  (reading from the stdin
   file stream) this is not possible and an error will be returned.

   4.  Else if the URL does not specify an extension (e.g. 'myfile.fits') then
   a special extension number = -99 will be returned to signal that no
   extension was specified.  This feature is mainly for compatibility with
   existing FTOOLS software.  CFITSIO would open the primary array by default
   (extension_num = 1) in this case.

*/
    fitsfile *fptr;
    char urltype[20];
    char infile[FLEN_FILENAME];
    char outfile[FLEN_FILENAME]; 
    char extspec[FLEN_FILENAME];
    char extname[FLEN_FILENAME];
    char rowfilter[FLEN_FILENAME];
    char binspec[FLEN_FILENAME];
    char colspec[FLEN_FILENAME];
    char *cptr;
    int extnum, extvers, hdutype;

    if (*status > 0)
        return(*status);

    /*  parse the input URL into its basic components  */
    ffiurl(url, urltype, infile, outfile,
             extspec, rowfilter,binspec, colspec, status);

    if (*status > 0)
        return(*status);

    if (*binspec)   /* is there a binning specification? */
    {
       *extension_num = 1; /* a temporary primary array image is created */
       return(*status);
    }

    if (*extspec)   /* is an extension specified? */
    {
      ffexts(extspec, &extnum, extname, &extvers,
                                  &hdutype, status);
      if (*status > 0)
        return(*status);

      if (*extname)
      {
         /* have to open the file to search for the extension name (curses!) */

         if (!strcmp(urltype, "stdin://"))
            /* opening stdin would destroying it! */
            return(*status = URL_PARSE_ERROR); 

         /* First, strip off any filtering specification */
         strcpy(infile, url);
         cptr = strchr(infile, ']');  /* locate the closing bracket */
         if (!cptr)
         {
             return(*status = URL_PARSE_ERROR);
         }
         else
         {
             cptr++;
             *cptr = '\0'; /* terminate URl after the extension spec */
         }

         if (ffopen(&fptr, infile, READONLY, status) > 0) /* open the file */
            return(*status);

         ffghdn(fptr, &extnum);    /* where am I in the file? */
         *extension_num = extnum;
         ffclos(fptr, status);

         return(*status);
      }
      else
      {
         *extension_num = extnum + 1;  /* return the specified number (+ 1) */
         return(*status);
      }
    }
    else
    {
         *extension_num = -99;  /* no specific extension was specified */
                                /* defaults to primary array */
         return(*status);
    }
}
/*--------------------------------------------------------------------------*/
int ffbins(char *binspec,   /* I - binning specification */
                   int *imagetype,      /* O - image type, TINT or TSHORT */
                   int *haxis,          /* O - no. of axes in the histogram */
                   char colname[4][FLEN_VALUE],  /* column name for axis */
                   double *minin,        /* minimum value for each axis */
                   double *maxin,        /* maximum value for each axis */
                   double *binsizein,    /* size of bins on each axis */
                   char minname[4][FLEN_VALUE],  /* keyword name for min */
                   char maxname[4][FLEN_VALUE],  /* keyword name for max */
                   char binname[4][FLEN_VALUE],  /* keyword name for binsize */
                   double *weight,       /* weighting factor          */
                   char *wtname,        /* keyword or column name for weight */
                   int *recip,          /* the reciprocal of the weight? */
                   int *status)
{
/*
   Parse the input binning specification string, returning the binning
   parameters.  Supports up to 4 dimensions.  The binspec string has
   one of these forms:

   bin binsize                  - 2D histogram with binsize on each axis
   bin xcol                     - 1D histogram on column xcol
   bin (xcol, ycol) = binsize   - 2D histogram with binsize on each axis
   bin x=min:max:size, y=min:max:size, z..., t... 
   bin x=:max, y=::size
   bin x=size, y=min::size

   most other reasonable combinations are supported.        
*/
    int ii, slen, defaulttype;
    char *ptr, tmpname[30];
    double  dummy;

    if (*status > 0)
         return(*status);

    /* set the default values */
    *haxis = 2;
    *imagetype = TINT;
    defaulttype = 1;
    *weight = 1.;
    *recip = 0;
    *wtname = '\0';

    /* set default values */
    for (ii = 0; ii < 4; ii++)
    {
        *colname[ii] = '\0';
        *minname[ii] = '\0';
        *maxname[ii] = '\0';
        *binname[ii] = '\0';
        minin[ii] = DOUBLENULLVALUE;  /* undefined values */
        maxin[ii] = DOUBLENULLVALUE;
        binsizein[ii] = DOUBLENULLVALUE;
    }

    ptr = binspec + 3;  /* skip over 'bin' */

    if (*ptr == 'i' )  /* bini */
    {
        *imagetype = TSHORT;
        defaulttype = 0;
        ptr++;
    }
    else if (*ptr == 'j' )  /* binj; same as default */
    {
        defaulttype = 0;
        ptr ++;
    }
    else if (*ptr == 'r' )  /* binr */
    {
        *imagetype = TFLOAT;
        defaulttype = 0;
        ptr ++;
    }
    else if (*ptr == 'd' )  /* bind */
    {
        *imagetype = TDOUBLE;
        defaulttype = 0;
        ptr ++;
    }
    else if (*ptr == 'b' )  /* binb */
    {
        *imagetype = TBYTE;
        defaulttype = 0;
        ptr ++;
    }

    if (*ptr == '\0')  /* use all defaults for other parameters */
        return(*status);
    else if (*ptr != ' ')  /* must be at least one blank */
    {
        ffpmsg("binning specification syntax error:");
        ffpmsg(binspec);
        return(*status = URL_PARSE_ERROR);
    }

    while (*ptr == ' ')  /* skip over blanks */
           ptr++;

    if (*ptr == '\0')   /* no other parameters; use defaults */
        return(*status);

    if (*ptr == '(' )
    {
        /* this must be the opening parenthesis around a list of column */
        /* names, optionally followed by a '=' and the binning spec. */

        for (ii = 0; ii < 4; ii++)
        {
            ptr++;               /* skip over the '(', ',', or ' ') */
            while (*ptr == ' ')  /* skip over blanks */
                ptr++;

            slen = strcspn(ptr, " ,)");
            strncat(colname[ii], ptr, slen); /* copy 1st column name */

            ptr += slen;
            while (*ptr == ' ')  /* skip over blanks */
                ptr++;

            if (*ptr == ')' )   /* end of the list of names */
            {
                *haxis = ii + 1;
                break;
            }
        }

        if (ii == 4)   /* too many names in the list , or missing ')'  */
        {
            ffpmsg(
 "binning specification has too many column names or is missing closing ')':");
            ffpmsg(binspec);
            return(*status = URL_PARSE_ERROR);
        }

        ptr++;  /* skip over the closing parenthesis */
        while (*ptr == ' ')  /* skip over blanks */
            ptr++;

        if (*ptr == '\0')
            return(*status);  /* parsed the entire string */

        else if (*ptr != '=')  /* must be an equals sign now*/
        {
            ffpmsg("illegal binning specification in URL:");
            ffpmsg(" an equals sign '=' must follow the column names");
            ffpmsg(binspec);
            return(*status = URL_PARSE_ERROR);
        }

        ptr++;  /* skip over the equals sign */
        while (*ptr == ' ')  /* skip over blanks */
            ptr++;


        /* get the single range specification for all the columns */
        ffbinr(&ptr, tmpname, minin,
                                     maxin, binsizein, minname[0],
                                     maxname[0], binname[0], status);
        if (*status > 0)
        {
            ffpmsg("illegal binning specification in URL:");
            ffpmsg(binspec);
            return(*status);
        }

        for (ii = 1; ii < *haxis; ii++)
        {
            minin[ii] = minin[0];
            maxin[ii] = maxin[0];
            binsizein[ii] = binsizein[0];
            strcpy(minname[ii], minname[0]);
            strcpy(maxname[ii], maxname[0]);
            strcpy(binname[ii], binname[0]);
        }

        while (*ptr == ' ')  /* skip over blanks */
            ptr++;

        if (*ptr == ';')
            goto getweight;   /* a weighting factor is specified */

        if (*ptr != '\0')  /* must have reached end of string */
        {
            ffpmsg("illegal binning specification in URL:");
            ffpmsg(binspec);
            return(*status = URL_PARSE_ERROR);
        }

        return(*status);
    }             /* end of case with list of column names in ( )  */

    /* if we've reached this point, then the binning specification */
    /* must be of the form: XCOL = min:max:binsize, YCOL = ...     */
    /* where the column name followed by '=' are optional.         */
    /* If the column name is not specified, then use the default name */

    for (ii = 0; ii < 4; ii++) /* allow up to 4 histogram dimensions */
    {
        ffbinr(&ptr, colname[ii], &minin[ii],
                                     &maxin[ii], &binsizein[ii], minname[ii],
                                     maxname[ii], binname[ii], status);

        if (*status > 0)
        {
            ffpmsg("illegal binning specification in URL:");
            ffpmsg(binspec);
            return(*status);
        }

        if (*ptr == '\0' || *ptr == ';')
            break;        /* reached the end of the string */

        if (*ptr == ' ')
        {
            while (*ptr == ' ')  /* skip over blanks */
                ptr++;

            if (*ptr == '\0' || *ptr == ';')
                break;        /* reached the end of the string */

            if (*ptr == ',')
                ptr++;  /* comma separates the next column specification */
        }
        else if (*ptr == ',')
        {          
            ptr++;  /* comma separates the next column specification */
        }
        else
        {
            ffpmsg("illegal binning specification in URL:");
            ffpmsg(binspec);
            return(*status = URL_PARSE_ERROR);
        }
    }

    if (ii == 4)
    {
        /* there are yet more characters in the string */
        ffpmsg("illegal binning specification in URL:");
        ffpmsg("apparently too many histogram dimension (> 4)");
        ffpmsg(binspec);
        return(*status = URL_PARSE_ERROR);
    }
    else
        *haxis = ii + 1;

    /* special case: if a single number was entered it should be      */
    /* interpreted as the binning factor for the default X and Y axes */
    if (*haxis == 1 && *colname[0] == '\0' && 
         minin[0] == FLOATNULLVALUE && maxin[0] == FLOATNULLVALUE)
    {
        *haxis = 2;
        binsizein[1] = binsizein[0];
    }

getweight:
    if (*ptr == ';')  /* looks like a weighting factor is given */
    {
        ptr++;
       
        while (*ptr == ' ')  /* skip over blanks */
            ptr++;

        recip = 0;
        if (*ptr == '/')
        {
            *recip = 1;  /* the reciprocal of the weight is entered */
            ptr++;

            while (*ptr == ' ')  /* skip over blanks */
                ptr++;
        }

        /* parse the weight as though it were a binrange. */
        /* either a column name or a numerical value will be returned */

        ffbinr(&ptr, wtname, &dummy, &dummy, weight, tmpname,
                                     tmpname, tmpname, status);

        if (*status > 0)
        {
            ffpmsg("illegal binning specification in URL:");
            ffpmsg(binspec);
            return(*status);
        }
    }

    while (*ptr == ' ')  /* skip over blanks */
         ptr++;

    if (*ptr != '\0')  /* should have reached the end of string */
    {
        ffpmsg("illegal binning specification in URL:");
        ffpmsg(binspec);
        *status = URL_PARSE_ERROR;
    }

    return(*status);
}
/*--------------------------------------------------------------------------*/
int fits_get_token(char **ptr, 
                   char *delimiter,
                   char *token,
                   int *isanumber)   /* O - is this token a number? */
/*
   parse off the next token, delimited by a character in 'delimiter',
   from the input ptr string;  increment *ptr to the end of the token.
   Returns the length of the token;
*/
{
    int slen, ii;

    *token = '\0';

    while (**ptr == ' ')  /* skip over leading blanks */
        (*ptr)++;

    slen = strcspn(*ptr, delimiter);  /* length of next token */
    if (slen)
    {
        strncat(token, *ptr, slen);       /* copy token */
        (*ptr) += slen;                   /* skip over the token */

        *isanumber = 1;
 
        for (ii = 0; ii < slen; ii++)
        {
            if ( !isdigit(token[ii]) && token[ii] != '.' && token[ii] != '-')
            {
                *isanumber = 0;
                break;
            }
        }
    }

    return(slen);
}
/*--------------------------------------------------------------------------*/
int ffbinr(char **ptr, 
                   char *colname, 
                   double *minin,
                   double *maxin, 
                   double *binsizein,
                   char *minname,
                   char *maxname,
                   char *binname,
                   int *status)
/*
   Parse the input binning range specification string, returning 
   the column name, histogram min and max values, and bin size.
*/
{
    int slen, isanumber;
    char token[FLEN_VALUE];

    if (*status > 0)
        return(*status);

    slen = fits_get_token(ptr, " ,=:;", token, &isanumber); /* get 1st token */

    if (slen == 0 && (**ptr == '\0' || **ptr == ',' || **ptr == ';') )
        return(*status);   /* a null range string */

    if (!isanumber && **ptr != ':')
    {
        /* this looks like the column name */

        if (token[0] == '#' && isdigit(token[1]) )
        {
            /* omit the leading '#' in the column number */
            strcpy(colname, token+1);
        }
        else
            strcpy(colname, token);

        if (**ptr != '=')
            return(*status);  /* reached the end */

        (*ptr)++;   /* skip over the = sign */

        slen = fits_get_token(ptr, " ,:;", token, &isanumber); /* get token */
    }

    if (**ptr != ':')
    {
        /* this is the first token, and since it is not followed by */
        /* a ':' this must be the binsize token */
        if (!isanumber)
            strcpy(binname, token);
        else
            *binsizein =  strtod(token, NULL);

        return(*status);  /* reached the end */
    }
    else
    {
        /* the token contains the min value */
        if (slen)
        {
            if (!isanumber)
                strcpy(minname, token);
            else
                *minin = strtod(token, NULL);
        }
    }

    (*ptr)++;  /* skip the colon between the min and max values */
    slen = fits_get_token(ptr, " ,:;", token, &isanumber); /* get token */

    /* the token contains the max value */
    if (slen)
    {
        if (!isanumber)
            strcpy(maxname, token);
        else
            *maxin = strtod(token, NULL);
    }

    if (**ptr != ':')
        return(*status);  /* reached the end; no binsize token */

    (*ptr)++;  /* skip the colon between the min and max values */
    slen = fits_get_token(ptr, " ,:;", token, &isanumber); /* get token */

    /* the token contains the binsize value */
    if (slen)
    {
        if (!isanumber)
            strcpy(binname, token);
        else
            *binsizein = strtod(token, NULL);
    }

    return(*status);
}
/*--------------------------------------------------------------------------*/
int urltype2driver(char *urltype, int *driver)
/*
   compare input URL with list of known drivers, returning the
   matching driver numberL.
*/

{ 
    int ii;

       /* find matching driver; search most recent drivers first */

    for (ii=no_of_drivers - 1; ii >= 0; ii--)
    {
        if (0 == strcmp(driverTable[ii].prefix, urltype))
        { 
             *driver = ii;
             return(0);
        }
    }

    return(NO_MATCHING_DRIVER);   
}
/*--------------------------------------------------------------------------*/
int ffclos(fitsfile *fptr,      /* I - FITS file pointer */
           int *status)         /* IO - error status     */
/*
  close the FITS file by completing the current HDU, flushing it to disk,
  then calling the system dependent routine to physically close the FITS file
*/   
{
    if (!fptr)
        return(*status = NULL_INPUT_PTR);
    else if ((fptr->Fptr)->validcode != VALIDSTRUC) /* check for magic value */
        return(*status = BAD_FILEPTR); 

    ffchdu(fptr, status);         /* close and flush the current HDU   */
    ffflsh(fptr, TRUE, status);   /* flush and disassociate IO buffers */

    ((fptr->Fptr)->open_count)--;           /* decrement usage counter */

    if ((fptr->Fptr)->open_count == 0)  /* if no other files use structure */
    {
        /* call driver function to actually close the file */
        if (
   (*driverTable[(fptr->Fptr)->driver].close)((fptr->Fptr)->filehandle) )
        {
            if (*status <= 0)
            {
              *status = FILE_NOT_CLOSED;  /* report if no previous error */

              ffpmsg("failed to close the following file: (ffclos)");
              ffpmsg((fptr->Fptr)->filename);
            }
        }

        free((fptr->Fptr)->filename);     /* free memory for the filename */
        (fptr->Fptr)->filename = 0;
        (fptr->Fptr)->validcode = 0; /* magic value to indicate invalid fptr */
        free(fptr->Fptr);         /* free memory for the FITS file structure */
        free(fptr);               /* free memory for the FITS file structure */
    }

    return(*status);
}
/*--------------------------------------------------------------------------*/
int ffdelt(fitsfile *fptr,      /* I - FITS file pointer */
           int *status)         /* IO - error status     */
/*
  close and DELETE the FITS file. 
*/
{
    char *basename;
    int slen;

    if (!fptr)
        return(*status = NULL_INPUT_PTR);
    else if ((fptr->Fptr)->validcode != VALIDSTRUC) /* check for magic value */
        return(*status = BAD_FILEPTR); 

    ffchdu(fptr, status);    /* close the current HDU, ignore any errors */
    ffflsh(fptr, TRUE, status);     /* flush and disassociate IO buffers */

        /* call driver function to actually close the file */
    if ( (*driverTable[(fptr->Fptr)->driver].close)((fptr->Fptr)->filehandle) )
    {
        if (*status <= 0)
        {
            *status = FILE_NOT_CLOSED;  /* report error if no previous error */

            ffpmsg("failed to close the following file: (ffdelt)");
            ffpmsg((fptr->Fptr)->filename);
        }
    }


    /* call driver function to actually delete the file */
    if ( (driverTable[(fptr->Fptr)->driver].remove) )
    {
        /* parse the input URL to get the base filename */
        slen = strlen((fptr->Fptr)->filename);
        basename = (char *) malloc(slen +1);
        if (!basename)
            return(*status = MEMORY_ALLOCATION);
    
        ffiurl((fptr->Fptr)->filename, NULL, basename, NULL, NULL, NULL, NULL,
               NULL, status);

       if ((*driverTable[(fptr->Fptr)->driver].remove)(basename))
        {
            ffpmsg("failed to delete the following file: (ffdelt)");
            ffpmsg((fptr->Fptr)->filename);
            if (!(*status))
                *status = FILE_NOT_CLOSED;
        }
        free(basename);
    }

    free((fptr->Fptr)->filename);     /* free memory for the filename */
    (fptr->Fptr)->filename = 0;
    (fptr->Fptr)->validcode = 0;      /* magic value to indicate invalid fptr */
    free(fptr->Fptr);              /* free memory for the FITS file structure */
    free(fptr);                    /* free memory for the FITS file structure */

    return(*status);
}
/*--------------------------------------------------------------------------*/
int fftrun( fitsfile *fptr,    /* I - FITS file pointer           */
             long filesize,    /* I - size to truncate the file   */
             int *status)      /* O - error status                */
/*
  low level routine to truncate a file to a new smaller size.
*/
{
  if (driverTable[(fptr->Fptr)->driver].truncate)
  {
    ffflsh(fptr, FALSE, status);  /* flush all the buffers first */
    (fptr->Fptr)->filesize = filesize;
    (fptr->Fptr)->logfilesize = filesize;
    (fptr->Fptr)->io_pos = filesize;
    (fptr->Fptr)->bytepos = filesize;

    return (
     (*driverTable[(fptr->Fptr)->driver].truncate)((fptr->Fptr)->filehandle,
     filesize) );
  }
  else
    return(*status);
}
/*--------------------------------------------------------------------------*/
int ffflushx( FITSfile *fptr)     /* I - FITS file pointer                  */
/*
  low level routine to flush internal file buffers to the file.
*/
{
    if (driverTable[fptr->driver].flush)
        return ( (*driverTable[fptr->driver].flush)(fptr->filehandle) );
    else
        return(0);    /* no flush function defined for this driver */
}
/*--------------------------------------------------------------------------*/
int ffseek( FITSfile *fptr,   /* I - FITS file pointer              */
            long position)    /* I - byte position to seek to       */
/*
  low level routine to seek to a position in a file.
*/
{
    return( (*driverTable[fptr->driver].seek)(fptr->filehandle, position) );
}
/*--------------------------------------------------------------------------*/
int ffwrite( FITSfile *fptr,   /* I - FITS file pointer              */
             long nbytes,      /* I - number of bytes to write       */
             void *buffer,     /* I - buffer to write                */
             int *status)      /* O - error status                   */
/*
  low level routine to write bytes to a file.
*/
{
    if ( (*driverTable[fptr->driver].write)(fptr->filehandle, buffer, nbytes) )
        *status = WRITE_ERROR;

    return(*status);
}
/*--------------------------------------------------------------------------*/
int ffread( FITSfile *fptr,   /* I - FITS file pointer              */
            long nbytes,      /* I - number of bytes to read        */
            void *buffer,     /* O - buffer to read into            */
            int *status)      /* O - error status                   */
/*
  low level routine to read bytes from a file.
*/
{
    if ( (*driverTable[fptr->driver].read)(fptr->filehandle, buffer, nbytes) )
        *status = READ_ERROR;

    return(*status);
}
/*--------------------------------------------------------------------------*/
int fftplt(fitsfile **fptr,      /* O - FITS file pointer                   */
           const char *filename, /* I - name of file to create              */
           const char *tempname, /* I - name of template file               */
           int *status)          /* IO - error status                       */
/*
  Create and initialize a new FITS file  based on a template file.
  Uses C fopen and fgets functions.
*/
{
    FILE *diskfile;
    fitsfile *tptr;
    int tstatus = 0, nkeys, nadd, ii, newhdu, slen, keytype;
    char card[FLEN_CARD], template[161];

    if (*status > 0)
        return(*status);

    if ( ffinit(fptr, filename, status) )
        return(*status);

    if (tempname == NULL || *tempname == '\0')     /* no template file? */
        return(*status);

    /* try opening template */
    ffopen(&tptr, (char *) tempname, READONLY, &tstatus); 

    if (tstatus)  /* not a FITS file, so treat it as an ASCII template */
    {
        ffxmsg(-2, card);  /* clear the  error message */

        diskfile = fopen(tempname,"r"); 
        if (!diskfile)          /* couldn't open file */
        {
            ffpmsg("Could not open template file (fftplt)");
            return(*status = FILE_NOT_OPENED); 
        }

        newhdu = 0;
        while (fgets(template, 160, diskfile) )  /* get next template line */
        {
          template[160] = '\0';      /* make sure string is terminated */
          slen = strlen(template);   /* get string length */
          template[slen - 1] = '\0';  /* over write the 'newline' char */

          if (ffgthd(template, card, &keytype, status) > 0) /* parse template */
             break;

          if (keytype == 2)       /* END card; start new HDU */
          {
             newhdu = 1;
          }
          else
          {
             if (newhdu)
             {
                ffcrhd(*fptr, status);      /* create empty new HDU */
                newhdu = 0;
             }
             ffprec(*fptr, card, status);  /* write the card */
          }
        }

        fclose(diskfile);   /* close the template file */
        ffmahd(*fptr, 1, 0, status);   /* move back to the primary array */
        return(*status);
    }
    else  /* template is a valid FITS file */
    {
        ffghsp(*fptr, &nkeys, &nadd, status); /* get no. of keywords */

        while (*status <= 0)
        {
           for (ii = 1; ii <= nkeys; ii++)   /* copy keywords */
           {
              ffgrec(*fptr,  ii, card, status);
              ffprec(tptr, card, status);
           }

           ffmrhd(tptr, 1, 0, status); /* move to next HDU until error */
           ffcrhd(*fptr, status);      /* create empty new HDU in output file */
        }
        ffclos(tptr, status);       /* close the template file */
    }

    if (*status == END_OF_FILE)
    {
       ffxmsg(-2, card);  /* clear the end of file error message */
       *status = 0;              /* expected error condition */
    }

    ffmahd(*fptr, 1, 0, status);   /* move to the primary array */

    return(*status);
}
/*--------------------------------------------------------------------------*/
void ffrprt( FILE *stream, int status)
/* 
   Print out report of cfitsio error status and messages on the error stack.
   Uses C FILE stream.
*/
{
    char status_str[FLEN_STATUS], errmsg[FLEN_ERRMSG];
  
    if (status)
    {

      fits_get_errstatus(status, status_str);  /* get the error description */
      fprintf(stream, "\nFITSIO status = %d: %s\n", status, status_str);

      while ( fits_read_errmsg(errmsg) )  /* get error stack messages */
             fprintf(stream, "%s\n", errmsg);
    }
    return; 
}

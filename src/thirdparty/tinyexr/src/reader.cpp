#include "reader.h"
#define TINYEXR_USE_OPENEXR 0
#define TINYEXR_USE_MINIZ 0
#define TINYEXR_USE_STB_ZLIB 1
#define TINYEXR_IMPLEMENTATION
#include "tinyexr.h"

extern "C"
{
    void loadExr(const char *filename, int *width, int *height, float **data){
        const char *err = NULL;
        
        int ret = LoadEXR(data, width, height, filename, &err);
        if (ret != TINYEXR_SUCCESS)
        {
            fprintf(stderr, "ERR: %s\n", err);
            FreeEXRErrorMessage(err);
            return;
        }
               
        
    }
}
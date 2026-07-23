#pragma once

// Lib already included
// #define STB_IMAGE_IMPLEMENTATION
// #include "stb_image.h"



#ifdef __cplusplus
extern "C"
{
#endif /* __cplusplus */
    void loadExr(const char *filename, int *width, int *height, float **data);
#ifdef __cplusplus
}
#endif /* __cplusplus */

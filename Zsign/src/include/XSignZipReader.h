#ifndef XSIGN_ZIP_READER_H
#define XSIGN_ZIP_READER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
void *XSignZipOpen(const char *path, uint64_t count);
int XSignZipNext(void *reader, const char *path, uint64_t size, uint32_t crc, int directory);
int XSignZipRead(void *reader, void *buffer, unsigned int capacity);
int XSignZipFinishEntry(void *reader);
void XSignZipClose(void *reader);
#ifdef __cplusplus
}
#endif
#endif

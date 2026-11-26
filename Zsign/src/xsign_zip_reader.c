#include "include/XSignZipReader.h"
#include "third-party/minizip/unzip.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    unzFile archive;
    int started;
    int entry_open;
} XSignZipReader;

void *XSignZipOpen(const char *path, uint64_t count) {
    unzFile archive = unzOpen64(path);
    if (!archive) return NULL;
    unz_global_info64 info;
    if (unzGetGlobalInfo64(archive, &info) != UNZ_OK || info.number_entry != count) {
        unzClose(archive);
        return NULL;
    }
    XSignZipReader *reader = calloc(1, sizeof(*reader));
    if (!reader) {
        unzClose(archive);
        return NULL;
    }
    reader->archive = archive;
    return reader;
}

int XSignZipNext(void *state, const char *path, uint64_t size, uint32_t crc, int directory) {
    XSignZipReader *reader = state;
    if (reader->entry_open) return -1;
    int result = reader->started ? unzGoToNextFile(reader->archive) : unzGoToFirstFile(reader->archive);
    reader->started = 1;
    if (result != UNZ_OK) return -1;

    unz_file_info64 info;
    char name[1026] = {0};
    if (unzGetCurrentFileInfo64(reader->archive, &info, name, sizeof(name), NULL, 0, NULL, 0) != UNZ_OK ||
        info.size_filename >= sizeof(name) || info.size_filename != strlen(path) ||
        memcmp(name, path, info.size_filename) != 0 || info.uncompressed_size != size || info.crc != crc) return -1;
    if (directory) return 0;
    if (unzOpenCurrentFile(reader->archive) != UNZ_OK) return -1;
    reader->entry_open = 1;
    return 0;
}

int XSignZipRead(void *state, void *buffer, unsigned int capacity) {
    XSignZipReader *reader = state;
    if (!reader->entry_open) return -1;
    return unzReadCurrentFile(reader->archive, buffer, capacity);
}

int XSignZipFinishEntry(void *state) {
    XSignZipReader *reader = state;
    if (!reader->entry_open) return -1;
    reader->entry_open = 0;
    return unzCloseCurrentFile(reader->archive) == UNZ_OK ? 0 : -1;
}

void XSignZipClose(void *state) {
    XSignZipReader *reader = state;
    if (reader->entry_open) unzCloseCurrentFile(reader->archive);
    unzClose(reader->archive);
    free(reader);
}

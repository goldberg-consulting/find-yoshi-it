#include "VectorMath.h"
#include <stdint.h>
#include <math.h>
#include <string.h>
double fy_packed_cosine_with_norm(const unsigned char *bytes, size_t length, const float *query, size_t dimensions, double query_norm) {
    if (!bytes || !query || length != dimensions + 12 || dimensions == 0 || dimensions > 4096 || !isfinite(query_norm) || query_norm <= 0) return -2;
    if (memcmp(bytes, "FAV1", 4) != 0) return -2;
    uint32_t dim = bytes[4] | ((uint32_t)bytes[5]<<8) | ((uint32_t)bytes[6]<<16) | ((uint32_t)bytes[7]<<24);
    if (dim != dimensions) return -2;
    float scale; memcpy(&scale, bytes+8, 4);
    if (!isfinite(scale) || scale <= 0 || scale > 1) return -2;
    const int8_t *values = (const int8_t *)(bytes + 12);
    float dot = 0;
    int32_t squared = 0, invalid = 0;
    #pragma clang loop vectorize(enable) interleave(enable)
    for (size_t i=0; i<dimensions; ++i) {
        int32_t value = values[i];
        invalid |= value == INT8_MIN;
        dot += value * query[i];
        squared += value * value;
    }
    return !invalid && squared > 0 && isfinite(dot) ? dot / (sqrt((double)squared) * query_norm) : -2;
}

double fy_packed_cosine(const unsigned char *bytes, size_t length, const float *query, size_t dimensions) {
    if (!query || dimensions > 4096) return -2;
    double squared = 0;
    for (size_t i=0; i<dimensions; ++i) squared += (double)query[i] * query[i];
    return fy_packed_cosine_with_norm(bytes, length, query, dimensions, sqrt(squared));
}

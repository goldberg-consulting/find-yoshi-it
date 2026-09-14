#ifndef FY_VECTOR_MATH_H
#define FY_VECTOR_MATH_H
#include <stddef.h>
// Cosine against the versioned int8 representation, without allocating decoded vectors.
double fy_packed_cosine(const unsigned char *bytes, size_t length, const float *query, size_t dimensions);
double fy_packed_cosine_with_norm(const unsigned char *bytes, size_t length, const float *query, size_t dimensions, double query_norm);
#endif

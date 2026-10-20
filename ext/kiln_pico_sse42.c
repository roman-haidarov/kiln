#if defined(__x86_64__) && defined(KILN_OPTIMIZED) && !defined(KILN_GENERIC)
#define phr_parse_request             kiln_phr_parse_request_sse42
#define phr_parse_response            kiln_phr_parse_response_sse42
#define phr_parse_headers             kiln_phr_parse_headers_sse42
#define phr_decode_chunked            kiln_phr_decode_chunked_sse42
#define phr_decode_chunked_is_in_data kiln_phr_decode_chunked_is_in_data_sse42
#include "picohttpparser/picohttpparser.c"
#endif

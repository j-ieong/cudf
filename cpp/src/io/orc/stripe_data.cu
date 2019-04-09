/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "orc_common.h"
#include "orc_gpu.h"

#if (__CUDACC_VER_MAJOR__ >= 9)
#define SHFL0(v)        __shfl_sync(~0, v, 0)
#define SHFL(v, t)      __shfl_sync(~0, v, t)
#define SHFL_XOR(v, m)  __shfl_xor_sync(~0, v, m)
#define SYNCWARP()      __syncwarp()
#define BALLOT(v)       __ballot_sync(~0, v)
#else
#define SHFL0(v)        __shfl(v, 0)
#define SHFL(v, t)      __shfl(v, t)
#define SHFL_XOR(v, m)  __shfl_xor(v, m)
#define SYNCWARP()
#define BALLOT(v)       __ballot(v)
#endif

#define LOG2_BYTESTREAM_BFRSZ   13  // Must be able to handle 512x 8-byte values

#define BYTESTREAM_BFRSZ        (1 << LOG2_BYTESTREAM_BFRSZ)
#define LOG2_NWARPS             5   // Log2 of number of warps per threadblock
#define LOG2_NTHREADS           (LOG2_NWARPS+5)
#define NWARPS                  (1 << LOG2_NWARPS)
#define NTHREADS                (1 << LOG2_NTHREADS)

#define IS_RLEv1(encoding_mode)         ((encoding_mode) < DIRECT_V2)
#define IS_RLEv2(encoding_mode)         ((encoding_mode) >= DIRECT_V2)
#define IS_DICTIONARY(encoding_mode)    ((encoding_mode) & 1)

namespace orc { namespace gpu {

struct orc_bytestream_s
{
    const uint8_t *base;
    uint32_t pos;
    uint32_t len;
    union {
        uint8_t u8[BYTESTREAM_BFRSZ];
        uint32_t u32[BYTESTREAM_BFRSZ >> 2];
        uint2 u64[BYTESTREAM_BFRSZ >> 3];
    } buf;
};

struct orc_rlev1_state_s
{
    uint32_t num_runs;
    uint32_t num_vals;
    uint32_t fill_pos;
    uint32_t fill_count;
    int32_t run_data[NWARPS*12];    // (delta << 24) | (count << 16) | (first_val)
};

struct orc_rlev2_state_s
{
    uint32_t num_runs;
    uint32_t num_vals;
    uint32_t fill_pos;
    uint32_t fill_count;

    int dbg;

    union {
        uint32_t u32[NWARPS];
        uint64_t u64[NWARPS];
    } baseval;
    uint16_t m2_pw_byte3[NWARPS];
    union {
        int32_t i32[NWARPS];
        int64_t i64[NWARPS];
    } delta;
    uint16_t runs_loc[NTHREADS];
};

struct orc_byterle_state_s
{
    uint32_t num_runs;
    uint32_t num_vals;
    uint32_t fill_pos;
    uint32_t fill_count;
    uint32_t runs_loc[NWARPS];
    uint32_t runs_pos[NWARPS];
};

struct orc_strdict_state_s
{
    uint2 *local_dict;
    uint32_t dict_pos;
    uint32_t dict_len;
};

struct orc_nulldec_state_s
{
    uint32_t row;
    uint32_t null_count[NWARPS];
};

struct orc_datadec_state_s
{
    uint32_t cur_row;                   // starting row of current batch
    uint32_t end_row;                   // ending row of this chunk (start_row + num_rows)
    uint32_t max_vals;                  // max # of non-zero values to decode in this batch
    uint32_t nrows;                     // # of rows in current batch (up to NTHREADS)
    uint32_t buffered_count;            // number of buffered values in the secondary data stream
    uint32_t buffered_pos;              // position of buffered values in the secondary data stream
    uint16_t row_ofs_plus1[NTHREADS*2]; // 0=skip, >0: row position relative to cur_row
};


struct orcdec_state_s
{
    ColumnDesc chunk;
    orc_bytestream_s bs;
    orc_bytestream_s bs2;
    union {
        orc_strdict_state_s dict;
        orc_nulldec_state_s nulls;
        orc_datadec_state_s data;
    } top;
    union {
        orc_rlev1_state_s rlev1;
        orc_rlev2_state_s rlev2;
        orc_byterle_state_s rle8;
    } u;
    union {
        uint8_t u8[NTHREADS * 8];
        uint32_t u32[NTHREADS * 2];
        int32_t i32[NTHREADS * 2];
        uint64_t u64[NTHREADS];
        int64_t i64[NTHREADS];
    } vals;
};


// Initializes byte stream, modifying length and start position to keep the read pointer 8-byte aligned
// Assumes that the address range [start_address & ~7, (start_address + len - 1) | 7] is valid
static __device__ void bytestream_init(volatile orc_bytestream_s *bs, const uint8_t *base, uint32_t len)
{
    uint32_t pos = static_cast<uint32_t>(7 & reinterpret_cast<size_t>(base));
    bs->base = base - pos;
    bs->pos = (len > 0) ? pos : 0;
    bs->len = (len + pos + 7) & ~7;
}

// Increment the read position, returns number of 64-bit slots to fill
static __device__ uint32_t bytestream_flush_bytes(volatile orc_bytestream_s *bs, uint32_t bytes_consumed)
{
    uint32_t pos = bs->pos;
    uint32_t pos_new = min(pos + bytes_consumed, bs->len);
    bs->pos = pos_new;
    return (pos_new >> 3) - (pos >> 3);
}

// Fill byte buffer
static __device__ void bytestream_fill(orc_bytestream_s *bs, uint32_t pos, uint32_t count, int t)
{
    if ((uint32_t)t < count)
    {
        int pos8 = (pos >> 3) + t;
        bs->buf.u64[pos8 & ((BYTESTREAM_BFRSZ >> 3) - 1)] = (reinterpret_cast<const uint2 *>(bs->base))[pos8];
    }
}

// Initial buffer fill
static __device__ void bytestream_initbuf(orc_bytestream_s *bs, int t)
{
    bytestream_fill(bs, 0, min(bs->len, BYTESTREAM_BFRSZ) >> 3, t);
}

inline __device__ uint8_t bytestream_readbyte(volatile orc_bytestream_s *bs, int pos)
{
    return bs->buf.u8[pos & (BYTESTREAM_BFRSZ - 1)];
}

inline __device__ uint32_t bytestream_readu32(volatile orc_bytestream_s *bs, int pos)
{
    uint32_t a = bs->buf.u32[(pos & (BYTESTREAM_BFRSZ - 1)) >> 2];
    uint32_t b = bs->buf.u32[((pos + 4) & (BYTESTREAM_BFRSZ - 1)) >> 2];
    return __funnelshift_r(a, b, (pos & 3) * 8);
}

inline __device__ uint64_t bytestream_readu64(volatile orc_bytestream_s *bs, int pos)
{
    uint32_t a = bs->buf.u32[(pos & (BYTESTREAM_BFRSZ - 1)) >> 2];
    uint32_t b = bs->buf.u32[((pos + 4) & (BYTESTREAM_BFRSZ - 1)) >> 2];
    uint32_t c = bs->buf.u32[((pos + 8) & (BYTESTREAM_BFRSZ - 1)) >> 2];
    uint32_t lo32 = __funnelshift_r(a, b, (pos & 3) * 8);
    uint32_t hi32 = __funnelshift_r(b, c, (pos & 3) * 8);
    uint64_t v = hi32;
    v <<= 32;
    v |= lo32;
    return v;
}

inline __device__ void bytestream_readbe(volatile orc_bytestream_s *bs, int bitpos, uint32_t numbits, uint32_t &result)
{
    uint32_t a = __byte_perm(bs->buf.u32[(bitpos & ((BYTESTREAM_BFRSZ - 1) * 8)) >> 5], 0, 0x0123);
    uint32_t b = __byte_perm(bs->buf.u32[((bitpos + 32) & ((BYTESTREAM_BFRSZ - 1) * 8)) >> 5], 0, 0x0123);
    result = __funnelshift_l(b, a, bitpos & 0x1f) >> (32 - numbits);
}

inline __device__ void bytestream_readbe(volatile orc_bytestream_s *bs, int bitpos, uint32_t numbits, int32_t &result)
{
    uint32_t u;
    bytestream_readbe(bs, bitpos, numbits, u);
    result = (int32_t)((u >> 1u) ^ -(int32_t)(u & 1));
}

inline __device__ void bytestream_readbe(volatile orc_bytestream_s *bs, int bitpos, uint32_t numbits, uint64_t &result)
{
    uint32_t a = __byte_perm(bs->buf.u32[(bitpos & ((BYTESTREAM_BFRSZ - 1)*8)) >> 5], 0, 0x0123);
    uint32_t b = __byte_perm(bs->buf.u32[((bitpos + 32) & ((BYTESTREAM_BFRSZ - 1) * 8)) >> 5], 0, 0x0123);
    uint32_t c = __byte_perm(bs->buf.u32[((bitpos + 64) & ((BYTESTREAM_BFRSZ - 1) * 8)) >> 5], 0, 0x0123);
    uint32_t hi32 = __funnelshift_l(b, a, bitpos & 0x1f);
    uint32_t lo32 = __funnelshift_l(c, b, bitpos & 0x1f);
    uint64_t v = hi32;
    v <<= 32;
    v |= lo32;
    v >>= (64 - numbits);
    result = v;
}

inline __device__ void bytestream_readbe(volatile orc_bytestream_s *bs, int bitpos, uint32_t numbits, int64_t &result)
{
    uint64_t u;
    bytestream_readbe(bs, bitpos, numbits, u);
    result = (int64_t)((u >> 1u) ^ -(int64_t)(u & 1));
}

inline __device__ uint32_t bytestream_readbits(volatile orc_bytestream_s *bs, int bitpos, uint32_t numbits)
{
    uint32_t a = __byte_perm(bs->buf.u32[(bitpos & ((BYTESTREAM_BFRSZ - 1)*8)) >> 5], 0, 0x0123);
    uint32_t b = __byte_perm(bs->buf.u32[((bitpos + 32) & ((BYTESTREAM_BFRSZ - 1)*8)) >> 5], 0, 0x0123);
    return __funnelshift_l(b, a, bitpos & 0x1f) >> (32 - numbits);
}

inline __device__ uint64_t bytestream_readbits64(volatile orc_bytestream_s *bs, int bitpos, uint32_t numbits)
{
    uint32_t a = __byte_perm(bs->buf.u32[(bitpos & ((BYTESTREAM_BFRSZ - 1) * 8)) >> 5], 0, 0x0123);
    uint32_t b = __byte_perm(bs->buf.u32[((bitpos + 32) & ((BYTESTREAM_BFRSZ - 1) * 8)) >> 5], 0, 0x0123);
    uint32_t c = __byte_perm(bs->buf.u32[((bitpos + 64) & ((BYTESTREAM_BFRSZ - 1) * 8)) >> 5], 0, 0x0123);
    uint32_t hi32 = __funnelshift_l(b, a, bitpos & 0x1f);
    uint32_t lo32 = __funnelshift_l(c, b, bitpos & 0x1f);
    uint64_t v = hi32;
    v <<= 32;
    v |= lo32;
    v >>= (64 - numbits);
    return v;
}


/**
 * @brief Return the length of a base-128 varint
 *
 * @param[in] bs Byte stream input
 * @param[in] pos Position in circular byte stream buffer
 * @return length of varint in bytes
 **/
template <class T>
inline __device__ uint32_t varint_length(volatile orc_bytestream_s *bs, int pos)
{
    if (bytestream_readbyte(bs, pos) > 0x7f)
    {
        uint32_t next32 = bytestream_readu32(bs, pos);
        uint32_t len = 1 + (__ffs((~next32) & 0x80808080) >> 3);
        if (sizeof(T) > 4 && len == 5)
        {
            next32 = bytestream_readu32(bs, pos + 4);
            len += __ffs((~next32) & 0x80808080) >> 3;
        }
        return len;
    }
    else
    {
        return 1;
    }
}

/**
 * @brief Decodes a base-128 varint
 *
 * @param[in] bs Byte stream input
 * @param[in] pos Position in circular byte stream buffer
 * @param[in] result Unpacked value
 * @return new position in byte stream buffer
 **/
template <class T>
inline __device__ int decode_varint(volatile orc_bytestream_s *bs, int pos, T &result)
{
    uint32_t v = bytestream_readbyte(bs, pos++);
    if (v > 0x7f)
    {
        uint32_t b = bytestream_readbyte(bs, pos++);
        v = (v & 0x7f) | (b << 7);
        if (b > 0x7f)
        {
            b = bytestream_readbyte(bs, pos++);
            v = (v & 0x3fff) | (b << 14);
            if (b > 0x7f)
            {
                b = bytestream_readbyte(bs, pos++);
                v = (v & 0x1fffff) | (b << 21);
                if (b > 0x7f)
                {
                    b = bytestream_readbyte(bs, pos++);
                    v = (v & 0x0fffffff) | (b << 28);
                    if (sizeof(T) > 4 && b > 0x7f)
                    {
                        uint32_t lo = v;
                        uint64_t hi;
                        v = (b >> 4) & 7;
                        b = bytestream_readbyte(bs, pos++);
                        v |= b << 3;
                        if (b > 0x7f)
                        {
                            b = bytestream_readbyte(bs, pos++);
                            v = (v & 0x3ff) | (b << 10);
                            if (b > 0x7f)
                            {
                                b = bytestream_readbyte(bs, pos++);
                                v = (v & 0x1ffff) | (b << 17);
                                if (b > 0x7f)
                                {
                                    b = bytestream_readbyte(bs, pos++);
                                    v = (v & 0xffffff) | (b << 24);
                                    if (b > 0x7f)
                                    {
                                        pos++; // last bit is redundant (extra byte implies bit63 is 1)
                                    }
                                }
                            }
                        }
                        hi = v;
                        hi <<= 32;
                        result = hi | lo;
                        return pos;
                    }
                }
            }
        }
    }
    result = v;
    return pos;
}


/**
 * @brief Signed version of 32-bit decode_varint
 **/
inline __device__ int decode_varint(volatile orc_bytestream_s *bs, int pos, int32_t &result)
{
    uint32_t u;
    pos = decode_varint<uint32_t>(bs, pos, u);
    result = (int32_t)((u >> 1u) ^ -(int32_t)(u & 1));
    return pos;
}

/**
* @brief Signed version of 64-bit decode_varint
**/
inline __device__ int decode_varint(volatile orc_bytestream_s *bs, int pos, int64_t &result)
{
    uint64_t u;
    pos = decode_varint<uint64_t>(bs, pos, u);
    result = (int64_t)((u >> 1u) ^ -(int64_t)(u & 1));
    return pos;
}


// Convert lengths into positions
template<class T>
inline __device__ void lengths_to_positions(volatile T *vals, uint32_t numvals, unsigned int t)
{
    for (uint32_t n = 1; n<numvals; n <<= 1)
    {
        __syncthreads();
        if ((t & n) && (t < numvals))
            vals[t] += vals[(t & ~n) | (n - 1)];
    }
}


// Integer RLEv1 for 32-bit values
template <class T>
static __device__ uint32_t Integer_RLEv1(orc_bytestream_s *bs, volatile orc_rlev1_state_s *rle, volatile T *vals, uint32_t maxvals, int t)
{
    uint32_t numvals, numruns;
    if (t == 0)
    {
        uint32_t maxpos = min(bs->len, bs->pos + (BYTESTREAM_BFRSZ - 8u));
        uint32_t lastpos = bs->pos;
        rle->fill_pos = lastpos;
        numvals = numruns = 0;
        // Find the length and start location of each run
        while (numvals < maxvals &&  numruns < NWARPS*12)
        {
            uint32_t pos = lastpos;
            uint32_t n = bytestream_readbyte(bs, pos++);
            if (n <= 0x7f)
            {
                // Run
                int32_t delta;
                n = n + 3;
                if (numvals + n > maxvals)
                    break;
                delta = bytestream_readbyte(bs, pos++);
                vals[numvals] = pos & 0xffff;
                pos += varint_length<T>(bs, pos);
                if (pos > maxpos)
                    break;
                rle->run_data[numruns++] = (delta << 24) | (n << 16) | numvals;
                numvals += n;
            }
            else
            {
                // Literals
                uint32_t i;
                n = 0x100 - n;
                if (numvals + n > maxvals)
                    break;
                i = 0;
                do
                {
                    vals[numvals + i] = pos & 0xffff;
                    pos += varint_length<T>(bs, pos);
                } while (++i < n);
                if (pos > maxpos)
                    break;
                numvals += n;
            }
            lastpos = pos;
        }
        rle->num_runs = numruns;
        rle->num_vals = numvals;
        rle->fill_count = bytestream_flush_bytes(bs, lastpos - bs->pos);
    }
    __syncthreads();
    // Expand the runs
    numruns = rle->num_runs;
    if (numruns > 0)
    {
        int r = t >> 5;
        int tr = t & 0x1f;
        for (uint32_t run = r; run < numruns; run += NWARPS)
        {
            int32_t run_data = rle->run_data[run];
            int n = (run_data >> 16) & 0xff;
            int delta = run_data >> 24;
            uint32_t base = run_data & 0x3ff;
            uint32_t pos = vals[base] & 0xffff;
            for (int i = 1+tr; i < n; i += 32)
            {
                vals[base + i] = ((delta * i) << 16) | pos;
            }
        }
        __syncthreads();
    }
    numvals = rle->num_vals;
    // Decode individual 32-bit varints
    if (t < numvals)
    {
        int32_t pos = vals[t];
        int32_t delta = pos >> 16;
        T v;
        decode_varint(bs, pos, v);
        vals[t] = v + delta;
    }
    __syncthreads();
    // Refill the byte stream buffer
    bytestream_fill(bs, rle->fill_pos, rle->fill_count, t);
    __syncthreads();
    return numvals;
}


// Maps the 5-bit code to 6-bit length
static const __device__ __constant__ uint8_t kRLEv2_W[32] =
{
    1,2,3,4,        5,6,7,8,        9,10,11,12,     13,14,15,16,
    17,18,19,20,    21,22,23,24,    26,28,30,32,    40,48,56,64
};

// Integer RLEv2 for 32-bit values
template <class T>
static __device__ uint32_t Integer_RLEv2(orc_bytestream_s *bs, volatile orc_rlev2_state_s *rle, volatile T *vals, uint32_t maxvals, int t)
{
    uint32_t numvals, numruns;
    int r, tr;

    if (t == 0)
    {
        uint32_t maxpos = min(bs->len, bs->pos + (BYTESTREAM_BFRSZ - 8u));
        uint32_t lastpos = bs->pos;
        rle->fill_pos = lastpos;
        numvals = numruns = 0;
        // Find the length and start location of each run
        while (numvals < maxvals)
        {
            uint32_t pos = lastpos;
            uint32_t byte0 = bytestream_readbyte(bs, pos++);
            uint32_t n, l;
            int mode = byte0 >> 6;
            rle->runs_loc[numruns] = numvals;
            vals[numvals] = lastpos;           
            if (mode == 0)
            {
                // 00lllnnn: short repeat encoding
                l = 1 + ((byte0 >> 3) & 7); // 1 to 8 bytes
                n = 3 + (byte0 & 7); // 3 to 10 values
            }
            else
            {
                l = kRLEv2_W[(byte0 >> 1) & 0x1f];
                n = 1 + ((byte0 & 1) << 8) + bytestream_readbyte(bs, pos++);
                if (mode == 1)
                {
                    // 01wwwwwn.nnnnnnnn: direct encoding
                    l = (l * n + 7) >> 3;
                }
                else if (mode == 2)
                {
                    // 10wwwwwn.nnnnnnnn.xxxxxxxx.yyyyyyyy: patched base encoding
                    uint32_t byte2 = bytestream_readbyte(bs, pos++);
                    uint32_t byte3 = bytestream_readbyte(bs, pos++);
                    uint32_t bw = 1 + (byte2 >> 5); // base value width, 1 to 8 bytes
                    uint32_t pw = kRLEv2_W[byte2 & 0x1f]; // patch width, 1 to 64 bits
                    uint32_t pgw = 1 + (byte3 >> 5); // patch gap width, 1 to 8 bits
                    uint32_t pll = byte3 & 0x1f;    // patch list length
                    l = (l * n + 7) >> 3;
                    l += bw;
                    l += (pll * (pgw + pw) + 7) >> 3;
                }
                else
                {
                    // 11wwwwwn.nnnnnnnn.<base>.<delta>: delta encoding
                    uint32_t deltapos = varint_length<T>(bs, pos);
                    deltapos += varint_length<T>(bs, pos + deltapos);
                    l = (l > 1) ? (l * n + 7) >> 3 : 0;
                    l += deltapos;
                }
            }
            if (numvals + n > maxvals)
                break;
            pos += l;
            if (pos > maxpos)
                break;
            lastpos = pos;
            numvals += n;
            numruns++;
        }
        rle->num_vals = numvals;
        rle->num_runs = numruns;
        rle->fill_count = bytestream_flush_bytes(bs, lastpos - bs->pos);
    }
    __syncthreads();
    // Process the runs, 1 warp per run
    numruns = rle->num_runs;
    r = t >> 5;
    tr = t & 0x1f;
    for (uint32_t run = r; run < numruns; run += NWARPS)
    {
        uint32_t base, pos, w, n;
        int mode;
        if (tr == 0)
        {
            uint32_t byte0;
            base = rle->runs_loc[run];
            pos = vals[base];
            byte0 = bytestream_readbyte(bs, pos++);
            mode = byte0 >> 6;
            if (mode == 0)
            {
                T baseval;
                // 00lllnnn: short repeat encoding
                w = 8 + (byte0 & 0x38); // 8 to 64 bits
                n = 3 + (byte0 & 7); // 3 to 10 values
                bytestream_readbe(bs, pos*8, w, baseval);
                if (sizeof(T) <= 4)
                {
                    rle->baseval.u32[r] = baseval;
                }
                else
                {
                    rle->baseval.u64[r] = baseval;
                }
            }
            else
            {
                w = kRLEv2_W[(byte0 >> 1) & 0x1f];
                n = 1 + ((byte0 & 1) << 8) + bytestream_readbyte(bs, pos++);
                if (mode > 1)
                {
                    if (mode == 2)
                    {
                        // Patched base
                        uint32_t byte2 = bytestream_readbyte(bs, pos++);
                        uint32_t byte3 = bytestream_readbyte(bs, pos++);
                        uint32_t bw = 1 + (byte2 >> 5); // base value width, 1 to 8 bytes
                        uint32_t pw = kRLEv2_W[byte2 & 0x1f]; // patch width, 1 to 64 bits
                        if (sizeof(T) <= 4)
                        {
                            uint32_t baseval, mask;
                            bytestream_readbe(bs, pos * 8, bw * 8, baseval);
                            mask = (1 << (bw*8-1)) - 1;
                            rle->baseval.u32[r] = (baseval > mask) ? (-(int32_t)(baseval & mask)) : baseval;
                        }
                        else
                        {
                            uint64_t baseval, mask;
                            bytestream_readbe(bs, pos * 8, bw * 8, baseval);
                            mask = 2;
                            mask <<= (bw*8) - 1;
                            mask -= 1;
                            rle->baseval.u64[r] = (baseval > mask) ? (-(int64_t)(baseval & mask)) : baseval;
                        }
                        rle->m2_pw_byte3[r] = (pw << 8) | byte3;
                        pos += bw;
                    }
                    else
                    {
                        T baseval;
                        // Delta
                        pos = decode_varint<T>(bs, pos, baseval);
                        if (sizeof(T) <= 4)
                        {
                            rle->baseval.u32[r] = baseval;
                            pos = decode_varint(bs, pos, rle->delta.i32[r]);
                        }
                        else
                        {
                            rle->baseval.u64[r] = baseval;
                            pos = decode_varint(bs, pos, rle->delta.i64[r]);
                        }
                    }
                }
            }
        }
        base = SHFL0(base);
        mode = SHFL0(mode);
        pos = SHFL0(pos);
        n = SHFL0(n);
        w = SHFL0(w);
        for (uint32_t i = tr; i < n; i += 32)
        {
            if (sizeof(T) <= 4)
            {
                if (mode == 0)
                {
                    vals[base + i] = rle->baseval.u32[r];
                }
                else if (mode == 1)
                {
                    T v;
                    bytestream_readbe(bs, pos * 8 + i*w, w, v);
                    vals[base + i] = v;
                }
                else if (mode == 2)
                {
                    uint32_t ofs = bytestream_readbits(bs, pos * 8 + i*w, w);
                    vals[base + i] = rle->baseval.u32[r] + ofs;
                }
                else
                {
                    int32_t delta = rle->delta.i32[r];
                    uint32_t ofs = (i >= 2) ? ((w > 1) ? bytestream_readbits(bs, pos * 8 + (i - 2)*w, w) : 0) : (i == 1) ? abs(delta) : 0;
                    vals[base + i] = (delta < 0) ? -ofs : ofs;
                }
            }
            else
            {
                if (mode == 0)
                {
                    vals[base + i] = rle->baseval.u64[r];
                }
                else if (mode == 1)
                {
                    T v;
                    bytestream_readbe(bs, pos * 8 + i*w, w, v);
                    vals[base + i] = v;
                }
                else if (mode == 2)
                {
                    uint32_t ofs = bytestream_readbits64(bs, pos * 8 + i*w, w);
                    vals[base + i] = rle->baseval.u64[r] + ofs;
                }
                else
                {
                    int64_t delta = rle->delta.i64[r];
                    uint64_t ofs = (i >= 2) ? ((w > 1) ? bytestream_readbits64(bs, pos * 8 + (i - 2)*w, w) : 0) : (i == 1) ? llabs(delta) : 0;
                    vals[base + i] = (delta < 0) ? -ofs : ofs;
                }
            }
        }
        SYNCWARP();
        // Patch values
        if (mode == 2)
        {
            uint32_t pw_byte3 = rle->m2_pw_byte3[r];
            uint32_t pw = pw_byte3 >> 8;
            uint32_t pgw = 1 + ((pw_byte3 >> 5) & 7); // patch gap width, 1 to 8 bits
            uint32_t pll = pw_byte3 & 0x1f;    // patch list length
            uint32_t patch_pos = (tr < pll) ? bytestream_readbits(bs, pos * 8 + n*w, pgw+pw) + 1 : 0; // FIXME: pgw+pw > 32
            uint32_t patch = patch_pos & ((1 << pw) - 1);
            patch_pos >>= pw;
            for (uint32_t k = 1; k < pll; k <<= 1)
            {
                uint32_t tmp = SHFL(patch_pos, (tr & ~k) | (k-1));
                patch_pos += (tr & k) ? tmp : 0;
            }
            if (tr < pll && patch_pos < n)
            {
                vals[base + patch_pos] += patch << w;
            }
        }
        SYNCWARP();
        if (mode == 3)
        {
            T baseval;
            for (uint32_t i = 1; i < n; i <<= 1)
            {
                SYNCWARP();
                for (uint32_t j = tr; j < n; j += 32)
                {
                    if (j & i)
                        vals[base + j] += vals[base + ((j & ~i) | (i - 1))];
                }
            }
            if (sizeof(T) <= 4)
                baseval = rle->baseval.u32[r];
            else
                baseval = rle->baseval.u64[r];
            for (uint32_t j = tr; j < n; j += 32)
            {
                vals[base + j] += baseval;
            }
        }
    }
    __syncthreads();
    // Refill the byte stream buffer
    bytestream_fill(bs, rle->fill_pos, rle->fill_count, t);
    __syncthreads();
    return rle->num_vals;
}


inline __device__ uint32_t rle8_read_u32(volatile uint32_t *vals, uint32_t bitpos)
{
    uint32_t a = vals[(bitpos >> 5) + 0];
    uint32_t b = vals[(bitpos >> 5) + 1];
    return __funnelshift_r(a, b, bitpos & 0x1f);
}

// Integer RLEv1 for 32-bit values
static __device__ uint32_t Byte_RLE(orc_bytestream_s *bs, volatile orc_byterle_state_s *rle, volatile uint8_t *vals, uint32_t maxvals, int t)
{
    uint32_t numvals, numruns;
    int r, tr;
    if (t == 0)
    {
        uint32_t maxpos = min(bs->len, bs->pos + (BYTESTREAM_BFRSZ - 8u));
        uint32_t lastpos = bs->pos;
        rle->fill_pos = lastpos;
        numvals = numruns = 0;
        // Find the length and start location of each run
        while (numvals < maxvals && numruns < NWARPS)
        {
            uint32_t pos = lastpos, n;
            rle->runs_pos[numruns] = pos;
            rle->runs_loc[numruns] = numvals;
            n = bytestream_readbyte(bs, pos++);
            if (n <= 0x7f)
            {
                // Run
                n = n + 3;
                pos++;
            }
            else
            {
                // Literals
                n = 0x100 - n;
                pos += n;
            }
            if (pos > maxpos || numvals + n > maxvals)
                break;
            numruns++;
            numvals += n;
            lastpos = pos;
        }
        rle->num_runs = numruns;
        rle->num_vals = numvals;
        rle->fill_count = bytestream_flush_bytes(bs, lastpos - bs->pos);
    }
    __syncthreads();
    numruns = rle->num_runs;
    r = t >> 5;
    tr = t & 0x1f;
    for (int run = r; run < numruns; run += NWARPS)
    {
        uint32_t pos = rle->runs_pos[run];
        uint32_t loc = rle->runs_loc[run];
        uint32_t n = bytestream_readbyte(bs, pos++);
        uint32_t literal_mask;
        if (n <= 0x7f)
        {
            literal_mask = 0;
            n += 3;
        }
        else
        {
            literal_mask = ~0;
            n = 0x100 - n;
        }
        for (uint32_t i = tr; i < n; i += 32)
        {
            vals[loc + i] = bytestream_readbyte(bs, pos + (i & literal_mask));
        }
    }
    __syncthreads();
    // Refill the byte stream buffer
    bytestream_fill(bs, rle->fill_pos, rle->fill_count, t);
    __syncthreads();
    return rle->num_vals;
}


// blockDim {NTHREADS,1,1}
extern "C" __global__ void __launch_bounds__(NTHREADS)
gpuDecodeNullsAndStringDictionaries(ColumnDesc *chunks, DictionaryEntry *global_dictionary, uint32_t num_columns, uint32_t num_stripes, size_t max_num_rows, size_t first_row)
{
    __shared__ __align__(16) orcdec_state_s state_g;
    
    orcdec_state_s * const s = &state_g;
    bool is_nulldec = (blockIdx.y >= num_stripes);
    uint32_t column = blockIdx.x;
    uint32_t stripe = (is_nulldec) ? blockIdx.y - num_stripes : blockIdx.y;
    uint32_t chunk_id = stripe * num_columns + column;
    int t = threadIdx.x;
    
    if (t < sizeof(ColumnDesc) / sizeof(uint32_t))
    {
        ((volatile uint32_t *)&s->chunk)[t] = ((const uint32_t *)&chunks[chunk_id])[t];
    }
    __syncthreads();
    if (is_nulldec)
    {
        uint32_t null_count = 0;
        // Decode NULLs
        if (t == 0)
        {
            s->top.nulls.row = 0;
            if (s->chunk.strm_len[CI_PRESENT] > 0)
            {
                bytestream_init(&s->bs, s->chunk.streams[CI_PRESENT], s->chunk.strm_len[CI_PRESENT]);
            }
        }
        __syncthreads();
        if (s->chunk.strm_len[CI_PRESENT] > 0)
        {
            bytestream_initbuf(&s->bs, t);
        }
        else
        {
            // No present stream: all rows are valid
            s->vals.u32[t] = ~0;
        }
        while (s->top.nulls.row < s->chunk.num_rows)
        {
            uint32_t nrows_max = min(s->chunk.num_rows - s->top.nulls.row, NTHREADS*32);
            uint32_t nrows;
            size_t row_in;
            __syncthreads();
            if (s->chunk.strm_len[CI_PRESENT] > 0)
            {
                uint32_t nbytes = Byte_RLE(&s->bs, &s->u.rle8, s->vals.u8, (nrows_max + 7) >> 3, t);
                nrows = min(nrows_max, nbytes * 8u);
                if (!nrows)
                {
                    // Error: mark all remaining rows as null
                    nrows = nrows_max;
                    if (t * 32 < nrows)
                    {
                        s->vals.u32[t] = 0;
                    }
                }
            }
            else
            {
                nrows = nrows_max;
            }
            __syncthreads();
            row_in = s->chunk.start_row + s->top.nulls.row;
            if (row_in + nrows > first_row && row_in < first_row + max_num_rows && s->chunk.valid_map_base != NULL)
            {
                int64_t dst_row = row_in - first_row;
                int64_t dst_pos = max(dst_row, (int64_t)0);
                uint32_t startbit = -static_cast<int32_t>(min(dst_row, (int64_t)0));
                uint32_t nbits = nrows - min(startbit, nrows);
                uint32_t *valid = s->chunk.valid_map_base + (dst_pos >> 5);
                uint32_t bitpos = static_cast<uint32_t>(dst_pos) & 0x1f;
                if ((size_t)(dst_pos + nbits) > max_num_rows)
                {
                    nbits = static_cast<uint32_t>(max_num_rows - min((size_t)dst_pos, max_num_rows));
                }
                // Store bits up to the next 32-bit aligned boundary
                if (bitpos != 0)
                {
                    uint32_t n = min(32u - bitpos, nbits);
                    if (t == 0)
                    {
                        uint32_t mask = ((1 << n) - 1) << bitpos;
                        uint32_t bits = (rle8_read_u32(s->vals.u32, startbit) << bitpos) & mask;
                        atomicAnd(valid, ~mask);
                        atomicOr(valid, bits);
                        null_count += __popc((~bits) & mask);
                    }
                    nbits -= n;
                    startbit += n;
                    valid++;
                }
                // Store bits aligned
                if (t * 32 + 32 <= nbits)
                {
                    uint32_t bits = rle8_read_u32(s->vals.u32, startbit + t * 32);
                    valid[t] = bits;
                    null_count += __popc(~bits);
                }
                else if (t * 32 < nbits)
                {
                    uint32_t n = nbits - t*32;
                    uint32_t mask = (1 << n) - 1;
                    uint32_t bits = rle8_read_u32(s->vals.u32, startbit + t * 32) & mask;
                    atomicAnd(valid + t, ~mask);
                    atomicOr(valid + t, bits);
                    null_count += __popc((~bits) & mask);
                }
                __syncthreads();
            }
            // We may have some valid values that are not decoded below first_row -> count these in skip_count,
            // so that subsequent kernel can infer the correct row position
            if (row_in < first_row && t < 32)
            {
                uint32_t skippedrows = min(static_cast<uint32_t>(first_row - row_in), nrows);
                uint32_t skip_count = 0;
                for (uint32_t i = 0; i < skippedrows; i += 32)
                {
                    uint32_t bits = s->vals.u32[i >> 5];
                    if (i + 32 > skippedrows)
                    {
                        bits &= (1 << (skippedrows - i)) - 1;
                    }
                    skip_count += __popc(bits);
                }
                skip_count += SHFL_XOR(skip_count, 1);
                skip_count += SHFL_XOR(skip_count, 2);
                skip_count += SHFL_XOR(skip_count, 4);
                skip_count += SHFL_XOR(skip_count, 8);
                skip_count += SHFL_XOR(skip_count, 16);
                if (t == 0)
                {
                    s->chunk.skip_count += skip_count;
                }
            }
            __syncthreads();
            if (t == 0)
            {
                s->top.nulls.row += nrows;
            }
            __syncthreads();
        }
        __syncthreads();
        // Sum up the valid counts and infer null_count
        null_count += SHFL_XOR(null_count, 1);
        null_count += SHFL_XOR(null_count, 2);
        null_count += SHFL_XOR(null_count, 4);
        null_count += SHFL_XOR(null_count, 8);
        null_count += SHFL_XOR(null_count, 16);
        if (!(t & 0x1f))
        {
            s->top.nulls.null_count[t >> 5] = null_count;
        }
        __syncthreads();
        if (t < 32)
        {
            null_count = (t < NWARPS) ? s->top.nulls.null_count[t] : 0;
            null_count += SHFL_XOR(null_count, 1);
            null_count += SHFL_XOR(null_count, 2);
            null_count += SHFL_XOR(null_count, 4);
            null_count += SHFL_XOR(null_count, 8);
            null_count += SHFL_XOR(null_count, 16);
            if (t == 0)
            {
                chunks[chunk_id].null_count = null_count;
            }
        }
    }
    else
    {
        // Decode string dictionary
        int encoding_kind = s->chunk.encoding_kind;
        if ((encoding_kind == DICTIONARY || encoding_kind == DICTIONARY_V2) && (s->chunk.dict_len > 0))
        {
            if (t == 0)
            {
                s->top.dict.dict_len = s->chunk.dict_len;
                s->top.dict.local_dict = (uint2 *)(global_dictionary + s->chunk.dictionary_start);  // Local dictionary
                s->top.dict.dict_pos = 0;
                // CI_DATA2 contains the LENGTH stream coding the length of individual dictionary entries
                bytestream_init(&s->bs, s->chunk.streams[CI_DATA2], s->chunk.strm_len[CI_DATA2]);
            }
            __syncthreads();
            bytestream_initbuf(&s->bs, t);
            while (s->top.dict.dict_len > 0)
            {
                uint32_t numvals = min(s->top.dict.dict_len, NTHREADS), len;
                volatile uint32_t *vals = s->vals.u32;
                __syncthreads();
                if (IS_RLEv1(s->chunk.encoding_kind))
                {
                    numvals = Integer_RLEv1(&s->bs, &s->u.rlev1, vals, numvals, t);
                }
                else // RLEv2
                {
                    numvals = Integer_RLEv2(&s->bs, &s->u.rlev2, vals, numvals, t);
                }
                __syncthreads();
                len = (t < numvals) ? vals[t] : 0;
                lengths_to_positions(vals, numvals, t);
                __syncthreads();
                if (numvals == 0)
                {
                    // This is an error (ran out of data)
                    numvals = min(s->top.dict.dict_len, NTHREADS);
                    vals[t] = 0;
                }
                if (t < numvals)
                {
                    uint2 dict_entry;
                    dict_entry.x = s->top.dict.dict_pos + vals[t] - len;
                    dict_entry.y = len;
                    s->top.dict.local_dict[t] = dict_entry;
                }
                __syncthreads();
                if (t == 0)
                {
                    s->top.dict.dict_pos += vals[numvals - 1];
                    s->top.dict.dict_len -= numvals;
                    s->top.dict.local_dict += numvals;
                }
                __syncthreads();
            }
        }
    }
}


/**
 * @brief Trailing zeroes Decodes column data
 *
 **/
static const __device__ __constant__ uint32_t kTimestampNanoScale[8] =
{
    1, 100, 1000, 1000, 10000, 100000, 1000000, 10000000
};

/**
 * @brief Decodes column data
 *
 * @param[in] chunks ColumnDesc device array
 * @param[in] global_dictionary Global dictionary device array
 * @param[in] max_num_rows Maximum number of rows to load
 * @param[in] first_row Crop all rows below first_row
 * @param[in] num_chunks Number of column chunks (num_columns * num_stripes)
 * @param[in] stream CUDA stream to use, default 0
 *
 **/
// blockDim {NTHREADS,1,1}
extern "C" __global__ void __launch_bounds__(NTHREADS, 1)
gpuDecodeOrcColumnData(ColumnDesc *chunks, DictionaryEntry *global_dictionary, size_t max_num_rows, size_t first_row, uint32_t num_chunks)
{
    __shared__ __align__(16) orcdec_state_s state_g;

    orcdec_state_s * const s = &state_g;
    uint32_t chunk_id = blockIdx.x;
    int t = threadIdx.x;

    if (t < sizeof(ColumnDesc) / sizeof(uint32_t))
    {
        ((volatile uint32_t *)&s->chunk)[t] = ((const uint32_t *)&chunks[chunk_id])[t];
    }
    __syncthreads();
    if (t == 0)
    {
        s->top.data.cur_row = s->chunk.start_row;
        s->top.data.end_row = s->chunk.start_row + s->chunk.num_rows;
        s->top.data.buffered_count = 0;
        s->top.data.buffered_pos = 0;
        if (s->top.data.end_row > first_row + max_num_rows)
        {
            s->top.data.end_row = static_cast<uint32_t>(first_row + max_num_rows);
        }
        if (!IS_DICTIONARY(s->chunk.encoding_kind))
        {
            s->chunk.dictionary_start = 0;
        }
        bytestream_init(&s->bs, s->chunk.streams[CI_DATA], s->chunk.strm_len[CI_DATA]);
        bytestream_init(&s->bs2, s->chunk.streams[CI_DATA2], s->chunk.strm_len[CI_DATA2]);
    }
    __syncthreads();
    bytestream_initbuf(&s->bs, t);
    if ((s->chunk.type_kind == STRING || s->chunk.type_kind == BINARY || s->chunk.type_kind == VARCHAR || s->chunk.type_kind == CHAR
     || s->chunk.type_kind == TIMESTAMP || s->chunk.type_kind == DECIMAL)
      && !IS_DICTIONARY(s->chunk.encoding_kind))
    {
        bytestream_initbuf(&s->bs2, t);
    }
    __syncthreads();
    while (s->top.data.cur_row < s->top.data.end_row)
    {
        __syncthreads();
        if (t == 0)
        {
            s->top.data.nrows = 0;
            s->top.data.max_vals = min(s->chunk.skip_count, NTHREADS);
        }
        __syncthreads();
        if (t < s->top.data.max_vals)
        {
            s->top.data.row_ofs_plus1[t] = 0; // Skipped values (below first_row)
        }
        // 1. Use the valid bits to compute non-null row positions until we get a full batch of values to decode (up to 64K rows)
        while (s->top.data.max_vals < NTHREADS && s->top.data.cur_row + s->top.data.nrows < s->top.data.end_row && s->top.data.nrows < 0xfe00)
        {
            uint32_t nrows = min(s->top.data.end_row - s->top.data.cur_row, min(0xfe00 - s->top.data.nrows, NTHREADS));
            if (s->chunk.strm_len[CI_PRESENT] > 0)
            {
                // We have a present stream
                uint32_t rmax = s->top.data.end_row - min((uint32_t)first_row, s->top.data.end_row);
                uint32_t r = (uint32_t)(s->top.data.cur_row + s->top.data.nrows + t - first_row);
                uint32_t valid = (t < nrows && r < rmax) ? (((const uint8_t *)s->chunk.valid_map_base)[r >> 3] >> (r & 7)) & 1 : 0;
                volatile uint16_t *row_ofs_plus1 = &s->top.data.row_ofs_plus1[s->top.data.max_vals];
                uint32_t nz_pos;
                if (t < nrows)
                {
                    row_ofs_plus1[t] = valid;
                }
                lengths_to_positions<uint16_t>(row_ofs_plus1, nrows, t);
                if (t == nrows - 1)
                {
                    s->top.data.max_vals += row_ofs_plus1[t];
                }
                __syncthreads();
                nz_pos = (valid) ? row_ofs_plus1[t] : 0;
                __syncthreads();
                if (valid)
                {
                    row_ofs_plus1[nz_pos - 1] = s->top.data.nrows + t;
                }
                __syncthreads();
                
                __syncthreads();
                if (t == 0)
                {
                    if (s->top.data.max_vals > NTHREADS)
                    {
                        s->top.data.max_vals = NTHREADS;
                        s->top.data.nrows = s->top.data.row_ofs_plus1[NTHREADS-1];
                    }
                    else
                    {
                        s->top.data.nrows += nrows;
                    }
                }
                __syncthreads();
            }
            else
            {
                // All values are valid
                nrows = min(nrows, NTHREADS - s->top.data.max_vals);
                if (t < nrows)
                {
                    s->top.data.row_ofs_plus1[s->top.data.max_vals + t] = s->top.data.nrows + t + 1;
                }
                __syncthreads();
                if (t == 0)
                {
                    s->top.data.nrows += nrows;
                    s->top.data.max_vals += nrows;
                }
            }
            __syncthreads();
        }
        // 2. Decode data streams
        if (s->top.data.max_vals > 0)
        {
            uint32_t numvals = s->top.data.max_vals;
            if (s->chunk.type_kind == STRING || s->chunk.type_kind == BINARY || s->chunk.type_kind == VARCHAR || s->chunk.type_kind == CHAR
             || s->chunk.type_kind == TIMESTAMP || s->chunk.type_kind == DECIMAL)
            {
                // For these data types, we have a secondary unsigned 32-bit data stream
                orc_bytestream_s *bs = &s->bs;//(IS_DICTIONARY(s->chunk.encoding_kind)) ? &s->bs : &s->bs2;
                uint32_t ofs = s->top.data.buffered_count;
                if (s->chunk.type_kind == TIMESTAMP && s->top.data.buffered_count > 0)
                {
                    // Restore buffered secondary stream values
                    uint32_t tmp = (t < ofs) ? s->vals.u32[s->top.data.buffered_pos + t] : 0;
                    __syncthreads();
                    if (t < ofs)
                    {
                        s->vals.u32[t] = tmp;
                    }
                    __syncthreads();
                }
                if (numvals > ofs)
                {
                    if (IS_RLEv1(s->chunk.encoding_kind))
                    {
                        numvals = ofs + Integer_RLEv1(bs, &s->u.rlev1, &s->vals.u32[ofs], numvals - ofs, t);
                    }
                    else
                    {
                        numvals = ofs + Integer_RLEv2(bs, &s->u.rlev2, &s->vals.u32[ofs], numvals - ofs, t);
                    }
                    __syncthreads();
                    if (numvals <= ofs && t >= ofs && t < s->top.data.max_vals)
                    {
                        s->vals.u32[t] = 0;
                    }
                }
                __syncthreads();
                // For strings with direct encoding, we need to convert the lengths into an offset
                if ((s->chunk.type_kind == STRING || s->chunk.type_kind == BINARY || s->chunk.type_kind == VARCHAR || s->chunk.type_kind == CHAR)
                 && (!IS_DICTIONARY(s->chunk.encoding_kind)))
                {
                    s->vals.u32[NTHREADS + t] = (t < numvals) ? s->vals.u32[t] : 0;
                    lengths_to_positions(&s->vals.u32[NTHREADS], numvals, t);
                    __syncthreads();
                }
            }
            __syncthreads();
            // Adjust the maximum number of values
            if (t == 0 && numvals > 0 && numvals < s->top.data.max_vals)
            {
                s->top.data.max_vals = numvals;
                s->top.data.nrows = s->top.data.row_ofs_plus1[numvals - 1];
            }
            __syncthreads();
            // Decode the primary data stream
            if (s->chunk.type_kind == INT || s->chunk.type_kind == TIMESTAMP || s->chunk.type_kind == DATE || s->chunk.type_kind == SHORT)
            {
                int ofs = (s->chunk.type_kind == TIMESTAMP) ? NTHREADS : 0;
                // Signed int32 primary data stream
                if (IS_RLEv1(s->chunk.encoding_kind))
                {
                    numvals = Integer_RLEv1(&s->bs, &s->u.rlev1, &s->vals.i32[ofs], numvals, t);
                }
                else
                {
                    numvals = Integer_RLEv2(&s->bs, &s->u.rlev2, &s->vals.i32[ofs], numvals, t);
                }
                __syncthreads();
                if (t == 0)
                {
                    uint32_t prev_buffered_count;
                    // Adjust the maximum number of values
                    if (s->chunk.type_kind == TIMESTAMP)
                    {
                        prev_buffered_count = s->top.data.buffered_count;
                        s->top.data.buffered_count = 0;
                    }
                    if (numvals > 0 && numvals < s->top.data.max_vals)
                    {
                        if (s->chunk.type_kind == TIMESTAMP)
                        {
                            // Buffer secondary stream values between numvals and s->top.data.max_vals
                            s->top.data.buffered_pos = numvals;
                            s->top.data.buffered_count = max(prev_buffered_count, s->top.data.max_vals) - numvals;
                        }
                        s->top.data.max_vals = numvals;
                        s->top.data.nrows = s->top.data.row_ofs_plus1[numvals - 1];
                    }
                }
                __syncthreads();
            }
            else if (s->chunk.type_kind == BYTE)
            {
                numvals = Byte_RLE(&s->bs, &s->u.rle8, s->vals.u8, numvals, t);
                __syncthreads();
            }
            else if (s->chunk.type_kind == BOOLEAN)
            {
                numvals = Byte_RLE(&s->bs, &s->u.rle8, s->vals.u8, (numvals + 7) >> 3, t);
                numvals = min(numvals << 3u, s->top.data.max_vals);
                __syncthreads();
            }
            else if (s->chunk.type_kind == LONG)
            {
                if (IS_RLEv1(s->chunk.encoding_kind))
                {
                    numvals = Integer_RLEv1<int64_t>(&s->bs, &s->u.rlev1, s->vals.i64, numvals, t);
                }
                else
                {
                    numvals = Integer_RLEv2<int64_t>(&s->bs, &s->u.rlev2, s->vals.i64, numvals, t);
                }
                __syncthreads();
            }
            else if (s->chunk.type_kind == FLOAT)
            {
                numvals = min(numvals, (BYTESTREAM_BFRSZ - 8u) >> 2);
                if (t < numvals)
                {
                    s->vals.u32[t] = bytestream_readu32(&s->bs, s->bs.pos + t * 4);
                }
                __syncthreads();
                if (t == 0)
                {
                    s->u.rle8.fill_pos = s->bs.pos;
                    s->u.rle8.fill_count = bytestream_flush_bytes(&s->bs, numvals * 4);
                }
                __syncthreads();
                bytestream_fill(&s->bs, s->u.rle8.fill_pos, s->u.rle8.fill_count, t);
                __syncthreads();
            }
            else if (s->chunk.type_kind == DOUBLE)
            {
                numvals = min(numvals, (BYTESTREAM_BFRSZ - 8u) >> 3);
                if (t < numvals)
                {
                    s->vals.u64[t] = bytestream_readu64(&s->bs, s->bs.pos + t * 8);
                }
                __syncthreads();
                if (t == 0)
                {
                    s->u.rle8.fill_pos = s->bs.pos;
                    s->u.rle8.fill_count = bytestream_flush_bytes(&s->bs, numvals * 8);
                }
                __syncthreads();
                bytestream_fill(&s->bs, s->u.rle8.fill_pos, s->u.rle8.fill_count, t);
                __syncthreads();
            }
            __syncthreads();
            if (t == 0 && numvals > 0 && numvals < s->top.data.max_vals)
            {
                s->top.data.max_vals = numvals;
                s->top.data.nrows = s->top.data.row_ofs_plus1[numvals - 1];
            }
            __syncthreads();
            // Store decoded values to output
            if (t < s->top.data.max_vals && s->top.data.row_ofs_plus1[t] != 0)
            {
                size_t row = s->top.data.cur_row + s->top.data.row_ofs_plus1[t] - 1 - first_row;
                if (row < max_num_rows)
                {
                    void *data_out = s->chunk.column_data_base;
                    switch (s->chunk.type_kind)
                    {
                    case FLOAT:
                    case INT:
                    case DATE:
                        reinterpret_cast<uint32_t *>(data_out)[row] = s->vals.u32[t];
                        break;
                    case DOUBLE:
                    case LONG:
                    case DECIMAL:
                        reinterpret_cast<uint64_t *>(data_out)[row] = s->vals.u64[t];
                        break;
                    case SHORT:
                        reinterpret_cast<uint16_t *>(data_out)[row] = static_cast<uint16_t>(s->vals.u32[t]);
                        break;
                    case BYTE:
                        reinterpret_cast<uint8_t *>(data_out)[row] = s->vals.u8[t];
                        break;
                    case BOOLEAN:
                        reinterpret_cast<uint8_t *>(data_out)[row] = (s->vals.u8[t >> 3] >> ((~t) & 7)) & 1;
                        break;
                    case STRING:
                    case BINARY:
                    case VARCHAR:
                    case CHAR:
                    {
                        nvstrdesc_s *strdesc = &reinterpret_cast<nvstrdesc_s *>(data_out)[row];
                        const uint8_t *ptr;
                        uint32_t count;
                        if (IS_DICTIONARY(s->chunk.encoding_kind))
                        {
                            uint32_t dict_idx = s->vals.u32[t];
                            ptr = s->chunk.streams[CI_DICTIONARY];
                            if (dict_idx < s->chunk.dict_len)
                            {
                                ptr += global_dictionary[s->chunk.dictionary_start + dict_idx].pos;
                                count = global_dictionary[s->chunk.dictionary_start + dict_idx].len;
                            }
                            else
                            {
                                count = 0;
                                ptr = (uint8_t *)0xdeadbeef;
                            }
                        }
                        else
                        {
                            uint32_t dict_idx = s->chunk.dictionary_start + s->vals.u32[NTHREADS + t] - count;
                            count = s->vals.u32[t];
                            ptr = s->chunk.streams[CI_DATA] + dict_idx;
                            if (dict_idx + count > s->chunk.strm_len[CI_DATA])
                            {
                                count = 0;
                                ptr = (uint8_t *)0xdeadbeef;
                            }
                        }
                        strdesc->ptr = reinterpret_cast<const char *>(ptr);
                        strdesc->count = count;
                        break;
                    }
                    case TIMESTAMP:
                    {
                        int64_t seconds = s->vals.u32[NTHREADS+t];
                        uint32_t nanos = s->vals.u32[t];
                        nanos = (nanos >> 7) * kTimestampNanoScale[nanos & 7];
                        reinterpret_cast<int64_t *>(data_out)[row] = seconds * 1000000000ll + nanos; // Output nanoseconds
                        break;
                    }
                    }
                }
            }
            __syncthreads();
        }
        __syncthreads();
        if (t == 0)
        {
            s->chunk.skip_count = s->chunk.skip_count - min(s->chunk.skip_count, s->top.data.max_vals);
            s->top.data.cur_row += s->top.data.nrows;
            if ((s->chunk.type_kind == STRING || s->chunk.type_kind == BINARY || s->chunk.type_kind == VARCHAR || s->chunk.type_kind == CHAR)
             && !IS_DICTIONARY(s->chunk.encoding_kind) && s->top.data.max_vals > 0)
            {
                s->chunk.dictionary_start += s->vals.u32[NTHREADS + s->top.data.max_vals - 1];
            }
            if (!s->top.data.max_vals && !s->top.data.nrows)
                break;
        }
        __syncthreads();
    }
}


cudaError_t __host__ DecodeNullsAndStringDictionaries(ColumnDesc *chunks, DictionaryEntry *global_dictionary, uint32_t num_columns, uint32_t num_stripes, size_t max_num_rows, size_t first_row, cudaStream_t stream)
{
    dim3 dim_block(NTHREADS, 1);
    dim3 dim_grid(num_columns, num_stripes * 2); // 1024 threads per chunk
    gpuDecodeNullsAndStringDictionaries <<< dim_grid, dim_block, 0, stream >>>(chunks, global_dictionary, num_columns, num_stripes, max_num_rows, first_row);
    return cudaSuccess;
}

cudaError_t __host__ DecodeOrcColumnData(ColumnDesc *chunks, DictionaryEntry *global_dictionary, uint32_t num_columns, uint32_t num_stripes, size_t max_num_rows, size_t first_row, cudaStream_t stream)
{
    uint32_t num_chunks = num_columns * num_stripes;
    dim3 dim_block(NTHREADS, 1);
    dim3 dim_grid(num_chunks, 1); // 1024 threads per chunk
    gpuDecodeOrcColumnData <<< dim_grid, dim_block, 0, stream >>>(chunks, global_dictionary, max_num_rows, first_row, num_chunks);
    return cudaSuccess;
}



};}; // orc::gpu namespace
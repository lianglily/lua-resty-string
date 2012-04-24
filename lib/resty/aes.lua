module("resty.aes", package.seeall)

_VERSION = '0.05'

--local asn1 = require "resty.asn1"
local ffi = require "ffi"
local ffi_new = ffi.new
local ffi_gc = ffi.gc
local ffi_str = ffi.string
local C = ffi.C

local mt = { __index = resty.aes }

ffi.cdef[[
typedef struct engine_st ENGINE;

typedef struct evp_cipher_st EVP_CIPHER;
typedef struct evp_cipher_ctx_st
{
const EVP_CIPHER *cipher;
ENGINE *engine;
int encrypt;
int buf_len;

unsigned char  oiv[16];
unsigned char  iv[16];
unsigned char buf[32];
int num;

void *app_data;
int key_len;
unsigned long flags;
void *cipher_data;
int final_used;
int block_mask;
unsigned char final[32];
} EVP_CIPHER_CTX;

typedef struct env_md_ctx_st EVP_MD_CTX;
typedef struct env_md_st EVP_MD;

const EVP_MD *EVP_md5(void);
const EVP_MD *EVP_sha(void);
const EVP_MD *EVP_sha1(void);
const EVP_MD *EVP_sha224(void);
const EVP_MD *EVP_sha256(void);
const EVP_MD *EVP_sha384(void);
const EVP_MD *EVP_sha512(void);

const EVP_CIPHER *EVP_aes_128_ecb(void);
const EVP_CIPHER *EVP_aes_128_cbc(void);
const EVP_CIPHER *EVP_aes_128_cfb1(void);
const EVP_CIPHER *EVP_aes_128_cfb8(void);
const EVP_CIPHER *EVP_aes_128_cfb128(void);
const EVP_CIPHER *EVP_aes_128_ofb(void);
const EVP_CIPHER *EVP_aes_128_ctr(void);
const EVP_CIPHER *EVP_aes_192_ecb(void);
const EVP_CIPHER *EVP_aes_192_cbc(void);
const EVP_CIPHER *EVP_aes_192_cfb1(void);
const EVP_CIPHER *EVP_aes_192_cfb8(void);
const EVP_CIPHER *EVP_aes_192_cfb128(void);
const EVP_CIPHER *EVP_aes_192_ofb(void);
const EVP_CIPHER *EVP_aes_192_ctr(void);
const EVP_CIPHER *EVP_aes_256_ecb(void);
const EVP_CIPHER *EVP_aes_256_cbc(void);
const EVP_CIPHER *EVP_aes_256_cfb1(void);
const EVP_CIPHER *EVP_aes_256_cfb8(void);
const EVP_CIPHER *EVP_aes_256_cfb128(void);
const EVP_CIPHER *EVP_aes_256_ofb(void);

void EVP_CIPHER_CTX_init(EVP_CIPHER_CTX *a);
int EVP_CIPHER_CTX_cleanup(EVP_CIPHER_CTX *a);
void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *a);

int EVP_EncryptInit(EVP_CIPHER_CTX *ctx,const EVP_CIPHER *cipher, const unsigned char *key, const unsigned char *iv);
int EVP_EncryptInit_ex(EVP_CIPHER_CTX *ctx,const EVP_CIPHER *cipher, ENGINE *impl, unsigned char *key, const unsigned char *iv);
int EVP_EncryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl, const unsigned char *in, int inl);
int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl);
int EVP_EncryptFinal(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl);

int EVP_DecryptInit(EVP_CIPHER_CTX *ctx,const EVP_CIPHER *cipher, unsigned char *key, const unsigned char *iv);
int EVP_DecryptInit_ex(EVP_CIPHER_CTX *ctx,const EVP_CIPHER *cipher, ENGINE *impl, unsigned char *key, const unsigned char *iv);
int EVP_DecryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl, const unsigned char *in, int inl);
int EVP_DecryptFinal(EVP_CIPHER_CTX *ctx, unsigned char *outm, int *outl);
int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *outm, int *outl);

int EVP_BytesToKey(const EVP_CIPHER *type,const EVP_MD *md, const unsigned char *salt, const unsigned char *data, int datal, int count, unsigned char *key,unsigned char *iv);
]]

local ctx_ptr_type = ffi.typeof("EVP_CIPHER_CTX[1]")

hash = {md5 = C.EVP_md5(),
  sha1 = C.EVP_sha1(),
  sha224 = C.EVP_sha224(),
  sha256 = C.EVP_sha256(),
  sha384 = C.EVP_sha512()
}

function cipher(size, _cipher)
    local _size = size or 128
    local _cipher = _cipher or "cbc"
    local func = "EVP_aes_" .. _size .. "_" .. _cipher
    if C[func] then
        return { size=_size, cipher=_cipher, method=C[func]()}
    else
        return nil
    end
end

function new(self, key, salt, _cipher, _hash, hash_rounds)
    local encrypt_ctx = ffi_new(ctx_ptr_type)
    local decrypt_ctx = ffi_new(ctx_ptr_type)
    local _cipher = _cipher or cipher()
    local _hash = _hash or hash.sha1
    local hash_rounds = hash_rounds or 5
    local _cipherLength = _cipher.size/8
    local gen_key = ffi_new("unsigned char[?]",_cipherLength)
    local gen_iv = ffi_new("unsigned char[?]",_cipherLength)

    if C.EVP_BytesToKey(_cipher.method, _hash, salt, key, #key,
      hash_rounds, gen_key, gen_iv) ~= _cipherLength then
        return nil
    end

    C.EVP_CIPHER_CTX_init(encrypt_ctx)
    C.EVP_CIPHER_CTX_init(decrypt_ctx)

    if C.EVP_EncryptInit_ex(encrypt_ctx, _cipher.method, nil,
      gen_key, gen_iv) == 0 or
      C.EVP_DecryptInit_ex(decrypt_ctx, _cipher.method, nil,
      gen_key, gen_iv) == 0 then
        return nil
    end

    ffi_gc(encrypt_ctx, C.EVP_CIPHER_CTX_cleanup)
    ffi_gc(decrypt_ctx, C.EVP_CIPHER_CTX_cleanup)

    return setmetatable({
      _encrypt_ctx = encrypt_ctx,
      _decrypt_ctx = decrypt_ctx
      }, mt)
end

function encrypt(self, s)
    local s_len = #s
    local max_len = s_len + 16
    local buf = ffi_new("unsigned char[?]", max_len)
    local out_len = ffi_new("int[1]")
    local tmp_len = ffi_new("int[1]")
    local ctx = self._encrypt_ctx

    if C.EVP_EncryptInit_ex(ctx, nil, nil, nil, nil) == 0 then
      return nil
    end

    if C.EVP_EncryptUpdate(ctx, buf, out_len, s, s_len) == 0 then
      return nil
    end

    if C.EVP_EncryptFinal_ex(ctx, buf + out_len[0], tmp_len) == 0 then
        return nil
    end

    return ffi_str(buf, out_len[0] + tmp_len[0])
end

function decrypt(self, s)
    local s_len = #s
    local buf = ffi_new("unsigned char[?]", s_len)
    local out_len = ffi_new("int[1]")
    local tmp_len = ffi_new("int[1]")
    local ctx = self._decrypt_ctx

    if C.EVP_DecryptInit_ex(ctx, nil, nil, nil, nil) == 0 then
      return nil
    end

    if C.EVP_DecryptUpdate(ctx, buf, out_len, s, s_len) == 0 then
      return nil
    end

    if C.EVP_DecryptFinal_ex(ctx, buf + out_len[0], tmp_len) == 0 then
        return nil
    end

    return ffi_str(buf, out_len[0] + tmp_len[0])
end

-- to prevent use of casual module global variables
getmetatable(resty.aes).__newindex = function (table, key, val)
    error('attempt to write to undeclared variable "' .. key .. '": '
            .. debug.traceback())
end

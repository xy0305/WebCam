#import "One15Crypto.h"
#import <CommonCrypto/CommonCryptor.h>
#import <Security/Security.h>
#import "uECC.h"
#import "lz4.h"

static const uint8_t remoteKey[56] = {0x57,0xA2,0x92,0x57,0xCD,0x23,0x20,0xE5,0xD6,0xD1,0x43,0x32,0x2F,0xA4,0xBB,0x8A,0x3C,0xF9,0xD3,0xCC,0x62,0x3E,0xF5,0xED,0xAC,0x62,0xB7,0x67,0x8A,0x89,0xC9,0x1A,0x83,0xBA,0x80,0x0D,0x61,0x29,0xF5,0x22,0xD0,0x34,0xC8,0x95,0xDD,0x24,0x65,0x24,0x3A,0xDD,0xC2,0x50,0x95,0x3B,0xEE,0xBA};
static const uint8_t crcSalt[] = "^j>WD3Kr?J2gLFjD4W2y@";
static int rng(uint8_t *dest, unsigned size) { return SecRandomCopyBytes(kSecRandomDefault, size, dest) == errSecSuccess; }
static void xorBytes(uint8_t *out, const uint8_t *a, const uint8_t *b, size_t n) { for(size_t i=0;i<n;i++) out[i]=a[i]^b[i]; }
static uint32_t crc32Local(uint32_t c, const uint8_t *p, size_t n) { c=~c; while(n--) { c^=*p++; for(int i=0;i<8;i++) c=(c>>1)^((c&1)?0xEDB88320:0); } return ~c; }

@implementation One15Crypto { uint8_t _key[16]; uint8_t _iv[16]; uint8_t _pub[30]; }
- (nullable instancetype)initWithError:(NSError **)error {
    if (!(self=[super init])) return nil;
    uECC_set_rng(rng); uint8_t pub[56], priv[28], secret[28];
    if (!uECC_make_key(pub, priv, uECC_secp224r1()) || !uECC_shared_secret(remoteKey, priv, secret, uECC_secp224r1())) { if(error)*error=[NSError errorWithDomain:@"One15" code:1 userInfo:nil]; return nil; }
    memcpy(_key,secret,16); memcpy(_iv,secret+12,16); _pub[0]=29; _pub[1]=(pub[55]&1)?3:2; memcpy(_pub+2,pub,28); return self;
}
- (NSString *)tokenForMilliseconds:(int64_t)ms error:(NSError **)error {
    uint8_t r[2]; if(!rng(r,2)){ if(error)*error=[NSError errorWithDomain:@"One15" code:2 userInfo:nil];return nil;} uint8_t b[48]; uint32_t t=(uint32_t)ms; size_t p=0;
    for(int i=0;i<15;i++)b[p++]=_pub[i]^r[0]; b[p++]=r[0];b[p++]=0x73^r[0]; for(int i=0;i<3;i++)b[p++]=r[0]; for(int i=0;i<4;i++)b[p++]=r[0]^((uint8_t*)&t)[i];
    for(int i=15;i<30;i++)b[p++]=_pub[i]^r[1]; b[p++]=r[1];b[p++]=0x01^r[1];for(int i=0;i<3;i++)b[p++]=r[1];
    uint32_t crc=crc32Local(0,crcSalt,sizeof(crcSalt)-1);crc=crc32Local(crc,b,p);for(int i=0;i<4;i++)b[p++]=(crc>>(8*i))&255;
    return [[NSData dataWithBytes:b length:p] base64EncodedStringWithOptions:0];
}
- (NSData *)encryptRequest:(NSData *)plain error:(NSError **)error {
    size_t n=((plain.length/16)+1)*16; NSMutableData *pad=[NSMutableData dataWithLength:n]; memcpy(pad.mutableBytes,plain.bytes,plain.length); memset((uint8_t*)pad.mutableBytes+plain.length,n-plain.length,n-plain.length);
    NSMutableData *out=[NSMutableData dataWithLength:n]; uint8_t prev[16];memcpy(prev,_iv,16); for(size_t i=0;i<n;i+=16){uint8_t block[16];xorBytes(block,(uint8_t*)pad.bytes+i,prev,16);size_t moved=0;CCCrypt(kCCEncrypt,kCCAlgorithmAES128,kCCOptionECBMode,_key,16,block,16,(uint8_t*)out.mutableBytes+i,16,&moved);memcpy(prev,(uint8_t*)out.bytes+i,16);} return out;
}
- (NSData *)decryptResponse:(NSData *)cipher error:(NSError **)error {
    size_t n=cipher.length-cipher.length%16;if(!n)return nil;NSMutableData *raw=[NSMutableData dataWithLength:n];size_t moved=0;CCCrypt(kCCDecrypt,kCCAlgorithmAES128,0,_key,16,_iv,cipher.bytes,n,raw.mutableBytes,n,&moved);if(moved<2)return nil;uint8_t *p=raw.mutableBytes;int len=p[0]|p[1]<<8;if(len<1||len+2>moved)return nil;int cap=65536;NSMutableData *out=[NSMutableData dataWithLength:cap];int got=LZ4_decompress_safe((char*)p+2,out.mutableBytes,len,cap);if(got<0)return nil;out.length=got;return out;
}
@end

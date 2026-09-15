#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface One15Crypto : NSObject
- (nullable instancetype)initWithError:(NSError **)error;
- (nullable NSString *)tokenForMilliseconds:(int64_t)milliseconds error:(NSError **)error;
- (nullable NSData *)encryptRequest:(NSData *)plainText error:(NSError **)error;
- (nullable NSData *)decryptResponse:(NSData *)cipherText error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END

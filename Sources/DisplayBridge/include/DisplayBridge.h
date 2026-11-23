#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface VirtualDisplaySession : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
+ (nullable instancetype)startWithWidth:(unsigned int)width
                                 height:(unsigned int)height
                                  hiDPI:(BOOL)hiDPI
                                  error:(NSError **)error;
- (void)stop;
@end
NS_ASSUME_NONNULL_END

#import <Security/SecProtocolOptions.h>
void ConfigurePairedTLS(sec_protocol_options_t _Nonnull options, NSData * _Nonnull key);

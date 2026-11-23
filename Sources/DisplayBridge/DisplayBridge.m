#import "DisplayBridge.h"

// These declarations describe the runtime API. Resolve the classes dynamically
// so the prototype can report an error if macOS removes them.
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) unsigned int vendorID, productID, serialNum, serialNumber;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                        height:(unsigned int)height
                   refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

@implementation VirtualDisplaySession {
    CGVirtualDisplay *_display;
}

+ (instancetype)startWithWidth:(unsigned int)width
                         height:(unsigned int)height
                          hiDPI:(BOOL)hiDPI
                          error:(NSError **)error {
    unsigned int backingScale = hiDPI ? 2 : 1;
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");

    NSString *failure;
    if (!descriptorClass || !modeClass || !settingsClass || !displayClass) {
        failure = @"The virtual display API is unavailable on this macOS build.";
    } else {
        @try {
            CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
            descriptor.name = @"Mac Extend";
            descriptor.queue = dispatch_get_main_queue();
            descriptor.maxPixelsWide = width * backingScale;
            descriptor.maxPixelsHigh = height * backingScale;
            descriptor.sizeInMillimeters = CGSizeMake(476, 268);
            descriptor.vendorID = 505;
            descriptor.productID = 1;
            descriptor.serialNum = arc4random_uniform(INT32_MAX) + 1;
            if ([descriptor respondsToSelector:@selector(setSerialNumber:)]) {
                descriptor.serialNumber = descriptor.serialNum;
            }
            descriptor.redPrimary = CGPointMake(0.64, 0.33);
            descriptor.greenPrimary = CGPointMake(0.30, 0.60);
            descriptor.bluePrimary = CGPointMake(0.15, 0.06);
            descriptor.whitePoint = CGPointMake(0.3127, 0.3290);

            CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
            CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width
                                                                  height:height
                                                             refreshRate:60];
            CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
            settings.hiDPI = hiDPI;
            if (display && mode && settings) {
                settings.modes = @[mode];
                if ([display applySettings:settings] && display.displayID != kCGNullDirectDisplay) {
                    VirtualDisplaySession *session = [[self alloc] init];
                    session->_display = display;
                    return session;
                }
            }
            failure = @"macOS could not create the requested virtual display mode.";
        } @catch (NSException *exception) {
            failure = [NSString stringWithFormat:@"Virtual display API failed: %@", exception.reason];
        }
    }

    if (error) {
        *error = [NSError errorWithDomain:@"iMacExtendedDisplay"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: failure}];
    }
    return nil;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

- (void)stop {
    _display = nil;
}
@end

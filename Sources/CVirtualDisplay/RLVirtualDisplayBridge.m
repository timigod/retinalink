#import "RLVirtualDisplayBridge.h"
#import <dispatch/dispatch.h>

// Selector declarations give ARC the right ownership and argument ABI. The
// classes themselves are obtained at runtime from the public CoreGraphics dylib.
@protocol RLDescriptor <NSObject>
@property(nonatomic, copy) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@end

@protocol RLMode <NSObject>
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@protocol RLSettings <NSObject>
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, copy) NSArray *modes;
@end

@protocol RLDisplay <NSObject>
- (instancetype)initWithDescriptor:(id<RLDescriptor>)descriptor;
- (BOOL)applySettings:(id<RLSettings>)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

@implementation RLVirtualDisplayMode
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _refreshRate = refreshRate;
    }
    return self;
}
@end

@implementation RLVirtualDisplayBridge {
    id<RLDisplay> _display;
}

- (instancetype)initWithName:(NSString *)name
                maxPixelsWide:(NSUInteger)maxPixelsWide
                maxPixelsHigh:(NSUInteger)maxPixelsHigh
          sizeInMillimeters:(CGSize)sizeInMillimeters
                     vendorID:(NSUInteger)vendorID
                    productID:(NSUInteger)productID
                    serialNum:(NSUInteger)serialNum
                        hiDPI:(BOOL)hiDPI
                        modes:(NSArray<RLVirtualDisplayMode *> *)modes {
    self = [super init];
    if (!self) { return nil; }
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !displayClass) { return nil; }

    id<RLDescriptor> descriptor = [[descriptorClass alloc] init];
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned int)maxPixelsWide;
    descriptor.maxPixelsHigh = (unsigned int)maxPixelsHigh;
    descriptor.sizeInMillimeters = sizeInMillimeters;
    descriptor.vendorID = (unsigned int)vendorID;
    descriptor.productID = (unsigned int)productID;
    descriptor.serialNum = (unsigned int)serialNum;
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    descriptor.redPrimary = CGPointMake(0.680, 0.320);
    descriptor.greenPrimary = CGPointMake(0.265, 0.690);
    descriptor.bluePrimary = CGPointMake(0.150, 0.060);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);

    _display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!_display || ![self applyModes:modes hiDPI:hiDPI]) {
        [self invalidate];
        return nil;
    }
    return self;
}

- (BOOL)applyModes:(NSArray<RLVirtualDisplayMode *> *)modes hiDPI:(BOOL)hiDPI {
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!_display || !modeClass || !settingsClass || modes.count == 0) { return NO; }

    NSMutableArray *nativeModes = [NSMutableArray arrayWithCapacity:modes.count];
    for (RLVirtualDisplayMode *mode in modes) {
        id nativeMode = [(id<RLMode>)[modeClass alloc] initWithWidth:(unsigned int)mode.width
                                                 height:(unsigned int)mode.height
                                            refreshRate:mode.refreshRate];
        if (!nativeMode) { return NO; }
        [nativeModes addObject:nativeMode];
    }

    id<RLSettings> settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI;
    settings.modes = nativeModes;
    return [_display applySettings:settings];
}

- (CGDirectDisplayID)displayID { return _display.displayID; }
- (void)invalidate { _display = nil; }
@end

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface RLVirtualDisplayMode : NSObject
@property(nonatomic, readonly) NSUInteger width;
@property(nonatomic, readonly) NSUInteger height;
@property(nonatomic, readonly) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface RLVirtualDisplayBridge : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithName:(NSString *)name
                       maxPixelsWide:(NSUInteger)maxPixelsWide
                       maxPixelsHigh:(NSUInteger)maxPixelsHigh
                 sizeInMillimeters:(CGSize)sizeInMillimeters
                            vendorID:(NSUInteger)vendorID
                           productID:(NSUInteger)productID
                           serialNum:(NSUInteger)serialNum
                               hiDPI:(BOOL)hiDPI
                               modes:(NSArray<RLVirtualDisplayMode *> *)modes;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)applyModes:(NSArray<RLVirtualDisplayMode *> *)modes hiDPI:(BOOL)hiDPI;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END

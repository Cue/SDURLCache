//
//  SDURLCache.h
//  SDURLCache
//
//  Created by Olivier Poitrey on 15/03/10.
//  Copyright 2010 Dailymotion. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SDURLCache : NSURLCache
{
    @private
    NSString *diskCachePath;
    NSMutableDictionary *diskCacheInfo;
    BOOL diskCacheInfoDirty, ignoreMemoryOnlyStoragePolicy, disabled, _enableForIOS5AndUp;
    NSUInteger diskCacheUsage;
    NSTimeInterval minDiskCacheItemInterval;
    NSTimeInterval maxMemoryCacheItemInterval;
    NSUInteger maxMemoryCacheItemSize;
    NSOperationQueue *ioQueue;
    NSTimer *periodicMaintenanceTimer;
    NSOperation *periodicMaintenanceOperation;
}

/*
 * Defines the minimum number of seconds between now and the expiration time of a cacheable response
 * in order for the response to be cached on disk. This prevent from spending time and storage capacity
 * for an entry which will certainly expire before behing read back from disk cache (memory cache is
 * best suited for short term cache). The default value is set to 5 minutes (300 seconds).
 */
@property (nonatomic, assign) NSTimeInterval minDiskCacheItemInterval;

/*
 * Defines the maximum number of seconds between now and the expiration time of a cacheable response
 * in order for the response to be cached in memory. Responses that have a very long time to live will
 * only be cached on disk.
 */
@property (nonatomic, assign) NSTimeInterval maxMemoryCacheItemInterval;

/* Defines the maximum size of a cacheable response in order for the response to be cached in memory.
 */
@property (nonatomic, assign) NSUInteger maxMemoryCacheItemSize;

/*
 * Allow the responses that have a storage policy of NSURLCacheStorageAllowedInMemoryOnly to be cached
 * on the disk anyway.
 *
 * This is mainly a workaround against cache policies generated by the UIWebViews: starting from iOS 4.2,
 * it always has a cache policy of NSURLCacheStorageAllowedInMemoryOnly.
 * The default value is YES
 */
@property (nonatomic, assign) BOOL ignoreMemoryOnlyStoragePolicy;

/*
 * Returns a default cache director path to be used at cache initialization. The generated path directory
 * will be located in the application's cache directory and thus won't be synced by iTunes.
 */
+ (NSString *)defaultCachePath;

/* 
 * yosit: It turns that although ios > 5 has a disk cache it doesn't behave in a predicatable way
 * the added enableForIOS5AndUp will enable SDURLCache to function like it does on all version of IOS
 */

- (id)initWithMemoryCapacity:(NSUInteger)memoryCapacity 
                diskCapacity:(NSUInteger)diskCapacity 
                    diskPath:(NSString *)path
          enableForIOS5AndUp:(BOOL)enableForIOS5AndUp;

/*
 * Checks if the provided URL exists in cache.
 */
- (BOOL)isCached:(NSURL *)url;

@end

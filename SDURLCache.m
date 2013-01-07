//
//  SDURLCache.m
//  SDURLCache
//
//  Created by Olivier Poitrey on 15/03/10.
//  Copyright 2010 Dailymotion. All rights reserved.
//

#import "SDURLCache.h"
#import "SDCachedURLResponse.h"
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIDevice.h>

// The removal of the NSCachedURLResponse category means that NSKeyedArchiver
// will throw an EXC_BAD_ACCESS when attempting to load NSCachedURLResponse
// data.
// This means that this change requires a cache refresh, and a new cache key
// namespace that will prevent this from happening.
// Old cache keys will eventually be evicted from the system as new keys are
// populated.
NSString *const kSDURLCacheVersion = @"VCue0";

static NSTimeInterval const kSDURLCacheInfoDefaultMinDiskCacheItemInterval = 15 * 60; // 15 minutes
static NSTimeInterval const kSDURLCacheInfoDefaultMaxMemoryCacheItemInterval = 36 * 60 * 60; // 36 hours
static NSInteger const kSDURLCacheInfoDefaultMaxMemoryCacheItemSize = 16 * 1024; // 16 KiB
static NSString *const kSDURLCacheInfoFileName = @"cacheInfo.plist";
static NSString *const kSDURLCacheInfoDiskUsageKey = @"diskUsage";
static NSString *const kSDURLCacheInfoAccessesKey = @"accesses";
static NSString *const kSDURLCacheInfoSizesKey = @"sizes";
static float const kSDURLCacheLastModFraction = 0.1f; // 10% since Last-Modified suggested by RFC2616 section 13.2.4
static float const kSDURLCacheDefault = 3600; // Default cache expiration delay if none defined (1 hour)

static NSDateFormatter* CreateDateFormatter(NSString *format)
{
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];

    [dateFormatter setLocale:locale];
    [dateFormatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"GMT"]];
    [dateFormatter setDateFormat:format];
    [locale release];

    return [dateFormatter autorelease];
}

@interface SDURLCache ()
@property (nonatomic, retain) NSString *diskCachePath;
@property (nonatomic, readonly) NSMutableDictionary *diskCacheInfo;
@property (nonatomic, retain) NSOperationQueue *ioQueue;
@property (retain) NSOperation *periodicMaintenanceOperation;
- (void)periodicMaintenance;
@end

@implementation SDURLCache

@synthesize diskCachePath, minDiskCacheItemInterval, maxMemoryCacheItemInterval, maxMemoryCacheItemSize, ioQueue, periodicMaintenanceOperation, ignoreMemoryOnlyStoragePolicy;
@dynamic diskCacheInfo;

#pragma mark SDURLCache (tools)

+ (NSCharacterSet *)plusOrPercent;
{
    static NSCharacterSet *retval = nil;
    if (!retval) {
        retval = [[NSCharacterSet characterSetWithCharactersInString:@"+%"] retain];
    }
    return retval;
}

// from http://code.google.com/p/google-toolbox-for-mac/source/browse/trunk/Foundation/GTMNSString%2BURLArguments.m
+ (NSString *)urlEncodedString:(NSString *)string;
{
    // Encode all the reserved characters, per RFC 3986
    // (<http://www.ietf.org/rfc/rfc3986.txt>)
    CFStringRef escaped =
    CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault,
                                            (CFStringRef)string,
                                            NULL,
                                            (CFStringRef)@"!*'();:@&=+$,/?%#[]",
                                            kCFStringEncodingUTF8);
    return [(NSString *)escaped autorelease]; // Toll-free bridging
}

// from http://code.google.com/p/google-toolbox-for-mac/source/browse/trunk/Foundation/GTMNSString%2BURLArguments.m
+ (NSString *)urlDecodedString:(NSString *)string;
{
    if ([string rangeOfCharacterFromSet:[self plusOrPercent]].location == NSNotFound) {
        // Avoid copying if we can.
        return string;
    }
    NSMutableString *resultString = [NSMutableString stringWithString:string];
    [resultString replaceOccurrencesOfString:@"+"
                                  withString:@" "
                                     options:NSLiteralSearch
                                       range:NSMakeRange(0, [resultString length])];
    return [resultString stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    NSString *string = request.URL.absoluteString;
    NSRange hash = [string rangeOfString:@"#"];
    if (hash.location == NSNotFound)
        return request;

    NSMutableURLRequest *copy = [[request mutableCopy] autorelease];
    copy.URL = [NSURL URLWithString:[string substringToIndex:hash.location]];
    return copy;
}

+ (NSString *)cacheKeyForURL:(NSURL *)url
{
    return [NSString stringWithFormat:@"%@_%@",
            kSDURLCacheVersion, [self urlEncodedString:url.absoluteString]];
}

/*
 * Parse HTTP Date: http://www.w3.org/Protocols/rfc2616/rfc2616-sec3.html#sec3.3.1
 */
+ (NSDate *)dateFromHttpDateString:(NSString *)httpDate
{
    static NSDateFormatter *RFC1123DateFormatter;
    static NSDateFormatter *ANSICDateFormatter;
    static NSDateFormatter *RFC850DateFormatter;
    NSDate *date = nil;

    @synchronized(self) // NSDateFormatter isn't thread safe
    {
        // RFC 1123 date format - Sun, 06 Nov 1994 08:49:37 GMT
        if (!RFC1123DateFormatter) RFC1123DateFormatter = [CreateDateFormatter(@"EEE, dd MMM yyyy HH:mm:ss z") retain];
        date = [RFC1123DateFormatter dateFromString:httpDate];
        if (!date)
        {
            // ANSI C date format - Sun Nov  6 08:49:37 1994
            if (!ANSICDateFormatter) ANSICDateFormatter = [CreateDateFormatter(@"EEE MMM d HH:mm:ss yyyy") retain];
            date = [ANSICDateFormatter dateFromString:httpDate];
            if (!date)
            {
                // RFC 850 date format - Sunday, 06-Nov-94 08:49:37 GMT
                if (!RFC850DateFormatter) RFC850DateFormatter = [CreateDateFormatter(@"EEEE, dd-MMM-yy HH:mm:ss z") retain];
                date = [RFC850DateFormatter dateFromString:httpDate];
            }
        }
    }

    return date;
}

/*
 * This method tries to determine the expiration date based on a response headers dictionary.
 */
+ (NSDate *)expirationDateFromHeaders:(NSDictionary *)headers withStatusCode:(NSInteger)status
{
    if (status != 200 && status != 203 && status != 300 && status != 301 && status != 302 && status != 307 && status != 410)
    {
        // Uncacheable response status code
        return nil;
    }

    // Check Pragma: no-cache
    NSString *pragma = [headers objectForKey:@"Pragma"];
    if (pragma && [pragma isEqualToString:@"no-cache"])
    {
        // Uncacheable response
        return nil;
    }

    // Define "now" based on the request
    NSString *date = [headers objectForKey:@"Date"];
    NSDate *now;
    if (date)
    {
        now = [SDURLCache dateFromHttpDateString:date];
    }
    else
    {
        // If no Date: header, define now from local clock
        now = [NSDate date];
    }

    // Look at info from the Cache-Control: max-age=n header
    NSString *cacheControl = [[headers objectForKey:@"Cache-Control"] lowercaseString];
    if (cacheControl)
    {
        NSRange foundRange = [cacheControl rangeOfString:@"no-store"];
        if (foundRange.length > 0)
        {
            // Can't be cached
            return nil;
        }

        NSInteger maxAge;
        foundRange = [cacheControl rangeOfString:@"max-age"];
        if (foundRange.length > 0)
        {
            NSScanner *cacheControlScanner = [NSScanner scannerWithString:cacheControl];
            [cacheControlScanner setScanLocation:foundRange.location + foundRange.length];
            [cacheControlScanner scanString:@"=" intoString:nil];
            if ([cacheControlScanner scanInteger:&maxAge])
            {
                if (maxAge > 0)
                {
                    return [[[NSDate alloc] initWithTimeInterval:maxAge sinceDate:now] autorelease];
                }
                else
                {
                    return nil;
                }
            }
        }
    }

    // If not Cache-Control found, look at the Expires header
    NSString *expires = [headers objectForKey:@"Expires"];
    if (expires)
    {
        NSTimeInterval expirationInterval = 0;
        NSDate *expirationDate = [SDURLCache dateFromHttpDateString:expires];
        if (expirationDate)
        {
            expirationInterval = [expirationDate timeIntervalSinceDate:now];
        }
        if (expirationInterval > 0)
        {
            // Convert remote expiration date to local expiration date
            return [NSDate dateWithTimeIntervalSinceNow:expirationInterval];
        }
        else
        {
            // If the Expires header can't be parsed or is expired, do not cache
            return nil;
        }
    }

    if (status == 302 || status == 307)
    {
        // If not explict cache control defined, do not cache those status
        return nil;
    }

    // If no cache control defined, try some heristic to determine an expiration date
    NSString *lastModified = [headers objectForKey:@"Last-Modified"];
    if (lastModified)
    {
        NSTimeInterval age = 0;
        NSDate *lastModifiedDate = [SDURLCache dateFromHttpDateString:lastModified];
        if (lastModifiedDate)
        {
            // Define the age of the document by comparing the Date header with the Last-Modified header
            age = [now timeIntervalSinceDate:lastModifiedDate];
        }
        if (age > 0)
        {
            return [NSDate dateWithTimeIntervalSinceNow:(age * kSDURLCacheLastModFraction)];
        }
        else
        {
            return nil;
        }
    }

    // If nothing permitted to define the cache expiration delay nor to restrict its cacheability, use a default cache expiration delay
    return [[[NSDate alloc] initWithTimeInterval:kSDURLCacheDefault sinceDate:now] autorelease];

}

#pragma mark SDURLCache (private)

- (NSMutableDictionary *)diskCacheInfo
{
    if (!diskCacheInfo)
    {
        @synchronized(self)
        {
            if (!diskCacheInfo) // Check again, maybe another thread created it while waiting for the mutex
            {
                diskCacheInfo = [[NSMutableDictionary alloc] initWithContentsOfFile:[diskCachePath stringByAppendingPathComponent:kSDURLCacheInfoFileName]];
                if (!diskCacheInfo)
                {
                    diskCacheInfo = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
                                     [NSNumber numberWithUnsignedInt:0], kSDURLCacheInfoDiskUsageKey,
                                     [NSMutableDictionary dictionary], kSDURLCacheInfoAccessesKey,
                                     [NSMutableDictionary dictionary], kSDURLCacheInfoSizesKey,
                                     nil];
                }
                diskCacheInfoDirty = NO;

                diskCacheUsage = [[diskCacheInfo objectForKey:kSDURLCacheInfoDiskUsageKey] unsignedIntValue];

                periodicMaintenanceTimer = [[NSTimer scheduledTimerWithTimeInterval:5
                                                                             target:self
                                                                           selector:@selector(periodicMaintenance)
                                                                           userInfo:nil
                                                                            repeats:YES] retain];
            }
        }
    }

    return diskCacheInfo;
}

- (void)createDiskCachePath
{
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    if (![fileManager fileExistsAtPath:diskCachePath])
    {
        [fileManager createDirectoryAtPath:diskCachePath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:NULL];
    }
    [fileManager release];
}

- (void)saveCacheInfo
{
    [self createDiskCachePath];
    @synchronized(self.diskCacheInfo)
    {
        NSData *data = [NSPropertyListSerialization dataFromPropertyList:self.diskCacheInfo format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
        if (data)
        {
            [data writeToFile:[diskCachePath stringByAppendingPathComponent:kSDURLCacheInfoFileName] atomically:YES];
        }

        diskCacheInfoDirty = NO;
    }
}

- (void)removeCachedResponseForCachedKeys:(NSArray *)cacheKeys
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSEnumerator *enumerator = [cacheKeys objectEnumerator];
    NSString *cacheKey;

    @synchronized(self.diskCacheInfo)
    {
        NSMutableDictionary *accesses = [self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey];
        NSMutableDictionary *sizes = [self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey];
        NSFileManager *fileManager = [[NSFileManager alloc] init];

        while ((cacheKey = [enumerator nextObject]))
        {
            NSUInteger cacheItemSize = [[sizes objectForKey:cacheKey] unsignedIntegerValue];
            [accesses removeObjectForKey:cacheKey];
            [sizes removeObjectForKey:cacheKey];
            [fileManager removeItemAtPath:[diskCachePath stringByAppendingPathComponent:cacheKey] error:NULL];

            diskCacheUsage -= cacheItemSize;
            [self.diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:diskCacheUsage] forKey:kSDURLCacheInfoDiskUsageKey];
        }
        [fileManager release];
    }

    [pool drain];
}

- (void)balanceDiskUsage
{
    if (diskCacheUsage < self.diskCapacity)
    {
        // Already done
        return;
    }

    NSMutableArray *keysToRemove = [NSMutableArray array];

    @synchronized(self.diskCacheInfo)
    {
        // Apply LRU cache eviction algorithm while disk usage outreach capacity
        NSDictionary *sizes = [self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey];

        NSInteger capacityToSave = diskCacheUsage - self.diskCapacity;
        NSArray *sortedKeys = [[self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey] keysSortedByValueUsingSelector:@selector(compare:)];
        NSEnumerator *enumerator = [sortedKeys objectEnumerator];
        NSString *cacheKey;

        while (capacityToSave > 0 && (cacheKey = [enumerator nextObject]))
        {
            [keysToRemove addObject:cacheKey];
            capacityToSave -= [(NSNumber *)[sizes objectForKey:cacheKey] unsignedIntegerValue];
        }
    }

    [self removeCachedResponseForCachedKeys:keysToRemove];
    [self saveCacheInfo];
}


- (void)storeToDisk:(NSDictionary *)context
{
    NSURLRequest *request = [context objectForKey:@"request"];
    // use wrapper to ensure we save appropriate fields
    SDCachedURLResponse *cachedResponse = [SDCachedURLResponse cachedURLResponseWithNSCachedURLResponse:[context objectForKey:@"cachedResponse"]];

    NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];
    NSString *cacheFilePath = [diskCachePath stringByAppendingPathComponent:cacheKey];

    [self createDiskCachePath];

    // Archive the cached response on disk
    if (![NSKeyedArchiver archiveRootObject:cachedResponse toFile:cacheFilePath])
    {
        // Caching failed for some reason
        return;
    }

    // Update disk usage info
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSNumber *cacheItemSize = [[fileManager attributesOfItemAtPath:cacheFilePath error:NULL] objectForKey:NSFileSize];
    [fileManager release];
    @synchronized(self.diskCacheInfo)
    {
        diskCacheUsage += [cacheItemSize unsignedIntegerValue];
        [self.diskCacheInfo setObject:[NSNumber numberWithUnsignedInteger:diskCacheUsage] forKey:kSDURLCacheInfoDiskUsageKey];


        // Update cache info for the stored item
        [(NSMutableDictionary *)[self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey] setObject:[NSDate date] forKey:cacheKey];
        [(NSMutableDictionary *)[self.diskCacheInfo objectForKey:kSDURLCacheInfoSizesKey] setObject:cacheItemSize forKey:cacheKey];
    }

    [self saveCacheInfo];
}

- (void)periodicMaintenance
{
    // If another maintenance operation is already sceduled, cancel it so this new operation will be executed after other
    // operations of the queue, so we can group more work together
    [periodicMaintenanceOperation cancel];
    self.periodicMaintenanceOperation = nil;

    // If disk usage exceeds capacity, run the cache eviction operation and if cacheInfo dictionary is dirty, save it in an operation
    if (diskCacheUsage > self.diskCapacity)
    {
        NSInvocationOperation *operation = [[NSInvocationOperation alloc] initWithTarget:self selector:@selector(balanceDiskUsage) object:nil];
        self.periodicMaintenanceOperation = operation;
        [ioQueue addOperation:periodicMaintenanceOperation];
        [operation release];
    }
    else if (diskCacheInfoDirty)
    {
        NSInvocationOperation *operation = [[NSInvocationOperation alloc] initWithTarget:self selector:@selector(saveCacheInfo) object:nil];
        self.periodicMaintenanceOperation = operation;
        [ioQueue addOperation:periodicMaintenanceOperation];
        [operation release];
    }
}

#pragma mark SDURLCache

+ (NSString *)defaultCachePath
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:@"SDURLCache"];
}

#pragma mark NSURLCache

- (id)initWithMemoryCapacity:(NSUInteger)memoryCapacity diskCapacity:(NSUInteger)diskCapacity diskPath:(NSString *)path
{
    // iOS 5 implements disk caching. SDURLCache then disables itself at runtime if the current device OS
    // version is 5 or greater
    NSArray *version = [[UIDevice currentDevice].systemVersion componentsSeparatedByString:@"."];
    disabled = [[version objectAtIndex:0] intValue] >= 5 && !_enableForIOS5AndUp;

    if (disabled)
    {
        // iOS NSURLCache doesn't accept a full path but a single path component
        path = [path lastPathComponent];
    }

    if ((self = [super initWithMemoryCapacity:memoryCapacity diskCapacity:diskCapacity diskPath:path]) && !disabled)
    {
        self.minDiskCacheItemInterval = kSDURLCacheInfoDefaultMinDiskCacheItemInterval;
        self.maxMemoryCacheItemSize = kSDURLCacheInfoDefaultMaxMemoryCacheItemSize;
        self.diskCachePath = path;

        // Init the operation queue
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        self.ioQueue = queue;
        [queue release];

        ioQueue.maxConcurrentOperationCount = 1; // used to streamline operations in a separate thread
        self.ignoreMemoryOnlyStoragePolicy = YES;
	}

    return self;
}

- (id)initWithMemoryCapacity:(NSUInteger)memoryCapacity
                diskCapacity:(NSUInteger)diskCapacity
                    diskPath:(NSString *)path
          enableForIOS5AndUp:(BOOL)enableForIOS5AndUp {

    _enableForIOS5AndUp = enableForIOS5AndUp;
    return [self initWithMemoryCapacity:memoryCapacity
                           diskCapacity:diskCapacity
                               diskPath:path];
}


- (void)storeCachedResponse:(NSCachedURLResponse *)cachedResponse forRequest:(NSURLRequest *)request
{
    if (disabled)
    {
        [super storeCachedResponse:cachedResponse forRequest:request];
        return;
    }

    request = [SDURLCache canonicalRequestForRequest:request];

    if (request.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData
        || request.cachePolicy == NSURLRequestReloadIgnoringLocalAndRemoteCacheData
        || request.cachePolicy == NSURLRequestReloadIgnoringCacheData)
    {
        // When cache is ignored for read, it's a good idea not to store the result as well as this option
        // have big chance to be used every times in the future for the same request.
        // NOTE: This is a change regarding default URLCache behavior
        return;
    }

    NSURLCacheStoragePolicy storagePolicy = cachedResponse.storagePolicy;
    NSDictionary *headers = [(NSHTTPURLResponse *)cachedResponse.response allHeaderFields];
    NSDate *expirationDate = [SDURLCache expirationDateFromHeaders:headers
                                                    withStatusCode:((NSHTTPURLResponse *)cachedResponse.response).statusCode];

    bool diskCacheable = ((storagePolicy == NSURLCacheStorageAllowed || (storagePolicy == NSURLCacheStorageAllowedInMemoryOnly && ignoreMemoryOnlyStoragePolicy))
                          && [cachedResponse.response isKindOfClass:[NSHTTPURLResponse class]]
                          && cachedResponse.data.length < self.diskCapacity
                          && [expirationDate timeIntervalSinceNow] > minDiskCacheItemInterval);

    bool memoryCacheable = cachedResponse.data.length < self.maxMemoryCacheItemSize;    
    if (memoryCacheable && (!diskCacheable || [expirationDate timeIntervalSinceNow] <= maxMemoryCacheItemInterval)) {
        // item is small enough, cache to memory only
        [super storeCachedResponse:cachedResponse forRequest:request];
        return;
    }

    if (diskCacheable)
    {
        if ([self isCachedOnDisk:[request URL]]) {
            NSLog(@"Item already cached on disk: %@", [request URL]);
        }
        
        NSInvocationOperation *operation = [[NSInvocationOperation alloc] initWithTarget:self
                                                                            selector:@selector(storeToDisk:)
                                                                              object:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                                      cachedResponse, @"cachedResponse",
                                                                                      request, @"request",
                                                                                      nil]];
        [ioQueue addOperation:operation];
        [operation release];
    }
}

- (NSCachedURLResponse *)cachedResponseForRequest:(NSURLRequest *)request
{
    if (disabled) return [super cachedResponseForRequest:request];

    request = [SDURLCache canonicalRequestForRequest:request];

    NSCachedURLResponse *memoryResponse = [super cachedResponseForRequest:request];
    if (memoryResponse)
    {
        return [[memoryResponse retain] autorelease];
    }

    NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];

    // NOTE: We don't handle expiration here as even staled cache data is necessary for NSURLConnection to handle cache revalidation.
    //       Staled cache data is also needed for cachePolicies which force the use of the cache.
    @synchronized(self.diskCacheInfo)
    {
        NSMutableDictionary *accesses = [self.diskCacheInfo objectForKey:kSDURLCacheInfoAccessesKey];
        if ([accesses objectForKey:cacheKey]) // OPTI: Check for cache-hit in a in-memory dictionary before hitting the file system
        {
            // load wrapper
            SDCachedURLResponse *diskResponseWrapper = [NSKeyedUnarchiver unarchiveObjectWithFile:[diskCachePath stringByAppendingPathComponent:cacheKey]];
            NSCachedURLResponse *diskResponse = diskResponseWrapper.response;

            if (diskResponse)
            {
                // OPTI: Log the entry last access time for LRU cache eviction algorithm but don't save the dictionary
                //       on disk now in order to save IO and time
                [accesses setObject:[NSDate date] forKey:cacheKey];
                diskCacheInfoDirty = YES;

                // OPTI: Store the response to memory cache for potential future requests
                [super storeCachedResponse:diskResponse forRequest:request];

                // SRK: Work around an interesting retainCount bug in CFNetwork on iOS << 3.2.
                if (kCFCoreFoundationVersionNumber < kCFCoreFoundationVersionNumber_iPhoneOS_3_2)
                {
                    diskResponse = [super cachedResponseForRequest:request];
                }

                if (diskResponse)
                {
                    return [[diskResponse retain] autorelease];
                }
            }
        }
    }

    return nil;
}

- (NSUInteger)currentDiskUsage
{
    if (disabled) return [super currentDiskUsage];

    if (!diskCacheInfo)
    {
        [self diskCacheInfo];
    }
    return diskCacheUsage;
}

- (void)removeCachedResponseForRequest:(NSURLRequest *)request
{
    if (disabled)
    {
        [super removeCachedResponseForRequest:request];
        return;
    }

    request = [SDURLCache canonicalRequestForRequest:request];

    [super removeCachedResponseForRequest:request];
    [self removeCachedResponseForCachedKeys:[NSArray arrayWithObject:[SDURLCache cacheKeyForURL:request.URL]]];
    [self saveCacheInfo];
}

-(void)clearMemoryCache
{
    [super removeAllCachedResponses];
}

- (void)removeAllCachedResponses
{
    [self clearMemoryCache];

    if (disabled) return;
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    [fileManager removeItemAtPath:diskCachePath error:NULL];
    [fileManager release];

    @synchronized(self)
    {
        [diskCacheInfo release], diskCacheInfo = nil;
    }
}

- (BOOL)isCached:(NSURL *)url
{
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    request = [SDURLCache canonicalRequestForRequest:request];

    if ([super cachedResponseForRequest:request])
    {
        return YES;
    }

    if (disabled) return NO;

    return [self isCachedOnDisk:url];
}

- (BOOL)isCachedOnDisk:(NSURL *)url
{
    NSString *cacheKey = [SDURLCache cacheKeyForURL:url];
    NSString *cacheFile = [diskCachePath stringByAppendingPathComponent:cacheKey];
    NSFileManager *manager = [[NSFileManager alloc] init];
    BOOL exists = [manager fileExistsAtPath:cacheFile];
    [manager release];
    return exists;
}

#pragma mark NSObject

- (void)dealloc
{
    if (!disabled)
    {
        [periodicMaintenanceTimer invalidate];
        [periodicMaintenanceTimer release], periodicMaintenanceTimer = nil;
        [periodicMaintenanceOperation release], periodicMaintenanceOperation = nil;
        [diskCachePath release], diskCachePath = nil;
        [diskCacheInfo release], diskCacheInfo = nil;
        [ioQueue release], ioQueue = nil;
    }
    [super dealloc];
}


@end

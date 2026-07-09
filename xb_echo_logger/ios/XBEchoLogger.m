#import "XBEchoLogger.h"

static NSString *const kQueueKey = @"xb_echo_logger_queue";
static NSString *const kDedupKey = @"xb_echo_logger_error_dedup";
static const NSUInteger kMaxQueueSize = 1000;
static const NSTimeInterval kStartDelay = 2.0;
static const NSTimeInterval kRequestTimeout = 3.0;

@interface XBEchoLogger ()

@property (nonatomic, copy, readwrite) NSString *echoHost;
@property (nonatomic, copy, readwrite) NSString *appId;
@property (nonatomic, assign, readwrite) BOOL isDebug;

@property (nonatomic, strong) NSMutableArray<NSDictionary *> *queue;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *dedupHashes;
@property (nonatomic, assign) BOOL canExecute;
@property (nonatomic, strong) dispatch_queue_t serialQueue;

@end

@implementation XBEchoLogger

#pragma mark - Singleton

+ (instancetype)shared {
    static XBEchoLogger *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[XBEchoLogger alloc] init];
    });
    return instance;
}

+ (void)initWithHost:(NSString *)echoHost
               appId:(NSString *)appId
            isDebug:(BOOL)isDebug {
    XBEchoLogger *logger = [self shared];
    logger.echoHost = echoHost;
    logger.appId = appId;
    logger.isDebug = isDebug;
    [logger setup];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = [NSMutableArray array];
        _dedupHashes = [NSMutableArray array];
        _canExecute = NO;
        _serialQueue = dispatch_queue_create("com.xb.echo.logger", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Setup

- (void)setup {
    // 从 NSUserDefaults 恢复队列
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *saved = [defaults arrayForKey:kQueueKey];
    if (saved) {
        [self.queue addObjectsFromArray:saved];
    }

    // 恢复去重列表
    NSString *dedupStr = [defaults stringForKey:kDedupKey];
    if (dedupStr.length > 0) {
        for (NSString *part in [dedupStr componentsSeparatedByString:@","]) {
            NSInteger hash = [part integerValue];
            if (hash != 0 || [part isEqualToString:@"0"]) {
                [self.dedupHashes addObject:@(hash)];
            }
        }
    }

    // 延迟启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStartDelay * NSEC_PER_SEC)),
                   self.serialQueue, ^{
        self.canExecute = YES;
        [self processQueue];
    });
}

#pragma mark - Public

- (void)echo:(NSDictionary<NSString *, id> *)info {
    dispatch_async(self.serialQueue, ^{
        if (self.queue.count >= kMaxQueueSize) {
            [self.queue removeObjectAtIndex:0];
        }
        [self.queue addObject:info];
        [self saveQueue];
        [self processQueue];
    });
}

- (void)err:(NSDictionary<NSString *, id> *)info {
    // 去重
    NSString *content = [info[@"content"] description] ?: @"";
    NSString *hashStr = [NSString stringWithFormat:@"%@%@%@%@%@%@",
                         content, self.appId,
                         self.isDebug ? @"debug" : @"release",
                         info[@"userId"] ?: @"",
                         info[@"device"] ?: @"",
                         info[@"systemVersion"] ?: @""];
    NSInteger hashValue = [hashStr hash];
    NSNumber *hashNum = @(hashValue);

    if ([self.dedupHashes containsObject:hashNum]) return;

    [self.dedupHashes addObject:hashNum];
    if (self.dedupHashes.count > 1000) {
        [self.dedupHashes removeObjectAtIndex:0];
    }
    [self saveDedupList];

    // 延迟 1 秒发送
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   self.serialQueue, ^{
        [self postDirectly:info path:@"/errCatch"];
    });
}

- (void)postDirectly:(NSDictionary<NSString *, id> *)info path:(NSString *)path {
    NSString *urlStr = [NSString stringWithFormat:@"%@%@", self.echoHost, path];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = kRequestTimeout;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:info
                                                       options:0
                                                         error:&jsonError];
    if (jsonError) return;
    request.HTTPBody = jsonData;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *_Nullable data,
                              NSURLResponse *_Nullable response,
                              NSError *_Nullable error) {
            if (error) {
                NSLog(@"[XBEchoLogger] POST failed: %@", error.localizedDescription);
            }
          }];
    [task resume];
}

- (NSUInteger)pendingCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.serialQueue, ^{
        count = self.queue.count;
    });
    return count;
}

#pragma mark - Queue Processing

- (void)processQueue {
    // 必须在 serialQueue 中调用
    if (self.queue.count == 0) return;
    if (!self.canExecute) return;

    self.canExecute = NO;
    NSDictionary *info = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];
    [self saveQueue];

    NSString *urlStr = [NSString stringWithFormat:@"%@/echo", self.echoHost];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        self.canExecute = YES;
        [self processQueue];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = kRequestTimeout;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:info
                                                       options:0
                                                         error:&jsonError];
    if (jsonError) {
        self.canExecute = YES;
        [self processQueue];
        return;
    }
    request.HTTPBody = jsonData;

    // 使用信号量同步等待，保证串行
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *_Nullable data,
                              NSURLResponse *_Nullable response,
                              NSError *_Nullable error) {
            dispatch_semaphore_signal(sema);
          }];
    [task resume];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    self.canExecute = YES;
    [self processQueue];
}

#pragma mark - Persistence

- (void)saveQueue {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:[self.queue copy] forKey:kQueueKey];
    [defaults synchronize];
}

- (void)saveDedupList {
    NSMutableArray *strs = [NSMutableArray arrayWithCapacity:self.dedupHashes.count];
    for (NSNumber *num in self.dedupHashes) {
        [strs addObject:[num stringValue]];
    }
    NSString *joined = [strs componentsJoinedByString:@","];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:joined forKey:kDedupKey];
    [defaults synchronize];
}

@end

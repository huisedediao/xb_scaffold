#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// iOS 原生端 Echo 日志上报组件。
///
/// 提供与 Dart 端对等的队列 + HTTP 上报能力，
/// 可在原生代码中直接调用，无需通过 Flutter MethodChannel。
///
/// 使用方式：
/// ```objc
/// // 初始化
/// [XBEchoLogger initWithHost:@"http://144.168.61.190:3000"
///                       appId:@"com.example.app"
///                    isDebug:NO];
///
/// // 上报日志
/// [XBEchoLogger echo:@{@"content": @"用户点击了按钮"}];
/// [XBEchoLogger err:@{@"content": @"接口异常"}];
/// ```
@interface XBEchoLogger : NSObject

/// 初始化组件（应在 AppDelegate 中尽早调用）。
+ (void)initWithHost:(NSString *)echoHost
               appId:(NSString *)appId
            isDebug:(BOOL)isDebug;

/// 获取单例。
+ (instancetype)shared;

/// 上报普通日志（走队列，离线缓存）。
- (void)echo:(NSDictionary<NSString *, id> *)info;

/// 上报错误日志（直接发送，带去重）。
- (void)err:(NSDictionary<NSString *, id> *)info;

/// 上报日志（直接发送，不经过队列）。
- (void)postDirectly:(NSDictionary<NSString *, id> *)info
                path:(NSString *)path;

/// 当前队列待发送数量。
@property (nonatomic, readonly) NSUInteger pendingCount;

/// 服务器地址。
@property (nonatomic, copy, readonly) NSString *echoHost;

/// 应用标识。
@property (nonatomic, copy, readonly) NSString *appId;

/// 是否调试模式。
@property (nonatomic, assign, readonly) BOOL isDebug;

@end

NS_ASSUME_NONNULL_END

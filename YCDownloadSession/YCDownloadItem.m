//
//  YCDownloadItem.m
//  YCDownloadSession
//
//  Created by wz on 17/7/28.
//  Copyright © 2017年 onezen.cc. All rights reserved.
//  Contact me: http://www.onezen.cc/about/
//  Github:     https://github.com/onezens/YCDownloadSession
//

#import "YCDownloadItem.h"
#import "YCDownloadUtils.h"

NSString * const kDownloadTaskFinishedNoti = @"kDownloadTaskFinishedNoti";
NSString * const kDownloadTaskAllFinishedNoti = @"kDownloadTaskAllFinishedNoti";

@interface YCDownloadTask(Downloader)
@property (nonatomic, strong) NSURLSessionDownloadTask *downloadTask;
@end

@interface YCDownloadItem()
@property (nonatomic, copy) NSString *rootPath;
@property (nonatomic, assign) NSInteger pid;
@property (nonatomic, assign) BOOL isRemoved;
@property (nonatomic, assign) BOOL noNeedStartNext;
@property (nonatomic, copy) NSString *fileExtension;
@property (nonatomic, assign, readonly) NSUInteger createTime;
@property (nonatomic, assign) NSTimeInterval speedMsec;
//@property (nonatomic, assign) uint64_t preDownloadedSize;
@end

@implementation YCDownloadItem

#pragma mark - init

- (instancetype)initWithPrivate{
    if (self = [super init]) {
        _createTime = [YCDownloadUtils sec_timestamp];
        _version = [YCDownloadTask downloaderVerison];
    }
    return self;
}

- (instancetype)initWithUrl:(NSString *)url fileId:(NSString *)fileId {
    if (self = [self initWithPrivate]) {
        _downloadURL = url;
        _fileId = fileId;
    }
    return self;
}
+ (instancetype)itemWithDict:(NSDictionary *)dict {
    YCDownloadItem *item = [[YCDownloadItem alloc] initWithPrivate];
    [item setValuesForKeysWithDictionary:dict];
//    item.preDownloadedSize = item.downloadedSize;
    return item;
}
+ (instancetype)itemWithUrl:(NSString *)url fileId:(NSString *)fileId {
    return [[YCDownloadItem alloc] initWithUrl:url fileId:fileId];
}

- (void)setValue:(id)value forUndefinedKey:(NSString *)key{}

#pragma mark - Handler
- (void)downloadProgress:(YCDownloadTask *)task downloadedSize:(int64_t)downloadedSize fileSize:(int64_t)fileSize {
    if (self.fileSize==0)  _fileSize = fileSize;
    if (!self.fileExtension) [self setFileExtensionWithTask:task];
    _downloadedSize = downloadedSize;
    if ([self.delegate respondsToSelector:@selector(downloadItem:downloadedSize:totalSize:)]) {
        [self.delegate downloadItem:self downloadedSize:downloadedSize totalSize:fileSize];
    }

}

- (void)downloadStatusChanged:(YCDownloadStatus)status downloadTask:(YCDownloadTask *)task {
    _downloadStatus = status;
    if ([self.delegate respondsToSelector:@selector(downloadItemStatusChanged:)]) {
        [self.delegate downloadItemStatusChanged:self];
    }
    //通知优先级最后，不与上面的finished重合
    if (status == YCDownloadStatusFinished || status == YCDownloadStatusFailed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kDownloadTaskFinishedNoti object:self];
        [YCDownloadDB saveItem:self];
    }
}

#pragma mark - getter & setter

- (void)setDownloadStatus:(YCDownloadStatus)downloadStatus {
    _downloadStatus = downloadStatus;
    if ([self.delegate respondsToSelector:@selector(downloadItemStatusChanged:)]) {
        [self.delegate downloadItemStatusChanged:self];
    }
}

- (void)setSaveRootPath:(NSString *)saveRootPath {
    NSString *path = [saveRootPath stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@""];
    _rootPath = path;
}

- (NSString *)saveRootPath {
    NSString *rootPath = self.rootPath;
    if(!rootPath){
        rootPath = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, true).firstObject;
        rootPath = [rootPath stringByAppendingPathComponent:@"YCDownload"];
    }else{
        rootPath = [NSHomeDirectory() stringByAppendingPathComponent:rootPath];
    }
    return rootPath;
}


- (void)setFileExtensionWithTask:(YCDownloadTask *)task {
    NSURLResponse *oriResponse =task.downloadTask.response;
    if ([oriResponse isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *response = (NSHTTPURLResponse *)oriResponse;
        NSString *extension = [[response.allHeaderFields valueForKey:@"Content-Type"] componentsSeparatedByString:@"/"].lastObject;
        if ([extension containsString:@";"]) {
            extension = [extension componentsSeparatedByString:@";"].firstObject;
        }
        if(extension.length==0) extension = response.suggestedFilename.pathExtension;
        _fileExtension = extension;
    }else{
        NSLog(@"[warning] downloadTask response class type error: %@", oriResponse);
    }
}

- (YCProgressHandler)progressHandler {
    __weak typeof(self) weakSelf = self;
    return ^(NSProgress *progress, YCDownloadTask *task){
        if(weakSelf.downloadStatus == YCDownloadStatusWaiting){
            [weakSelf downloadStatusChanged:YCDownloadStatusDownloading downloadTask:task];
        }
        [weakSelf downloadProgress:task downloadedSize:progress.completedUnitCount fileSize:(progress.totalUnitCount>0 ? progress.totalUnitCount : 0)];
    };
}

- (YCDownloadSpeedHandler)speedHanlder {
    if (![self.delegate respondsToSelector:@selector(downloadItem:speed:speedDesc:)]) {
        return nil;
    }
    __weak typeof(self) weakSelf = self;
    return ^(uint64_t bytesWrited){
        uint64_t secWriteSize = (self.speedMsec>0 && bytesWrited>0) ? bytesWrited / ([YCDownloadUtils msec_timestamp] - self.speedMsec) * 1000 : 0;
        NSString *ss = [NSString stringWithFormat:@"%@/s",[YCDownloadUtils fileSizeStringFromBytes:secWriteSize]];
        [self.delegate downloadItem:self speed:secWriteSize speedDesc:ss];
        NSLog(@"[speed] size: %llu ss: %@ phase: %llu", secWriteSize, ss, bytesWrited);
        self.speedMsec = [YCDownloadUtils msec_timestamp];
        [weakSelf.delegate downloadItem:weakSelf speed:secWriteSize speedDesc:ss];
    };
}

- (YCCompletionHandler)completionHandler {
    __weak typeof(self) weakSelf = self;
    return ^(NSString *localPath, NSError *error){
        YCDownloadTask *task = [YCDownloadDB taskWithTid:self.taskId];
        if (error) {
            NSLog(@"[Item completionHandler] error : %@", error);
            [weakSelf downloadStatusChanged:YCDownloadStatusFailed downloadTask:nil];
            if(!weakSelf.isRemoved) [YCDownloadDB saveItem:weakSelf];
            return ;
        }
        
        // bg completion ,maybe had no extension
        if (!self.fileExtension) [self setFileExtensionWithTask:task];
        NSError *saveError = nil;
        if([[NSFileManager defaultManager] fileExistsAtPath:self.savePath]){
            NSLog(@"[Item completionHandler] Warning file Exist at path: %@ and replaced it!", weakSelf.savePath);
            [[NSFileManager defaultManager] removeItemAtPath:self.savePath error:nil];
        }
        
        if([[NSFileManager defaultManager] moveItemAtPath:localPath toPath:self.savePath error:&saveError]){
            NSAssert(self.fileExtension, @"file extension can not nil!");
            int64_t fileSize = [YCDownloadUtils fileSizeWithPath:weakSelf.savePath];
            self->_downloadedSize = fileSize;
            self->_fileSize = fileSize;
            [weakSelf downloadStatusChanged:YCDownloadStatusFinished downloadTask:nil];
        }else{
            [weakSelf downloadStatusChanged:YCDownloadStatusFailed downloadTask:nil];
            NSLog(@"[Item completionHandler] move file failed error: %@ \nlocalPath: %@ \nsavePath:%@", saveError,localPath,self.savePath);
        }
        
    };
}


#pragma mark - public

- (NSString *)compatibleKey {
    return [YCDownloadTask downloaderVerison];
}

- (NSString *)saveUidDirectory {
    return [[self saveRootPath] stringByAppendingPathComponent:self.uid];
}

- (NSString *)saveDirectory {
    NSString *path = [self saveUidDirectory];
    path = [path stringByAppendingPathComponent:(self.fileType ? self.fileType : @"data")];
    [YCDownloadUtils createPathIfNotExist:path];
    return path;
}

- (NSString *)saveName {
    NSString *saveName = self.fileId ? self.fileId : self.taskId;
    return [saveName stringByAppendingPathExtension: self.fileExtension.length>0 ? self.fileExtension : @"data"];
}

- (NSString *)savePath {
    return [[self saveDirectory] stringByAppendingPathComponent:[self saveName]];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<YCDownloadTask: %p>{taskId: %@, url: %@ fileId: %@}", self, self.taskId, self.downloadURL, self.fileId];
}

@end

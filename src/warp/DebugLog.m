//
//  DebugLog.m
//  Troubadour
//
//  Замена журнала Dante-WARP (DebugLog.h — авторский, без изменений).
//
//  У автора журнал пишется в свой файл Documents/debug.log с синхронизацией
//  каждой строки. В приложении журнал один — Documents/youtube.log, куда
//  уходит всё, что пишет NSLog (см. src/YTLog.h). Поэтому здесь всё сводится
//  к NSLog с меткой, а служебные вызовы для демона ничего не делают.
//

#import "DebugLog.h"

void DLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);

    NSString *text = [[NSString alloc] initWithFormat:format arguments:arguments];

    va_end(arguments);

    NSLog(@"[YouTube/WARP] %@", text);
}

void DCon(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);

    NSString *text = [[NSString alloc] initWithFormat:format arguments:arguments];

    va_end(arguments);

    NSLog(@"[YouTube/WARP] %@", text);
}

void DebugLogInit(void) {}
void DebugLogInitWithPath(NSString *path) { (void)path; }
NSString *DebugLogPath(void) { return nil; }
NSString *DebugLogContents(void) { return @""; }
void WriteCrashReport(NSException *exception) { (void)exception; }
void DebugLogSetGated(BOOL gated) { (void)gated; }
BOOL DebugLogUIPing(void) { return NO; }
BOOL DebugLogActive(void) { return YES; }
void DebugLogSetForced(BOOL forced) { (void)forced; }
BOOL DebugLogForced(void) { return NO; }
NSString *DConText(void) { return @""; }

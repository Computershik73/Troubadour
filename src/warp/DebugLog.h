//
//  DebugLog.h
//  YouTube
//
//  File-based debug logging utility
//  Logs are written to Documents/debug.log and readable via iTunes File Sharing
//

#import <Foundation/Foundation.h>

// Log a message to both NSLog and file
void DLog(NSString *format, ...);

// Подробный лог (строка на пакет или соединение). Каждая строка пишется на
// диск с синхронизацией — на iPhone 4 это заметно тормозило туннель, поэтому
// по умолчанию вырезается при сборке. Включить: -DDANTE_VERBOSE_LOG=1.
#if DANTE_VERBOSE_LOG
#define DLogVerbose(...) DLog(__VA_ARGS__)
#else
#define DLogVerbose(...) do { } while (0)
#endif

// Initialize logging (call from AppDelegate)
void DebugLogInit(void);
// То же, но в указанный файл: у демона и приложения логи раздельные.
void DebugLogInitWithPath(NSString *path);

// Get the log file path
NSString *DebugLogPath(void);

// Get all logged content (for display in UI)
NSString *DebugLogContents(void);

// Write a crash report
void WriteCrashReport(NSException *exception);

// Журнал службы пишется, только пока открыто приложение: оно раз в секунду
// спрашивает STATUS, и каждый такой запрос продлевает запись на 6 с. Закрыли —
// DLog выходит сразу, ещё до форматирования строки, и не тратит ни процессор,
// ни запись на диск. DebugLogSetGated(YES) включает это правило (служба);
// в самом приложении журнал пишется всегда.
void DebugLogSetGated(BOOL gated);
// Приложение на связи. YES — если до этого оно было закрыто (пора показать
// сводку состояния в консоли).
BOOL DebugLogUIPing(void);
BOOL DebugLogActive(void);
// Для разработки: писать всегда, даже без приложения (команда DEBUGLOG 1).
void DebugLogSetForced(BOOL forced);
BOOL DebugLogForced(void);

// Консоль за кнопкой: короткие строки в духе dmesg, только по делу. Пишется
// лишь пока приложение открыто, живёт в памяти (последние 64 строки).
void DCon(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *DConText(void);

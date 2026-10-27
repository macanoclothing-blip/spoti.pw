#import <Foundation/Foundation.h>
#import <os/log.h>

// %{public}s so idevicesyslog on the Mac sees the text instead of <private>.
#define SGLog(fmt, ...) SGLogMessage([NSString stringWithFormat:(fmt), ##__VA_ARGS__])

// Writes to the unified log and to a small rolling file inside the app container. The file makes
// diagnostics exportable even when iOS has already dropped the process's unified-log entries.
void SGLogMessage(NSString *message);
NSArray<NSString *> *SGLogFilePaths(void); // previous file first, then current
void SGLogFlush(void);                     // drains queued writes before an export

// Long dumps, split into numbered parts under the unified log's size cap.
void SGLogLong(NSString *tag, NSString *text);
// Logs every class of the list that this Spotify does not have; a feature calls it from its %ctor.
void SGRequireClasses(NSArray<NSString *> *names);

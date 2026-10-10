// A private listening atlas: Spotify's extended-history JSON seeds it, and player-state changes keep
// adding local listening sessions. No listening data leaves the device unless the user exports it.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Navigation/Links.h"
#import "Shared/Player/PlayerState.h"
#import "MusicUniverse.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <float.h>
#import <math.h>

static NSString *const kUniverseChanged = @"spotifyglass.redesign.musicUniverse.changed";
static NSString *const kEventsKey = @"events";
static NSString *const kArtistKey = @"artist";
static NSString *const kArtistURIKey = @"artistURI";
static NSString *const kTrackKey = @"track";
static NSString *const kAlbumKey = @"album";
static NSString *const kTrackURIKey = @"trackURI";
static NSString *const kTimestampKey = @"timestamp";
static NSString *const kDurationKey = @"msPlayed";
static NSString *const kSessionKey = @"session";
static char kArtistRowKey;

static NSURL *universeStoreURL(NSError **error) {
    NSURL *directory = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
                                                              inDomain:NSUserDomainMask
                                                     appropriateForURL:nil
                                                                create:YES
                                                                 error:error];
    if (!directory) return nil;
    NSURL *folder = [directory URLByAppendingPathComponent:@"spoti.pw" isDirectory:YES];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:folder
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:error]) return nil;
    return [folder URLByAppendingPathComponent:@"MusicUniverse.json"];
}

static NSString *normalizedArtist(NSString *artist) {
    return [[artist stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            lowercaseString];
}

static NSString *eventIdentity(NSDictionary *event) {
    return [NSString stringWithFormat:@"%.3f|%@|%@|%@",
            [event[kTimestampKey] doubleValue],
            event[kTrackURIKey] ?: @"",
            event[kDurationKey] ?: @0,
            normalizedArtist(event[kArtistKey] ?: @"")];
}

static NSDate *historyDate(NSDictionary *row, NSISO8601DateFormatter *iso, NSDateFormatter *legacy) {
    id value = row[@"ts"] ?: row[@"endTime"] ?: row[@"timestamp"];
    if ([value isKindOfClass:NSNumber.class]) return [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *text = value;
    NSDate *date = [iso dateFromString:text];
    if (!date && text.length > 19) date = [iso dateFromString:[text stringByReplacingOccurrencesOfString:@" " withString:@"T"]];
    if (!date) date = [legacy dateFromString:text];
    if (date && row[@"endTime"] && !row[@"ts"] && !row[@"timestamp"]) {
        id duration = row[@"msPlayed"] ?: row[@"ms_played"];
        date = [date dateByAddingTimeInterval:-MAX(0, [duration doubleValue] / 1000.0)];
    }
    return date;
}

static NSString *firstString(NSDictionary *row, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = row[key];
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }
    return nil;
}

static NSDictionary *eventFromHistoryRow(NSDictionary *row, NSISO8601DateFormatter *iso,
                                         NSDateFormatter *legacy) {
    NSString *track = firstString(row, @[@"master_metadata_track_name", @"trackName", @"track_name", @"track"]);
    NSString *artist = firstString(row, @[@"master_metadata_album_artist_name", @"artistName", @"artist_name", @"artist"]);
    if (!track || !artist) return nil;
    NSDate *date = historyDate(row, iso, legacy);
    if (!date) return nil;
    id duration = row[@"ms_played"] ?: row[@"msPlayed"];
    NSString *trackURI = firstString(row, @[@"spotify_track_uri", @"trackUri", @"track_uri", kTrackURIKey]);
    NSString *album = firstString(row, @[@"master_metadata_album_album_name", @"albumName", @"album_name", kAlbumKey]);
    return @{
        kArtistKey: artist,
        kArtistURIKey: firstString(row, @[@"artistURI"]) ?: @"",
        kTrackKey: track,
        kAlbumKey: album ?: @"",
        kTrackURIKey: trackURI ?: @"",
        kTimestampKey: @(date.timeIntervalSince1970),
        kDurationKey: @([duration respondsToSelector:@selector(doubleValue)] ? MAX(0, [duration doubleValue]) : 0),
        kSessionKey: firstString(row, @[kSessionKey]) ?: NSUUID.UUID.UUIDString,
    };
}

@interface SGRUniverseStore : NSObject <SGPlayerStateObserver>
@property (nonatomic, readonly) NSArray<NSDictionary *> *events;
@property (nonatomic, readonly, getter=isLoaded) BOOL loaded;
@property (nonatomic, copy, readonly) NSString *storageWarning;
+ (instancetype)shared;
- (void)importURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSUInteger imported, NSUInteger skipped, NSError *error))completion;
- (void)exportToController:(UIViewController *)controller source:(UIView *)source;
- (void)clearHistory;
@end

@implementation SGRUniverseStore {
    NSMutableArray<NSDictionary *> *_events;
    NSMutableArray<NSDictionary *> *_pending;
    NSMutableSet<NSString *> *_identities;
    dispatch_queue_t _ioQueue;
    BOOL _loaded;
    NSDictionary *_activeTrack;
    NSDate *_activeChunkStart;
    NSString *_activeSession;
    NSTimer *_checkpoint;
    BOOL _batching;
    BOOL _storageWritable;
    NSString *_storageWarning;
}

+ (instancetype)shared {
    static SGRUniverseStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [SGRUniverseStore new]; });
    return store;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _events = [NSMutableArray array];
    _pending = [NSMutableArray array];
    _identities = [NSMutableSet set];
    _ioQueue = dispatch_queue_create("pw.spoti.music-universe.storage", DISPATCH_QUEUE_SERIAL);
    dispatch_async(_ioQueue, ^{
        NSError *error = nil;
        NSURL *url = universeStoreURL(&error);
        NSData *data = url ? [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&error] : nil;
        NSArray *saved = nil;
        if (data.length) {
            id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            if ([root isKindOfClass:NSDictionary.class] && [root[kEventsKey] isKindOfClass:NSArray.class]) {
                saved = root[kEventsKey];
            } else if (root) {
                error = [NSError errorWithDomain:@"MusicUniverse" code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"The saved listening atlas has an unsupported format."}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error && !( [error.domain isEqualToString:NSCocoaErrorDomain] &&
                            error.code == NSFileReadNoSuchFileError)) {
                SGLog(@"music universe: saved data could not be read: %@", error);
            }
            NSArray *pending = [self->_pending copy];
            [self->_pending removeAllObjects];
            self->_loaded = YES;
            self->_storageWritable = !error ||
                ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSFileReadNoSuchFileError);
            if (!self->_storageWritable) self->_storageWarning = error.localizedDescription;
            self->_batching = YES;
            for (NSDictionary *event in saved) [self appendEvent:event persist:NO];
            for (NSDictionary *event in pending) [self appendEvent:event persist:NO];
            self->_batching = NO;
            if (self->_storageWritable) [self persist];
            [NSNotificationCenter.defaultCenter postNotificationName:kUniverseChanged object:self];
        });
    });
    return self;
}

- (NSArray<NSDictionary *> *)events {
    return [_events copy];
}

- (BOOL)isLoaded {
    return _loaded;
}

- (NSString *)storageWarning {
    return _storageWarning;
}

- (void)appendEvent:(NSDictionary *)event persist:(BOOL)persist {
    if (![event[kArtistKey] isKindOfClass:NSString.class] ||
        ![event[kTrackKey] isKindOfClass:NSString.class] ||
        ![event[kTimestampKey] isKindOfClass:NSNumber.class]) return;
    NSString *identity = eventIdentity(event);
    if ([_identities containsObject:identity]) return;
    [_identities addObject:identity];
    if (_loaded) [_events addObject:event];
    else [_pending addObject:event];
    if (persist && _loaded && _storageWritable) [self persist];
    if (!_batching) [NSNotificationCenter.defaultCenter postNotificationName:kUniverseChanged object:self];
}

- (void)persist {
    if (!_storageWritable) return;
    NSArray *snapshot = [_events copy];
    dispatch_async(_ioQueue, ^{
        NSError *error = nil;
        NSURL *url = universeStoreURL(&error);
        NSDictionary *root = @{@"version": @1, kEventsKey: snapshot};
        NSData *data = url ? [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingSortedKeys error:&error] : nil;
        if (data && ![data writeToURL:url options:NSDataWritingAtomic error:&error]) data = nil;
        if (!data) {
            SGLog(@"music universe: could not save listening history: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_storageWarning = error.localizedDescription ?: @"Local storage is unavailable.";
                [NSNotificationCenter.defaultCenter postNotificationName:kUniverseChanged object:self];
            });
        }
    });
}

- (void)beginTrack:(SPTPlayerTrack *)track {
    NSString *artist = track.artistName;
    NSString *title = track.trackTitle;
    NSString *uri = SGURIString(track.URI);
    if (!artist.length || !title.length) return;
    NSDictionary *source = track.metadata;
    _activeTrack = @{
        kArtistKey: artist,
        kArtistURIKey: SGURIString(track.artistURI) ?: @"",
        kTrackKey: title,
        kAlbumKey: firstString(source, @[@"album_title", @"album_name"]) ?: @"",
        kTrackURIKey: uri ?: @"",
    };
    _activeChunkStart = [NSDate date];
    _activeSession = NSUUID.UUID.UUIDString;
    __weak typeof(self) weakSelf = self;
    _checkpoint = [NSTimer scheduledTimerWithTimeInterval:45 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf finishChunkAt:[NSDate date] continuePlaying:YES];
    }];
}

- (void)finishChunkAt:(NSDate *)end continuePlaying:(BOOL)continuePlaying {
    if (!_activeTrack || !_activeChunkStart) return;
    NSTimeInterval seconds = [end timeIntervalSinceDate:_activeChunkStart];
    if (seconds >= 10) {
        NSMutableDictionary *event = [_activeTrack mutableCopy];
        event[kTimestampKey] = @(_activeChunkStart.timeIntervalSince1970);
        event[kDurationKey] = @(llround(seconds * 1000));
        event[kSessionKey] = _activeSession ?: NSUUID.UUID.UUIDString;
        [self appendEvent:event persist:YES];
    }
    if (continuePlaying) {
        _activeChunkStart = end;
    } else {
        [_checkpoint invalidate];
        _checkpoint = nil;
        _activeTrack = nil;
        _activeChunkStart = nil;
        _activeSession = nil;
    }
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self playerStateDidChange:state]; });
        return;
    }
    NSString *uri = SGURIString(state.track.URI);
    NSString *activeURI = _activeTrack[kTrackURIKey];
    if (_activeTrack && (!state.isPlaying || ![uri isEqualToString:activeURI])) {
        [self finishChunkAt:[NSDate date] continuePlaying:NO];
    }
    if (state.isPlaying && state.track && !_activeTrack) [self beginTrack:state.track];
}

- (void)importURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSUInteger, NSUInteger, NSError *))completion {
    NSParameterAssert(completion);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary *> *parsed = [NSMutableArray array];
        NSUInteger skipped = 0;
        NSError *firstError = nil;
        NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
        iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        NSISO8601DateFormatter *plainISO = [NSISO8601DateFormatter new];
        plainISO.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        NSDateFormatter *legacy = [NSDateFormatter new];
        legacy.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        legacy.timeZone = NSTimeZone.localTimeZone;
        legacy.dateFormat = @"yyyy-MM-dd HH:mm";

        for (NSURL *url in urls) {
            if (![url.pathExtension.lowercaseString isEqualToString:@"json"]) {
                skipped++;
                continue;
            }
            BOOL accessed = [url startAccessingSecurityScopedResource];
            NSError *readError = nil;
            NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
            if (accessed) [url stopAccessingSecurityScopedResource];
            if (!data) {
                if (!firstError) firstError = readError;
                skipped++;
                continue;
            }
            NSError *jsonError = nil;
            id root = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&jsonError];
            NSArray *rows = [root isKindOfClass:NSArray.class] ? root :
                ([root isKindOfClass:NSDictionary.class] && [root[@"version"] integerValue] == 1 &&
                 [root[kEventsKey] isKindOfClass:NSArray.class] ? root[kEventsKey] : nil);
            if (!rows) {
                if (!firstError) firstError = jsonError ?: [NSError errorWithDomain:@"MusicUniverse" code:2
                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is not a Spotify streaming-history JSON file.", url.lastPathComponent]}];
                skipped++;
                continue;
            }
            NSUInteger fileAccepted = 0;
            for (id value in rows) {
                if (![value isKindOfClass:NSDictionary.class]) { skipped++; continue; }
                NSDictionary *row = value;
                NSDictionary *event = eventFromHistoryRow(row, iso, legacy) ?: eventFromHistoryRow(row, plainISO, legacy);
                if (!event) { skipped++; continue; }
                [parsed addObject:event];
                fileAccepted++;
            }
            if (!fileAccepted && !firstError) {
                firstError = [NSError errorWithDomain:@"MusicUniverse" code:3
                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ contained no supported track history.", url.lastPathComponent]}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_loaded) {
                self->_batching = YES;
                for (NSDictionary *event in parsed) [self appendEvent:event persist:NO];
                self->_batching = NO;
                if (self->_storageWritable) [self persist];
            } else {
                for (NSDictionary *event in parsed) {
                    NSString *identity = eventIdentity(event);
                    if ([self->_identities containsObject:identity]) continue;
                    [self->_identities addObject:identity];
                    [self->_pending addObject:event];
                }
            }
            [NSNotificationCenter.defaultCenter postNotificationName:kUniverseChanged object:self];
            completion(parsed.count, skipped, firstError);
        });
    });
}

- (void)exportToController:(UIViewController *)controller source:(UIView *)source {
    NSArray *events = self.events;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, kEventsKey: events}
                                                   options:NSJSONWritingPrettyPrinted error:&error];
    if (!data) {
        SGLog(@"music universe: failed to serialize the user's local export: %@", error);
        return;
    }
    NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"MusicUniverse.json"]];
    NSError *writeError = nil;
    if (![data writeToURL:file options:NSDataWritingAtomic error:&writeError]) {
        SGLog(@"music universe: could not prepare export: %@", writeError);
        return;
    }
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    activity.popoverPresentationController.sourceView = source;
    activity.popoverPresentationController.sourceRect = source.bounds;
    [controller presentViewController:activity animated:YES completion:nil];
}

- (void)clearHistory {
    if (_activeTrack) {
        _activeChunkStart = [NSDate date];
        _activeSession = NSUUID.UUID.UUIDString;
    }
    [_events removeAllObjects];
    [_pending removeAllObjects];
    [_identities removeAllObjects];
    [self persist];
    [NSNotificationCenter.defaultCenter postNotificationName:kUniverseChanged object:self];
}

@end

@interface SGRUniverseMapView : UIView
@property (nonatomic, copy) NSArray<NSDictionary *> *nodes;
@property (nonatomic, copy) NSArray<NSDictionary *> *edges;
@property (nonatomic, copy) NSString *selectedArtist;
@property (nonatomic, copy) void (^artistPicked)(NSDictionary *artist);
@end

@implementation SGRUniverseMapView {
    CGFloat _zoom;
    CGPoint _pan;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.accessibilityLabel = @"Interactive map of listening history. Move with two fingers, pinch to zoom, tap an artist.";
    _zoom = 1;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    pan.minimumNumberOfTouches = 2;
    [self addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinched:)];
    [self addGestureRecognizer:pinch];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    [tap requireGestureRecognizerToFail:pan];
    [self addGestureRecognizer:tap];
    return self;
}

- (void)setNodes:(NSArray<NSDictionary *> *)nodes { _nodes = [nodes copy] ?: @[]; [self setNeedsDisplay]; }
- (void)setEdges:(NSArray<NSDictionary *> *)edges { _edges = [edges copy] ?: @[]; [self setNeedsDisplay]; }
- (void)setSelectedArtist:(NSString *)selectedArtist { _selectedArtist = [selectedArtist copy]; [self setNeedsDisplay]; }

- (CGPoint)basePointForIndex:(NSUInteger)index count:(NSUInteger)count {
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    CGFloat angle = (CGFloat)index * 2.39996323;
    CGFloat fraction = sqrt((index + 1.0) / MAX(1.0, count));
    CGFloat radius = MIN(width, height) * 0.40 * fraction;
    return CGPointMake(width * 0.5 + cos(angle) * radius, height * 0.5 + sin(angle) * radius);
}

- (CGPoint)pointForIndex:(NSUInteger)index count:(NSUInteger)count {
    CGPoint base = [self basePointForIndex:index count:count];
    return CGPointMake(base.x * _zoom + _pan.x, base.y * _zoom + _pan.y);
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect bounds = self.bounds;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat colors[] = {0.07,0.10,0.20,1, 0.008,0.012,0.03,1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, NULL, 2);
    CGContextDrawRadialGradient(context, gradient, CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)), 0,
                                CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds)), MAX(bounds.size.width, bounds.size.height) * 0.75, 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);

    for (NSUInteger i = 0; i < 72; i++) {
        CGFloat x = fmod((CGFloat)(i * 83.17 + 21), MAX(1, bounds.size.width));
        CGFloat y = fmod((CGFloat)(i * 47.91 + 13), MAX(1, bounds.size.height));
        CGFloat diameter = i % 9 == 0 ? 2 : 1;
        [[UIColor colorWithWhite:1 alpha:i % 9 == 0 ? 0.32 : 0.13] setFill];
        CGContextFillEllipseInRect(context, CGRectMake(x, y, diameter, diameter));
    }

    NSUInteger count = self.nodes.count;
    if (!count) {
        NSString *empty = @"Importa la cronologia per dare forma al tuo universo";
        NSDictionary *attributes = @{NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightMedium],
                                     NSForegroundColorAttributeName: SGRSecondary()};
        CGSize size = [empty sizeWithAttributes:attributes];
        [empty drawAtPoint:CGPointMake(MAX(16, (bounds.size.width - size.width) / 2),
                                      CGRectGetMidY(bounds) - size.height / 2) withAttributes:attributes];
        return;
    }

    NSMutableDictionary<NSString *, NSNumber *> *indexes = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < count; i++) indexes[normalizedArtist(self.nodes[i][kArtistKey])] = @(i);
    for (NSDictionary *edge in self.edges) {
        NSNumber *a = indexes[edge[@"from"]], *b = indexes[edge[@"to"]];
        if (!a || !b) continue;
        CGPoint start = [self pointForIndex:a.unsignedIntegerValue count:count];
        CGPoint end = [self pointForIndex:b.unsignedIntegerValue count:count];
        CGFloat alpha = MIN(0.34, 0.08 + [edge[@"weight"] doubleValue] * 0.025);
        CGContextSetStrokeColorWithColor(context, [SGRAccent() colorWithAlphaComponent:alpha].CGColor);
        CGContextSetLineWidth(context, 0.7 + MIN(1.2, [edge[@"weight"] doubleValue] * 0.08));
        CGContextMoveToPoint(context, start.x, start.y);
        CGContextAddLineToPoint(context, end.x, end.y);
        CGContextStrokePath(context);
    }

    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *artist = self.nodes[i];
        CGPoint point = [self pointForIndex:i count:count];
        CGFloat radius = 4 + MIN(7, sqrt([artist[@"ms"] doubleValue] / 60000.0) * 0.35);
        UIColor *color = SGRAccent();
        BOOL selected = [normalizedArtist(artist[kArtistKey]) isEqualToString:normalizedArtist(self.selectedArtist ?: @"")];
        CGContextSetFillColorWithColor(context, [color colorWithAlphaComponent:selected ? 0.95 : 0.68].CGColor);
        CGContextFillEllipseInRect(context, CGRectMake(point.x - radius, point.y - radius, radius * 2, radius * 2));
        if (selected) {
            CGContextSetStrokeColorWithColor(context, [UIColor.whiteColor colorWithAlphaComponent:0.9].CGColor);
            CGContextSetLineWidth(context, 1.5);
            CGContextStrokeEllipseInRect(context, CGRectInset(CGRectMake(point.x - radius - 4, point.y - radius - 4,
                                                                          (radius + 4) * 2, (radius + 4) * 2), 0, 0));
        }
        if (i < 18 || selected) {
            NSDictionary *attributes = @{NSFontAttributeName: [UIFont systemFontOfSize:selected ? 11 : 9 weight:selected ? UIFontWeightSemibold : UIFontWeightRegular],
                                         NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:selected ? 0.95 : 0.7]};
            [artist[kArtistKey] drawAtPoint:CGPointMake(point.x + radius + 5, point.y - 6) withAttributes:attributes];
        }
    }
}

- (void)panned:(UIPanGestureRecognizer *)gesture {
    CGPoint delta = [gesture translationInView:self];
    _pan = CGPointMake(_pan.x + delta.x, _pan.y + delta.y);
    [gesture setTranslation:CGPointZero inView:self];
    [self setNeedsDisplay];
}

- (void)pinched:(UIPinchGestureRecognizer *)gesture {
    _zoom = MIN(2.6, MAX(0.65, _zoom * gesture.scale));
    gesture.scale = 1;
    [self setNeedsDisplay];
}

- (void)tapped:(UITapGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:self];
    NSUInteger count = self.nodes.count, selected = NSNotFound;
    CGFloat closest = 30;
    for (NSUInteger i = 0; i < count; i++) {
        CGPoint node = [self pointForIndex:i count:count];
        CGFloat distance = hypot(point.x - node.x, point.y - node.y);
        if (distance < closest) { closest = distance; selected = i; }
    }
    if (selected != NSNotFound && self.artistPicked) self.artistPicked(self.nodes[selected]);
}

@end

@interface SGRMusicUniverseViewController : UIViewController <UIDocumentPickerDelegate, UITextFieldDelegate>
@end

@implementation SGRMusicUniverseViewController {
    SGRUniverseMapView *_map;
    UISlider *_timeline;
    UISegmentedControl *_mood;
    UITextField *_search;
    UILabel *_period, *_summary, *_selectionTitle, *_selectionDetail, *_insight, *_status;
    UIStackView *_artistList;
    UIButton *_openArtist;
    NSDictionary *_selectedArtist;
    NSArray<NSDictionary *> *_events;
    NSArray<NSDictionary *> *_visibleArtists;
    NSArray<NSDictionary *> *_visibleEdges;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.view.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.modalPresentationStyle = UIModalPresentationFullScreen;
    _events = SGRUniverseStore.shared.events;

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    UIStackView *content = [[UIStackView alloc] init];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 20;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:10],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:SGRSideMargin],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-SGRSideMargin],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-2 * SGRSideMargin],
    ]];

    UIView *header = [UIView new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
    close.tintColor = SGRPrimary();
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    close.layer.cornerRadius = 20;
    close.frame = CGRectMake(0, 0, 40, 40);
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:close];
    UILabel *heading = [UILabel new];
    heading.translatesAutoresizingMaskIntoConstraints = NO;
    heading.text = @"Music Universe";
    heading.textColor = SGRPrimary();
    heading.font = SGRFont(UIFontTextStyleLargeTitle, UIFontWeightBold, UIContentSizeCategoryLarge);
    [header addSubview:heading];
    [NSLayoutConstraint activateConstraints:@[
        [header.heightAnchor constraintEqualToConstant:52],
        [close.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [close.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [heading.leadingAnchor constraintEqualToAnchor:close.trailingAnchor constant:12],
        [heading.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    ]];
    [content addArrangedSubview:header];

    UILabel *intro = [self label:@"La tua storia musicale, trasformata in un universo da esplorare. Richiedi a Spotify la Cronologia di ascolto estesa, estrai lo ZIP e seleziona i file Streaming_History_Audio_*.json." style:UIFontTextStyleSubheadline weight:UIFontWeightRegular color:SGRSecondary()];
    intro.numberOfLines = 0;
    [content addArrangedSubview:intro];

    UIStackView *actions = [[UIStackView alloc] init];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.spacing = 10;
    actions.distribution = UIStackViewDistributionFillEqually;
    UIButton *import = [self button:@"Importa cronologia" symbol:@"square.and.arrow.down" action:@selector(importHistory)];
    UIButton *export = [self button:@"Esporta atlante" symbol:@"square.and.arrow.up" action:@selector(exportHistory)];
    [actions addArrangedSubview:import];
    [actions addArrangedSubview:export];
    [content addArrangedSubview:actions];

    _status = [self label:@"I dati restano su questo dispositivo." style:UIFontTextStyleCaption1 weight:UIFontWeightRegular color:SGRTertiary()];
    _status.numberOfLines = 0;
    [content addArrangedSubview:_status];

    _map = [SGRUniverseMapView new];
    _map.translatesAutoresizingMaskIntoConstraints = NO;
    _map.layer.cornerRadius = SGRRadiusCard;
    _map.layer.masksToBounds = YES;
    [content addArrangedSubview:_map];
    [_map.heightAnchor constraintEqualToConstant:340].active = YES;
    __weak typeof(self) weakSelf = self;
    _map.artistPicked = ^(NSDictionary *artist) { [weakSelf selectArtist:artist]; };

    UILabel *timeTitle = [self sectionTitle:@"VIAGGIA NEL TEMPO"];
    [content addArrangedSubview:timeTitle];
    _period = [self label:@"Tutta la cronologia" style:UIFontTextStyleCaption1 weight:UIFontWeightMedium color:SGRSecondary()];
    [content addArrangedSubview:_period];
    _timeline = [UISlider new];
    _timeline.minimumValue = 0;
    _timeline.maximumValue = 1;
    _timeline.accessibilityLabel = @"Viaggia nella cronologia";
    _timeline.minimumTrackTintColor = SGRAccent();
    [_timeline addTarget:self action:@selector(filtersChanged) forControlEvents:UIControlEventValueChanged];
    [content addArrangedSubview:_timeline];
    _mood = [[UISegmentedControl alloc] initWithItems:@[@"Tutto", @"Mattina", @"Giorno", @"Sera", @"Notte"]];
    _mood.accessibilityLabel = @"Filtra per momento della giornata";
    _mood.selectedSegmentIndex = 0;
    _mood.selectedSegmentTintColor = [SGRAccent() colorWithAlphaComponent:0.8];
    [_mood addTarget:self action:@selector(filtersChanged) forControlEvents:UIControlEventValueChanged];
    [content addArrangedSubview:_mood];

    UITextField *search = [UITextField new];
    search.placeholder = @"Cerca artisti nella tua storia";
    search.textColor = SGRPrimary();
    search.tintColor = SGRAccent();
    search.backgroundColor = [UIColor colorWithWhite:1 alpha:0.09];
    search.layer.cornerRadius = 14;
    search.clearButtonMode = UITextFieldViewModeWhileEditing;
    search.returnKeyType = UIReturnKeySearch;
    search.delegate = self;
    search.leftView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
    search.leftViewMode = UITextFieldViewModeAlways;
    ((UIImageView *)search.leftView).tintColor = SGRSecondary();
    search.leftView.frame = CGRectMake(0, 0, 38, 40);
    search.leftView.contentMode = UIViewContentModeCenter;
    search.translatesAutoresizingMaskIntoConstraints = NO;
    [search.heightAnchor constraintEqualToConstant:44].active = YES;
    [search addTarget:self action:@selector(filtersChanged) forControlEvents:UIControlEventEditingChanged];
    _search = search;
    [content addArrangedSubview:search];

    UILabel *artistsHeading = [self sectionTitle:@"COSTELLAZIONI"];
    [content addArrangedSubview:artistsHeading];
    _artistList = [[UIStackView alloc] init];
    _artistList.axis = UILayoutConstraintAxisVertical;
    _artistList.spacing = 0;
    [content addArrangedSubview:_artistList];

    UIView *selection = [self card];
    UIStackView *selectionContent = [[UIStackView alloc] init];
    selectionContent.axis = UILayoutConstraintAxisVertical;
    selectionContent.spacing = 7;
    selectionContent.translatesAutoresizingMaskIntoConstraints = NO;
    [selection addSubview:selectionContent];
    [NSLayoutConstraint activateConstraints:@[
        [selectionContent.topAnchor constraintEqualToAnchor:selection.topAnchor constant:16],
        [selectionContent.leadingAnchor constraintEqualToAnchor:selection.leadingAnchor constant:16],
        [selectionContent.trailingAnchor constraintEqualToAnchor:selection.trailingAnchor constant:-16],
        [selectionContent.bottomAnchor constraintEqualToAnchor:selection.bottomAnchor constant:-16],
    ]];
    _selectionTitle = [self label:@"Scegli un artista sulla mappa" style:UIFontTextStyleHeadline weight:UIFontWeightSemibold color:SGRPrimary()];
    _selectionDetail = [self label:@"Ogni collegamento racconta artisti ascoltati vicini nel tempo." style:UIFontTextStyleSubheadline weight:UIFontWeightRegular color:SGRSecondary()];
    _selectionDetail.numberOfLines = 0;
    _openArtist = [self button:@"Apri in Spotify" symbol:@"arrow.up.right" action:@selector(openSelectedArtist)];
    _openArtist.enabled = NO;
    [selectionContent addArrangedSubview:_selectionTitle];
    [selectionContent addArrangedSubview:_selectionDetail];
    [selectionContent addArrangedSubview:_openArtist];
    [content addArrangedSubview:selection];

    [content addArrangedSubview:[self sectionTitle:@"IL TUO ASCOLTO, IN BREVE"]];
    _summary = [self label:@"" style:UIFontTextStyleSubheadline weight:UIFontWeightMedium color:SGRPrimary()];
    _summary.numberOfLines = 0;
    [content addArrangedSubview:_summary];
    _insight = [self label:@"" style:UIFontTextStyleSubheadline weight:UIFontWeightRegular color:SGRSecondary()];
    _insight.numberOfLines = 0;
    [content addArrangedSubview:_insight];

    UILabel *privacy = [self label:@"La cronologia viene conservata localmente. L'esportazione è manuale; spoti.pw non invia questi dati a server." style:UIFontTextStyleCaption1 weight:UIFontWeightRegular color:SGRTertiary()];
    privacy.numberOfLines = 0;
    [content addArrangedSubview:privacy];
    UIButton *clear = [self button:@"Elimina cronologia locale" symbol:@"trash" action:@selector(confirmClearHistory)];
    UIButtonConfiguration *clearStyle = clear.configuration;
    clearStyle.baseForegroundColor = UIColor.systemRedColor;
    clear.configuration = clearStyle;
    [content addArrangedSubview:clear];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(storeChanged:)
                                                 name:kUniverseChanged object:SGRUniverseStore.shared];
    [self refresh];
}

- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = SGRFont(style, weight, UIContentSizeCategoryLarge);
    label.textColor = color;
    return label;
}

- (UILabel *)sectionTitle:(NSString *)text {
    UILabel *label = [self label:text style:UIFontTextStyleCaption1 weight:UIFontWeightBold color:SGRTertiary()];
    return label;
}

- (UIButton *)button:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:symbol];
    configuration.imagePadding = 6;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    configuration.baseForegroundColor = SGRPrimary();
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(10, 12, 10, 12);
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)card {
    UIView *view = [UIView new];
    view.backgroundColor = SGRElevated(UIColor.blackColor);
    view.layer.cornerRadius = SGRRadiusCard;
    view.layer.borderWidth = 1;
    view.layer.borderColor = SGRHairline().CGColor;
    return view;
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)importHistory {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)picker;
    if (!urls.count) return;
    _status.text = [NSString stringWithFormat:@"Importazione di %lu file…", (unsigned long)urls.count];
    __weak typeof(self) weakSelf = self;
    [SGRUniverseStore.shared importURLs:urls completion:^(NSUInteger imported, NSUInteger skipped, NSError *error) {
        SGRMusicUniverseViewController *self = weakSelf;
        if (!self) return;
        [self refresh];
        if (!imported) {
            NSString *details = error.localizedDescription ?: @"Seleziona i file JSON Streaming_History_Audio_*.json estratti dall'esportazione estesa di Spotify.";
            [self showAlert:@"Nessuna cronologia importata" message:details];
            return;
        }
        self->_status.text = [NSString stringWithFormat:@"%lu ascolti importati; %lu righe non compatibili ignorate.",
                              (unsigned long)imported, (unsigned long)skipped];
        if (error) {
            self->_status.text = [self->_status.text stringByAppendingFormat:@" %@", error.localizedDescription];
            SGLog(@"music universe: partial import: %@", error);
        }
    }];
}

- (void)exportHistory {
    [SGRUniverseStore.shared exportToController:self source:self.view];
}

- (void)confirmClearHistory {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Eliminare l'Atlante?"
                                                                   message:@"La cronologia importata e raccolta su questo dispositivo verrà cancellata. L'operazione non si può annullare."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Elimina" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        [SGRUniverseStore.shared clearHistory];
        self->_status.text = @"Cronologia locale eliminata.";
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)storeChanged:(NSNotification *)notification {
    (void)notification;
    _events = SGRUniverseStore.shared.events;
    [self refresh];
}

- (void)filtersChanged {
    [self refresh];
}

- (NSArray<NSDictionary *> *)filteredEvents {
    if (!_events.count) return @[];
    NSTimeInterval earliest = DBL_MAX, latest = 0;
    for (NSDictionary *event in _events) {
        NSTimeInterval timestamp = [event[kTimestampKey] doubleValue];
        earliest = MIN(earliest, timestamp);
        latest = MAX(latest, timestamp);
    }
    NSTimeInterval cutoff = earliest;
    if (_timeline.value > 0.001 && latest > earliest) {
        cutoff = earliest + (latest - earliest) * _timeline.value;
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = NSLocale.currentLocale;
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterNoStyle;
        _period.text = [NSString stringWithFormat:@"Dal %@", [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:cutoff]]];
    } else {
        _period.text = @"Tutta la cronologia";
    }
    NSString *query = _search.text.lowercaseString ?: @"";
    NSInteger mood = _mood.selectedSegmentIndex;
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *event in _events) {
        NSTimeInterval timestamp = [event[kTimestampKey] doubleValue];
        if (timestamp < cutoff) continue;
        if (mood > 0) {
            NSDateComponents *components = [NSCalendar.currentCalendar components:NSCalendarUnitHour fromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
            NSInteger hour = components.hour;
            BOOL matches = mood == 1 ? hour >= 5 && hour < 12 :
                           mood == 2 ? hour >= 12 && hour < 17 :
                           mood == 3 ? hour >= 17 && hour < 22 :
                                       hour >= 22 || hour < 5;
            if (!matches) continue;
        }
        NSString *artistName = [event[kArtistKey] lowercaseString];
        if (query.length && [artistName rangeOfString:query].location == NSNotFound) continue;
        [result addObject:event];
    }
    return result;
}

- (void)refresh {
    NSArray<NSDictionary *> *events = [self filteredEvents];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *artists = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *edges = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *sessions = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *albums = [NSMutableDictionary dictionary];
    NSArray *sorted = [events sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[kTimestampKey] compare:b[kTimestampKey]];
    }];
    NSDictionary *previous = nil;
    for (NSDictionary *event in sorted) {
        NSString *name = event[kArtistKey];
        NSString *key = normalizedArtist(name);
        if (!key.length) continue;
        NSMutableDictionary *artist = artists[key];
        if (!artist) {
            artist = [@{kArtistKey: name, @"ms": @0, @"plays": @0, @"recent": @0,
                        @"track": @"", @"trackURI": @"", @"artistURI": @""} mutableCopy];
            artists[key] = artist;
        }
        artist[@"ms"] = @([artist[@"ms"] doubleValue] + [event[kDurationKey] doubleValue]);
        artist[@"recent"] = event[kTimestampKey];
        artist[@"track"] = event[kTrackKey] ?: @"";
        artist[@"trackURI"] = event[kTrackURIKey] ?: @"";
        NSString *artistURI = event[kArtistURIKey];
        if (artistURI.length) artist[@"artistURI"] = artistURI;
        NSString *session = event[kSessionKey] ?: eventIdentity(event);
        if (!sessions[key]) sessions[key] = [NSMutableDictionary dictionary];
        sessions[key][session] = @YES;

        NSString *album = event[kAlbumKey];
        if (album.length) albums[album] = @([albums[album] doubleValue] + [event[kDurationKey] doubleValue]);

        NSString *previousKey = normalizedArtist(previous[kArtistKey] ?: @"");
        NSTimeInterval gap = [event[kTimestampKey] doubleValue] - [previous[kTimestampKey] doubleValue];
        if (previousKey.length && ![previousKey isEqualToString:key] && gap >= 0 && gap < 1800) {
            NSArray<NSString *> *pair = [@[previousKey, key] sortedArrayUsingSelector:@selector(compare:)];
            NSString *edgeKey = [pair componentsJoinedByString:@"|"];
            NSMutableDictionary *edge = edges[edgeKey];
            if (!edge) {
                edge = [@{@"from": pair[0],
                          @"to": pair[1],
                          @"weight": @0} mutableCopy];
                edges[edgeKey] = edge;
            }
            edge[@"weight"] = @([edge[@"weight"] integerValue] + 1);
        }
        previous = event;
    }

    NSMutableArray *nodeList = [NSMutableArray array];
    for (NSString *key in artists) {
        NSMutableDictionary *artist = artists[key];
        artist[@"plays"] = @(sessions[key].count);
        [nodeList addObject:artist];
    }
    [nodeList sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"ms"] compare:a[@"ms"]];
    }];
    _visibleArtists = [nodeList copy];
    _visibleEdges = [edges.allValues copy];
    _map.nodes = [_visibleArtists subarrayWithRange:NSMakeRange(0, MIN(60, _visibleArtists.count))];
    _map.edges = _visibleEdges;
    _map.selectedArtist = _selectedArtist[kArtistKey];
    [self updateArtistList];

    if (!SGRUniverseStore.shared.isLoaded) {
        _status.text = @"Sto caricando la cronologia salvata…";
    } else if (!_events.count) {
        _status.text = @"Importa i JSON della Cronologia di ascolto estesa di Spotify. Da ora registrerò anche gli ascolti futuri.";
    } else {
        _status.text = [NSString stringWithFormat:@"%lu sessioni di ascolto raccolte su questo dispositivo.",
                        (unsigned long)_events.count];
    }
    if (SGRUniverseStore.shared.storageWarning.length) {
        _status.text = [NSString stringWithFormat:@"%@ Salvataggio locale non disponibile: %@",
                        _status.text ?: @"", SGRUniverseStore.shared.storageWarning];
    }
    NSTimeInterval total = 0;
    for (NSDictionary *event in events) total += [event[kDurationKey] doubleValue];
    NSString *top = nodeList.firstObject[kArtistKey] ?: @"—";
    NSInteger totalMinutes = (NSInteger)(total / 60000.0);
    NSString *duration = totalMinutes >= 60
        ? [NSString stringWithFormat:@"%ld h", (long)(totalMinutes / 60)]
        : [NSString stringWithFormat:@"%ld min", (long)totalMinutes];
    _summary.text = [NSString stringWithFormat:@"%lu ascolti nel periodo · %lu artisti · %@ di musica ascoltata\nIn cima: %@",
                     (unsigned long)events.count, (unsigned long)nodeList.count, duration, top];

    NSMutableDictionary *byMonth = [NSMutableDictionary dictionary];
    for (NSDictionary *event in events) {
        NSDateComponents *components = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth
                                                                      fromDate:[NSDate dateWithTimeIntervalSince1970:[event[kTimestampKey] doubleValue]]];
        NSString *month = [NSString stringWithFormat:@"%04ld-%02ld", (long)components.year, (long)components.month];
        byMonth[month] = @([byMonth[month] doubleValue] + [event[kDurationKey] doubleValue]);
    }
    NSString *bestMonth = [[byMonth allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [byMonth[b] compare:byMonth[a]];
    }].firstObject;
    NSString *topAlbum = [[albums allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [albums[b] compare:albums[a]];
    }].firstObject;
    if (bestMonth) {
        NSArray *parts = [bestMonth componentsSeparatedByString:@"-"];
        _insight.text = [NSString stringWithFormat:@"Il tuo mese più musicale qui è %@/%@%@. Le linee collegano artisti ascoltati uno dopo l'altro, nella stessa sessione.",
                         parts.lastObject, parts.firstObject,
                         topAlbum ? [NSString stringWithFormat:@"; l'album più presente è %@", topAlbum] : @""];
    } else {
        _insight.text = @"Con più ascolti, l'Atlante farà emergere le costellazioni, le rotte e i tuoi periodi musicali.";
    }
}

- (void)updateArtistList {
    for (UIView *view in _artistList.arrangedSubviews) {
        [_artistList removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSUInteger count = MIN(8, _visibleArtists.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *artist = _visibleArtists[i];
        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        [row setTitle:[NSString stringWithFormat:@"%lu   %@   ·   %lu ascolti",
                       (unsigned long)(i + 1), artist[kArtistKey], (unsigned long)[artist[@"plays"] unsignedIntegerValue]]
               forState:UIControlStateNormal];
        row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        row.tintColor = SGRPrimary();
        row.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        row.accessibilityLabel = [NSString stringWithFormat:@"%@, %lu ascolti", artist[kArtistKey],
                                  (unsigned long)[artist[@"plays"] unsignedIntegerValue]];
        objc_setAssociatedObject(row, &kArtistRowKey, artist, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [row addTarget:self action:@selector(artistRowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_artistList addArrangedSubview:row];
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    }
}

- (void)artistRowTapped:(UIButton *)sender {
    NSDictionary *artist = objc_getAssociatedObject(sender, &kArtistRowKey);
    if (artist) [self selectArtist:artist];
}

- (void)selectArtist:(NSDictionary *)artist {
    _selectedArtist = artist;
    _selectionTitle.text = artist[kArtistKey];
    NSTimeInterval millis = [artist[@"ms"] doubleValue];
    NSString *artistKey = normalizedArtist(artist[kArtistKey]);
    NSMutableArray<NSDictionary *> *neighbors = [NSMutableArray array];
    for (NSDictionary *edge in _visibleEdges) {
        NSString *other = [edge[@"from"] isEqualToString:artistKey] ? edge[@"to"] :
                          [edge[@"to"] isEqualToString:artistKey] ? edge[@"from"] : nil;
        if (!other) continue;
        for (NSDictionary *candidate in _visibleArtists) {
            if ([normalizedArtist(candidate[kArtistKey]) isEqualToString:other]) {
                [neighbors addObject:@{@"artist": candidate[kArtistKey], @"weight": edge[@"weight"]}];
                break;
            }
        }
    }
    [neighbors sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"weight"] compare:a[@"weight"]];
    }];
    NSString *connection = neighbors.firstObject
        ? [NSString stringWithFormat:@" · Spesso vicino a %@", neighbors.firstObject[@"artist"]] : @"";
    _selectionDetail.text = [NSString stringWithFormat:@"%lu ascolti · %@ ascoltati · Ultima traccia: %@%@",
                             (unsigned long)[artist[@"plays"] unsignedIntegerValue],
                             [self formattedDuration:millis],
                             artist[@"track"] ?: @"—", connection];
    _openArtist.enabled = [artist[@"artistURI"] length] || [artist[@"trackURI"] length];
    UIButtonConfiguration *openConfiguration = _openArtist.configuration;
    openConfiguration.title = [artist[@"artistURI"] length] ? @"Apri artista" : @"Apri ultimo brano";
    _openArtist.configuration = openConfiguration;
    _map.selectedArtist = artist[kArtistKey];
}

- (NSString *)formattedDuration:(NSTimeInterval)millis {
    NSInteger minutes = (NSInteger)(millis / 60000.0);
    if (minutes >= 60 * 24) return [NSString stringWithFormat:@"%ld giorni", (long)(minutes / (60 * 24))];
    if (minutes >= 60) return [NSString stringWithFormat:@"%ld ore", (long)(minutes / 60)];
    return [NSString stringWithFormat:@"%ld minuti", (long)minutes];
}

- (void)openSelectedArtist {
    NSString *uri = _selectedArtist[@"artistURI"];
    if (!uri.length) uri = _selectedArtist[@"trackURI"];
    NSURL *url = uri.length ? [NSURL URLWithString:uri] : nil;
    if (!SGOpenSpotifyURI(url)) [self showAlert:@"Impossibile aprire in Spotify" message:uri ?: @"Questo ascolto non contiene un link Spotify."];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self refresh];
    return YES;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end

static UIViewController *controllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

void SGRMusicUniversePresentFrom(UIView *source) {
    UIViewController *owner = controllerForView(source);
    if (!owner) {
        SGLog(@"music universe: could not find the Library's view controller");
        return;
    }
    if ([owner.presentedViewController isKindOfClass:SGRMusicUniverseViewController.class]) return;
    SGRMusicUniverseViewController *page = [SGRMusicUniverseViewController new];
    [owner presentViewController:page animated:YES completion:nil];
}

static SGRUniverseStore *sgr_universeStore;

%ctor {
    if (!SGRedesignedUI()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        sgr_universeStore = SGRUniverseStore.shared;
        SGAddPlayerStateObserver(sgr_universeStore);
        SPTPlayerState *state = SGPlayerState();
        if (state) [sgr_universeStore playerStateDidChange:state];
    });
}

// The queue lives in the same in-player stage as lyrics. Its translucent material lets the current
// artwork remain visible underneath while the shared player layout moves the cover to its thumbnail.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Player.h"
#import <objc/message.h>

static char kQueueOverlayKey;
static NSCache<NSString *, UIImage *> *sg_queueArtwork;

static NSString *queueTrackURI(SPTPlayerTrack *track) {
    id uri = track.URI;
    if ([uri isKindOfClass:NSURL.class]) return [(NSURL *)uri absoluteString];
    return [uri isKindOfClass:NSString.class] ? uri : nil;
}

static NSArray<SPTPlayerTrack *> *queueFuture(SPTPlayerState *state) {
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    NSMutableArray<SPTPlayerTrack *> *tracks = [NSMutableArray array];
    for (id item in [future isKindOfClass:NSArray.class] ? future : @[]) {
        if (![item isKindOfClass:objc_getClass("SPTPlayerTrack")]) continue;
        if (!queueTrackURI(item) || ![(SPTPlayerTrack *)item trackTitle].length) continue;
        [tracks addObject:item];
    }
    return tracks;
}

static NSArray<SPTPlayerTrack *> *queueUpcoming(NSArray *queueTracks, NSArray<SPTPlayerTrack *> *future) {
    NSMutableArray<SPTPlayerTrack *> *tracks = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *queueOccurrences = [NSMutableDictionary dictionary];
    for (id item in queueTracks ?: @[]) {
        if (![item isKindOfClass:objc_getClass("SPTPlayerTrack")]) continue;
        SPTPlayerTrack *track = item;
        NSString *uri = queueTrackURI(track);
        if (!uri.length || !track.trackTitle.length) continue;
        [tracks addObject:track];
        queueOccurrences[uri] = @([queueOccurrences[uri] unsignedIntegerValue] + 1);
    }

    NSMutableDictionary<NSString *, NSNumber *> *futureOccurrences = [NSMutableDictionary dictionary];
    for (SPTPlayerTrack *track in future ?: @[]) {
        NSString *uri = queueTrackURI(track);
        if (!uri.length || !track.trackTitle.length) continue;
        NSUInteger occurrence = [futureOccurrences[uri] unsignedIntegerValue] + 1;
        futureOccurrences[uri] = @(occurrence);
        if (occurrence <= [queueOccurrences[uri] unsignedIntegerValue]) continue;
        [tracks addObject:track];
    }
    return tracks;
}

static NSURL *queueArtworkURL(SPTPlayerTrack *track) {
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    for (NSString *key in @[@"image_xlarge_url", @"image_large_url", @"image_url", @"image_small_url"]) {
        id value = metadata[key];
        if (![value isKindOfClass:NSString.class] || ![value length]) continue;
        NSURL *url = nil;
        if ([value hasPrefix:@"https://"]) {
            url = [NSURL URLWithString:value];
        } else if ([value hasPrefix:@"spotify:image:"]) {
            NSString *identifier = [value substringFromIndex:@"spotify:image:".length];
            NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"] invertedSet];
            if ([identifier rangeOfCharacterFromSet:invalid].location != NSNotFound) continue;
            url = [NSURL URLWithString:[@"https://i.scdn.co/image/" stringByAppendingString:identifier]];
        }
        if ([url.scheme isEqualToString:@"https"] && [url.host isEqualToString:@"i.scdn.co"]) return url;
    }
    return nil;
}

@interface SGRQueueCell : UITableViewCell
@property (nonatomic, copy) NSString *trackURI;
@property (nonatomic, readonly) UIImageView *artwork;
- (void)showTrack:(SPTPlayerTrack *)track;
@end

@implementation SGRQueueCell
- (UIImageView *)artwork {
    UIImageView *image = objc_getAssociatedObject(self, @selector(artwork));
    if (!image) {
        image = [UIImageView new];
        image.contentMode = UIViewContentModeScaleAspectFill;
        image.clipsToBounds = YES;
        image.layer.cornerRadius = 8;
        objc_setAssociatedObject(self, @selector(artwork), image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.contentView addSubview:image];
    }
    return image;
}

- (UILabel *)trackTitleLabel {
    UILabel *label = objc_getAssociatedObject(self, @selector(trackTitleLabel));
    if (!label) {
        label = [UILabel new];
        label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        label.textColor = UIColor.whiteColor;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        objc_setAssociatedObject(self, @selector(trackTitleLabel), label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.contentView addSubview:label];
    }
    return label;
}

- (UILabel *)artistLabel {
    UILabel *label = objc_getAssociatedObject(self, @selector(artistLabel));
    if (!label) {
        label = [UILabel new];
        label.font = [UIFont systemFontOfSize:13];
        label.textColor = [UIColor colorWithWhite:1 alpha:0.62];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        objc_setAssociatedObject(self, @selector(artistLabel), label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.contentView addSubview:label];
    }
    return label;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    [self artwork];
    [self trackTitleLabel];
    [self artistLabel];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = self.contentView.bounds.size.height;
    UIImageView *image = [self artwork];
    image.frame = CGRectMake(8, (height - 42) / 2, 42, 42);
    CGFloat x = CGRectGetMaxX(image.frame) + 12;
    CGFloat width = MAX(0, self.contentView.bounds.size.width - x - 8);
    [self trackTitleLabel].frame = CGRectMake(x, 7, width, 22);
    [self artistLabel].frame = CGRectMake(x, 29, width, 18);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.trackURI = nil;
    [self artwork].image = nil;
    self.accessoryView = nil;
}

- (void)showTrack:(SPTPlayerTrack *)track {
    NSString *uri = queueTrackURI(track);
    self.trackURI = uri;
    [self trackTitleLabel].text = track.trackTitle;
    [self artistLabel].text = track.artistName;
    self.artwork.image = [sg_queueArtwork objectForKey:uri];
    NSURL *url = self.artwork.image ? nil : queueArtworkURL(track);
    if (!url) return;

    __weak SGRQueueCell *weakCell = self;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        UIImage *image = !error && status == 200 ? [UIImage imageWithData:data] : nil;
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [sg_queueArtwork setObject:image forKey:uri];
            SGRQueueCell *cell = weakCell;
            if ([cell.trackURI isEqualToString:uri]) cell.artwork.image = image;
        });
    }];
    [task resume];
}
@end

@interface SGRQueueOverlay : UIView <UITableViewDataSource, UITableViewDelegate, SGPlayerStateObserver, SPTPlayerQueueObserver>
- (void)stopObservingQueue;
@end

@implementation SGRQueueOverlay {
    UIVisualEffectView *_mosaicBlur;
    UILabel *_queueTitle, *_emptyQueue;
    UIButton *_shuffle, *_repeat, *_autoplay, *_clear;
    UITableView *_table;
    NSArray<SPTPlayerTrack *> *_tracks;
    NSArray<SPTPlayerTrack *> *_queueTracks;
    NSString *_contextURI;
    __weak id<SPTPlayer> _queuePlayer;
    id _artworkObserver;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (!sg_queueArtwork) sg_queueArtwork = [NSCache new];
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.layer.backgroundColor = UIColor.clearColor.CGColor;
    _mosaicBlur = [[UIVisualEffectView alloc] initWithEffect:nil];
    _mosaicBlur.userInteractionEnabled = NO;
    _mosaicBlur.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addSubview:_mosaicBlur];
    [NSNotificationCenter.defaultCenter addObserver:self
                                             selector:@selector(updateMosaicBlur)
                                                 name:SGRPlayerBackgroundDidChangeNotification
                                               object:nil];
    [self updateMosaicBlur];

    _shuffle = [self buttonWithSymbol:@"shuffle" title:@"Shuffle"];
    [_shuffle addTarget:self action:@selector(toggleShuffle) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_shuffle];
    _repeat = [self buttonWithSymbol:@"repeat" title:@"Repeat"];
    [_repeat addTarget:self action:@selector(cycleRepeat) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_repeat];
    // The active player bridge has no autoplay setter, so keep the reference control visible but unavailable.
    _autoplay = [self buttonWithSymbol:@"infinity" title:@"Autoplay unavailable"];
    _autoplay.enabled = NO;
    _autoplay.alpha = 0.55;
    [self addSubview:_autoplay];

    _queueTitle = [UILabel new];
    _queueTitle.text = @"Queue";
    _queueTitle.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    _queueTitle.textColor = UIColor.whiteColor;
    [self addSubview:_queueTitle];
    _clear = [UIButton buttonWithType:UIButtonTypeSystem];
    [_clear setTitle:@"Clear" forState:UIControlStateNormal];
    _clear.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _clear.accessibilityLabel = @"Clear upcoming tracks";
    [_clear addTarget:self action:@selector(clearQueue) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_clear];
    _emptyQueue = [UILabel new];
    _emptyQueue.text = @"No upcoming tracks";
    _emptyQueue.font = [UIFont systemFontOfSize:15];
    _emptyQueue.textColor = [UIColor colorWithWhite:1 alpha:0.62];
    _emptyQueue.textAlignment = NSTextAlignmentCenter;
    _emptyQueue.hidden = YES;
    [self addSubview:_emptyQueue];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.opaque = NO;
    _table.backgroundColor = UIColor.clearColor;
    _table.backgroundView = nil;
    _table.layer.backgroundColor = UIColor.clearColor.CGColor;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.rowHeight = 52;
    _table.estimatedRowHeight = 52;
    _table.dataSource = self;
    _table.delegate = self;
    _table.contentInset = UIEdgeInsetsMake(2, 0, 4, 0);
    _table.showsVerticalScrollIndicator = YES;
    _table.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _table.scrollEnabled = YES;
    [_table registerClass:SGRQueueCell.class forCellReuseIdentifier:@"queue-track"];
    [self addSubview:_table];

    SGAddPlayerStateObserver(self);
    id<SPTPlayer> player = SGKaraokePlayer();
    if ([player respondsToSelector:@selector(addPlayerQueueObserver:)]) {
        _queuePlayer = player;
        [player addPlayerQueueObserver:self];
    } else {
        SGLog(@"redesign queue: player has no queue observer; showing the tracks in player state only");
    }
    __weak typeof(self) weakSelf = self;
    _artworkObserver = [NSNotificationCenter.defaultCenter addObserverForName:SGRNowPlayingArtworkDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        [weakSelf refresh];
    }];
    [self refresh];
    return self;
}

- (void)dealloc {
    if (_artworkObserver) [NSNotificationCenter.defaultCenter removeObserver:_artworkObserver];
    [NSNotificationCenter.defaultCenter removeObserver:self name:SGRPlayerBackgroundDidChangeNotification object:nil];
    [self stopObservingQueue];
}

- (void)updateMosaicBlur {
    BOOL mosaic = SGRPlayerBackgroundStyle() == SGRPlayerBackgroundMosaic;
    _mosaicBlur.effect = mosaic
        ? [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]
        : nil;
    _mosaicBlur.backgroundColor = mosaic ? [UIColor colorWithWhite:0 alpha:0.18] : UIColor.clearColor;
}

- (void)stopObservingQueue {
    id<SPTPlayer> player = _queuePlayer;
    _queuePlayer = nil;
    if ([player respondsToSelector:@selector(removePlayerQueueObserver:)])
        [player removePlayerQueueObserver:self];
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol title:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = title;
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    button.layer.cornerRadius = 12;
    return button;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _mosaicBlur.frame = bounds;
    [self sendSubviewToBack:_mosaicBlur];
    CGFloat margin = 12, gap = 8, actionHeight = 44;
    CGFloat actionWidth = MAX(0, (bounds.size.width - margin * 2 - gap * 2) / 3);
    _shuffle.frame = CGRectMake(margin, 8, actionWidth, actionHeight);
    _repeat.frame = CGRectMake(CGRectGetMaxX(_shuffle.frame) + gap, 8, actionWidth, actionHeight);
    _autoplay.frame = CGRectMake(CGRectGetMaxX(_repeat.frame) + gap, 8, actionWidth, actionHeight);
    _queueTitle.frame = CGRectMake(margin, 58, bounds.size.width - margin * 2 - 60, 26);
    _clear.frame = CGRectMake(bounds.size.width - 72, 50, 60, 44);
    CGFloat tableTop = CGRectGetMaxY(_queueTitle.frame) + 6;
    CGFloat tableBottom = bounds.size.height - 4;
    _table.frame = CGRectMake(margin, tableTop, bounds.size.width - margin * 2, MAX(0, tableBottom - tableTop));
    _emptyQueue.frame = _table.frame;
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self refresh];
}

- (void)player:(id)player queueDidChange:(id<SPTPlayerQueue>)queue {
    id value = [queue respondsToSelector:@selector(nextTracks)] ? queue.nextTracks : nil;
    if (![value isKindOfClass:NSArray.class]) {
        SGLog(@"redesign queue: received a queue snapshot without nextTracks (%@)", NSStringFromClass([queue class]));
        return;
    }
    NSArray<SPTPlayerTrack *> *tracks = [value copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_queuePlayer != player) return;
        self->_queueTracks = tracks;
        [self refresh];
    });
}

- (void)refresh {
    SPTPlayerState *state = SGPlayerState();
    NSString *artworkURI = nil;
    UIImage *artwork = SGRNowPlayingArtwork(&artworkURI, NULL);
    NSString *currentURI = SGURIString(state.track.URI);
    SGRPlayerLyricsUpdateArtwork([artworkURI isEqualToString:currentURI] ? artwork : nil);
    id context = [state.contextURI isKindOfClass:NSURL.class] ? [(NSURL *)state.contextURI absoluteString] :
        ([state.contextURI isKindOfClass:NSString.class] ? state.contextURI : nil);
    if (![_contextURI isEqualToString:context]) {
        _contextURI = [context copy];
        _queueTracks = nil;
    }
    _tracks = queueUpcoming(_queueTracks, queueFuture(state));
    _emptyQueue.hidden = _tracks.count != 0;
    id player = SGKaraokePlayer();
    SEL clearSelector = NSSelectorFromString(@"clearQueue");
    _clear.enabled = _tracks.count > 0 && [player respondsToSelector:clearSelector];
    _clear.alpha = _clear.enabled ? 1 : 0.45;
    _shuffle.selected = state.options.shufflingContext;
    _shuffle.backgroundColor = _shuffle.selected ? [UIColor colorWithWhite:1 alpha:0.28] : [UIColor colorWithWhite:1 alpha:0.12];
    BOOL repeatTrack = state.options.repeatingTrack;
    BOOL repeatContext = state.options.repeatingContext;
    [_repeat setImage:[UIImage systemImageNamed:repeatTrack ? @"repeat.1" : @"repeat"] forState:UIControlStateNormal];
    _repeat.selected = repeatTrack || repeatContext;
    _repeat.backgroundColor = _repeat.selected ? [UIColor colorWithWhite:1 alpha:0.28] : [UIColor colorWithWhite:1 alpha:0.12];
    [_table reloadData];
    [self setNeedsLayout];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _tracks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SGRQueueCell *cell = [tableView dequeueReusableCellWithIdentifier:@"queue-track" forIndexPath:indexPath];
    if (indexPath.row < _tracks.count) [cell showTrack:_tracks[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= _tracks.count) return;
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerTrack *track = _tracks[indexPath.row];
    if (![player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) {
        SGLog(@"redesign queue: player cannot play queued track %@", queueTrackURI(track));
        return;
    }
    id result = [player skipToNextTrackWithOptions:nil track:track];
    SGLog(@"redesign queue: play %@ -> %@", queueTrackURI(track), result);
}

- (void)toggleShuffle {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = SGPlayerState();
    id result = [player setShufflingContext:!state.options.shufflingContext];
    SGLog(@"redesign queue: shuffle -> %@", result);
}

- (void)cycleRepeat {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerOptions *options = SGPlayerState().options;
    id result = nil;
    if (options.repeatingTrack) {
        [player setRepeatingTrack:NO];
        result = [player setRepeatingContext:NO];
    }
    else if (options.repeatingContext) result = [player setRepeatingTrack:YES];
    else result = [player setRepeatingContext:YES];
    SGLog(@"redesign queue: repeat -> %@", result);
}

- (void)clearQueue {
    id player = SGKaraokePlayer();
    SEL selector = NSSelectorFromString(@"clearQueue");
    if (![player respondsToSelector:selector]) {
        SGLog(@"redesign queue: clear queue is unavailable from the active player");
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(player, selector);
    SGLog(@"redesign queue: cleared upcoming tracks");
}

@end

BOOL SGRPlayerQueueIsOpen(void) {
    UIView *host = SGRPlayerContentHost();
    return host && objc_getAssociatedObject(host, &kQueueOverlayKey) != nil;
}

void SGRPlayerQueueClose(void) {
    UIView *host = SGRPlayerContentHost();
    SGRQueueOverlay *overlay = host ? objc_getAssociatedObject(host, &kQueueOverlayKey) : nil;
    if (!overlay) return;
    [overlay stopObservingQueue];
    objc_setAssociatedObject(host, &kQueueOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGRPlayerQueueSetInlineView(nil, NO, YES);
}

void SGRPlayerQueueCloseForTransition(void) {
    UIView *host = SGRPlayerContentHost();
    SGRQueueOverlay *overlay = host ? objc_getAssociatedObject(host, &kQueueOverlayKey) : nil;
    if (!overlay) return;
    [overlay stopObservingQueue];
    objc_setAssociatedObject(host, &kQueueOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGRPlayerQueueSetInlineView(nil, NO, NO);
}

void SGRPlayerQueueReleaseForLyrics(void) {
    UIView *host = SGRPlayerContentHost();
    SGRQueueOverlay *overlay = host ? objc_getAssociatedObject(host, &kQueueOverlayKey) : nil;
    if (!overlay) return;
    [overlay stopObservingQueue];
    objc_setAssociatedObject(host, &kQueueOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void SGRPlayerQueuePresentFrom(UIView *source) {
    UIView *host = SGRPlayerContentHost();
    if (!host && source.bounds.size.height > 200) host = source;
    if (!host || !host.window) {
        SGLog(@"redesign queue: cannot open without the full-screen player host");
        return;
    }
    SGRQueueOverlay *overlay = objc_getAssociatedObject(host, &kQueueOverlayKey);
    if (overlay) {
        SGRPlayerQueueClose();
        return;
    }
    overlay = [[SGRQueueOverlay alloc] initWithFrame:CGRectZero];
    objc_setAssociatedObject(host, &kQueueOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!SGRPlayerQueueSetInlineView(overlay, YES, YES)) {
        [overlay stopObservingQueue];
        objc_setAssociatedObject(host, &kQueueOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%ctor {
    if (!SGRedesignedUI()) return;
}

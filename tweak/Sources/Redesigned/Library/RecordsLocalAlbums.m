#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Shared/Navigation/Links.h"
#import "RecordsLocalAlbums.h"

NSNotificationName const SGLocalAlbumsDidChangeNotification = @"spotifyglass.records.localAlbumsChanged";

@interface SGLocalAlbum ()
@property (nonatomic, strong) UIImage *cover;
@end

@implementation SGLocalTrack
@end

@implementation SGLocalAlbum
@end

static NSArray<SGLocalAlbum *> *sg_albums;
static BOOL sg_scanning;

static NSString *trim(NSString *text) {
    return [[text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] copy];
}

static NSString *fold(NSString *text) {
    return [trim(text) stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch
                                           locale:NSLocale.currentLocale];
}

static NSString *spotifyLocalPart(NSString *text) {
    NSMutableString *encoded = [NSMutableString string];
    const unsigned char *bytes = (const unsigned char *)(text ?: @"").UTF8String;
    for (const unsigned char *byte = bytes; byte && *byte; byte++) {
        if ((*byte >= 'a' && *byte <= 'z') || (*byte >= 'A' && *byte <= 'Z') ||
            (*byte >= '0' && *byte <= '9') || strchr(".-*_", *byte)) [encoded appendFormat:@"%c", *byte];
        else if (*byte == ' ') [encoded appendString:@"+"];
        else [encoded appendFormat:@"%%%02X", *byte];
    }
    return encoded;
}

static NSString *metadataText(NSArray<AVMetadataItem *> *items, AVMetadataKey key) {
    for (AVMetadataItem *item in items) {
        if ([item.commonKey isEqual:key] && [item.stringValue isKindOfClass:NSString.class]) return trim(item.stringValue);
    }
    return @"";
}

static SGLocalTrack *trackForURL(NSURL *url, NSDate **modified, NSInteger *year, NSInteger *seconds, UIImage **cover) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
    NSArray<AVMetadataItem *> *metadata = asset.commonMetadata ?: @[];
    NSString *title = metadataText(metadata, AVMetadataCommonKeyTitle);
    NSString *artist = metadataText(metadata, AVMetadataCommonKeyArtist);
    NSString *album = metadataText(metadata, AVMetadataCommonKeyAlbumName);
    if (!title.length) title = url.lastPathComponent.stringByDeletingPathExtension;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
    *modified = attributes[NSFileModificationDate] ?: attributes[NSFileCreationDate] ?: NSDate.distantPast;
    *seconds = isfinite(CMTimeGetSeconds(asset.duration)) ? (NSInteger)llround(CMTimeGetSeconds(asset.duration)) : 0;
    for (AVMetadataItem *item in metadata) {
        if ([item.commonKey isEqual:AVMetadataCommonKeyCreationDate]) {
            NSString *date = item.stringValue;
            if (date.length >= 4) *year = [[date substringToIndex:4] integerValue];
        }
        if (!*cover && [item.commonKey isEqual:AVMetadataCommonKeyArtwork]) {
            NSData *data = [item.dataValue isKindOfClass:NSData.class] ? item.dataValue : nil;
            UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
            if (image) *cover = [image imageByPreparingForDisplay] ?: image;
        }
    }

    SGLocalTrack *track = [SGLocalTrack new];
    track.path = url.path;
    track.title = title;
    track.artist = artist;
    track.seconds = *seconds;
    NSString *uri = [NSString stringWithFormat:@"spotify:local:%@:%@:%@:%ld",
                     spotifyLocalPart(artist), spotifyLocalPart(album), spotifyLocalPart(title), (long)*seconds];
    track.uri = uri;
    return track;
}

static NSArray<SGLocalAlbum *> *scanLocalAlbums(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents.length) return @[];
    NSSet *extensions = [NSSet setWithArray:@[@"mp3", @"m4a", @"mp4", @"aac", @"wav", @"aif", @"aiff", @"flac", @"caf", @"alac", @"ogg"]];
    NSURL *root = [NSURL fileURLWithPath:documents isDirectory:YES];
    NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtURL:root
                                                     includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLContentModificationDateKey]
                                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                   errorHandler:nil];
    NSMutableDictionary<NSString *, NSMutableArray<SGLocalTrack *> *> *groups = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray *> *details = [NSMutableDictionary dictionary];
    for (NSURL *url in files) {
        if (! [extensions containsObject:url.pathExtension.lowercaseString]) continue;
        NSString *lowerPath = url.path.lowercaseString;
        if ([lowerPath containsString:@"/spoti.pw/"] || [lowerPath containsString:@"/vitrinerecords/"]) continue;
        NSDate *modified = nil;
        NSInteger year = 0, seconds = 0;
        UIImage *cover = nil;
        SGLocalTrack *track = trackForURL(url, &modified, &year, &seconds, &cover);
        // Files without album tags stay visible as one-track records, instead of vanishing.
        NSString *album = metadataText([AVURLAsset URLAssetWithURL:url options:nil].commonMetadata ?: @[], AVMetadataCommonKeyAlbumName);
        if (!album.length) album = track.title;
        NSString *artist = track.artist.length ? track.artist : @"Unknown Artist";
        NSString *key = [NSString stringWithFormat:@"%@\n%@", fold(artist), fold(album)];
        if (!groups[key]) {
            groups[key] = [NSMutableArray array];
            details[key] = [NSMutableArray arrayWithObjects:album, artist, @(year), modified ?: NSDate.distantPast, cover ?: NSNull.null, nil];
        }
        [groups[key] addObject:track];
        NSArray *old = details[key];
        NSDate *added = old[3];
        if ([modified compare:added] == NSOrderedDescending) details[key][3] = modified;
        if (year > 0 && [old[2] integerValue] == 0) details[key][2] = @(year);
        if (old[4] == NSNull.null && cover) details[key][4] = cover;
    }

    NSMutableArray<SGLocalAlbum *> *albums = [NSMutableArray array];
    for (NSString *key in groups) {
        NSArray *info = details[key];
        SGLocalAlbum *album = [SGLocalAlbum new];
        album.title = info[0];
        album.artist = info[1];
        album.year = [info[2] integerValue];
        album.added = info[3];
        album.cover = info[4] == NSNull.null ? nil : info[4];
        album.tracks = [groups[key] sortedArrayUsingComparator:^NSComparisonResult(SGLocalTrack *a, SGLocalTrack *b) {
            return [a.title localizedStandardCompare:b.title];
        }];
        for (SGLocalTrack *track in album.tracks) album.seconds += track.seconds;
        [albums addObject:album];
    }
    [albums sortUsingComparator:^NSComparisonResult(SGLocalAlbum *a, SGLocalAlbum *b) {
        return [a.title localizedStandardCompare:b.title];
    }];
    return albums;
}

NSArray<SGLocalAlbum *> *SGLocalAlbums(void) {
    if (!sg_albums && !sg_scanning) SGLocalAlbumsRefresh(nil);
    return sg_albums ?: @[];
}

void SGLocalAlbumsRefresh(void (^done)(void)) {
    if (sg_scanning) {
        if (done) dispatch_async(dispatch_get_main_queue(), done);
        return;
    }
    sg_scanning = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *albums = scanLocalAlbums();
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_albums = albums;
            sg_scanning = NO;
            [NSNotificationCenter.defaultCenter postNotificationName:SGLocalAlbumsDidChangeNotification object:nil];
            if (done) done();
        });
    });
}

void SGLocalAlbumCover(SGLocalAlbum *album, CGFloat side, void (^done)(UIImage *cover)) {
    UIImage *cover = album.cover;
    if (cover && side > 0 && MAX(cover.size.width, cover.size.height) > side) {
        CGFloat scale = side / MAX(cover.size.width, cover.size.height);
        CGSize size = CGSizeMake(round(cover.size.width * scale), round(cover.size.height * scale));
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
        cover = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) { [cover drawInRect:(CGRect){CGPointZero, size}]; }];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(cover); });
}

@interface SGRLocalAlbumPage : SGPage
- (instancetype)initWithAlbum:(SGLocalAlbum *)album;
@end

@implementation SGRLocalAlbumPage {
    SGLocalAlbum *_album;
}
- (instancetype)initWithAlbum:(SGLocalAlbum *)album {
    if (!(self = [super initWithStyle:UITableViewStylePlain])) return nil;
    _album = album;
    self.title = album.title;
    return self;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_album.tracks.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"local-record-track"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"local-record-track"];
    SGLocalTrack *track = _album.tracks[(NSUInteger)path.row];
    cell.textLabel.text = track.title;
    cell.detailTextLabel.text = track.artist.length ? track.artist : _album.artist;
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.62];
    cell.backgroundColor = UIColor.clearColor;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    SGLocalTrack *track = _album.tracks[(NSUInteger)path.row];
    if (!SGOpenSpotifyURI([NSURL URLWithString:track.uri])) SGLog(@"records: could not open local track %@", track.uri);
}
@end

UIViewController *SGRLocalAlbumPageNew(SGLocalAlbum *album) { return [[SGRLocalAlbumPage alloc] initWithAlbum:album]; }

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreText/CoreText.h>
#import <CoreVideo/CoreVideo.h>
#import <stdint.h>
#import <math.h>
#import <unistd.h>
#import "LockScreenLyrics.h"
#import "LockScreenLyricsVideo.h"
#import "Shared/Lyrics/Lyrics.h"

static UIImage *canvasFrame(NSURL *url, NSInteger positionMs, CGSize size) {
    if (!url) return nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
    generator.appliesPreferredTrackTransform = YES;
    generator.maximumSize = CGSizeMake(size.width, size.height);
    generator.requestedTimeToleranceBefore = kCMTimeZero;
    generator.requestedTimeToleranceAfter = CMTimeMake(1, 4);
    CMTime duration = asset.duration;
    NSInteger durationMs = CMTIME_IS_NUMERIC(duration) ? (NSInteger)llround(CMTimeGetSeconds(duration) * 1000) : 0;
    if (durationMs > 0) positionMs %= durationMs;
    CMTime time = CMTimeMake(MAX(positionMs, 0), 1000);
    CGImageRef image = [generator copyCGImageAtTime:time actualTime:nil error:nil];
    if (!image) return nil;
    UIImage *result = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    return result;
}

static CGImageRef blurred(CGImageRef image, CGSize size, CGFloat blurRatio) {
    if (!image) return NULL;
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}]; });
    CIImage *source = [CIImage imageWithCGImage:image];
    CGFloat scale = MAX(size.width / source.extent.size.width, size.height / source.extent.size.height);
    source = [source imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    source = [source imageByApplyingTransform:CGAffineTransformMakeTranslation((size.width - source.extent.size.width) / 2,
                                                                                (size.height - source.extent.size.height) / 2)];
    source = [[source imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:size.width * blurRatio];
    return [context createCGImage:source fromRect:(CGRect){CGPointZero, size}];
}

@interface SGLyricSticker : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic, strong) UIColor *background, *foreground;
@property (nonatomic) CGFloat width, height, paddingX, paddingY, rotation;
@property (nonatomic) NSInteger wordIndex;
@end
@implementation SGLyricSticker
@end

static uint32_t nextRandom(uint32_t *state) {
    *state = *state * 1664525u + 1013904223u;
    return *state;
}

static uint32_t lyricSeed(NSString *line) {
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = data.bytes;
    uint32_t hash = 2166136261u;
    for (NSUInteger index = 0; index < data.length; index++) hash = (hash ^ bytes[index]) * 16777619u;
    return hash ?: 1u;
}

static NSArray<NSString *> *lyricWords(NSString *line) {
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSArray<NSString *> *parts = [line componentsSeparatedByCharactersInSet:spaces];
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *part in parts) if (part.length) [words addObject:part];
    if (words.count > 1 || !line.length) return words;

    [words removeAllObjects];
    [line enumerateSubstringsInRange:NSMakeRange(0, line.length)
                            options:NSStringEnumerationByWords
                         usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
        if (substring.length) [words addObject:substring];
    }];
    if (words.count > 1 || (words.count && !SGKaraokeUnspacedScript(line))) return words;
    [line enumerateSubstringsInRange:NSMakeRange(0, line.length)
                            options:NSStringEnumerationByComposedCharacterSequences
                         usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
        if (substring.length) [words addObject:substring];
    }];
    return words;
}

static UIColor *mixKaraokeColors(UIColor *from, UIColor *to, CGFloat progress) {
    CGFloat fr = 1, fg = 1, fb = 1, fa = 1, tr = 1, tg = 1, tb = 1, ta = 1;
    if (![from getRed:&fr green:&fg blue:&fb alpha:&fa]) {
        CGFloat white = 1;
        [from getWhite:&white alpha:&fa];
        fr = fg = fb = white;
    }
    if (![to getRed:&tr green:&tg blue:&tb alpha:&ta]) {
        CGFloat white = 1;
        [to getWhite:&white alpha:&ta];
        tr = tg = tb = white;
    }
    return [UIColor colorWithRed:fr + (tr - fr) * progress
                           green:fg + (tg - fg) * progress
                            blue:fb + (tb - fb) * progress
                           alpha:fa + (ta - fa) * progress];
}

static NSAttributedString *karaokeLine(NSArray<SGKaraokeWord *> *words, NSString *fallback,
                                       NSInteger positionMs, UIFont *font,
                                       NSParagraphStyle *paragraph, UIColor *sungColor,
                                       UIColor *activeColor, UIColor *futureColor, BOOL uppercase) {
    if (!words.count) {
        NSString *text = uppercase ? fallback.uppercaseString : (fallback ?: @"");
        return [[NSAttributedString alloc] initWithString:text
                                               attributes:@{NSFontAttributeName: font,
                                                            NSForegroundColorAttributeName: sungColor,
                                                            NSParagraphStyleAttributeName: paragraph}];
    }
    NSMutableAttributedString *result = [NSMutableAttributedString new];
    for (NSUInteger index = 0; index < words.count; index++) {
        SGKaraokeWord *word = words[index];
        NSDictionary *spaceAttributes = @{NSFontAttributeName: font,
                                          NSForegroundColorAttributeName: sungColor,
                                          NSParagraphStyleAttributeName: paragraph};
        if (index && !word.joined) [result appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:spaceAttributes]];
        NSString *text = uppercase ? word.text.uppercaseString : word.text;
        if (!text.length) continue;
        if (word.end <= word.start) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:text
                attributes:@{NSFontAttributeName: font,
                             NSForegroundColorAttributeName: sungColor,
                             NSParagraphStyleAttributeName: paragraph}]];
            continue;
        }
        __block NSUInteger characterCount = 0;
        [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                                 options:NSStringEnumerationByComposedCharacterSequences
                              usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
            if (substring.length) characterCount++;
        }];
        if (!characterCount) continue;
        __block NSUInteger characterIndex = 0;
        [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                                 options:NSStringEnumerationByComposedCharacterSequences
                              usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
            if (!substring.length) return;
            CGFloat wordDuration = MAX((CGFloat)(word.end - word.start), 1);
            CGFloat charStart = word.start + wordDuration * characterIndex / characterCount;
            CGFloat charEnd = word.start + wordDuration * (characterIndex + 1) / characterCount;
            CGFloat linear = positionMs <= charStart ? 0 : (positionMs >= charEnd ? 1 :
                            (positionMs - charStart) / MAX(charEnd - charStart, 1));
            CGFloat eased = linear * linear * (3 - 2 * linear);
            BOOL inMotion = linear > 0 && linear < 1;
            CGFloat lift = font.pointSize * 0.14 * eased;
            if (inMotion) lift += font.pointSize * 0.055 * sin(M_PI * linear);
            CGFloat colorProgress = linear < 0.5 ? linear * 2 : (linear - 0.5) * 2;
            CGFloat colorEased = colorProgress * colorProgress * (3 - 2 * colorProgress);
            UIColor *color = linear < 0.5
                ? mixKaraokeColors(futureColor, activeColor, colorEased)
                : mixKaraokeColors(activeColor, sungColor, colorEased);
            NSMutableDictionary *attributes = [@{NSFontAttributeName: font,
                                                  NSForegroundColorAttributeName: color,
                                                  NSParagraphStyleAttributeName: paragraph} mutableCopy];
            if (lift > 0.01) attributes[NSBaselineOffsetAttributeName] = @(-lift);
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:substring attributes:attributes]];
            characterIndex++;
        }];
    }
    return result;
}

// Keep every lyric visible inside its design's text box. Several lock-screen styles use a
// deliberately short caption area; scaling the composed text block is preferable to clipping
// the last wrapped line or dropping a long word at the edge.
static void drawFittedLyric(CGContextRef context, NSAttributedString *text, CGRect rect) {
    if (!text.length || rect.size.width <= 0 || rect.size.height <= 0) return;

    NSMutableAttributedString *wrapped = [text mutableCopy];
    __block CGFloat largestFontSize = 0;
    [wrapped enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, wrapped.length)
                         options:0 usingBlock:^(UIFont *font, NSRange range, BOOL *stop) {
        if (font) largestFontSize = MAX(largestFontSize, font.pointSize);
    }];
    NSMutableArray<NSDictionary *> *paragraphUpdates = [NSMutableArray array];
    [wrapped enumerateAttribute:NSParagraphStyleAttributeName inRange:NSMakeRange(0, wrapped.length)
                         options:0 usingBlock:^(NSParagraphStyle *style, NSRange range, BOOL *stop) {
        NSMutableParagraphStyle *paragraph = style ? [style mutableCopy] : [NSMutableParagraphStyle new];
        paragraph.lineBreakMode = NSLineBreakByCharWrapping;
        [paragraphUpdates addObject:@{@"range": [NSValue valueWithRange:range], @"style": paragraph}];
    }];
    for (NSDictionary *update in paragraphUpdates)
        [wrapped addAttribute:NSParagraphStyleAttributeName value:update[@"style"] range:[update[@"range"] rangeValue]];

    CGRect measured = [wrapped boundingRectWithSize:CGSizeMake(rect.size.width, CGFLOAT_MAX)
                                            options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                            context:nil];
    CGFloat contentHeight = ceil(MAX(measured.size.height, largestFontSize));
    CGFloat verticalSafety = largestFontSize * 0.30;
    CGFloat scale = MIN(1, rect.size.height / MAX(contentHeight + verticalSafety, 1));
    if (!isfinite(scale) || scale <= 0) return;

    CGFloat drawnWidth = rect.size.width * scale;
    CGFloat drawHeight = contentHeight + verticalSafety;
    CGFloat drawnHeight = drawHeight * scale;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, CGRectGetMidX(rect) - drawnWidth / 2,
                          CGRectGetMidY(rect) - drawnHeight / 2);
    CGContextScaleCTM(context, scale, scale);
    [wrapped drawInRect:CGRectMake(0, 0, rect.size.width, drawHeight)];
    CGContextRestoreGState(context);
}

static void drawLyricsStack(CGContextRef context, CGSize size, NSArray<SGKaraokeLine *> *lines,
                            NSInteger suggestedIndex, NSInteger positionMs) {
    if (!lines.count) return;
    NSInteger activeIndex = SGKaraokeLeadLine(lines, positionMs);
    if (activeIndex < 0) activeIndex = MIN(MAX(suggestedIndex, 0), (NSInteger)lines.count - 1);
    activeIndex = MIN(MAX(activeIndex, 0), (NSInteger)lines.count - 1);
    SGKaraokeLine *activeLine = lines[(NSUInteger)activeIndex];
    NSInteger transitionStart = activeLine.start;
    if (activeIndex > 0) transitionStart = MAX(transitionStart, lines[(NSUInteger)activeIndex - 1].end);
    CGFloat rawTransition = MIN(MAX((positionMs - transitionStart) / 360.0, 0), 1);
    CGFloat transition = rawTransition * rawTransition * (3 - 2 * rawTransition);
    CGFloat width = size.width;
    CGFloat rowHeight = MAX(size.height * 0.09, width * 0.05 * 2.45);
    CGFloat centerY = size.height * 0.39;
    CGFloat scrollOffset = rowHeight * (1 - transition);
    CGFloat margin = width * 0.085;
    CGFloat textWidth = width - margin * 2;
    UIFont *activeFont = [UIFont systemFontOfSize:width * 0.050 weight:UIFontWeightBold];
    UIFont *contextFont = [UIFont systemFontOfSize:width * 0.043 weight:UIFontWeightSemibold];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = UIColor.blackColor;
    shadow.shadowBlurRadius = width * 0.012;
    NSMutableParagraphStyle *left = [NSMutableParagraphStyle new];
    left.alignment = NSTextAlignmentLeft;
    left.lineBreakMode = NSLineBreakByCharWrapping;
    left.lineSpacing = width * 0.003;
    NSAttributedString *activeText = karaokeLine(activeLine.words, SGKaraokeLineText(activeLine),
        positionMs, activeFont, left, [UIColor colorWithWhite:1 alpha:0.96], UIColor.whiteColor,
        [UIColor colorWithWhite:1 alpha:0.43], NO);
    CGRect activeMeasured = [activeText boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading context:nil];
    CGFloat activeRowHeight = MIN(size.height * 0.24,
        MAX(rowHeight, ceil(activeMeasured.size.height + activeFont.pointSize * 0.30)));

    CGContextSaveGState(context);
    CGContextClipToRect(context, CGRectMake(0, size.height * 0.105, width, size.height * 0.79));
    NSInteger firstIndex = MAX(0, activeIndex - 3);
    NSInteger lastIndex = MIN((NSInteger)lines.count - 1, activeIndex + 3);
    for (NSInteger index = firstIndex; index <= lastIndex; index++) {
        NSInteger distance = index > activeIndex ? index - activeIndex : activeIndex - index;
        CGFloat alpha = distance == 0 ? (0.34 + 0.66 * transition)
            : distance == 1 ? (index < activeIndex ? (0.34 + 0.66 * (1 - transition)) : 0.43)
            : distance == 2 ? 0.31 : distance == 3 ? 0.20 : 0.12;
        CGFloat y = centerY + scrollOffset;
        CGFloat drawHeight = rowHeight * 0.96;
        if (index == activeIndex) {
            drawHeight = activeRowHeight;
        } else {
            CGFloat direction = index < activeIndex ? -1 : 1;
            y += direction * (activeRowHeight * 0.5 + rowHeight * (distance - 0.5));
        }
        SGKaraokeLine *line = lines[(NSUInteger)index];
        NSString *text = SGKaraokeLineText(line);
        if (!text.length) continue;
        NSAttributedString *attributed = index == activeIndex
            ? activeText
            : [[NSAttributedString alloc] initWithString:text attributes:@{
                NSFontAttributeName: contextFont,
                NSForegroundColorAttributeName: UIColor.whiteColor,
                NSParagraphStyleAttributeName: left,
            }];
        NSMutableAttributedString *row = [attributed mutableCopy];
        [row addAttribute:NSShadowAttributeName value:shadow range:NSMakeRange(0, row.length)];
        CGRect rect = CGRectMake(margin, y - drawHeight * 0.5, textWidth, drawHeight);
        CGContextSaveGState(context);
        CGContextSetAlpha(context, alpha);
        drawFittedLyric(context, row, rect);
        CGContextRestoreGState(context);
    }
    CGContextRestoreGState(context);
}

static SGLyricSticker *sticker(NSString *word, CGSize size, CGFloat baseFont, uint32_t *random) {
    SGLyricSticker *tile = [SGLyricSticker new];
    CGFloat scale = 0.94 + (nextRandom(random) % 13) / 100.0;
    CGFloat fontSize = baseFont * scale;
    UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightHeavy];
    CGFloat paddingX = baseFont * 0.34, paddingY = baseFont * 0.16;
    CGFloat textWidth = [word sizeWithAttributes:@{NSFontAttributeName: font}].width;
    CGFloat maxWidth = size.width * 0.88;
    BOOL wraps = textWidth + 2 * paddingX > maxWidth;
    CGFloat tileHeight = font.lineHeight + 2 * paddingY;
    if (wraps) {
        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.alignment = NSTextAlignmentCenter;
        paragraph.lineBreakMode = NSLineBreakByCharWrapping;
        NSAttributedString *measuredWord = [[NSAttributedString alloc] initWithString:word attributes:@{
            NSFontAttributeName: font,
            NSParagraphStyleAttributeName: paragraph,
        }];
        CGRect measured = [measuredWord boundingRectWithSize:CGSizeMake(maxWidth - 2 * paddingX, CGFLOAT_MAX)
                                                      options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                      context:nil];
        textWidth = maxWidth - 2 * paddingX;
        tileHeight = ceil(MAX(font.lineHeight, measured.size.height) + 2 * paddingY);
    }
    uint32_t color = nextRandom(random) % 3;
    NSArray<UIColor *> *backgrounds = @[
        [UIColor colorWithRed:0.02 green:0.39 blue:0.76 alpha:1],
        [UIColor colorWithWhite:0.98 alpha:1],
        [UIColor colorWithWhite:0.015 alpha:1],
    ];
    tile.text = word;
    tile.font = font;
    tile.paddingX = paddingX;
    tile.paddingY = paddingY;
    tile.width = ceil(wraps ? maxWidth : textWidth + 2 * paddingX);
    tile.height = tileHeight;
    tile.background = backgrounds[color];
    tile.foreground = color == 2 ? UIColor.whiteColor : UIColor.blackColor;
    tile.rotation = (((NSInteger)(nextRandom(random) % 81) - 40) / 10.0) * (CGFloat)M_PI / 180.0;
    return tile;
}

static void drawWordCollage(CGContextRef context, NSString *line, CGSize size,
                           NSArray<SGKaraokeWord *> *words, NSInteger positionMs, NSInteger activeWordIndex) {
    NSArray<NSString *> *tokens = lyricWords(line);
    if (!tokens.count) return;

    CGFloat baseFont = size.width * 0.052;
    CGFloat gap = baseFont * 0.16;
    CGFloat rowGap = baseFont * 0.34;
    CGFloat maxRowWidth = size.width * 0.88;
    uint32_t random = lyricSeed(line);
    NSMutableArray<NSMutableArray<SGLyricSticker *> *> *rows = [NSMutableArray array];
    NSMutableArray<NSNumber *> *rowWidths = [NSMutableArray array];
    NSMutableArray<NSNumber *> *rowHeights = [NSMutableArray array];
    NSMutableArray<SGLyricSticker *> *row = nil;
    CGFloat rowWidth = 0, rowHeight = 0;

    NSUInteger wordIndex = 0;
    for (NSString *word in tokens) {
        SGLyricSticker *tile = sticker(word, size, baseFont, &random);
        tile.wordIndex = (NSInteger)wordIndex++;
        CGFloat proposed = row.count ? rowWidth + gap + tile.width : tile.width;
        if (!row || (row.count && proposed > maxRowWidth)) {
            if (row) {
                [rowWidths addObject:@(rowWidth)];
                [rowHeights addObject:@(rowHeight)];
            }
            row = [NSMutableArray array];
            [rows addObject:row];
            rowWidth = 0;
            rowHeight = 0;
        }
        if (row.count) rowWidth += gap;
        [row addObject:tile];
        rowWidth += tile.width;
        rowHeight = MAX(rowHeight, tile.height);
    }
    if (row) {
        [rowWidths addObject:@(rowWidth)];
        [rowHeights addObject:@(rowHeight)];
    }

    CGFloat totalHeight = rowGap * MAX((NSInteger)rows.count - 1, 0);
    for (NSNumber *height in rowHeights) totalHeight += height.doubleValue;
    CGFloat clusterCenter = size.height * 0.39;
    CGFloat fitScale = totalHeight > 0 ? MIN(1, size.height * 0.68 / totalHeight) : 1;
    CGFloat clusterHeight = totalHeight * fitScale;
    CGFloat top = size.height * 0.08;
    CGFloat bottom = size.height * 0.92;
    CGFloat y = MIN(MAX(clusterCenter - clusterHeight / 2, top), MAX(top, bottom - clusterHeight));

    for (NSUInteger rowIndex = 0; rowIndex < rows.count; rowIndex++) {
        NSArray<SGLyricSticker *> *tiles = rows[rowIndex];
        CGFloat currentRowHeight = rowHeights[rowIndex].doubleValue * fitScale;
        CGFloat currentRowWidth = rowWidths[rowIndex].doubleValue * fitScale;
        CGFloat x = (size.width - currentRowWidth) / 2;
        CGFloat rowJitter = (((NSInteger)(nextRandom(&random) % 41) - 20) / 1000.0) * size.width;
        CGFloat minX = size.width * 0.04;
        CGFloat maxX = MAX(minX, size.width * 0.96 - currentRowWidth);
        x = MIN(MAX(x + rowJitter, minX), maxX);

        for (SGLyricSticker *tile in tiles) {
            CGRect rect = CGRectMake(x, y + (currentRowHeight - tile.height * fitScale) / 2,
                                     tile.width * fitScale, tile.height * fitScale);
            CGContextSaveGState(context);
            CGContextTranslateCTM(context, CGRectGetMidX(rect), CGRectGetMidY(rect));
            CGContextRotateCTM(context, tile.rotation);
            CGRect local = CGRectMake(-rect.size.width / 2, -rect.size.height / 2, rect.size.width, rect.size.height);
            UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:local cornerRadius:baseFont * fitScale * 0.025];
            BOOL active = tile.wordIndex == activeWordIndex;
            [(active ? [UIColor colorWithRed:0.27 green:0.88 blue:1 alpha:1] : tile.background) setFill];
            [path fill];
            UIFont *tileFont = [UIFont systemFontOfSize:tile.font.pointSize * fitScale weight:UIFontWeightHeavy];
            NSMutableParagraphStyle *tileParagraph = [NSMutableParagraphStyle new];
            tileParagraph.alignment = NSTextAlignmentCenter;
            tileParagraph.lineBreakMode = NSLineBreakByCharWrapping;
            NSInteger wordTime = tile.wordIndex >= 0 && tile.wordIndex < (NSInteger)words.count
                ? positionMs : 0;
            NSArray<SGKaraokeWord *> *tileWords = tile.wordIndex >= 0 && tile.wordIndex < (NSInteger)words.count
                ? @[words[tile.wordIndex]] : nil;
            NSAttributedString *tileText = karaokeLine(tileWords, tile.text, wordTime, tileFont, tileParagraph,
                tile.foreground, [UIColor colorWithRed:0.02 green:0.08 blue:0.13 alpha:1], tile.foreground, NO);
            drawFittedLyric(context, tileText,
                            CGRectInset(local, tile.paddingX * fitScale, tile.paddingY * fitScale));
            if (active) {
                CGContextSetStrokeColorWithColor(context, [UIColor colorWithRed:0.80 green:0.98 blue:1 alpha:1].CGColor);
                CGContextSetLineWidth(context, MAX(1, baseFont * fitScale * 0.045));
                [path stroke];
            }
            CGContextRestoreGState(context);
            x += (tile.width + gap) * fitScale;
        }
        y += currentRowHeight + rowGap * fitScale;
    }
}

static void drawEditorial(CGContextRef context, CGSize size, NSString *currentLine, NSString *currentTranslation,
                          NSString *nextLine, NSString *title, NSString *artist,
                          NSInteger positionMs, NSArray<SGKaraokeWord *> *words, NSInteger activeWordIndex) {
    CGFloat margin = size.width * 0.105;
    CGFloat textWidth = size.width - margin * 2;
    UIColor *white = [UIColor colorWithWhite:1 alpha:0.96];
    UIFont *masthead = [UIFont fontWithName:@"Georgia-Bold" size:size.width * 0.061] ?: [UIFont boldSystemFontOfSize:size.width * 0.061];
    UIFont *metadata = [UIFont monospacedSystemFontOfSize:size.width * 0.027 weight:UIFontWeightMedium];
    UIFont *lyricFont = [UIFont fontWithName:@"Georgia" size:size.width * 0.092] ?: [UIFont systemFontOfSize:size.width * 0.092];
    UIFont *translationFont = [UIFont fontWithName:@"Georgia-Italic" size:size.width * 0.044] ?: [UIFont italicSystemFontOfSize:size.width * 0.044];
    UIFont *nextFont = [UIFont fontWithName:@"Georgia-Italic" size:size.width * 0.048] ?: [UIFont italicSystemFontOfSize:size.width * 0.048];

    NSMutableParagraphStyle *left = [NSMutableParagraphStyle new];
    left.alignment = NSTextAlignmentLeft;
    left.lineBreakMode = NSLineBreakByWordWrapping;
    left.lineSpacing = size.width * 0.012;
    NSMutableParagraphStyle *right = [left mutableCopy];
    right.alignment = NSTextAlignmentRight;

    NSString *artistName = artist.length ? artist.uppercaseString : @"NOW PLAYING";
    [artistName drawInRect:CGRectMake(margin, size.height * 0.155, textWidth, size.height * 0.064)
            withAttributes:@{NSFontAttributeName: masthead, NSForegroundColorAttributeName: white,
                             NSKernAttributeName: @(size.width * 0.006)}];
    NSString *metadataText = title.length ? [title uppercaseString] : @"SYNCED LYRICS";
    [metadataText drawInRect:CGRectMake(margin, size.height * 0.225, textWidth, size.height * 0.045)
               withAttributes:@{NSFontAttributeName: metadata,
                                NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.72],
                                NSKernAttributeName: @(size.width * 0.002)}];

    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:0.34].CGColor);
    CGContextSetLineWidth(context, MAX(1, size.width * 0.002));
    CGContextMoveToPoint(context, margin, size.height * 0.285);
    CGContextAddLineToPoint(context, size.width - margin, size.height * 0.285);
    CGContextStrokePath(context);

    if (currentLine.length) {
        NSShadow *shadow = [NSShadow new];
        shadow.shadowColor = UIColor.blackColor;
        shadow.shadowBlurRadius = 8;
        NSMutableAttributedString *lyric = [karaokeLine(words, currentLine, positionMs, lyricFont, left,
                                                          white, [UIColor colorWithRed:0.52 green:0.85 blue:1 alpha:1],
                                                          [UIColor colorWithWhite:1 alpha:0.42], NO) mutableCopy];
        [lyric addAttribute:NSShadowAttributeName value:shadow range:NSMakeRange(0, lyric.length)];
        drawFittedLyric(context, lyric, CGRectMake(margin, size.height * 0.325, textWidth, size.height * 0.28));
    }
    if (currentTranslation.length) {
        [currentTranslation drawInRect:CGRectMake(margin, size.height * 0.615, textWidth, size.height * 0.07)
                         withAttributes:@{NSFontAttributeName: translationFont,
                                          NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.83],
                                          NSParagraphStyleAttributeName: left}];
    }
    if (nextLine.length) {
        [nextLine drawInRect:CGRectMake(margin + textWidth * 0.12, size.height * 0.735, textWidth * 0.88, size.height * 0.13)
              withAttributes:@{NSFontAttributeName: nextFont,
                               NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.76],
                               NSParagraphStyleAttributeName: right}];
    }
}

static void drawReceipt(CGContextRef context, CGSize size, NSString *currentLine, NSString *nextLine,
                        NSString *title, NSString *artist, NSArray<SGKaraokeWord *> *words,
                        NSInteger positionMs, NSInteger activeWordIndex) {
    CGRect paper = CGRectMake(size.width * 0.12, size.height * 0.205, size.width * 0.76, size.height * 0.57);
    CGContextSaveGState(context);
    CGContextSetShadowWithColor(context, CGSizeMake(0, size.height * 0.012), size.width * 0.025,
                                [UIColor colorWithWhite:0 alpha:0.72].CGColor);
    [[UIColor colorWithRed:0.94 green:0.92 blue:0.85 alpha:1] setFill];
    [[UIBezierPath bezierPathWithRect:paper] fill];
    CGContextRestoreGState(context);

    CGFloat inset = paper.size.width * 0.095;
    CGFloat x = paper.origin.x + inset;
    CGFloat width = paper.size.width - inset * 2;
    UIFont *header = [UIFont monospacedSystemFontOfSize:size.width * 0.039 weight:UIFontWeightSemibold];
    UIFont *body = [UIFont monospacedSystemFontOfSize:size.width * 0.040 weight:UIFontWeightRegular];
    UIFont *bold = [UIFont monospacedSystemFontOfSize:size.width * 0.040 weight:UIFontWeightBold];
    UIFont *small = [UIFont monospacedSystemFontOfSize:size.width * 0.033 weight:UIFontWeightRegular];
    UIColor *ink = [UIColor colorWithRed:0.14 green:0.13 blue:0.11 alpha:1];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentLeft;
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;
    paragraph.lineSpacing = size.width * 0.006;
    CGFloat y = paper.origin.y + paper.size.height * 0.09;

    NSString *heading = [NSString stringWithFormat:@"%@ / %@", title.length ? title.uppercaseString : @"NOW PLAYING",
                         artist.length ? artist.uppercaseString : @"SPOTIFY"];
    [heading drawInRect:CGRectMake(x, y, width, paper.size.height * 0.13)
         withAttributes:@{NSFontAttributeName: header, NSForegroundColorAttributeName: ink,
                          NSParagraphStyleAttributeName: paragraph}];
    [@"--------------------------------" drawInRect:CGRectMake(x, paper.origin.y + paper.size.height * 0.25,
                                                            width, paper.size.height * 0.07)
                              withAttributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: ink}];
    y = paper.origin.y + paper.size.height * 0.30;
    [@"NOW PLAYING" drawInRect:CGRectMake(x, y, width, paper.size.height * 0.075)
                 withAttributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: [ink colorWithAlphaComponent:0.62]}];
    y = paper.origin.y + paper.size.height * 0.40;
    if (currentLine.length) {
        NSAttributedString *lyric = karaokeLine(words, currentLine, positionMs, bold, paragraph,
                                                ink, [UIColor colorWithRed:0.70 green:0.23 blue:0.12 alpha:1],
                                                [ink colorWithAlphaComponent:0.42], YES);
        drawFittedLyric(context, lyric, CGRectMake(x, y, width, paper.size.height * 0.22));
    }
    y = paper.origin.y + paper.size.height * 0.63;
    if (nextLine.length) {
        [nextLine.uppercaseString drawInRect:CGRectMake(x, y, width, paper.size.height * 0.17)
                              withAttributes:@{NSFontAttributeName: body,
                                               NSForegroundColorAttributeName: [ink colorWithAlphaComponent:0.58],
                                               NSParagraphStyleAttributeName: paragraph}];
    }
    [@"SPOTI.PW • LIVE LYRICS" drawInRect:CGRectMake(x, paper.origin.y + paper.size.height * 0.89,
                                                      width, paper.size.height * 0.07)
                           withAttributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: [ink colorWithAlphaComponent:0.65],
                                            NSParagraphStyleAttributeName: paragraph}];
}

static NSString *elapsedClock(NSInteger positionMs) {
    NSInteger seconds = MAX(positionMs, 0) / 1000;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

static void drawMusicAvatar(CGContextRef context, CGRect rect, CGFloat alpha) {
    CGContextSaveGState(context);
    UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:rect];
    [[UIColor colorWithWhite:0.46 alpha:alpha] setFill];
    [circle fill];
    CGContextAddEllipseInRect(context, CGRectInset(rect, rect.size.width * 0.17, rect.size.height * 0.17));
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:alpha * 0.58].CGColor);
    CGContextSetLineWidth(context, MAX(1, rect.size.width * 0.025));
    CGContextStrokePath(context);
    CGFloat midY = CGRectGetMidY(rect);
    CGContextMoveToPoint(context, CGRectGetMinX(rect) + rect.size.width * 0.28, midY);
    CGContextAddCurveToPoint(context, CGRectGetMinX(rect) + rect.size.width * 0.4, midY - rect.size.height * 0.16,
                             CGRectGetMinX(rect) + rect.size.width * 0.48, midY + rect.size.height * 0.16,
                             CGRectGetMinX(rect) + rect.size.width * 0.6, midY);
    CGContextAddCurveToPoint(context, CGRectGetMinX(rect) + rect.size.width * 0.7, midY - rect.size.height * 0.12,
                             CGRectGetMinX(rect) + rect.size.width * 0.76, midY + rect.size.height * 0.12,
                             CGRectGetMinX(rect) + rect.size.width * 0.82, midY);
    CGContextStrokePath(context);
    CGContextRestoreGState(context);
}

static void drawVerifiedMark(CGContextRef context, CGPoint center, CGFloat radius) {
    CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.12 green:0.61 blue:0.96 alpha:1].CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(center.x - radius, center.y - radius, radius * 2, radius * 2));
    CGContextSetStrokeColorWithColor(context, UIColor.whiteColor.CGColor);
    CGContextSetLineWidth(context, MAX(1, radius * 0.22));
    CGContextMoveToPoint(context, center.x - radius * 0.45, center.y);
    CGContextAddLineToPoint(context, center.x - radius * 0.1, center.y + radius * 0.32);
    CGContextAddLineToPoint(context, center.x + radius * 0.5, center.y - radius * 0.36);
    CGContextStrokePath(context);
}

static void drawSocialPost(CGContextRef context, CGSize size, NSString *currentLine, NSString *nextLine,
                           NSString *artist, NSInteger positionMs, NSArray<SGKaraokeWord *> *words,
                           NSInteger activeWordIndex) {
    CGFloat width = size.width;
    CGFloat margin = width * 0.105;
    CGFloat avatarSize = width * 0.075;
    CGFloat bodyX = margin + avatarSize + width * 0.025;
    CGFloat bodyWidth = width - bodyX - margin;
    UIFont *small = [UIFont systemFontOfSize:width * 0.031 weight:UIFontWeightMedium];
    UIFont *nameFont = [UIFont systemFontOfSize:width * 0.033 weight:UIFontWeightBold];
    UIFont *lyricFont = [UIFont systemFontOfSize:width * 0.050 weight:UIFontWeightSemibold];
    UIColor *muted = [UIColor colorWithWhite:1 alpha:0.52];
    UIColor *white = [UIColor colorWithWhite:1 alpha:0.95];
    NSMutableParagraphStyle *left = [NSMutableParagraphStyle new];
    left.alignment = NSTextAlignmentLeft;
    left.lineBreakMode = NSLineBreakByWordWrapping;

    [@"‹   Post" drawInRect:CGRectMake(margin, size.height * 0.155, width * 0.5, size.height * 0.048)
             withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:width * 0.043 weight:UIFontWeightBold],
                              NSForegroundColorAttributeName: white}];

    CGFloat previewY = size.height * 0.225;
    drawMusicAvatar(context, CGRectMake(margin, previewY, avatarSize, avatarSize), 0.46);
    NSString *displayArtist = artist.length ? artist : @"Now Playing";
    [displayArtist drawInRect:CGRectMake(bodyX, previewY, bodyWidth * 0.68, avatarSize * 0.47)
               withAttributes:@{NSFontAttributeName: nameFont, NSForegroundColorAttributeName: muted}];
    drawVerifiedMark(context, CGPointMake(bodyX + MIN([displayArtist sizeWithAttributes:@{NSFontAttributeName: nameFont}].width,
                                                       bodyWidth * 0.65) + width * 0.017,
                                           previewY + avatarSize * 0.23), width * 0.010);
    [[NSString stringWithFormat:@"· %@", elapsedClock(positionMs)] drawInRect:CGRectMake(bodyX + bodyWidth * 0.67, previewY,
                                                                                            bodyWidth * 0.33, avatarSize * 0.45)
                                                                              withAttributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: muted}];
    [(nextLine.length ? nextLine : @"Synced lyrics") drawInRect:CGRectMake(bodyX, previewY + avatarSize * 0.47,
                                                                             bodyWidth, size.height * 0.065)
                                                   withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:width * 0.035 weight:UIFontWeightRegular],
                                                                    NSForegroundColorAttributeName: muted,
                                                                    NSParagraphStyleAttributeName: left}];

    CGFloat separatorY = size.height * 0.315;
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:0.10].CGColor);
    CGContextSetLineWidth(context, MAX(1, width * 0.0015));
    CGContextMoveToPoint(context, margin, separatorY);
    CGContextAddLineToPoint(context, width - margin, separatorY);
    CGContextStrokePath(context);

    CGFloat activeY = size.height * 0.338;
    drawMusicAvatar(context, CGRectMake(margin, activeY, avatarSize, avatarSize), 0.96);
    [displayArtist drawInRect:CGRectMake(bodyX, activeY, bodyWidth * 0.70, avatarSize * 0.47)
               withAttributes:@{NSFontAttributeName: nameFont, NSForegroundColorAttributeName: white}];
    drawVerifiedMark(context, CGPointMake(bodyX + MIN([displayArtist sizeWithAttributes:@{NSFontAttributeName: nameFont}].width,
                                                       bodyWidth * 0.67) + width * 0.017,
                                           activeY + avatarSize * 0.23), width * 0.011);
    [[NSString stringWithFormat:@"· %@", elapsedClock(positionMs)] drawInRect:CGRectMake(bodyX + bodyWidth * 0.69, activeY,
                                                                                            bodyWidth * 0.31, avatarSize * 0.45)
                                                                              withAttributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: muted}];

    if (currentLine.length) {
        NSAttributedString *lyric = karaokeLine(words, currentLine, positionMs, lyricFont, left,
                                                white, [UIColor colorWithRed:0.57 green:0.83 blue:1 alpha:1],
                                                [UIColor colorWithWhite:1 alpha:0.42], NO);
        drawFittedLyric(context, lyric,
                        CGRectMake(bodyX, activeY + avatarSize * 0.58, bodyWidth, size.height * 0.135));
    }
    CGFloat metaY = size.height * 0.505;
    [[NSString stringWithFormat:@"%@  ·  LIVE LYRICS", displayArtist] drawInRect:CGRectMake(bodyX, metaY, bodyWidth, size.height * 0.035)
                                                                              withAttributes:@{NSFontAttributeName: small,
                                                                                               NSForegroundColorAttributeName: muted}];
    CGFloat actionY = size.height * 0.552;
    CGContextMoveToPoint(context, bodyX, actionY - size.height * 0.018);
    CGContextAddLineToPoint(context, width - margin, actionY - size.height * 0.018);
    CGContextStrokePath(context);
    NSDictionary *actionAttrs = @{NSFontAttributeName: [UIFont systemFontOfSize:width * 0.034 weight:UIFontWeightMedium],
                                  NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.64]};
    [@"●  ···" drawInRect:CGRectMake(bodyX, actionY, bodyWidth * 0.27, size.height * 0.05) withAttributes:actionAttrs];
    [@"↻  ···" drawInRect:CGRectMake(bodyX + bodyWidth * 0.36, actionY, bodyWidth * 0.30, size.height * 0.05) withAttributes:actionAttrs];
    [@"♥" drawInRect:CGRectMake(width - margin - width * 0.045, actionY, width * 0.045, size.height * 0.05)
       withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:width * 0.041 weight:UIFontWeightBold],
                        NSForegroundColorAttributeName: [UIColor colorWithRed:1 green:0.12 blue:0.47 alpha:1]}];
}

static void drawRetroTV(CGContextRef context, CGSize size, NSString *currentLine, NSString *currentTranslation,
                        NSString *title, NSString *artist, NSInteger positionMs,
                        NSArray<SGKaraokeWord *> *words, NSInteger activeWordIndex) {
    CGFloat width = size.width;
    CGFloat unit = width / 390.0;
    CGRect cabinet = CGRectMake(width * 0.105, size.height * 0.225, width * 0.79, size.height * 0.385);
    CGFloat radius = width * 0.044;
    CGContextSaveGState(context);
    CGContextSetShadowWithColor(context, CGSizeMake(0, size.height * 0.014), width * 0.035,
                                [UIColor colorWithWhite:0 alpha:0.82].CGColor);
    UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:cabinet cornerRadius:radius];
    [[UIColor colorWithRed:0.20 green:0.18 blue:0.16 alpha:1] setFill];
    [body fill];
    CGContextRestoreGState(context);

    CGContextSetStrokeColorWithColor(context, [UIColor colorWithRed:0.42 green:0.38 blue:0.33 alpha:0.82].CGColor);
    CGContextSetLineWidth(context, width * 0.007);
    CGContextMoveToPoint(context, width * 0.46, CGRectGetMinY(cabinet));
    CGContextAddLineToPoint(context, width * 0.38, size.height * 0.165);
    CGContextMoveToPoint(context, width * 0.50, CGRectGetMinY(cabinet));
    CGContextAddLineToPoint(context, width * 0.59, size.height * 0.165);
    CGContextStrokePath(context);
    CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.62 green:0.57 blue:0.49 alpha:1].CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(width * 0.37, size.height * 0.154, width * 0.018, width * 0.018));
    CGContextFillEllipseInRect(context, CGRectMake(width * 0.585, size.height * 0.154, width * 0.018, width * 0.018));

    CGRect screenFrame = CGRectMake(cabinet.origin.x + cabinet.size.width * 0.095,
                                    cabinet.origin.y + cabinet.size.height * 0.085,
                                    cabinet.size.width * 0.81, cabinet.size.height * 0.59);
    UIBezierPath *screenBezel = [UIBezierPath bezierPathWithRoundedRect:screenFrame cornerRadius:width * 0.037];
    [[UIColor colorWithRed:0.075 green:0.072 blue:0.068 alpha:1] setFill];
    [screenBezel fill];
    CGRect screen = CGRectInset(screenFrame, width * 0.018, width * 0.016);
    UIBezierPath *glass = [UIBezierPath bezierPathWithRoundedRect:screen cornerRadius:width * 0.029];
    [[UIColor colorWithRed:0.025 green:0.075 blue:0.08 alpha:1] setFill];
    [glass fill];

    CGContextSaveGState(context);
    [glass addClip];
    UIFont *statusFont = [UIFont monospacedSystemFontOfSize:width * 0.025 weight:UIFontWeightBold];
    UIColor *green = [UIColor colorWithRed:0.22 green:1 blue:0.53 alpha:1];
    NSMutableParagraphStyle *clockParagraph = [NSMutableParagraphStyle new];
    clockParagraph.alignment = NSTextAlignmentRight;
    [@"▶ PLAY" drawInRect:CGRectMake(screen.origin.x + screen.size.width * 0.055, screen.origin.y + screen.size.height * 0.07,
                                       screen.size.width * 0.42, screen.size.height * 0.12)
                withAttributes:@{NSFontAttributeName: statusFont, NSForegroundColorAttributeName: green,
                                 NSKernAttributeName: @(width * 0.002)}];
    NSString *clock = elapsedClock(positionMs);
    [clock drawInRect:CGRectMake(CGRectGetMaxX(screen) - screen.size.width * 0.25, screen.origin.y + screen.size.height * 0.07,
                                 screen.size.width * 0.19, screen.size.height * 0.12)
       withAttributes:@{NSFontAttributeName: statusFont, NSForegroundColorAttributeName: green,
                        NSParagraphStyleAttributeName: clockParagraph}];

    NSMutableParagraphStyle *center = [NSMutableParagraphStyle new];
    center.alignment = NSTextAlignmentCenter;
    center.lineBreakMode = NSLineBreakByWordWrapping;
    center.lineSpacing = width * 0.006;
    UIFont *lyricFont = [UIFont monospacedSystemFontOfSize:width * 0.045 weight:UIFontWeightBold];
    CGRect lyricRect = CGRectMake(screen.origin.x + screen.size.width * 0.075, screen.origin.y + screen.size.height * 0.25,
                                  screen.size.width * 0.85, screen.size.height * 0.42);
    NSAttributedString *lyric = karaokeLine(words, currentLine ?: @"Lyrics ready", positionMs,
                                            lyricFont, center, UIColor.whiteColor,
                                            [UIColor colorWithRed:0.60 green:1 blue:0.56 alpha:1],
                                            [UIColor colorWithWhite:1 alpha:0.46], NO);
    NSMutableAttributedString *chromatic = [lyric mutableCopy];
    [chromatic addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:1 green:0.2 blue:0.32 alpha:0.82]
                       range:NSMakeRange(0, chromatic.length)];
    drawFittedLyric(context, chromatic, CGRectOffset(lyricRect, -width * 0.003, 0));
    drawFittedLyric(context, lyric, CGRectOffset(lyricRect, width * 0.003, 0));
    drawFittedLyric(context, lyric, lyricRect);
    if (currentTranslation.length) {
        UIFont *translationFont = [UIFont monospacedSystemFontOfSize:width * 0.029 weight:UIFontWeightMedium];
        [currentTranslation drawInRect:CGRectMake(screen.origin.x + screen.size.width * 0.08,
                                                  CGRectGetMaxY(lyricRect) + screen.size.height * 0.015,
                                                  screen.size.width * 0.84, screen.size.height * 0.18)
                         withAttributes:@{NSFontAttributeName: translationFont,
                                          NSForegroundColorAttributeName: [UIColor colorWithRed:0.48 green:0.82 blue:0.93 alpha:0.96],
                                          NSParagraphStyleAttributeName: center}];
    }
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:0.8 alpha:0.10].CGColor);
    CGContextSetLineWidth(context, MAX(1, unit));
    for (NSInteger row = 1; row < 12; row++) {
        CGFloat y = screen.origin.y + screen.size.height * row / 12.0;
        CGContextMoveToPoint(context, screen.origin.x, y);
        CGContextAddLineToPoint(context, CGRectGetMaxX(screen), y);
    }
    CGContextStrokePath(context);
    CGContextRestoreGState(context);

    CGRect speaker = CGRectMake(cabinet.origin.x + cabinet.size.width * 0.075,
                                cabinet.origin.y + cabinet.size.height * 0.765,
                                cabinet.size.width * 0.22, cabinet.size.height * 0.13);
    UIBezierPath *speakerPlate = [UIBezierPath bezierPathWithRoundedRect:speaker cornerRadius:width * 0.008];
    [[UIColor colorWithRed:0.09 green:0.08 blue:0.075 alpha:1] setFill];
    [speakerPlate fill];
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:0 alpha:0.86].CGColor);
    CGContextSetLineWidth(context, width * 0.006);
    for (NSInteger slot = 1; slot < 9; slot++) {
        CGFloat x = speaker.origin.x + speaker.size.width * slot / 9.0;
        CGContextMoveToPoint(context, x, speaker.origin.y + speaker.size.height * 0.12);
        CGContextAddLineToPoint(context, x, CGRectGetMaxY(speaker) - speaker.size.height * 0.12);
    }
    CGContextStrokePath(context);

    NSString *label = [NSString stringWithFormat:@"%@  /  %@", title.length ? title.uppercaseString : @"LIVE LYRICS",
                       artist.length ? artist.uppercaseString : @"SPOTIFY"];
    [label drawInRect:CGRectMake(cabinet.origin.x + cabinet.size.width * 0.31,
                                 cabinet.origin.y + cabinet.size.height * 0.765,
                                 cabinet.size.width * 0.43, cabinet.size.height * 0.13)
        withAttributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:width * 0.019 weight:UIFontWeightSemibold],
                         NSForegroundColorAttributeName: [UIColor colorWithRed:0.70 green:0.63 blue:0.52 alpha:0.9],
                         NSKernAttributeName: @(width * 0.0008)}];
    for (NSInteger knob = 0; knob < 2; knob++) {
        CGFloat diameter = width * (knob == 0 ? 0.064 : 0.054);
        CGRect knobRect = CGRectMake(cabinet.origin.x + cabinet.size.width * (0.78 + knob * 0.105),
                                     cabinet.origin.y + cabinet.size.height * 0.755,
                                     diameter, diameter);
        CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.34 green:0.31 blue:0.27 alpha:1].CGColor);
        CGContextFillEllipseInRect(context, knobRect);
        CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:0.05 alpha:1].CGColor);
        CGContextSetLineWidth(context, width * 0.004);
        CGContextStrokeEllipseInRect(context, knobRect);
        CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:0.83 alpha:0.62].CGColor);
        CGContextMoveToPoint(context, CGRectGetMidX(knobRect), CGRectGetMidY(knobRect));
        CGContextAddLineToPoint(context, CGRectGetMidX(knobRect) + diameter * 0.18, CGRectGetMidY(knobRect) - diameter * 0.22);
        CGContextStrokePath(context);
    }

    CGRect shelf = CGRectMake(width * 0.08, CGRectGetMaxY(cabinet) + size.height * 0.012,
                              width * 0.84, size.height * 0.018);
    UIBezierPath *shelfPath = [UIBezierPath bezierPathWithRoundedRect:shelf cornerRadius:shelf.size.height / 2];
    [[UIColor colorWithRed:0.25 green:0.20 blue:0.15 alpha:0.96] setFill];
    [shelfPath fill];
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:0.55 alpha:0.22].CGColor);
    CGContextSetLineWidth(context, MAX(1, unit));
    CGContextMoveToPoint(context, CGRectGetMinX(shelf), CGRectGetMinY(shelf));
    CGContextAddLineToPoint(context, CGRectGetMaxX(shelf), CGRectGetMinY(shelf));
    CGContextStrokePath(context);
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithRed:0.19 green:0.15 blue:0.12 alpha:0.62].CGColor);
    CGContextSetLineWidth(context, width * 0.012);
    CGContextMoveToPoint(context, width * 0.19, CGRectGetMaxY(shelf));
    CGContextAddLineToPoint(context, width * 0.15, size.height * 0.72);
    CGContextMoveToPoint(context, width * 0.81, CGRectGetMaxY(shelf));
    CGContextAddLineToPoint(context, width * 0.85, size.height * 0.72);
    CGContextStrokePath(context);
}

static void drawNeon(CGContextRef context, CGSize size, NSString *currentLine, NSString *currentTranslation,
                     NSString *nextLine, NSString *title, NSString *artist,
                     NSInteger positionMs, NSArray<SGKaraokeWord *> *words, NSInteger activeWordIndex) {
    CGFloat width = size.width;
    UIColor *pink = [UIColor colorWithRed:1 green:0.18 blue:0.59 alpha:1];
    UIColor *cyan = [UIColor colorWithRed:0.25 green:0.92 blue:1 alpha:1];
    CGRect frame = CGRectMake(width * 0.095, size.height * 0.285, width * 0.81, size.height * 0.37);
    UIBezierPath *outline = [UIBezierPath bezierPathWithRoundedRect:frame cornerRadius:width * 0.045];
    CGContextSaveGState(context);
    CGContextSetStrokeColorWithColor(context, [cyan colorWithAlphaComponent:0.82].CGColor);
    CGContextSetLineWidth(context, width * 0.0035);
    CGContextSetShadowWithColor(context, CGSizeZero, width * 0.024, cyan.CGColor);
    [outline stroke];
    CGContextRestoreGState(context);

    NSString *artistLabel = artist.length ? artist.uppercaseString : @"NOW PLAYING";
    NSString *trackLabel = title.length ? title : @"SYNCED LYRICS";
    UIFont *labelFont = [UIFont monospacedSystemFontOfSize:width * 0.027 weight:UIFontWeightSemibold];
    NSMutableParagraphStyle *center = [NSMutableParagraphStyle new];
    center.alignment = NSTextAlignmentCenter;
    center.lineBreakMode = NSLineBreakByWordWrapping;
    [artistLabel drawInRect:CGRectMake(width * 0.13, size.height * 0.19, width * 0.74, size.height * 0.04)
             withAttributes:@{NSFontAttributeName: labelFont, NSForegroundColorAttributeName: [cyan colorWithAlphaComponent:0.92],
                              NSKernAttributeName: @(width * 0.004), NSParagraphStyleAttributeName: center}];
    [trackLabel drawInRect:CGRectMake(width * 0.14, size.height * 0.225, width * 0.72, size.height * 0.04)
            withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:width * 0.031 weight:UIFontWeightMedium],
                             NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.62],
                             NSParagraphStyleAttributeName: center}];

    UIFont *lyricFont = [UIFont fontWithName:@"AvenirNextCondensed-Heavy" size:width * 0.092] ?:
                        [UIFont systemFontOfSize:width * 0.086 weight:UIFontWeightHeavy];
    CGRect lyricRect = CGRectMake(width * 0.15, size.height * 0.36, width * 0.70, size.height * 0.20);
    if (currentLine.length) {
        NSMutableAttributedString *glow = [karaokeLine(words, currentLine, positionMs, lyricFont, center,
                                                         [UIColor colorWithWhite:1 alpha:0.96], cyan,
                                                         [UIColor colorWithWhite:1 alpha:0.35], NO) mutableCopy];
        NSShadow *pinkGlow = [NSShadow new];
        pinkGlow.shadowColor = pink;
        pinkGlow.shadowOffset = CGSizeZero;
        pinkGlow.shadowBlurRadius = width * 0.033;
        [glow addAttribute:NSShadowAttributeName value:pinkGlow range:NSMakeRange(0, glow.length)];
        drawFittedLyric(context, glow, lyricRect);
        NSShadow *cyanGlow = [NSShadow new];
        cyanGlow.shadowColor = cyan;
        cyanGlow.shadowOffset = CGSizeZero;
        cyanGlow.shadowBlurRadius = width * 0.013;
        [glow addAttribute:NSShadowAttributeName value:cyanGlow range:NSMakeRange(0, glow.length)];
        drawFittedLyric(context, glow, lyricRect);
    }
    if (currentTranslation.length) {
        [currentTranslation drawInRect:CGRectMake(width * 0.16, size.height * 0.565, width * 0.68, size.height * 0.06)
                        withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:width * 0.036 weight:UIFontWeightMedium],
                                         NSForegroundColorAttributeName: [cyan colorWithAlphaComponent:0.90],
                                         NSParagraphStyleAttributeName: center}];
    } else if (nextLine.length) {
        [nextLine drawInRect:CGRectMake(width * 0.16, size.height * 0.575, width * 0.68, size.height * 0.06)
              withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:width * 0.033 weight:UIFontWeightMedium],
                               NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.53],
                               NSParagraphStyleAttributeName: center}];
    }

    CGContextSetStrokeColorWithColor(context, [pink colorWithAlphaComponent:0.82].CGColor);
    CGContextSetLineWidth(context, width * 0.004);
    CGContextSetShadowWithColor(context, CGSizeZero, width * 0.016, pink.CGColor);
    CGFloat centerX = width * 0.5;
    CGFloat y = CGRectGetMaxY(frame);
    CGContextMoveToPoint(context, centerX - width * 0.055, y);
    CGContextAddLineToPoint(context, centerX + width * 0.055, y);
    CGContextStrokePath(context);
    CGContextSetFillColorWithColor(context, pink.CGColor);
    CGContextFillEllipseInRect(context, CGRectMake(centerX - width * 0.008, y - width * 0.008, width * 0.016, width * 0.016));
}

static void drawVHS(CGContextRef context, CGSize size, NSString *currentLine, NSString *currentTranslation,
                    NSString *nextLine, NSString *title, NSInteger positionMs,
                    NSArray<SGKaraokeWord *> *words, NSInteger activeWordIndex) {
    CGFloat width = size.width;
    CGFloat height = size.height;
    UIColor *green = [UIColor colorWithRed:0.47 green:1 blue:0.60 alpha:1];
    UIColor *amber = [UIColor colorWithRed:1 green:0.70 blue:0.31 alpha:1];
    UIFont *mono = [UIFont monospacedSystemFontOfSize:width * 0.027 weight:UIFontWeightSemibold];

    CGContextSaveGState(context);
    CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:0 alpha:0.34].CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, width, height * 0.17));
    CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:0 alpha:0.26].CGColor);
    CGContextFillRect(context, CGRectMake(0, height * 0.635, width, height * 0.045));
    CGContextSetStrokeColorWithColor(context, [UIColor colorWithWhite:1 alpha:0.065].CGColor);
    CGContextSetLineWidth(context, MAX(1, width * 0.0012));
    for (NSInteger row = 0; row < 64; row++) {
        CGFloat y = height * (0.17 + row * 0.0072);
        if (y > height * 0.64) break;
        CGContextMoveToPoint(context, 0, y);
        CGContextAddLineToPoint(context, width, y);
    }
    CGContextStrokePath(context);

    [@"PLAY ▶" drawInRect:CGRectMake(width * 0.09, height * 0.175, width * 0.28, height * 0.04)
            withAttributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: green,
                             NSKernAttributeName: @(width * 0.002)}];
    CGRect recDot = CGRectMake(width * 0.69, height * 0.187, width * 0.018, width * 0.018);
    CGContextSetFillColorWithColor(context, [UIColor colorWithRed:1 green:0.18 blue:0.16 alpha:1].CGColor);
    CGContextFillEllipseInRect(context, recDot);
    [@"REC" drawInRect:CGRectMake(CGRectGetMaxX(recDot) + width * 0.012, height * 0.175, width * 0.10, height * 0.04)
          withAttributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: [UIColor colorWithRed:1 green:0.28 blue:0.25 alpha:0.96]}];
    NSMutableParagraphStyle *right = [NSMutableParagraphStyle new];
    right.alignment = NSTextAlignmentRight;
    [elapsedClock(positionMs) drawInRect:CGRectMake(width * 0.79, height * 0.175, width * 0.13, height * 0.04)
                          withAttributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: green,
                                           NSParagraphStyleAttributeName: right}];

    CGRect subtitle = CGRectMake(width * 0.075, height * 0.37, width * 0.85, height * 0.22);
    CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:0 alpha:0.58].CGColor);
    UIBezierPath *captionBox = [UIBezierPath bezierPathWithRoundedRect:subtitle cornerRadius:width * 0.018];
    [captionBox fill];
    CGContextSetStrokeColorWithColor(context, [amber colorWithAlphaComponent:0.55].CGColor);
    CGContextSetLineWidth(context, width * 0.0018);
    [captionBox stroke];

    NSMutableParagraphStyle *center = [NSMutableParagraphStyle new];
    center.alignment = NSTextAlignmentCenter;
    center.lineBreakMode = NSLineBreakByWordWrapping;
    UIFont *subtitleFont = [UIFont systemFontOfSize:width * 0.061 weight:UIFontWeightHeavy];
    CGRect lineRect = CGRectInset(subtitle, width * 0.06, height * 0.038);
    NSShadow *subtitleShadow = [NSShadow new];
    subtitleShadow.shadowColor = UIColor.blackColor;
    subtitleShadow.shadowOffset = CGSizeMake(0, width * 0.002);
    subtitleShadow.shadowBlurRadius = width * 0.01;
    NSMutableAttributedString *subtitleText = [karaokeLine(words, currentLine ?: @"Lyrics ready", positionMs,
                                                             subtitleFont, center, UIColor.whiteColor, amber,
                                                             [UIColor colorWithWhite:1 alpha:0.48], NO) mutableCopy];
    [subtitleText addAttribute:NSShadowAttributeName value:subtitleShadow range:NSMakeRange(0, subtitleText.length)];
    NSMutableAttributedString *cyanText = [subtitleText mutableCopy];
    [cyanText addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:0.38 green:0.92 blue:1 alpha:0.55]
                      range:NSMakeRange(0, cyanText.length)];
    drawFittedLyric(context, cyanText, CGRectOffset(lineRect, -width * 0.0025, 0));
    drawFittedLyric(context, subtitleText, CGRectOffset(lineRect, width * 0.0025, 0));
    drawFittedLyric(context, subtitleText, lineRect);
    NSString *secondary = currentTranslation.length ? currentTranslation : nextLine;
    if (secondary.length) {
        [secondary drawInRect:CGRectMake(width * 0.14, height * 0.605, width * 0.72, height * 0.045)
               withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:width * 0.031 weight:UIFontWeightMedium],
                                NSForegroundColorAttributeName: currentTranslation.length ? amber : [UIColor colorWithWhite:1 alpha:0.65],
                                NSParagraphStyleAttributeName: center}];
    }

    NSString *label = title.length ? title.uppercaseString : @"SPOTI.PW • LIVE CAPTIONS";
    [label drawInRect:CGRectMake(width * 0.09, height * 0.645, width * 0.82, height * 0.035)
       withAttributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:width * 0.022 weight:UIFontWeightMedium],
                        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.70],
                        NSParagraphStyleAttributeName: center}];

    // A few restrained tracking glitches sell the tape look without obscuring the lyric.
    CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.48 green:0.92 blue:1 alpha:0.17].CGColor);
    CGContextFillRect(context, CGRectMake(width * 0.075, height * 0.335, width * 0.13, height * 0.003));
    CGContextSetFillColorWithColor(context, [UIColor colorWithRed:1 green:0.31 blue:0.38 alpha:0.19].CGColor);
    CGContextFillRect(context, CGRectMake(width * 0.80, height * 0.59, width * 0.12, height * 0.003));
    CGContextRestoreGState(context);
}

static void drawBlueprint(CGContextRef context, CGSize size, NSString *currentLine, NSString *currentTranslation,
                          NSString *nextLine, NSString *title, NSString *artist, NSInteger positionMs,
                          NSArray<SGKaraokeWord *> *words, NSInteger activeWordIndex) {
    CGFloat width = size.width;
    CGFloat height = size.height;
    UIColor *cyan = [UIColor colorWithRed:0.33 green:0.83 blue:1 alpha:1];
    UIColor *muted = [cyan colorWithAlphaComponent:0.58];
    CGContextSaveGState(context);
    CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.015 green:0.055 blue:0.13 alpha:0.75].CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, width, height * 0.70));

    CGContextSetStrokeColorWithColor(context, [cyan colorWithAlphaComponent:0.10].CGColor);
    CGContextSetLineWidth(context, MAX(1, width * 0.001));
    CGFloat gridX = width * 0.055, gridY = height * 0.025;
    for (CGFloat x = 0; x <= width; x += gridX) {
        CGContextMoveToPoint(context, x, height * 0.13);
        CGContextAddLineToPoint(context, x, height * 0.68);
    }
    for (CGFloat y = height * 0.13; y <= height * 0.68; y += gridY) {
        CGContextMoveToPoint(context, 0, y);
        CGContextAddLineToPoint(context, width, y);
    }
    CGContextStrokePath(context);

    UIFont *mono = [UIFont monospacedSystemFontOfSize:width * 0.027 weight:UIFontWeightMedium];
    UIFont *small = [UIFont monospacedSystemFontOfSize:width * 0.022 weight:UIFontWeightRegular];
    NSMutableParagraphStyle *right = [NSMutableParagraphStyle new];
    right.alignment = NSTextAlignmentRight;
    NSString *artistLabel = artist.length ? artist.uppercaseString : @"UNKNOWN ARTIST";
    NSString *trackLabel = title.length ? title.uppercaseString : @"UNTITLED TRACK";
    [@"LYRIC DISPLAY   /   LIVE SYNC" drawInRect:CGRectMake(width * 0.10, height * 0.165, width * 0.56, height * 0.04)
                                  withAttributes:@{NSFontAttributeName: mono, NSForegroundColorAttributeName: cyan,
                                                   NSKernAttributeName: @(width * 0.0015)}];
    [@"01 — ACTIVE" drawInRect:CGRectMake(width * 0.69, height * 0.165, width * 0.21, height * 0.04)
                 withAttributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: muted,
                                  NSParagraphStyleAttributeName: right}];

    CGRect panel = CGRectMake(width * 0.085, height * 0.245, width * 0.83, height * 0.375);
    UIBezierPath *panelPath = [UIBezierPath bezierPathWithRoundedRect:panel cornerRadius:width * 0.012];
    CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.01 green:0.035 blue:0.09 alpha:0.44].CGColor);
    [panelPath fill];
    CGContextSetStrokeColorWithColor(context, [cyan colorWithAlphaComponent:0.43].CGColor);
    CGContextSetLineWidth(context, width * 0.002);
    [panelPath stroke];

    CGFloat left = panel.origin.x + width * 0.055;
    CGFloat mainWidth = panel.size.width - width * 0.11;
    [trackLabel drawInRect:CGRectMake(left, panel.origin.y + panel.size.height * 0.075, mainWidth, panel.size.height * 0.09)
            withAttributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: muted,
                             NSKernAttributeName: @(width * 0.0012)}];
    CGContextSetFillColorWithColor(context, cyan.CGColor);
    CGContextFillRect(context, CGRectMake(left, panel.origin.y + panel.size.height * 0.21, width * 0.008, panel.size.height * 0.48));

    NSMutableParagraphStyle *leftParagraph = [NSMutableParagraphStyle new];
    leftParagraph.alignment = NSTextAlignmentLeft;
    leftParagraph.lineBreakMode = NSLineBreakByWordWrapping;
    UIFont *lyricFont = [UIFont monospacedSystemFontOfSize:width * 0.055 weight:UIFontWeightSemibold];
    NSAttributedString *lyric = karaokeLine(words, currentLine ?: @"Waiting for lyrics", positionMs,
                                            lyricFont, leftParagraph, [UIColor colorWithWhite:1 alpha:0.96],
                                            cyan, [UIColor colorWithWhite:1 alpha:0.39], NO);
    drawFittedLyric(context, lyric, CGRectMake(left + width * 0.035,
                                                panel.origin.y + panel.size.height * 0.24,
                                                mainWidth - width * 0.035, panel.size.height * 0.39));
    NSString *secondary = currentTranslation.length ? currentTranslation : nextLine;
    if (secondary.length) {
        [secondary drawInRect:CGRectMake(left + width * 0.035,
                                         panel.origin.y + panel.size.height * 0.69,
                                         mainWidth - width * 0.035, panel.size.height * 0.18)
                withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:width * 0.029 weight:UIFontWeightRegular],
                                 NSForegroundColorAttributeName: muted,
                                 NSParagraphStyleAttributeName: leftParagraph}];
    }

    NSString *clockLine = [NSString stringWithFormat:@"%@   //   %@", artistLabel, elapsedClock(positionMs)];
    [clockLine drawInRect:CGRectMake(width * 0.10, height * 0.645, width * 0.80, height * 0.04)
           withAttributes:@{NSFontAttributeName: small, NSForegroundColorAttributeName: cyan}];
    CGContextSetStrokeColorWithColor(context, [cyan colorWithAlphaComponent:0.56].CGColor);
    CGContextSetLineWidth(context, width * 0.002);
    CGContextMoveToPoint(context, width * 0.10, height * 0.695);
    CGContextAddLineToPoint(context, width * 0.90, height * 0.695);
    CGContextStrokePath(context);
    CGContextRestoreGState(context);
}

static CGFloat styleBlurRatio(NSInteger style) {
    if (style == SGLockScreenLyricsArtworkStyleWordCollage) return 0.016;
    if (style == SGLockScreenLyricsArtworkStyleEditorial) return 0.022;
    if (style == SGLockScreenLyricsArtworkStyleSocialPost) return 0.035;
    if (style == SGLockScreenLyricsArtworkStyleRetroTV || style == SGLockScreenLyricsArtworkStyleVHS) return 0.045;
    return 0.035;
}

static CGFloat styleShade(NSInteger style) {
    if (style == SGLockScreenLyricsArtworkStyleWordCollage) return 0.19;
    if (style == SGLockScreenLyricsArtworkStyleEditorial) return 0.25;
    if (style == SGLockScreenLyricsArtworkStyleReceipt) return 0.34;
    if (style == SGLockScreenLyricsArtworkStyleSocialPost) return 0.57;
    if (style == SGLockScreenLyricsArtworkStyleRetroTV) return 0.48;
    if (style == SGLockScreenLyricsArtworkStyleNeon) return 0.68;
    if (style == SGLockScreenLyricsArtworkStyleVHS) return 0.39;
    if (style == SGLockScreenLyricsArtworkStyleBlueprint) return 0.54;
    return 0.38;
}

UIImage *SGLockScreenLyricsPreparedBackgroundFrame(UIImage *source, NSInteger style, CGSize size) {
    size.width = floor(size.width / 16) * 16;
    size.height = floor(size.height / 16) * 16;
    if (size.width < 16 || size.height < 16) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat new];
    format.scale = 1;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef context = rendererContext.CGContext;
        CGRect bounds = (CGRect){CGPointZero, size};
        CGImageRef soft = blurred(source.CGImage, size, styleBlurRatio(style));
        if (soft) {
            [[UIImage imageWithCGImage:soft] drawInRect:bounds];
            CGImageRelease(soft);
        } else {
            CGContextSetRGBFillColor(context, 0.08, 0.08, 0.09, 1);
            CGContextFillRect(context, bounds);
        }
        CGContextSetRGBFillColor(context, 0, 0, 0, styleShade(style));
        CGContextFillRect(context, bounds);
    }];
}

static UIImage *renderFrame(UIImage *source, BOOL backgroundPrepared, NSString *currentLine, NSString *currentTranslation,
                            NSString *nextLine, NSString *title, NSString *artist, NSInteger positionMs,
                            NSInteger style, NSArray<SGKaraokeWord *> *words,
                            NSInteger activeWordIndex, NSArray<SGKaraokeLine *> *lyricsLines,
                            NSInteger activeLineIndex, CGSize size) {
    size.width = floor(size.width / 16) * 16;
    size.height = floor(size.height / 16) * 16;
    if (size.width < 16 || size.height < 16) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat new];
    format.scale = 1;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef context = rendererContext.CGContext;
        CGRect bounds = (CGRect){CGPointZero, size};
        if (backgroundPrepared) {
            [source drawInRect:bounds];
        } else {
            CGImageRef soft = blurred(source.CGImage, size, styleBlurRatio(style));
            if (soft) {
                // Draw through UIKit so the top-left renderer does not flip the CGImage.
                [[UIImage imageWithCGImage:soft] drawInRect:bounds];
                CGImageRelease(soft);
            } else {
                CGContextSetRGBFillColor(context, 0.08, 0.08, 0.09, 1);
                CGContextFillRect(context, bounds);
            }
            CGContextSetRGBFillColor(context, 0, 0, 0, styleShade(style));
            CGContextFillRect(context, bounds);
        }

        BOOL collage = style == SGLockScreenLyricsArtworkStyleWordCollage;
        BOOL editorial = style == SGLockScreenLyricsArtworkStyleEditorial;
        BOOL receipt = style == SGLockScreenLyricsArtworkStyleReceipt;
        BOOL socialPost = style == SGLockScreenLyricsArtworkStyleSocialPost;
        BOOL retroTV = style == SGLockScreenLyricsArtworkStyleRetroTV;
        BOOL neon = style == SGLockScreenLyricsArtworkStyleNeon;
        BOOL vhs = style == SGLockScreenLyricsArtworkStyleVHS;
        BOOL blueprint = style == SGLockScreenLyricsArtworkStyleBlueprint;

        if (collage) {
            drawWordCollage(context, currentLine, size, words, positionMs, activeWordIndex);
            return;
        }
        if (editorial) {
            drawEditorial(context, size, currentLine, currentTranslation, nextLine, title, artist, positionMs, words, activeWordIndex);
            return;
        }
        if (receipt) {
            drawReceipt(context, size, currentLine, nextLine, title, artist, words, positionMs, activeWordIndex);
            return;
        }
        if (socialPost) {
            drawSocialPost(context, size, currentLine, nextLine, artist, positionMs, words, activeWordIndex);
            return;
        }
        if (retroTV) {
            drawRetroTV(context, size, currentLine, currentTranslation, title, artist, positionMs, words, activeWordIndex);
            return;
        }
        if (neon) {
            drawNeon(context, size, currentLine, currentTranslation, nextLine, title, artist, positionMs, words, activeWordIndex);
            return;
        }
        if (vhs) {
            drawVHS(context, size, currentLine, currentTranslation, nextLine, title, positionMs, words, activeWordIndex);
            return;
        }
        if (blueprint) {
            drawBlueprint(context, size, currentLine, currentTranslation, nextLine, title, artist, positionMs, words, activeWordIndex);
            return;
        }
        if (lyricsLines.count) {
            drawLyricsStack(context, size, lyricsLines, activeLineIndex, positionMs);
            return;
        }

        CGFloat fontSize = size.width * 0.057;
        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.alignment = NSTextAlignmentCenter;
        paragraph.lineSpacing = fontSize * 0.32;
        paragraph.lineBreakMode = NSLineBreakByWordWrapping;
        UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightBold];
        NSShadow *shadow = [NSShadow new];
        shadow.shadowColor = UIColor.blackColor;
        shadow.shadowBlurRadius = 8;
        NSDictionary *currentAttributes = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: UIColor.whiteColor,
            NSParagraphStyleAttributeName: paragraph,
            NSShadowAttributeName: shadow,
        };
        NSMutableAttributedString *lyrics = [NSMutableAttributedString new];
        if (currentLine.length) {
            NSMutableAttributedString *current = [karaokeLine(words, currentLine, positionMs, font, paragraph,
                                                                 UIColor.whiteColor, [UIColor colorWithRed:0.42 green:0.90 blue:1 alpha:1],
                                                                 [UIColor colorWithWhite:1 alpha:0.44], NO) mutableCopy];
            [current addAttribute:NSShadowAttributeName value:shadow range:NSMakeRange(0, current.length)];
            [lyrics appendAttributedString:current];
        }
        if (nextLine.length) {
            NSMutableParagraphStyle *nextParagraph = [paragraph mutableCopy];
            nextParagraph.paragraphSpacingBefore = fontSize * 0.55;
            NSDictionary *nextAttributes = @{
                NSFontAttributeName: [UIFont systemFontOfSize:fontSize * 0.72 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.48],
                NSParagraphStyleAttributeName: nextParagraph,
                NSShadowAttributeName: currentAttributes[NSShadowAttributeName],
            };
            if (lyrics.length) [lyrics appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:nextAttributes]];
            [lyrics appendAttributedString:[[NSAttributedString alloc] initWithString:nextLine attributes:nextAttributes]];
        }
        if (!lyrics.length) return;
        CGFloat textWidth = size.width * 0.76;
        CGRect measured = [lyrics boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
                                               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                               context:nil];
        CGFloat textHeight = ceil(measured.size.height);
        CGRect textRect = CGRectMake((size.width - textWidth) / 2, (size.height - textHeight) / 2, textWidth, textHeight);
        drawFittedLyric(context, lyrics, textRect);
    }];
}

UIImage *SGLockScreenLyricsFrameOnBackground(UIImage *background, NSInteger positionMs,
                                             NSString *currentLine, NSString *currentTranslation, NSString *nextLine,
                                             NSString *title, NSString *artist, NSInteger style,
                                             NSArray<SGKaraokeWord *> *words, NSInteger activeWordIndex,
                                             NSArray<SGKaraokeLine *> *lyricsLines, NSInteger activeLineIndex, CGSize size) {
    return renderFrame(background, YES, currentLine, currentTranslation, nextLine, title, artist,
                       positionMs, style, words, activeWordIndex, lyricsLines, activeLineIndex, size);
}

UIImage *SGLockScreenLyricsFrame(NSURL *canvas, NSInteger positionMs, UIImage *cover,
                                NSString *currentLine, NSString *currentTranslation, NSString *nextLine,
                                NSString *title, NSString *artist, NSInteger style,
                                NSArray<SGKaraokeWord *> *words, NSInteger activeWordIndex,
                                NSArray<SGKaraokeLine *> *lyricsLines, NSInteger activeLineIndex, CGSize size) {
    UIImage *source = canvasFrame(canvas, positionMs, size) ?: cover;
    UIImage *background = SGLockScreenLyricsPreparedBackgroundFrame(source, style, size);
    return SGLockScreenLyricsFrameOnBackground(background, positionMs, currentLine, currentTranslation,
                                               nextLine, title, artist, style, words, activeWordIndex,
                                               lyricsLines, activeLineIndex, size);
}

static UIImage *stylePreviewBackground(CGSize size) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat new];
    format.scale = 1;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef context = rendererContext.CGContext;
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[
            (id)[UIColor colorWithRed:0.02 green:0.18 blue:0.60 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.02 green:0.48 blue:0.72 alpha:1].CGColor,
            (id)[UIColor colorWithRed:0.04 green:0.12 blue:0.42 alpha:1].CGColor,
        ];
        CGFloat locations[] = {0, 0.52, 1};
        CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)colors, locations);
        CGContextDrawLinearGradient(context, gradient, CGPointZero, CGPointMake(size.width, size.height), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(colorSpace);

        CGContextSetBlendMode(context, kCGBlendModeScreen);
        CGContextSetAlpha(context, 0.55);
        CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.04 green:0.92 blue:0.72 alpha:1].CGColor);
        CGContextFillEllipseInRect(context, CGRectMake(size.width * 0.08, size.height * 0.24,
                                                       size.width * 0.46, size.height * 0.27));
        CGContextSetFillColorWithColor(context, [UIColor colorWithRed:0.20 green:0.43 blue:1 alpha:1].CGColor);
        CGContextFillEllipseInRect(context, CGRectMake(size.width * 0.45, size.height * 0.48,
                                                       size.width * 0.64, size.height * 0.32));
    }];
}

UIImage *SGLockScreenLyricsStylePreviewFrame(NSInteger style, CGSize size) {
    size.width = floor(size.width / 16) * 16;
    size.height = floor(size.height / 16) * 16;
    if (size.width < 16 || size.height < 16) return nil;
    UIImage *background = stylePreviewBackground(size);
    NSArray<SGKaraokeLine *> *sampleLines = SGKaraokeEstimatedLines(@[@100000, @104000],
        @[@"We ran before the doors could close", @"And laughed the whole way through the tunnel"]);
    SGKaraokeLine *sampleLine = sampleLines.firstObject;
    return renderFrame(background, NO, @"We ran before the doors could close",
                       @"Abbiamo corso prima che si chiudessero le porte.",
                       @"And laughed the whole way through the tunnel", @"Last Train Home", @"The Demo Band",
                       100380, style, sampleLine.words, 0, sampleLines, 0, size);
}

BOOL SGLockScreenLyricsMovie(NSUInteger frameCount, NSInteger frameRate, NSURL *destination,
                             UIImage *(^frameAtIndex)(NSUInteger index)) {
    if (!frameAtIndex || !frameCount || !destination) return NO;
    frameRate = MAX(frameRate, 1);
    UIImage *firstFrame = frameAtIndex(0);
    if (!firstFrame.CGImage) return NO;
    [NSFileManager.defaultManager createDirectoryAtURL:[destination URLByDeletingLastPathComponent]
                            withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *partial = [destination URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    size_t width = CGImageGetWidth(firstFrame.CGImage), height = CGImageGetHeight(firstFrame.CGImage);
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    if (!writer) return NO;
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(width),
        AVVideoHeightKey: @(height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(width * height * 2)},
    }];
    input.expectsMediaDataInRealTime = NO;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                                                                        sourcePixelBufferAttributes:attributes];
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    CVPixelBufferRef buffer = NULL;
    CVReturn created = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                           (__bridge CFDictionaryRef)attributes, &buffer);
    if (created != kCVReturnSuccess || !buffer) { [writer cancelWriting]; return NO; }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    BOOL okay = colorSpace != NULL;
    for (NSUInteger index = 0; okay && index < frameCount; index++) {
        @autoreleasepool {
            UIImage *frame = index == 0 ? firstFrame : frameAtIndex(index);
            if (!frame.CGImage || CGImageGetWidth(frame.CGImage) != width || CGImageGetHeight(frame.CGImage) != height) {
                okay = NO;
                break;
            }
            CVPixelBufferLockBaseAddress(buffer, 0);
            CGContextRef bitmap = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), width, height, 8,
                CVPixelBufferGetBytesPerRow(buffer), colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            if (bitmap) {
                CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), frame.CGImage);
                CGContextRelease(bitmap);
            } else {
                okay = NO;
            }
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
            okay = okay && writer.status == AVAssetWriterStatusWriting &&
                   [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake((int64_t)index, (int32_t)frameRate)];
        }
    }
    CVPixelBufferRelease(buffer);
    CGColorSpaceRelease(colorSpace);
    [input markAsFinished];
    if (okay) {
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
        dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
        okay = writer.status == AVAssetWriterStatusCompleted;
    } else {
        [writer cancelWriting];
    }
    if (okay) {
        [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
        okay = [NSFileManager.defaultManager moveItemAtURL:partial toURL:destination error:nil];
    } else {
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    }
    return okay;
}

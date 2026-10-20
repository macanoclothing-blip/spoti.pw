#import "Core/SGCore.h"
#import "SGMusicRecognition.h"
#import "Settings/SGPageStyle.h"
#import <AVFoundation/AVFoundation.h>
#import <ShazamKit/ShazamKit.h>

static NSNotificationName const kRecognitionChanged = @"spotifyglass.musicRecognition.changed";

@interface SGMusicRecognition : NSObject <SHSessionDelegate>
@property (nonatomic) AVAudioEngine *engine;
@property (nonatomic) SHSession *session;
@property (nonatomic) NSTimer *timeout;
@property (nonatomic) BOOL listening;
@property (nonatomic, copy) AVAudioSessionCategory previousCategory;
@property (nonatomic, copy) AVAudioSessionMode previousMode;
@property (nonatomic) AVAudioSessionCategoryOptions previousOptions;
@property (nonatomic) BOOL hasPreviousSession;
@end

@implementation SGMusicRecognition

+ (instancetype)shared {
    static SGMusicRecognition *recognition;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ recognition = [SGMusicRecognition new]; });
    return recognition;
}

- (void)publishChange {
    [NSNotificationCenter.defaultCenter postNotificationName:kRecognitionChanged object:nil];
}

- (void)requestMicrophonePermission:(void (^)(BOOL granted))completion {
    if (@available(iOS 17.0, *)) {
        [AVAudioApplication requestRecordPermissionWithCompletionHandler:completion];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [AVAudioSession.sharedInstance requestRecordPermission:completion];
#pragma clang diagnostic pop
    }
}

- (void)start {
    if (self.listening) return;
    if (!SGFlag(SGKeyMusicRecognition, NO)) {
        [self showMessage:@"Music recognition is off" message:@"Turn on ShazamKit recognition in Mod Settings → Player first."];
        return;
    }
    if (@available(iOS 15.0, *)) {
        __weak typeof(self) weakSelf = self;
        [self requestMicrophonePermission:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SGMusicRecognition *self = weakSelf;
                if (!self) return;
                if (!granted) {
                    [self showMessage:@"Microphone access needed"
                              message:@"Allow microphone access in iPhone Settings to identify music playing nearby."];
                    return;
                }
                [self beginListening];
            });
        }];
    } else {
        [self showMessage:@"Requires iOS 15 or later" message:@"ShazamKit music recognition is not available on this iOS version."];
    }
}

- (void)beginListening {
    if (self.listening || !SGFlag(SGKeyMusicRecognition, NO)) return;
    AVAudioSession *audioSession = AVAudioSession.sharedInstance;
    NSError *error = nil;
    self.previousCategory = audioSession.category;
    self.previousMode = audioSession.mode;
    self.previousOptions = audioSession.categoryOptions;
    self.hasPreviousSession = YES;
    if (![audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                              mode:AVAudioSessionModeDefault
                           options:AVAudioSessionCategoryOptionMixWithOthers |
                                   AVAudioSessionCategoryOptionAllowBluetoothHFP |
                                   AVAudioSessionCategoryOptionDefaultToSpeaker
                             error:&error] ||
        ![audioSession setActive:YES error:&error]) {
        SGLog(@"music recognition: could not activate microphone session: %@", error.localizedDescription);
        [self restoreAudioSession];
        [self showMessage:@"Could not start listening" message:error.localizedDescription ?: @"The audio session could not be activated."];
        return;
    }

    AVAudioEngine *engine = [AVAudioEngine new];
    AVAudioInputNode *input = engine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    if (!format.sampleRate || !format.channelCount) {
        [self restoreAudioSession];
        [self showMessage:@"Microphone unavailable" message:@"No usable microphone input is available on this device."];
        return;
    }

    self.session = [SHSession new];
    self.session.delegate = self;
    self.engine = engine;
    self.listening = YES;
    SHSession *session = self.session;
    [input installTapOnBus:0 bufferSize:4096 format:format
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        [session matchStreamingBuffer:buffer atTime:when];
    }];
    [engine prepare];
    if (![engine startAndReturnError:&error]) {
        [input removeTapOnBus:0];
        self.listening = NO;
        self.engine = nil;
        self.session.delegate = nil;
        self.session = nil;
        SGLog(@"music recognition: audio engine failed to start: %@", error.localizedDescription);
        [self restoreAudioSession];
        [self showMessage:@"Could not start listening" message:error.localizedDescription ?: @"The microphone could not be opened."];
        return;
    }
    self.timeout = [NSTimer scheduledTimerWithTimeInterval:20 target:self selector:@selector(noMatchTimeout)
                                                  userInfo:nil repeats:NO];
    [self publishChange];
    SGLog(@"music recognition: microphone listening started");
}

- (void)stop {
    if (!self.listening && !self.hasPreviousSession) return;
    [self.timeout invalidate];
    self.timeout = nil;
    self.listening = NO;
    [self.engine.inputNode removeTapOnBus:0];
    [self.engine stop];
    self.engine = nil;
    self.session.delegate = nil;
    self.session = nil;
    [self restoreAudioSession];
    [self publishChange];
    SGLog(@"music recognition: listening stopped");
}

- (void)restoreAudioSession {
    if (!self.hasPreviousSession) return;
    AVAudioSession *audioSession = AVAudioSession.sharedInstance;
    NSError *error = nil;
    if (![audioSession setCategory:self.previousCategory mode:self.previousMode options:self.previousOptions error:&error]) {
        SGLog(@"music recognition: could not restore audio category: %@", error.localizedDescription);
    }
    self.hasPreviousSession = NO;
}

- (void)noMatchTimeout {
    if (!self.listening) return;
    [self stop];
    [self showMessage:@"No match found" message:@"Try again closer to the speaker, with less background noise."];
}

- (void)session:(SHSession *)session didFindMatch:(SHMatch *)match {
    (void)session;
    SHMediaItem *item = match.mediaItems.firstObject;
    NSString *title = item.title;
    NSString *artist = item.artist;
    if (!title.length || !artist.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.listening) return;
        [self stop];
        [self showMatchTitle:title artist:artist];
    });
}

- (void)session:(SHSession *)session didNotFindMatchForSignature:(SHSignature *)signature error:(NSError *)error {
    (void)session;
    (void)signature;
    if (!error) return;
    SGLog(@"music recognition: ShazamKit match attempt failed: %@", error.localizedDescription);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.listening) return;
        [self stop];
        [self showMessage:@"ShazamKit could not identify music"
                  message:[NSString stringWithFormat:@"%@ Check that ShazamKit is enabled for the app ID used to sign this Spotify build.",
                           error.localizedDescription ?: @"The catalog request failed."]];
    });
}

- (void)showMessage:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
            message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
    });
}

- (void)showMatchTitle:(NSString *)title artist:(NSString *)artist {
    NSString *query = [NSString stringWithFormat:@"%@ %@", title, artist];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    NSString *encoded = [query stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSURL *searchURL = encoded.length ? [NSURL URLWithString:[@"spotify:search:" stringByAppendingString:encoded]] : nil;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:[NSString stringWithFormat:@"Identified by ShazamKit\n%@", artist]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    if (searchURL) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Search in Spotify" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) { SGOpenURL(searchURL.absoluteString); }]];
    }
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}
@end

static SGMusicRecognition *recognition(void) {
    return [SGMusicRecognition shared];
}

void SGMusicRecognitionStart(void) {
    [recognition() start];
}

SGModSection *SGMusicRecognitionSection(void) {
    SGModRow *enabled = SGOptionRow(@"ShazamKit recognition",
        @"Identify music audible nearby, including from another device. Requires ShazamKit access in the signing app ID.",
        SGKeyMusicRecognition);
    enabled.changed = ^(BOOL on) {
        if (!on) [recognition() stop];
    };
    SGModRow *start = SGActionRow(@"Identify nearby music", @"Listen for up to 20 seconds", ^{
        [recognition() start];
    });
    start.visible = ^BOOL {
        return SGFlag(SGKeyMusicRecognition, NO) && !recognition().listening;
    };
    start.refreshOn = kRecognitionChanged;
    SGModRow *stop = SGActionRow(@"Stop listening", @"Microphone is active", ^{
        [recognition() stop];
    });
    stop.visible = ^BOOL { return recognition().listening; };
    stop.refreshOn = kRecognitionChanged;
    SGModSection *section = SGSection(@"Music recognition", @[enabled, start, stop]);
    section.footer = @"Listening starts only when you tap Identify nearby music and stops after a match or 20 seconds. "
                     "ShazamKit checks an audio signature against its catalog; spoti.pw does not save microphone audio. "
                     "Pause Spotify on this iPhone so its own speaker output does not interfere. The App ID used to sign this build must have ShazamKit enabled.";
    return section;
}

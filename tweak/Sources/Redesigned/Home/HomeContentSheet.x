#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Navigation/Links.h"

static BOOL sgrHomeVisible(void) {
    UIViewController *top = SGTopController();
    if (!top) return NO;
    NSMutableArray<UIViewController *> *pending = [NSMutableArray arrayWithObject:top];
    while (pending.count) {
        UIViewController *controller = pending.lastObject;
        [pending removeLastObject];
        NSString *name = NSStringFromClass(controller.class).lowercaseString;
        if ([name containsString:@"home"]) return YES;
        [pending addObjectsFromArray:controller.childViewControllers];
        if (controller.presentedViewController) [pending addObject:controller.presentedViewController];
        if ([controller isKindOfClass:UINavigationController.class]) {
            UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
            if (visible) [pending addObject:visible];
        }
    }
    return NO;
}

static NSString *sgrHTTPURL(NSURL *uri) {
    if (![uri.scheme.lowercaseString isEqualToString:@"spotify"]) return uri.absoluteString;
    NSArray<NSString *> *parts = [uri.resourceSpecifier componentsSeparatedByString:@":"];
    if (parts.count < 2) return uri.absoluteString;
    return [NSString stringWithFormat:@"https://open.spotify.com/%@/%@", parts[0], parts[1]];
}

@interface SGRHomeContentSheet : UIViewController
@property (nonatomic, strong) NSURL *uri;
@property (nonatomic, copy) NSString *kind;
@end

@implementation SGRHomeContentSheet

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.clearColor;

    UIVisualEffectView *surface = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    surface.translatesAutoresizingMaskIntoConstraints = NO;
    surface.layer.cornerRadius = 28;
    surface.layer.cornerCurve = kCACornerCurveContinuous;
    surface.clipsToBounds = YES;
    [self.view addSubview:surface];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = self.kind.length ? self.kind : @"Spotify";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    title.numberOfLines = 1;
    [surface.contentView addSubview:title];

    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = self.uri.absoluteString;
    subtitle.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.62];
    subtitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    subtitle.numberOfLines = 2;
    [surface.contentView addSubview:subtitle];

    NSArray<NSArray<NSString *> *> *rows = @[
        @[@"square.and.arrow.up", @"Condividi"],
        @[@"qrcode", @"Mostra il codice Spotify"],
        @[@"plus", @"Aggiungi a La tua libreria"],
    ];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    [surface.contentView addSubview:stack];
    for (NSArray<NSString *> *row in rows) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.accessibilityIdentifier = row[1];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        [button setTitle:row[1] forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        UIImage *image = [UIImage systemImageNamed:row[0]];
        button.tintColor = UIColor.whiteColor;
        UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
        configuration.image = image;
        configuration.imagePadding = 14;
        configuration.contentInsets = NSDirectionalEdgeInsetsMake(14, 16, 14, 16);
        configuration.baseForegroundColor = UIColor.whiteColor;
        button.configuration = configuration;
        button.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:0.10];
        button.layer.cornerRadius = 17;
        [button addTarget:self action:@selector(action:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];
    }
    [NSLayoutConstraint activateConstraints:@[
        [surface.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [surface.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [surface.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12],
        [surface.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-12],
        [title.topAnchor constraintEqualToAnchor:surface.contentView.topAnchor constant:24],
        [title.leadingAnchor constraintEqualToAnchor:surface.contentView.leadingAnchor constant:22],
        [title.trailingAnchor constraintEqualToAnchor:surface.contentView.trailingAnchor constant:-22],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:5],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:22],
        [stack.leadingAnchor constraintEqualToAnchor:surface.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:surface.contentView.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:surface.contentView.bottomAnchor constant:-20],
    ]];
}

- (void)action:(UIButton *)button {
    NSString *identifier = button.accessibilityIdentifier;
    NSString *webURL = sgrHTTPURL(self.uri);
    if ([identifier isEqualToString:@"Condividi"]) {
        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[webURL] applicationActivities:nil];
        [self presentViewController:activity animated:YES completion:nil];
        return;
    }
    if ([identifier isEqualToString:@"Mostra il codice Spotify"]) {
        NSString *encodedURI = [self.uri.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLPathAllowedCharacterSet]];
        NSString *codeURL = [NSString stringWithFormat:
            @"https://scannables.scdn.co/uri/plain/png/ffffff/black/640/%@", encodedURI];
        NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:codeURL]
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error || !data.length) {
                    SGLog(@"redesign home: Spotify Code request failed: %@", error);
                    return;
                }
                UIImage *code = [UIImage imageWithData:data];
                if (!code) return;
                UIImageView *preview = [[UIImageView alloc] initWithImage:code];
                preview.backgroundColor = UIColor.blackColor;
                preview.contentMode = UIViewContentModeScaleAspectFit;
                preview.frame = CGRectMake(0, 0, 240, 240);
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Codice Spotify"
                    message:nil preferredStyle:UIAlertControllerStyleAlert];
                [alert.view addSubview:preview];
                [alert addAction:[UIAlertAction actionWithTitle:@"Condividi" style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *action) {
                    UIActivityViewController *activity = [[UIActivityViewController alloc]
                        initWithActivityItems:@[code] applicationActivities:nil];
                    [self presentViewController:activity animated:YES completion:nil];
                }]];
                [alert addAction:[UIAlertAction actionWithTitle:@"Chiudi" style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:alert animated:YES completion:^{
                    preview.translatesAutoresizingMaskIntoConstraints = NO;
                    [NSLayoutConstraint activateConstraints:@[
                        [preview.heightAnchor constraintEqualToConstant:240],
                        [preview.widthAnchor constraintEqualToConstant:240],
                        [preview.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
                        [preview.topAnchor constraintEqualToAnchor:alert.view.topAnchor constant:55],
                    ]];
                }];
            });
        }];
        [task resume];
        return;
    }
    if ([identifier isEqualToString:@"Aggiungi a La tua libreria"]) {
        SGLog(@"redesign home: add-to-library requested for %@", self.uri.absoluteString);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"La tua libreria"
            message:@"Apri il contenuto per aggiungerlo alla tua libreria dal menu di Spotify."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}
@end

static BOOL sgrPresentHomeSheet(NSURL *uri) {
    UIViewController *presenter = SGTopController();
    if (!presenter || presenter.presentedViewController || !sgrHomeVisible()) return NO;
    SGRHomeContentSheet *sheet = [SGRHomeContentSheet new];
    sheet.uri = uri;
    sheet.kind = [uri.resourceSpecifier.lowercaseString hasPrefix:@"playlist:"] ? @"Playlist" : @"Album";
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        sheet.sheetPresentationController.detents = @[
            UISheetPresentationControllerDetent.mediumDetent,
            UISheetPresentationControllerDetent.largeDetent
        ];
        sheet.sheetPresentationController.prefersGrabberVisible = YES;
        sheet.sheetPresentationController.preferredCornerRadius = 28;
    }
    [presenter presentViewController:sheet animated:YES completion:nil];
    return YES;
}

%hook SPTLinkDispatcherImplementation
- (void)navigateToURI:(NSURL *)uri options:(long long)options interactionID:(id)interactionID {
    NSString *resource = uri.resourceSpecifier.lowercaseString;
    BOOL content = [resource hasPrefix:@"album:"] || [resource hasPrefix:@"playlist:"];
    if (content && sgrPresentHomeSheet(uri)) return;
    %orig;
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"SPTLinkDispatcherImplementation"]);
}

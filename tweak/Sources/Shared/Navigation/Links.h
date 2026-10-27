// Opening a Spotify URI through its dispatcher, or a registered spotifyglass: URI on the current tab's stack.
#import <Foundation/Foundation.h>
@class UIViewController;

// NO before the dispatcher is set up for Spotify URIs, or for an unknown URI.
BOOL SGOpenSpotifyURI(NSURL *uri);
// A page of the mod's own, made on each open and pushed onto the selected Spotify navigation stack.
void SGRegisterModPage(NSString *uri, UIViewController *(^make)(void));
// The higher UI layer supplies presentation so Shared does not depend on Settings or Redesigned.
void SGRegisterModPageOpener(BOOL (^open)(UIViewController *page, NSURL *uri));
id SGLinkDispatcher(void);   // SPTLinkDispatcherImplementation, nil until it is set up

// Whether the dispatcher has somewhere to send a URI, asked the way it asks itself before it opens
// one: every handler in its URI subtype registry is asked -URISubtypeHandlerCanHandleURI:, then the
// same again for the URI its fallback resolver remaps an unhandled one to. None of them saying yes is
// what ends in Spotify's "Couldn't open link" alert.
typedef NS_ENUM(NSInteger, SGLinkRoute) {
    SGLinkRouteUnknown = -1,   // the dispatcher or its registry is not there to ask
    SGLinkRouteNone = 0,
    SGLinkRouteOpens = 1,
};
// `via`, when given, is the class of the handler that said yes, prefixed "remap <uri> " when it took
// the fallback resolver's URI; nil otherwise.
SGLinkRoute SGSpotifyURIRoute(NSURL *uri, NSString **via);

// What someone typed or pasted as a link, as a spotify: URI: surrounding blanks trimmed, and a share
// link (https://open.spotify.com/[intl-xx/]playlist/<id>?si=…) turned into spotify:playlist:<id>.
// nil when there is nothing a URI can be made of.
NSURL *SGSpotifyURIFromText(NSString *text);

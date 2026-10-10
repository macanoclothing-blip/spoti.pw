#import "Core/SGCore.h"
#import "PlayerOrientation.h"

static char kOrientationHookKey;
static NSString *const kPlayerClass = @"_TtC19NowPlaying_ViewImpl24NowPlayingViewController";

static BOOL visibleControllerTreeContainsPlayer(UIViewController *controller, UIWindow *window, NSUInteger depth) {
    if (!controller || !window || depth > 32) return NO;
    UIView *view = controller.viewIfLoaded;
    if (view && (view.window != window || view.hidden || view.alpha < 0.01)) return NO;
    Class playerClass = NSClassFromString(kPlayerClass);
    if (playerClass && [controller isKindOfClass:playerClass]) return YES;

    UIViewController *presented = controller.presentedViewController;
    if (presented && visibleControllerTreeContainsPlayer(presented, window, depth + 1)) return YES;
    if ([controller isKindOfClass:UINavigationController.class]) {
        return visibleControllerTreeContainsPlayer(((UINavigationController *)controller).visibleViewController, window, depth + 1);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return visibleControllerTreeContainsPlayer(((UITabBarController *)controller).selectedViewController, window, depth + 1);
    }
    for (UIViewController *child in controller.childViewControllers.reverseObjectEnumerator) {
        if (visibleControllerTreeContainsPlayer(child, window, depth + 1)) return YES;
    }
    return NO;
}

static BOOL playerVisibleInWindow(UIWindow *window) {
    if (!window) return NO;
    return visibleControllerTreeContainsPlayer(window.rootViewController, window, 0);
}

static void installOnDelegate(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL selector = @selector(application:supportedInterfaceOrientationsForWindow:);
    if (objc_getAssociatedObject(cls, &kOrientationHookKey)) return;

    Method inherited = class_getInstanceMethod(cls, selector);
    Method own = NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            own = methods[i];
            break;
        }
    }
    free(methods);

    IMP original = own ? method_getImplementation(own)
                       : inherited ? class_getMethodImplementation(class_getSuperclass(cls), selector) : NULL;
    const char *types = inherited ? method_getTypeEncoding(inherited) : "Q@:@@";
    IMP replacement = imp_implementationWithBlock(^UIInterfaceOrientationMask(id target, UIApplication *application, UIWindow *window) {
        UIWindow *checkedWindow = window;
        if (!checkedWindow) {
            for (UIScene *scene in application.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                    if (candidate.isKeyWindow) {
                        checkedWindow = candidate;
                        break;
                    }
                }
                if (checkedWindow) break;
            }
        }
        if (playerVisibleInWindow(checkedWindow)) return UIInterfaceOrientationMaskAllButUpsideDown;
        if (original) {
            UIInterfaceOrientationMask (*callOriginal)(id, SEL, UIApplication *, UIWindow *) =
                (UIInterfaceOrientationMask (*)(id, SEL, UIApplication *, UIWindow *))original;
            return callOriginal(target, selector, application, window);
        }
        return UIInterfaceOrientationMaskPortrait;
    });
    BOOL installed = own ? (method_setImplementation(own, replacement), YES) : class_addMethod(cls, selector, replacement, types);
    if (!installed) {
        SGLog(@"redesign player: could not install app orientation policy on %@", NSStringFromClass(cls));
        return;
    }
    objc_setAssociatedObject(cls, &kOrientationHookKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGLog(@"redesign player: landscape orientation enabled only while the full-screen player is visible (%@)", NSStringFromClass(cls));
}

void SGRPlayerInstallOrientationPolicy(void) {
    NSCAssert(NSThread.isMainThread, @"Orientation policy must be installed on the main thread");
    installOnDelegate(UIApplication.sharedApplication.delegate);
}

void SGRPlayerRefreshOrientationPolicy(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SGRPlayerInstallOrientationPolicy();
        Class playerClass = NSClassFromString(kPlayerClass);
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                UIViewController *root = window.rootViewController;
                if (!window.isKeyWindow || !playerClass || !visibleControllerTreeContainsPlayer(root, window, 0)) continue;
                UIViewController *player = nil;
                NSMutableArray<UIViewController *> *pending = [NSMutableArray arrayWithObject:root];
                while (pending.count) {
                    UIViewController *current = pending.lastObject;
                    [pending removeLastObject];
                    if ([current isKindOfClass:playerClass]) {
                        player = current;
                        break;
                    }
                    if (current.presentedViewController) [pending addObject:current.presentedViewController];
                    [pending addObjectsFromArray:current.childViewControllers];
                    if ([current isKindOfClass:UINavigationController.class]) {
                        UIViewController *visible = ((UINavigationController *)current).visibleViewController;
                        if (visible) [pending addObject:visible];
                    } else if ([current isKindOfClass:UITabBarController.class]) {
                        UIViewController *selected = ((UITabBarController *)current).selectedViewController;
                        if (selected) [pending addObject:selected];
                    }
                }
                if (player) {
                    if (@available(iOS 16.0, *)) [player setNeedsUpdateOfSupportedInterfaceOrientations];
                    return;
                }
            }
        }
    });
}

__attribute__((constructor)) static void SGRPlayerOrientationStart(void) {
    if (!SGRedesignedUI()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        SGRPlayerInstallOrientationPolicy();
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) { SGRPlayerInstallOrientationPolicy(); }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) { SGRPlayerInstallOrientationPolicy(); }];
    });
}

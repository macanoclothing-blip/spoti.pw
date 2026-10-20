#import "Core/SGCore.h"
#import "PlayerOrientation.h"
#import <objc/runtime.h>

static char kOrientationHookKey;
static char kControllerOrientationHookKey;
static char kControllerAutorotationHookKey;
static NSString *const kPlayerClass = @"_TtC19NowPlaying_ViewImpl24NowPlayingViewController";
static UIInterfaceOrientationMask sg_forcedOrientationMask;
static UIDeviceOrientation sg_lastPhysicalOrientation;

static BOOL physicalOrientationIsValid(UIDeviceOrientation orientation) {
    return UIDeviceOrientationIsPortrait(orientation) || UIDeviceOrientationIsLandscape(orientation);
}

static UIInterfaceOrientationMask maskForPhysicalOrientation(UIDeviceOrientation orientation) {
    return UIDeviceOrientationIsLandscape(orientation) ? UIInterfaceOrientationMaskLandscape
                                                       : UIInterfaceOrientationMaskPortrait;
}

#pragma mark - Ricerca del player nell'albero dei controller

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

static void installControllerOrientationMethod(UIViewController *controller, SEL selector, const void *hookKey) {
    if (!controller) return;
    Class cls = [controller class];
    if ([NSStringFromClass(cls) isEqualToString:kPlayerClass] || objc_getAssociatedObject(cls, hookKey)) return;

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
    const char *types = inherited ? method_getTypeEncoding(inherited) : "Q@:";
    IMP replacement = imp_implementationWithBlock(^UIInterfaceOrientationMask(UIViewController *target) {
        UIWindow *window = target.viewIfLoaded.window;
        if (window && playerVisibleInWindow(window)) {
            return sg_forcedOrientationMask ?: UIInterfaceOrientationMaskAllButUpsideDown;
        }
        if (original) {
            UIInterfaceOrientationMask (*callOriginal)(id, SEL) = (UIInterfaceOrientationMask (*)(id, SEL))original;
            return callOriginal(target, selector);
        }
        return UIInterfaceOrientationMaskPortrait;
    });
    BOOL installed = own ? (method_setImplementation(own, replacement), YES)
                         : class_addMethod(cls, selector, replacement, types);
    if (!installed) {
        SGLog(@"redesign player: could not install orientation policy on controller %@", NSStringFromClass(cls));
        return;
    }
    objc_setAssociatedObject(cls, hookKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void installControllerAutorotationMethod(UIViewController *controller) {
    if (!controller) return;
    Class cls = [controller class];
    if ([NSStringFromClass(cls) isEqualToString:kPlayerClass] || objc_getAssociatedObject(cls, &kControllerAutorotationHookKey)) return;
    SEL selector = @selector(shouldAutorotate);
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
    const char *types = inherited ? method_getTypeEncoding(inherited) : "B@:";
    IMP replacement = imp_implementationWithBlock(^BOOL(UIViewController *target) {
        UIWindow *window = target.viewIfLoaded.window;
        if (window && playerVisibleInWindow(window)) return YES;
        if (original) {
            BOOL (*callOriginal)(id, SEL) = (BOOL (*)(id, SEL))original;
            return callOriginal(target, selector);
        }
        return YES;
    });
    BOOL installed = own ? (method_setImplementation(own, replacement), YES)
                         : class_addMethod(cls, selector, replacement, types);
    if (installed) objc_setAssociatedObject(cls, &kControllerAutorotationHookKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void installOnController(UIViewController *controller) {
    if (!controller || [NSStringFromClass([controller class]) isEqualToString:kPlayerClass]) return;
    Class cls = [controller class];
    BOOL needsInstall = !objc_getAssociatedObject(cls, &kControllerOrientationHookKey) ||
                        !objc_getAssociatedObject(cls, &kControllerAutorotationHookKey);
    installControllerOrientationMethod(controller, @selector(supportedInterfaceOrientations), &kControllerOrientationHookKey);
    installControllerAutorotationMethod(controller);
    if (needsInstall && objc_getAssociatedObject(cls, &kControllerOrientationHookKey) &&
        objc_getAssociatedObject(cls, &kControllerAutorotationHookKey)) {
        SGLog(@"redesign player: conditional rotation policy installed on %@", NSStringFromClass(cls));
    }
}

#pragma mark - Richiesta di rotazione alla scena

static void requestWindowOrientationIfNeeded(UIWindow *window) {
    if (@available(iOS 16.0, *)) {
        UIWindowScene *windowScene = window.windowScene;
        if (!windowScene || windowScene.activationState != UISceneActivationStateForegroundActive) {
            SGLog(@"redesign player: cannot request orientation without an active window scene");
            return;
        }
        UIDeviceOrientation deviceOrientation = UIDevice.currentDevice.orientation;
        UIInterfaceOrientationMask requested = sg_forcedOrientationMask;
        if (!requested && physicalOrientationIsValid(deviceOrientation)) {
            requested = maskForPhysicalOrientation(deviceOrientation);
        }
        if (!requested) return;
        BOOL deviceLandscape = (requested & UIInterfaceOrientationMaskLandscape) != 0;
        UIInterfaceOrientation interfaceOrientation = windowScene.interfaceOrientation;
        BOOL orientationMismatch = (deviceLandscape && !UIInterfaceOrientationIsLandscape(interfaceOrientation)) ||
                                   (!deviceLandscape && !UIInterfaceOrientationIsPortrait(interfaceOrientation));
        if (orientationMismatch) {
            UIWindowSceneGeometryPreferencesIOS *preferences =
                [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:requested];
            [windowScene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
                SGLog(@"redesign player: scene rejected orientation update (%@)", error);
            }];
        }
    }
}

#pragma mark - Hook sul delegate dell'app

static void installOnDelegate(id delegate) {
    if (!delegate) return;
    // The app delegate's orientation callback is an instance method. Using object_getClass
    // here returns its metaclass, so UIKit never sees the policy we install.
    Class cls = [delegate class];
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
        if (playerVisibleInWindow(checkedWindow)) {
            return sg_forcedOrientationMask ?: UIInterfaceOrientationMaskAllButUpsideDown;
        }
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

#pragma mark - API pubbliche

void SGRPlayerInstallOrientationPolicy(void) {
    NSCAssert(NSThread.isMainThread, @"Orientation policy must be installed on the main thread");
    installOnDelegate(UIApplication.sharedApplication.delegate);
}

void SGRPlayerToggleOrientation(void) {
    NSCAssert(NSThread.isMainThread, @"Orientation changes must be requested on the main thread");
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow && playerVisibleInWindow(candidate)) {
                window = candidate;
                break;
            }
        }
        if (window) break;
    }
    if (!window) {
        SGLog(@"redesign player: orientation toggle could not find the visible player window");
        return;
    }

    UIInterfaceOrientation orientation = window.windowScene.interfaceOrientation;
    BOOL currentLandscape = UIInterfaceOrientationIsLandscape(orientation);
    if (sg_forcedOrientationMask) {
        currentLandscape = (sg_forcedOrientationMask & UIInterfaceOrientationMaskLandscape) != 0;
    } else if (!UIInterfaceOrientationIsPortrait(orientation) && !UIInterfaceOrientationIsLandscape(orientation)) {
        currentLandscape = window.bounds.size.height < window.bounds.size.width;
    }
    BOOL landscape = !currentLandscape;
    sg_forcedOrientationMask = landscape ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskPortrait;
    UIDeviceOrientation physical = UIDevice.currentDevice.orientation;
    if (physicalOrientationIsValid(physical)) sg_lastPhysicalOrientation = physical;
    SGRPlayerRefreshOrientationPolicy();
    SGLog(@"redesign player: lyrics requested %@ orientation from %@",
          landscape ? @"landscape" : @"portrait",
          UIInterfaceOrientationIsLandscape(orientation) ? @"landscape" : @"portrait");
}

void SGRPlayerClearOrientationOverride(void) {
    if (!sg_forcedOrientationMask) return;
    sg_forcedOrientationMask = 0;
    SGRPlayerRefreshOrientationPolicy();
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
                    for (UIViewController *ancestor = player; ancestor; ancestor = ancestor.parentViewController) {
                        installOnController(ancestor);
                    }
                    if (@available(iOS 16.0, *)) {
                        for (UIViewController *ancestor = player; ancestor; ancestor = ancestor.parentViewController) {
                            [ancestor setNeedsUpdateOfSupportedInterfaceOrientations];
                        }
                        if (root && root != player) [root setNeedsUpdateOfSupportedInterfaceOrientations];
                    }
                    requestWindowOrientationIfNeeded(window);
                    return;
                }
            }
        }
        if (sg_forcedOrientationMask) {
            SGLog(@"redesign player: requested orientation retained while the player scene is being resolved");
        }
    });
}

#pragma mark - Avvio

__attribute__((constructor)) static void SGRPlayerOrientationStart(void) {
    if (!SGRedesignedUI()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        SGRPlayerInstallOrientationPolicy();
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) { (void)note; SGRPlayerInstallOrientationPolicy(); }];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) { (void)note; SGRPlayerInstallOrientationPolicy(); }];
        [center addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            (void)note;
            UIDeviceOrientation physical = UIDevice.currentDevice.orientation;
            if (sg_forcedOrientationMask && physicalOrientationIsValid(physical) &&
                physicalOrientationIsValid(sg_lastPhysicalOrientation) &&
                UIDeviceOrientationIsLandscape(physical) != UIDeviceOrientationIsLandscape(sg_lastPhysicalOrientation)) {
                sg_forcedOrientationMask = 0;
            }
            if (physicalOrientationIsValid(physical)) sg_lastPhysicalOrientation = physical;
            SGRPlayerRefreshOrientationPolicy();
        }];
    });
}

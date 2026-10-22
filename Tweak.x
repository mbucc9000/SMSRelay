// SMSRelay — texts sent to the real iPhone's number, shown on the iPhone 5 (iOS 6, armv7).
//
// The SIM with your real number lives in your main iPhone (iOS 26, no jailbreak).
// iMessages to that number already reach the iPhone 5 through his Apple ID, but plain SMS
// (bank and 2FA codes, Android friends) stay on the 17, because Text Message Forwarding needs
// iOS 8. So the 17 runs a Shortcuts automation (see README.md). On every incoming message it
// sends an iMessage to your own number that reads
//
//     [SMS] <sender>
//     <text>
//
// and that message lands here in the own-number chat.
//
// This tweak hooks SpringBoard's BBServer, which every notification passes through before it
// becomes a banner, a lock-screen item or a Notification Center row. For Messages
// notifications:
//   - A relayed one gets the original sender as its title and the original text as its
//     body. If the text holds a verification code, the code is copied to the clipboard.
//   - Shortcuts can't tell SMS from iMessage, so the 17 relays iMessages too, and those have
//     already come here directly. When the same text arrives both ways within a few minutes,
//     whichever copy comes second is dropped: no banner, no sound.
// Nothing here touches imagent, iMessage registration or sms.db. The messages themselves stay
// in the own-number chat exactly as they arrived.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <substrate.h>
#include <notify.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#define SR_PREFS_PATH       @"/var/mobile/Library/Preferences/com.mbucc9000.smsrelay.plist"
#define SR_NOTIFY_PREFS     "com.mbucc9000.smsrelay/prefs"
#define SR_LOG_PATH         "/var/mobile/SMSRelay.log"
#define SR_LOG_MAX_BYTES    (128 * 1024)
#define SR_LOG_MAX_LINES    300
#define SR_SECTION          @"com.apple.MobileSMS"
#define SR_TAG              @"[SMS]"
#define SR_DUP_WINDOW       180.0   // s: the same text twice within this is one message seen twice
#define SR_DUP_MIN_LENGTH   12      // shorter texts ("ok") also need the same sender to count
#define SR_CODE_WINDOW      600.0   // s: a republished bulletin doesn't copy its code again
#define SR_SECTIONS_LOGGED  12      // first N bulletins of any app get a line, to confirm the hook
#define SR_SMS_LOGGED       40      // first N Messages bulletins get a line

// What we use of BBBulletin / BBBulletinRequest (a subclass). Every call is guarded with
// respondsToSelector:, so nothing links against BulletinBoard.
@protocol SRBulletin <NSObject>
- (NSString *)sectionID;
- (NSString *)title;
- (void)setTitle:(NSString *)title;
- (void)setSubtitle:(NSString *)subtitle;
- (NSString *)message;
- (void)setMessage:(NSString *)message;
@end

typedef enum {
    SRKindDirect = 0,   // came straight here as an iMessage
    SRKindRelayed,      // came through the 17's automation (already rewritten by us)
} SRKind;

typedef void (*SRPublishFn)(id server, SEL cmd, id bulletin, unsigned int destinations, BOOL alwaysToLockScreen);
static SRPublishFn gOrigPublish;
static SRPublishFn gOrigPublishRequest;

static BOOL gEnabled = YES;
static BOOL gCopyCodes = YES;
static BOOL gHideDuplicates = YES;

static NSMutableArray *gSeen;   // recent Messages bulletins: @{t: title, s: sender key, b: text, k: kind, at: time}
static NSString *gLastCode;
static CFAbsoluteTime gLastCodeAt;
static int gLogLines;
static int gSectionsLogged;
static int gSmsLogged;

#pragma mark - Log

// Never logs message text, senders or codes: only lengths, kinds and what was done.
static void SRLog(NSString *format, ...) {
    if (gLogLines >= SR_LOG_MAX_LINES) {
        return;
    }
    gLogLines++;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
    int fd = open(SR_LOG_PATH, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) {
        NSLog(@"SMSRelay: %@", msg);
        return;
    }
    const char *bytes = [line UTF8String];
    write(fd, bytes, strlen(bytes));
    close(fd);
}

#pragma mark - Prefs

static BOOL SRBool(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

// Defaults match the "default" values in the pane (layout/.../SMSRelay.plist).
static void SRLoadPrefs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:SR_PREFS_PATH];
    gEnabled = SRBool(prefs, @"enabled", YES);
    gCopyCodes = SRBool(prefs, @"copyCodes", YES);
    gHideDuplicates = SRBool(prefs, @"hideDuplicates", YES);
}

#pragma mark - Relayed format

static NSString *SRTrim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// "[SMS] Sender\nText", or on one line "[SMS] Sender: Text". If the Shortcut lost its line
// break ("[SMS] 70924Venmo: 151339 is…"), a number or short code at the start is the sender.
// A lone "[SMS] Sender" is a picture or empty text (iMessage drops the trailing newline).
// NO if it isn't a relayed message.
static BOOL SRParse(NSString *message, NSString **sender, NSString **body) {
    static NSRegularExpression *numericSender;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        numericSender = [NSRegularExpression regularExpressionWithPattern:
            @"^\\s*(\\+?[0-9][0-9 ().-]*[0-9])(?=\\s*[^0-9\\s().+-])" options:0 error:NULL];
    });
    NSString *m = SRTrim(message);
    if (![m hasPrefix:SR_TAG]) {
        return NO;
    }
    NSString *rest = [m substringFromIndex:SR_TAG.length];
    NSString *s = rest;
    NSString *b = @"";
    NSRange newline = [rest rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
    NSTextCheckingResult *number = [numericSender firstMatchInString:rest options:0 range:NSMakeRange(0, rest.length)];
    if (newline.location != NSNotFound) {
        s = [rest substringToIndex:newline.location];
        b = [rest substringFromIndex:NSMaxRange(newline)];
    } else if (number) {
        NSRange digits = [number rangeAtIndex:1];
        NSMutableCharacterSet *separators = [NSMutableCharacterSet whitespaceCharacterSet];
        [separators addCharactersInString:@":"];
        s = [rest substringWithRange:digits];
        b = [[rest substringFromIndex:NSMaxRange(digits)] stringByTrimmingCharactersInSet:separators];
    } else {
        NSRange colon = [rest rangeOfString:@": "];
        if (colon.location != NSNotFound) {
            s = [rest substringToIndex:colon.location];
            b = [rest substringFromIndex:NSMaxRange(colon)];
        }
    }
    s = SRTrim(s);
    b = SRTrim(b);
    *sender = s.length ? s : @"SMS";
    *body = b.length ? b : @"(no text: picture or empty message)";
    return YES;
}

#pragma mark - Verification codes

// A code is 4-8 digits (or 123-456 / 123 456, or G-123456) in a text that talks about codes.
// Six digits win, then 5/7/8, then 4; a 4-digit number that looks like a year comes last.
static NSString *SRFindCode(NSString *text) {
    static NSRegularExpression *keyword;
    static NSRegularExpression *candidate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keyword = [NSRegularExpression regularExpressionWithPattern:
            @"code|passcode|\\bpin\\b|\\botp\\b|one[- ]?time|verif|security|log ?in|sign[- ]?in|2fa|two[- ]factor|authenti|confirm"
            options:NSRegularExpressionCaseInsensitive error:NULL];
        candidate = [NSRegularExpression regularExpressionWithPattern:
            @"(?<![0-9A-Za-z$#:/.,-])(?<![0-9] )(?:[A-Z]{1,3}-)?([0-9]{3}[ -][0-9]{3}|[0-9]{4,8})(?![0-9]|[ .,:/-][0-9])"
            options:0 error:NULL];
    });
    if (!keyword || !candidate) {
        return nil;
    }
    NSRange all = NSMakeRange(0, text.length);
    if ([keyword numberOfMatchesInString:text options:0 range:all] == 0) {
        return nil;
    }
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    NSString *best = nil;
    int bestScore = 0;
    for (NSTextCheckingResult *match in [candidate matchesInString:text options:0 range:all]) {
        NSString *raw = [text substringWithRange:[match rangeAtIndex:1]];
        NSString *digits = [[raw componentsSeparatedByCharactersInSet:nonDigits] componentsJoinedByString:@""];
        NSUInteger n = digits.length;
        int score;
        if (n == 6) {
            score = 4;
        } else if (n >= 5) {
            score = 3;
        } else {
            int value = digits.intValue;
            score = (value >= 1900 && value <= 2099) ? 1 : 2;
        }
        if (score > bestScore) {
            best = digits;
            bestScore = score;
        }
    }
    return best;
}

// YES once the code is on the clipboard: now, or earlier for this same bulletin.
static BOOL SRCopyCode(NSString *code, CFAbsoluteTime now) {
    if ([code isEqualToString:gLastCode] && now - gLastCodeAt < SR_CODE_WINDOW) {
        return YES;
    }
    gLastCode = code;
    gLastCodeAt = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = code;
    });
    return YES;
}

#pragma mark - Recent Messages bulletins

static void SRPrune(CFAbsoluteTime now) {
    NSIndexSet *old = [gSeen indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger idx, BOOL *stop) {
        return now - [entry[@"at"] doubleValue] > SR_DUP_WINDOW;
    }];
    [gSeen removeObjectsAtIndexes:old];
}

// Who a message is from, comparable between the 17's Shortcuts ("+1 (555) 010-9999", "Chase")
// and iOS 6's notification titles: the last 10 digits of a number, else lowercase letters/digits.
static NSString *SRSenderKey(NSString *name) {
    if (!name.length) {
        return @"";
    }
    NSString *digits = [[name componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]]
                        componentsJoinedByString:@""];
    if (digits.length >= 7) {
        return digits.length > 10 ? [digits substringFromIndex:digits.length - 10] : digits;
    }
    return [[[name componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]]
             componentsJoinedByString:@""] lowercaseString];
}

static void SRRemember(NSString *title, NSString *senderKey, NSString *text, SRKind kind, CFAbsoluteTime now) {
    [gSeen addObject:@{ @"t": title ?: @"", @"s": senderKey ?: @"", @"b": text, @"k": @(kind), @"at": @(now) }];
}

// One of our rewritten bulletins coming past again: same kind, text and exact title.
static BOOL SRIsOurs(NSString *text, NSString *title) {
    for (NSDictionary *entry in gSeen) {
        if ([entry[@"k"] intValue] == SRKindRelayed && [entry[@"b"] isEqualToString:text]
            && [entry[@"t"] isEqualToString:title ?: @""]) {
            return YES;
        }
    }
    return NO;
}

// The same text recently arrived the other way. A short text only counts from the same sender.
static BOOL SRIsDuplicate(NSString *text, SRKind otherKind, NSString *senderKey) {
    for (NSDictionary *entry in gSeen) {
        if ([entry[@"k"] intValue] == otherKind && [entry[@"b"] isEqualToString:text]
            && (text.length >= SR_DUP_MIN_LENGTH || (senderKey.length && [entry[@"s"] isEqualToString:senderKey]))) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - The decision

static BOOL SRHandleRelayed(id<SRBulletin> bulletin, NSString *sender, NSString *body, const char *via,
                            CFAbsoluteTime now) {
    NSString *senderKey = SRSenderKey(sender);
    if (gHideDuplicates && SRIsDuplicate(body, SRKindDirect, senderKey)) {
        SRLog(@"relayed text (%lu chars) via %s already came here as an iMessage: banner dropped",
              (unsigned long)body.length, via);
        return NO;
    }
    if (![bulletin respondsToSelector:@selector(setTitle:)] || ![bulletin respondsToSelector:@selector(setMessage:)]) {
        SRLog(@"relayed text via %s but %@ can't be edited (no setTitle:/setMessage:); shown as it came",
              via, NSStringFromClass([(id)bulletin class]));
        return YES;
    }
    NSString *code = gCopyCodes ? SRFindCode(body) : nil;
    BOOL copied = code && SRCopyCode(code, now);
    NSString *title = copied ? [sender stringByAppendingString:@" — Code Copied"] : sender;
    [bulletin setTitle:title];
    [bulletin setMessage:body];
    if ([bulletin respondsToSelector:@selector(setSubtitle:)]) {
        [bulletin setSubtitle:nil];
    }
    SRRemember(title, senderKey, body, SRKindRelayed, now);
    SRLog(@"relayed text via %s: sender %lu chars, text %lu chars, code %@: banner rewritten",
          via, (unsigned long)sender.length, (unsigned long)body.length,
          code ? @"found + copied" : (gCopyCodes ? @"none" : @"(copying off)"));
    return YES;
}

static BOOL SRHandleDirect(NSString *title, NSString *text, const char *via, CFAbsoluteTime now) {
    // Our rewritten bulletin again: the second hook, or the same bulletin republished.
    if (SRIsOurs(text, title)) {
        return YES;
    }
    NSString *senderKey = SRSenderKey(title);
    if (gHideDuplicates && SRIsDuplicate(text, SRKindRelayed, senderKey)) {
        SRLog(@"iMessage (%lu chars) via %s came after its relayed copy: banner dropped",
              (unsigned long)text.length, via);
        return NO;
    }
    SRRemember(title, senderKey, text, SRKindDirect, now);
    return YES;
}

// NO = drop the bulletin (no banner, lock-screen item, Notification Center row or sound).
static BOOL SRShouldPublish(id<SRBulletin> bulletin, const char *via) {
    if (!gEnabled || !bulletin) {
        return YES;
    }
    @try {
        if (![bulletin respondsToSelector:@selector(sectionID)] || ![bulletin respondsToSelector:@selector(message)]) {
            return YES;
        }
        NSString *section = [bulletin sectionID];
        if (gSectionsLogged < SR_SECTIONS_LOGGED) {
            gSectionsLogged++;
            SRLog(@"bulletin via %s: %@ from %@", via, NSStringFromClass([(id)bulletin class]), section);
        }
        if (![section isKindOfClass:[NSString class]] || ![section isEqualToString:SR_SECTION]) {
            return YES;
        }
        NSString *message = [bulletin message];
        if (![message isKindOfClass:[NSString class]] || !message.length) {
            return YES;
        }
        NSString *title = [bulletin respondsToSelector:@selector(title)] ? [bulletin title] : nil;
        if (![title isKindOfClass:[NSString class]]) {
            title = nil;
        }
        NSString *sender = nil;
        NSString *body = nil;
        BOOL relayed = SRParse(message, &sender, &body);
        if (gSmsLogged < SR_SMS_LOGGED) {
            gSmsLogged++;
            SRLog(@"Messages bulletin via %s (%@): relayed %@, title %lu chars, text %lu chars",
                  via, NSStringFromClass([(id)bulletin class]), relayed ? @"yes" : @"no",
                  (unsigned long)title.length, (unsigned long)message.length);
        }
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        @synchronized (gSeen) {
            SRPrune(now);
            if (relayed) {
                return SRHandleRelayed(bulletin, sender, body, via, now);
            }
            return SRHandleDirect(title, SRTrim(message), via, now);
        }
    } @catch (NSException *e) {
        SRLog(@"exception %@ via %s; bulletin passed through untouched", e.name, via);
        return YES;
    }
}

#pragma mark - Hooks

static void SRPublish(id server, SEL cmd, id bulletin, unsigned int destinations, BOOL alwaysToLockScreen) {
    if (SRShouldPublish(bulletin, "publishBulletin")) {
        gOrigPublish(server, cmd, bulletin, destinations, alwaysToLockScreen);
    }
}

static void SRPublishRequest(id server, SEL cmd, id request, unsigned int destinations, BOOL alwaysToLockScreen) {
    if (SRShouldPublish(request, "publishBulletinRequest")) {
        gOrigPublishRequest(server, cmd, request, destinations, alwaysToLockScreen);
    }
}

static BOOL SRHook(Class cls, SEL sel, IMP replacement, SRPublishFn *orig) {
    if (!class_getInstanceMethod(cls, sel)) {
        SRLog(@"BBServer has no -%@", NSStringFromSelector(sel));
        return NO;
    }
    MSHookMessageEx(cls, sel, replacement, (IMP *)orig);
    SRLog(@"hooked -[BBServer %@] (%@)", NSStringFromSelector(sel), *orig ? @"ok" : @"FAILED");
    return *orig != NULL;
}

%ctor
{
    @autoreleasepool {
        struct stat st;
        if (stat(SR_LOG_PATH, &st) == 0 && st.st_size > SR_LOG_MAX_BYTES) {
            truncate(SR_LOG_PATH, 0);
        }
        gSeen = [NSMutableArray array];
        SRLoadPrefs();
        int token;
        notify_register_dispatch(SR_NOTIFY_PREFS, &token, dispatch_get_main_queue(), ^(int t) {
            SRLoadPrefs();
            SRLog(@"prefs: enabled %d, copy codes %d, hide duplicates %d", gEnabled, gCopyCodes, gHideDuplicates);
        });

        Class server = objc_getClass("BBServer");
        if (!server) {
            SRLog(@"loaded in %s but there's no BBServer class; doing nothing", getprogname());
            return;
        }
        SRLog(@"loaded in %s; prefs: enabled %d, copy codes %d, hide duplicates %d", getprogname(), gEnabled,
              gCopyCodes, gHideDuplicates);
        BOOL a = SRHook(server, @selector(publishBulletin:destinations:alwaysToLockScreen:), (IMP)SRPublish,
                        &gOrigPublish);
        BOOL b = SRHook(server, @selector(publishBulletinRequest:destinations:alwaysToLockScreen:),
                        (IMP)SRPublishRequest, &gOrigPublishRequest);
        if (!a && !b) {
            // Neither entry point exists on this firmware: list BBServer's publish methods for the next build.
            unsigned int count = 0;
            Method *methods = class_copyMethodList(server, &count);
            for (unsigned int i = 0; i < count; i++) {
                NSString *name = NSStringFromSelector(method_getName(methods[i]));
                if ([name rangeOfString:@"ublish"].location != NSNotFound) {
                    SRLog(@"  BBServer -%@", name);
                }
            }
            free(methods);
        }
    }
}

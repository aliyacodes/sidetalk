
import Foundation
import XMPPFramework
import ReactiveCocoa
import enum Result.NoError

enum Presence {
    case Online, Offline, Away, Busy, Invisible, None;
}

class AvatarDelegate: NSObject, XMPPvCardTempModuleDelegate {
    private let _withResult: (NSImage!) -> ();
    init(withResult: (NSImage!) -> ()) { self._withResult = withResult; }

    @objc internal func xmppvCardTempModule(vCardTempModule: XMPPvCardTempModule!, didReceivevCardTemp vCardTemp: XMPPvCardTemp!, forJID jid: XMPPJID!) {
        let avatarb64 = vCardTemp.elementForName("PHOTO").stringValue;
        if avatarb64 != nil {
            let decoded = NSData.init(base64EncodedString: avatarb64!, options: .IgnoreUnknownCharacters);
            if decoded != nil { self._withResult(NSImage.init(data: decoded!)); };
        }
    }
}

class Contact: Hashable {
    internal var inner: XMPPUser;
    internal let connection: Connection; // TODO: i hate this being here but i'm not sure how else to manage this yet.

    var displayName: String { get { return self.inner.nickname() ?? self.inner.jid().bare(); } };

    var initials: String { get {
        let full = self.displayName;
        let initialsRegex = try! NSRegularExpression(pattern: "^(.)[^ ._-]*[ ._-](.)", options: .UseUnicodeWordBoundaries);
        let initials = initialsRegex.matchesInString(full, options: NSMatchingOptions(), range: NSRange());

        if initials.count > 1 {
            let nsFull = full as NSString;
            return initials.map({ result in nsFull.substringWithRange(result.range); }).joinWithSeparator("");
        } else {
            return full.substringToIndex(full.startIndex.advancedBy(2));
        }
    } };

    private var _onlineSignal = ManagedSignal<Bool>();
    var online: Signal<Bool, NoError> { get { return self._onlineSignal.signal; } };
    var online_: Bool { get { return self.inner.isOnline(); } };

    private var _presenceSignal = ManagedSignal<String?>();
    var presence: Signal<String?, NoError> { get { return self._presenceSignal.signal; } };
    var presence_: String? { get { return self.inner.primaryResource()?.presence()?.show(); } };

    private var _avatarSignal: SignalProducer<NSImage?, NoError>?;
    var avatar: SignalProducer<NSImage?, NoError> { get { return self._avatarSignal!; } };

    private var _conversation: Conversation?;
    var conversation: Conversation { get { return self._conversation!; } };

    var hashValue: Int { get { return self.inner.jid().hashValue; } };

    init(xmppUser: XMPPUser, connection: Connection) {
        self.inner = xmppUser;
        self.connection = connection;
        self._conversation = Conversation(self, connection: connection);
        self.update(xmppUser, forceUpdate: true);

        self.prepare();
    }

    func update(xmppUser: XMPPUser, forceUpdate: Bool = false) {
        let old = self.inner;
        let new = xmppUser;

        // TODO: really really repetitive
        if forceUpdate || (old.isOnline() != new.isOnline()) { self._onlineSignal.observer.sendNext(new.isOnline()); }
        if forceUpdate || (old.primaryResource()?.presence()?.show() !=
                           new.primaryResource()?.presence()?.show()) { self._presenceSignal.observer.sendNext(new.primaryResource()?.presence()?.show()); }

        self.inner = xmppUser;
    }

    func isSelf() -> Bool { return self == self.connection.myself_; }

    private func prepare() {
        self._avatarSignal = SignalProducer { observer, disposable in
            observer.sendNext(nil); // start with fallback avvy

            // cold signal to fetch the avatar if asked for.
            let backgroundThread = dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0);
            dispatch_async(backgroundThread, {
                // TODO: lots of instantiation and shit. overhead?
                let vcardTemp = XMPPvCardTempModule(vCardStorage: XMPPvCardCoreDataStorage.sharedInstance());
                let vcardAvatar = XMPPvCardAvatarModule(vCardTempModule: vcardTemp);

                let photoData = vcardAvatar.photoDataForJID(self.inner.jid());
                if photoData == nil {
                    // we don't have it already cached, so go fetch it
                    vcardTemp.activate(self.connection.stream);
                    vcardAvatar.activate(self.connection.stream);

                    vcardAvatar.addDelegate(AvatarDelegate(withResult: { image in observer.sendNext(image); }), delegateQueue: backgroundThread);
                    vcardTemp.fetchvCardTempForJID(self.inner.jid(), ignoreStorage: true);
                } else {
                    observer.sendNext(NSImage.init(data: photoData));
                }
            });
        }
    }
}

// base equality on JID. TODO: this is probably an awful idea.
func ==(lhs: Contact, rhs: Contact) -> Bool {
    return lhs.inner.jid().isEqual(rhs.inner.jid());
}

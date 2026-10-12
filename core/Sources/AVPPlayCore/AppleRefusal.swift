import Foundation

/// Was Apple beim Signieren oder Installieren abgelehnt hat – als Art. Die Meldungen von `xcodebuild` und
/// `devicectl` sind englisch, lang und nennen selten den nächsten Handgriff; hier wird aus dem Wortlaut erkannt,
/// worum es geht, damit die Oberfläche und der Hintergrunddienst dasselbe dazu sagen.
public enum AppleRefusal: String, Codable, Sendable, CaseIterable {
    /// Ein kostenloses Konto darf nur wenige Apps zugleich auf einem Gerät haben.
    case tooManyApps
    /// Ein kostenloses Konto darf je Woche nur wenige neue App-Kennungen anlegen.
    case tooManyAppIds
    /// Das Team hat keine freien Plätze für Geräte mehr.
    case tooManyDevices
    /// Das Konto darf eine Berechtigung nicht vergeben, die der Bau verlangt.
    case capability
    /// Die App-Kennung gehört schon einem anderen Team.
    case identifierTaken
    /// Xcode ist bei Apple nicht (mehr) angemeldet.
    case accountSession
    /// Xcodes Bauwerkzeug findet auf diesem Mac gar kein Apple-Konto – auch wenn Xcode selbst eines zeigt.
    case noAccount
    /// Apple wartet auf die Zustimmung zu geänderten Bedingungen.
    case agreement
    /// Das Bereitstellungsprofil gilt nicht (mehr) für diese App auf diesem Gerät.
    case profile
    /// Das Gerät ist gesperrt.
    case deviceLocked
    /// Auf dem Gerät ist kein Platz.
    case deviceFull
    /// Der Entwickler ist auf dem Gerät noch nicht als vertrauenswürdig bestätigt.
    case notTrusted
}

public enum AppleMessages {
    /// Wie viele Apps ein kostenloses Konto zugleich auf einem Gerät haben darf, und wie viele neue Kennungen es
    /// in sieben Tagen anlegen kann (Apple, „Choosing a Membership“; Stand 2026).
    public static let freeAppsPerDevice = 3
    public static let freeAppIdsPerWeek = 10
    public static let freeSigningDays = 7

    /// Die Wortlaute, an denen eine Ablehnung zu erkennen ist – das Genauere zuerst. Verglichen wird ohne
    /// Rücksicht auf Groß- und Kleinschreibung; typografische Anführungszeichen sind schon vereinheitlicht.
    static let patterns: [(AppleRefusal, String)] = [
        // Der Satz dazu steht nur in der vollen Ausgabe von `devicectl`; das Bauskript behält die letzten Zeilen, und
        // dort stehen Apples Kennzeichen: die Stelle im Installer, die die Apps eines kostenlosen Profils zählt, und
        // ihre Fehlernummer (am Gerät beobachtet, visionOS 27.2, 2026-10-11).
        (.tooManyApps, #"maximum number of (installed )?apps (for|using an?) free (development|developer) profiles?|MIFreeProfileValidatedAppTracker|LibMISErrorNumber = -402620383"#),
        (.tooManyAppIds, #"maximum app id limit|app ids every 7 days|maximum number of app ids"#),
        (.tooManyDevices, #"maximum number of (registered )?[a-z ]*devices|no devices? slots? (are )?available"#),
        (.capability, #"personal development teams?[^\n]{0,200}do(es)? not support|personal team[^\n]{0,200}(isn't|is not) eligible"#),
        (.identifierTaken, #"cannot be registered to your development team because it is not available|failed to register bundle identifier"#),
        (.agreement, #"program license agreement|agreement[^\n]{0,80}(has been updated|must be (accepted|agreed)|needs to be (accepted|reviewed))|pla update available"#),
        // So meldet es `xcodebuild`, wenn es kein einziges Konto sieht (Protokoll eines Nutzers mit kostenlosem Team,
        // 2026-10-11). In Xcode stand das Konto dabei als angemeldet; die Teamliste in Xcodes Einstellungen, aus
        // der die App liest, war ebenfalls da. Abmelden und neu anmelden in Xcode hat es behoben, der nächste Bau
        // lief durch – deshalb nennt der Rat genau diesen Handgriff.
        (.noAccount, #"no accounts: add a new account"#),
        (.accountSession, #"your session has expired|no account for team|unable to log in with account|log in to your account|please sign in (again )?(with|to) (an|your) apple"#),
        (.notTrusted, #"has not been explicitly trusted by the user|untrusted developer"#),
        (.profile, #"a valid provisioning profile for this executable was not found|provisioning profile[^\n]{0,120}(has expired|is expired|expired on)|profile has expired"#),
        (.deviceLocked, #"device is (currently )?locked|device was locked|passcode protected|unlock the device"#),
        (.deviceFull, #"not enough (free |available )?(space|storage)|insufficient (space|storage)|there isn't enough space"#),
    ]

    /// Die erste Ablehnung, die sich im Text eines Bau- oder Installationsprotokolls erkennen lässt.
    public static func refusal(in text: String) -> AppleRefusal? {
        let plain = text.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        let range = NSRange(plain.startIndex..., in: plain)
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            if regex.firstMatch(in: plain, range: range) != nil { return kind }
        }
        return nil
    }

    /// Was die Ablehnung bedeutet und was als Nächstes zu tun ist, in einem Absatz.
    /// - Parameter free: ob mit einem kostenlosen Team signiert wird; ein paar Sätze gelten nur dafür.
    public static func advice(_ refusal: AppleRefusal, free: Bool) -> String {
        switch refusal {
        case .tooManyApps:
            return L("Apple refused the installation: a free Apple account may have only \(freeAppsPerDevice) apps on the Vision Pro at a time, and that many are already there. Remove one on the headset (press and hold its icon, then “Remove App”) and choose “Resume” – or use a paid developer membership, which has no such limit. Apps you installed from Xcode with the same account count as well. Before you remove a game, let AVP Play fetch its saved games (the game's page, “Saved Games”): they stay on this Mac and are put back when you install the game again.",
                     "Apple hat die Installation abgelehnt: Ein kostenloses Apple-Konto darf nur \(freeAppsPerDevice) Apps gleichzeitig auf der Vision Pro haben, und so viele sind schon dort. Entferne eine auf dem Headset (Icon gedrückt halten, dann „App entfernen“) und wähle „Fortsetzen“ – oder nutze eine bezahlte Entwickler-Mitgliedschaft, die diese Grenze nicht hat. Apps, die du mit demselben Konto aus Xcode installiert hast, zählen mit. Bevor du ein Spiel entfernst, lass AVP Play seine Spielstände holen (Seite des Spiels, „Spielstände“): Sie bleiben auf diesem Mac und werden zurückgespielt, wenn du das Spiel wieder installierst.")
        case .tooManyAppIds:
            return L("Apple refused to register this game: a free Apple account can set up only \(freeAppIdsPerWeek) new apps within \(freeSigningDays) days, and that number is used up. Games you have installed before are not affected and can still be renewed. A new game works again once the oldest registration is \(freeSigningDays) days old – choose “Resume” then.",
                     "Apple hat die Anmeldung dieses Spiels abgelehnt: Ein kostenloses Apple-Konto kann innerhalb von \(freeSigningDays) Tagen nur \(freeAppIdsPerWeek) neue Apps anlegen, und diese Zahl ist aufgebraucht. Schon einmal installierte Spiele sind davon nicht betroffen und lassen sich weiter erneuern. Ein neues Spiel geht wieder, sobald die älteste Anmeldung \(freeSigningDays) Tage zurückliegt – wähle dann „Fortsetzen“.")
        case .tooManyDevices:
            return L("Apple refused to add this Vision Pro to your developer team: the team has no free place for another device\(free ? " (a free account gets very few within \(freeSigningDays) days)" : ""). Free a place at developer.apple.com under Certificates, Identifiers & Profiles › Devices, or wait until one becomes free, then choose “Resume”.",
                     "Apple hat diese Vision Pro nicht in dein Entwicklerteam aufgenommen: Das Team hat keinen freien Platz für ein weiteres Gerät\(free ? " (ein kostenloses Konto bekommt innerhalb von \(freeSigningDays) Tagen nur wenige)" : ""). Gib bei developer.apple.com unter Certificates, Identifiers & Profiles › Devices einen Platz frei oder warte, bis einer frei wird, und wähle dann „Fortsetzen“.")
        case .capability:
            return L("Apple refused to sign the game: a free Apple account may not use a permission this build asks for. Make sure the newest toolchain is installed (see “Setup”) – it leaves out what free accounts cannot have. If it stops here again, this game needs a paid developer membership.",
                     "Apple hat das Signieren abgelehnt: Ein kostenloses Apple-Konto darf eine Berechtigung nicht verwenden, die dieser Bau verlangt. Prüfe, dass die neueste Toolchain installiert ist (siehe „Einrichtung“) – sie lässt weg, was es für kostenlose Konten nicht gibt. Hält es hier wieder an, braucht dieses Spiel eine bezahlte Entwickler-Mitgliedschaft.")
        case .identifierTaken:
            return L("Apple refused the app's identifier: it already belongs to another developer team – typically because the game was installed with a different Apple account before. Under “Settings › Advanced”, choose another prefix for the app identifiers, then start again. The Vision Pro treats the game as a new app; its data is copied again.",
                     "Apple hat die Kennung der App abgelehnt: Sie gehört schon einem anderen Entwicklerteam – meist, weil das Spiel vorher mit einem anderen Apple-Konto installiert wurde. Wähle unter „Einstellungen › Erweitert“ ein anderes Präfix für die App-Kennungen und starte neu. Die Vision Pro sieht das Spiel dann als neue App; seine Daten werden neu kopiert.")
        case .agreement:
            return L("Apple is waiting for you to accept updated terms. Sign in at developer.apple.com/account, accept the agreement shown there, then choose “Resume”.",
                     "Apple wartet darauf, dass du geänderten Bedingungen zustimmst. Melde dich bei developer.apple.com/account an, stimme der dort gezeigten Vereinbarung zu und wähle dann „Fortsetzen“.")
        case .accountSession:
            return L("Xcode is no longer signed in to your Apple account. Open Xcode › Settings › Accounts, sign in again, then choose “Resume”.",
                     "Xcode ist nicht mehr bei deinem Apple-Konto angemeldet. Öffne Xcode › Einstellungen › Accounts, melde dich neu an und wähle dann „Fortsetzen“.")
        case .noAccount:
            return L("Xcode's build tool finds no Apple account on this Mac, so it cannot sign the game. Open Xcode › Settings › Accounts and add your Apple account. If it is already listed there, sign out and sign in again – an account can be shown as signed in and still not be usable for building. Then choose “Resume”.",
                     "Xcodes Bauwerkzeug findet auf diesem Mac kein Apple-Konto und kann das Spiel deshalb nicht signieren. Öffne Xcode › Einstellungen › Accounts und füge dein Apple-Konto hinzu. Steht es dort schon, melde dich ab und wieder an – ein Konto kann als angemeldet angezeigt werden und trotzdem nicht zum Bauen taugen. Wähle dann „Fortsetzen“.")
        case .notTrusted:
            return L("The Vision Pro does not trust this developer yet. On the headset, open Settings › General › VPN & Device Management, choose your Apple account and confirm “Trust”. This is needed once per account.",
                     "Die Vision Pro vertraut diesem Entwickler noch nicht. Öffne auf dem Headset Einstellungen › Allgemein › VPN & Geräteverwaltung, wähle dein Apple-Konto und bestätige „Vertrauen“. Das ist einmal je Konto nötig.")
        case .profile:
            return L("The signing profile for this game is not valid for this Vision Pro (any more). Keep the headset on, unlocked and on the same Wi-Fi as this Mac and choose “Resume” – the profile is requested again.",
                     "Das Signierprofil für dieses Spiel gilt für diese Vision Pro nicht (mehr). Headset anlassen, entsperrt und im selben WLAN wie dieser Mac halten und „Fortsetzen“ wählen – das Profil wird neu angefordert.")
        case .deviceLocked:
            return L("The Vision Pro is locked. Put it on, unlock it, then choose “Resume”.",
                     "Die Vision Pro ist gesperrt. Aufsetzen, entsperren und dann „Fortsetzen“ wählen.")
        case .deviceFull:
            return L("There is not enough free space on the Vision Pro for this game. Free some space on the headset, then choose “Resume”.",
                     "Auf der Vision Pro ist nicht genug Platz für dieses Spiel. Schaffe auf dem Headset Platz und wähle dann „Fortsetzen“.")
        }
    }

    /// Was ein kostenloses Apple-Konto von einem bezahlten unterscheidet, als Liste kurzer Sätze.
    public static func freeAccountLimits() -> [String] {
        [L("A game opens for \(freeSigningDays) days after it was installed. Installing it again renews it; saved games and data stay.",
           "Ein Spiel lässt sich nach der Installation \(freeSigningDays) Tage lang öffnen. Erneutes Installieren erneuert es; Spielstände und Daten bleiben."),
         L("At most \(freeAppsPerDevice) apps from your account can be on the Vision Pro at the same time.",
           "Höchstens \(freeAppsPerDevice) Apps deines Kontos können gleichzeitig auf der Vision Pro sein."),
         L("At most \(freeAppIdsPerWeek) different games can be set up within \(freeSigningDays) days.",
           "Höchstens \(freeAppIdsPerWeek) verschiedene Spiele lassen sich innerhalb von \(freeSigningDays) Tagen neu anlegen."),
         // Von den drei Berechtigungen der Toolchain gibt Apple kostenlosen Konten eine (mehr Arbeitsspeicher) und
         // zwei nicht. Genannt wird nur die, die Spiele betrifft: mehr Adressraum. Die andere, verzögerungsarmes
         // Streaming, verlangt nur der Bau von Steam Link; ob sie dort etwas bewirkt, ist nicht belegt (der Schlüssel
         // kam beim Suchen nach einem Streaming-Fehler dazu, siehe gen_xcodeproj.py der Toolchain).
         // Nachgesehen an den signierten Bauten vom 2026-10-11: mit dem kostenlosen Team steht genau
         // increased-memory-limit in der Signatur, mit dem bezahlten stehen alle drei darin.
         L("The permission for more memory, which large games need, is there with a free account too. Only the one for more address space is missing; a very large game may fail to start because of it.",
           "Die Berechtigung für mehr Arbeitsspeicher, die große Spiele brauchen, gibt es auch mit einem kostenlosen Konto. Nur die für mehr Adressraum fehlt; ein sehr großes Spiel startet deshalb womöglich nicht."),
         L("Once per account, the developer has to be trusted on the headset: Settings › General › VPN & Device Management.",
           "Einmal je Konto muss der Entwickler auf dem Headset als vertrauenswürdig bestätigt werden: Einstellungen › Allgemein › VPN & Geräteverwaltung.")]
    }
}

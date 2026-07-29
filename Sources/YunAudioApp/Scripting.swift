import Foundation
import JavaScriptCore
import YunAudioControl
import YunAudioRT
import YunDesign

/// What a script is allowed to talk to.
///
/// A protocol rather than the model directly, so the whole surface can be
/// exercised against a stub. A scripting API is a promise about compatibility —
/// somebody's script has to keep working across versions — and a promise that
/// is only ever tested by hand is not one.
@MainActor
protocol ScriptTarget: AnyObject {
    /// Carried out through the same vocabulary the URL scheme and MIDI use.
    @discardableResult
    func perform(_ command: RemoteCommand) -> String?
    /// What a script can read, as plain values.
    var scriptStatus: [String: Any] { get }
    /// Named scenes and arrangements, so a script can find out what exists
    /// rather than guessing at names.
    var scriptPresetNames: [String] { get }
    var scriptConfigNames: [String] { get }
    /// Whether the last `perform` did what it was asked.
    ///
    /// `perform` answers in a sentence, which is exactly right for a menu bar
    /// and useless to a shell: `yunaudio-cli script` printed the interpreter's
    /// error and exited 0, so a script that had stopped working looked from
    /// outside like one that was working. Read immediately after `perform`.
    var lastCommandFailed: Bool { get }
}

/// Runs a script against the application.
///
/// **JavaScriptCore, which ships with macOS**, so the interpreter costs
/// nothing. The work is the object model, and the object model is deliberately
/// the same vocabulary as the URL scheme: `RemoteCommand` is the one definition
/// of what this application can be asked to do, and the three front ends — a
/// URL, a MIDI note, a line of script — are three ways of saying it. A second
/// definition would be a second thing to keep in step, and they do not stay in
/// step.
///
/// What a script cannot do is as much of the design as what it can. The context
/// starts empty: no filesystem, no network, no `require`, no timers. Only what
/// is injected here exists. That is not a sandbox anybody has to maintain — it
/// is the absence of anything to escape from.
@MainActor
final class ScriptHost {

    /// How long a script may run before it is stopped.
    ///
    /// A script is somebody else's loop and the model is on the main actor, so
    /// a runaway `while (true)` would take the interface with it. Two seconds
    /// is far more than any command sequence needs and short enough that a
    /// mistake reads as an error rather than as a hang.
    static let timeLimit: TimeInterval = 2

    private weak var target: ScriptTarget?
    private var output: [String] = []

    /// The context a resident script lives in.
    ///
    /// Kept, unlike the one a single run gets. A script that reacts to things
    /// has to still be there when they happen, and its handlers are closures
    /// over its own state — so the context is the script, and throwing it away
    /// between events would throw away everything it had worked out.
    private var residentContext: JSContext?
    /// Handlers by event name, in the order they were registered. Several
    /// handlers for one event is the ordinary case: one script watching the
    /// microphone and another watching the recording are not one script.
    private var handlers: [String: [JSManagedValue]] = [:]

    init(target: ScriptTarget) {
        self.target = target
    }

    /// What a run produced.
    struct Result: Equatable {
        /// Whatever the last expression evaluated to, as a string. Empty when
        /// the script ended on something with no value.
        var value: String
        /// Lines the script asked to be shown, in order.
        var log: [String]
        /// The message from a thrown error or a syntax error, if there was one.
        var error: String?

        var isSuccess: Bool { error == nil }
    }

    /// Runs a script and returns what happened.
    ///
    /// Never throws and never traps: a script is untrusted text, and the only
    /// correct answer to a bad one is a message.
    func run(_ source: String) -> Result {
        output = []
        guard let context = JSContext() else {
            return Result(value: "", log: [], error: loc("The interpreter could not be started."))
        }

        // Held weakly for the lifetime of the host — the model owns the host,
        // so the other direction would be a cycle — but a run needs it alive,
        // and finding out in the middle produces nonsense. Without this, a run
        // against a released target reported "there is no scene called
        // \"Voice chat\"" for a scene that exists: every command silently did
        // nothing and every failure blamed the argument.
        guard target != nil else {
            return Result(value: "", log: [], error: loc("The application is no longer there."))
        }

        var thrown: String?
        context.exceptionHandler = { _, exception in
            thrown = exception?.toString() ?? "unknown error"
        }
        install(into: context)

        // Stopped rather than trusted. The limit is on the context group, which
        // is what actually interrupts a loop with no function calls in it.
        var value: JSValue?
        withTimeLimit(context) { value = context.evaluateScript(source) }
        if let thrown {
            return Result(value: "", log: output, error: thrown)
        }
        let rendered =
            (value?.isUndefined ?? true) || (value?.isNull ?? true)
            ? "" : (value?.toString() ?? "")
        return Result(value: rendered, log: output, error: nil)
    }

    // MARK: Scripts that stay

    /// The events a script may ask to be told about.
    ///
    /// A closed set, and named rather than derived from anything internal. This
    /// is the part of a scripting interface that is hardest to take back: a
    /// handler somebody wrote a year ago has to still be called, so every name
    /// here is a promise. Adding one later is free; changing what one means is
    /// not.
    enum Event: String, CaseIterable, Sendable {
        case routingStarted = "start"
        case routingStopped = "stop"
        case muted
        case unmuted
        case recordingStarted = "recordStart"
        case recordingStopped = "recordStop"
        /// The microphone is muted and the system's own detector can hear
        /// somebody speaking. The reason a script can be more useful than a
        /// pill: it can also unmute, or say something out loud.
        case speakingWhileMuted
        case deviceAppeared
        case deviceDisappeared
        /// Once a second while routing, so a script can watch a number without
        /// needing timers of its own. There are deliberately no timers in the
        /// context — a script cannot schedule itself, the application decides
        /// when it runs, and that is what keeps a runaway script bounded.
        case tick
    }

    /// Loads a script that stays, replacing whatever was loaded before.
    ///
    /// - Returns: What evaluating it produced. Handlers registered during that
    ///   evaluation are kept; one that throws while registering leaves none,
    ///   because a half-loaded script is worse than no script.
    @discardableResult
    func load(_ source: String) -> Result {
        residentContext = nil
        handlers = [:]
        guard target != nil else {
            return Result(
                value: "", log: [], error: loc("The application is no longer there."))
        }
        guard let context = JSContext() else {
            return Result(value: "", log: [], error: loc("The interpreter could not be started."))
        }
        output = []
        var thrown: String?
        context.exceptionHandler = { _, exception in thrown = exception?.toString() }
        install(into: context)
        installEvents(into: context)
        withTimeLimit(context) { _ = context.evaluateScript(source) }
        if let thrown {
            handlers = [:]
            return Result(value: "", log: output, error: thrown)
        }
        residentContext = context
        return Result(value: "", log: output, error: nil)
    }

    /// True when a script is loaded and listening for this event.
    func listens(for event: Event) -> Bool {
        !(handlers[event.rawValue] ?? []).isEmpty
    }

    /// Tells the loaded script something happened.
    ///
    /// - Returns: The messages the handlers asked to show, and the first error
    ///   any of them threw. A handler that throws does not stop the others and
    ///   does not unregister itself: an event that fails once because a device
    ///   was busy should not silently stop being handled for the rest of the
    ///   session.
    @discardableResult
    func dispatch(_ event: Event, _ payload: [String: Any] = [:]) -> Result {
        guard let context = residentContext, let listeners = handlers[event.rawValue],
            !listeners.isEmpty
        else { return Result(value: "", log: [], error: nil) }
        output = []
        var thrown: String?
        context.exceptionHandler = { _, exception in
            if thrown == nil { thrown = exception?.toString() }
        }
        let argument = JSValue(object: payload, in: context) ?? JSValue(undefinedIn: context)
        withTimeLimit(context) {
            for listener in listeners {
                listener.value?.call(withArguments: [argument as Any])
            }
        }
        return Result(value: "", log: output, error: thrown)
    }

    /// Runs something inside the limit and clears it afterwards.
    ///
    /// Applied to every entry into the interpreter rather than only to a
    /// one-shot run: an endless loop inside an event handler hangs the
    /// application exactly as thoroughly as one at the top level, and a handler
    /// runs on somebody else's schedule rather than on a person pressing a
    /// button.
    private func withTimeLimit(_ context: JSContext, _ body: () -> Void) {
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        JSContextGroupSetExecutionTimeLimit(group, Self.timeLimit, nil, nil)
        defer { JSContextGroupClearExecutionTimeLimit(group) }
        body()
    }

    private func installEvents(into context: JSContext) {
        let names = Set(Event.allCases.map(\.rawValue))
        let on: @convention(block) (String, JSValue?) -> Void = { [weak self] name, handler in
            guard let self else { return }
            // An unknown event name is an error rather than a handler that
            // never fires. A typo in `yun.on('started', …)` would otherwise be
            // a script that looks right, loads cleanly and does nothing for
            // ever — the worst outcome available.
            guard names.contains(name) else {
                context.exception = JSValue(
                    object: "there is no event called \"\(name)\" — "
                        + Event.allCases.map(\.rawValue).sorted().joined(separator: ", "),
                    in: context)
                return
            }
            guard let handler, handler.isObject,
                let managed = JSManagedValue(value: handler, andOwner: self)
            else { return }
            self.handlers[name, default: []].append(managed)
        }
        context.objectForKeyedSubscript("yun")?
            .setObject(on, forKeyedSubscript: "on" as NSString)
    }

    // MARK: The object model

    /// Everything a script can see, injected as one object called `yun`.
    ///
    /// Blocks rather than a `JSExport` protocol: `JSExport` needs `@objc`, which
    /// needs the model to be an `NSObject` subclass, and the model is a Swift
    /// `@Observable` — making it one to suit the scripting layer would be the
    /// tail wagging the dog.
    private func install(into context: JSContext) {
        let api = JSValue(newObjectIn: context)

        // Commands. Each takes an optional boolean: `true`, `false`, or nothing
        // for toggle — the same three states the URL scheme has, for the same
        // reason. A button with no light has to be able to ask for a toggle;
        // anything that knows the state should say which it wants.
        func command(_ make: @escaping (Bool?) -> RemoteCommand) -> @convention(block) (
            JSValue?
        ) -> String {
            { [weak self] argument in
                let wanted: Bool? =
                    (argument?.isUndefined ?? true) || (argument?.isNull ?? true)
                    ? nil : argument?.toBool()
                return self?.target?.perform(make(wanted)) ?? ""
            }
        }
        api?.setObject(command { .routing($0) }, forKeyedSubscript: "routing" as NSString)
        api?.setObject(command { .mute($0) }, forKeyedSubscript: "mute" as NSString)
        api?.setObject(command { .record($0) }, forKeyedSubscript: "record" as NSString)
        api?.setObject(
            command { .transcribe($0) }, forKeyedSubscript: "transcribe" as NSString)

        // Named things. These return the sentence the command produced, or
        // throw when the name is not one this application has — a script asking
        // for a scene that has been renamed should stop, not carry on as if it
        // had worked.
        func named(_ make: @escaping (String) -> RemoteCommand, _ kind: String)
            -> @convention(block) (String) -> String
        {
            { [weak self] name in
                guard let outcome = self?.target?.perform(make(name)) else {
                    context.exception = JSValue(
                        object: "there is no \(kind) called \"\(name)\"", in: context)
                    return ""
                }
                return outcome
            }
        }
        api?.setObject(
            named({ .preset($0) }, "scene"), forKeyedSubscript: "preset" as NSString)
        api?.setObject(
            named({ .config($0) }, "setup"), forKeyedSubscript: "config" as NSString)

        // Reading. One call returning one object rather than a property per
        // fact: a script that wants three of them should see one consistent
        // moment, not three moments a few milliseconds apart.
        let status: @convention(block) () -> [String: Any] = { [weak self] in
            self?.target?.scriptStatus ?? [:]
        }
        api?.setObject(status, forKeyedSubscript: "status" as NSString)

        let presets: @convention(block) () -> [String] = { [weak self] in
            self?.target?.scriptPresetNames ?? []
        }
        api?.setObject(presets, forKeyedSubscript: "presets" as NSString)

        let configs: @convention(block) () -> [String] = { [weak self] in
            self?.target?.scriptConfigNames ?? []
        }
        api?.setObject(configs, forKeyedSubscript: "configs" as NSString)

        // Somewhere for a script to say something. There is no `console` in a
        // bare context, and a script with no way to report is a script somebody
        // debugs by guessing.
        let log: @convention(block) (JSValue?) -> Void = { [weak self] value in
            self?.output.append(value?.toString() ?? "")
        }
        api?.setObject(log, forKeyedSubscript: "log" as NSString)

        context.setObject(api, forKeyedSubscript: "yun" as NSString)

        // `console.log` as well, because everybody types it. Pointing at the
        // same place rather than at nothing.
        let console = JSValue(newObjectIn: context)
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }
}

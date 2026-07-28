import Foundation
import JavaScriptCore
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
        JSContextGroupSetExecutionTimeLimit(
            JSContextGetGroup(context.jsGlobalContextRef), Self.timeLimit, nil, nil)
        defer {
            JSContextGroupClearExecutionTimeLimit(JSContextGetGroup(context.jsGlobalContextRef))
        }

        let value = context.evaluateScript(source)
        if let thrown {
            return Result(value: "", log: output, error: thrown)
        }
        let rendered =
            (value?.isUndefined ?? true) || (value?.isNull ?? true)
            ? "" : (value?.toString() ?? "")
        return Result(value: rendered, log: output, error: nil)
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

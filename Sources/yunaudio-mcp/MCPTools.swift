import Foundation
import YunAudioControl

extension MCPServer {

    /// Why an argument list was refused. A type of its own only because
    /// `Result` insists on an `Error`; the reason is the whole of it.
    struct ArgumentFault: Error, Equatable, Sendable {
        let reason: String
    }

    /// One argument a tool takes.
    ///
    /// The JSON Schema an agent reads and the check the server applies are both
    /// generated from this, so they cannot disagree. Written as two separate
    /// things they would: a schema saying `boolean` beside a check that accepted
    /// the string `"true"` is the kind of drift nothing notices until an agent
    /// sends a string and something toggles.
    struct Argument: Sendable {
        enum Kind: String, Sendable {
            case boolean, string
        }
        let name: String
        let kind: Kind
        let isRequired: Bool
        let description: String
    }

    /// Something an agent can ask for.
    struct Tool: Sendable {
        let name: String
        let description: String
        let arguments: [Argument]
        /// Whether calling it can change anything. Agents use this to decide
        /// what is safe to call while working out what is going on.
        let isReadOnly: Bool
        /// What to ask the application, once the arguments are known good.
        let request: @Sendable ([String: JSONValue]) -> ControlRequest

        var schema: JSONValue {
            var properties: [String: JSONValue] = [:]
            for argument in arguments {
                properties[argument.name] = .object([
                    "type": .string(argument.kind.rawValue),
                    "description": .string(argument.description),
                ])
            }
            let required = arguments.filter(\.isRequired).map { JSONValue.string($0.name) }
            return .object([
                "name": .string(name),
                "description": .string(description),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object(properties),
                    "required": .array(required),
                    // Said in the schema as well as enforced below, so a client
                    // that validates locally refuses the same things this does.
                    "additionalProperties": .bool(false),
                ]),
                "annotations": .object([
                    "readOnlyHint": .bool(isReadOnly),
                    "destructiveHint": .bool(false),
                    "idempotentHint": .bool(isReadOnly),
                    "openWorldHint": .bool(false),
                ]),
            ])
        }

        /// Checks what arrived against `arguments`.
        ///
        /// Strict, including about names it does not know. An agent that sends
        /// `{"value": true}` to a tool taking `state` would otherwise get the
        /// toggle — the microphone would change state, the call would report
        /// success, and the mistake would only show up as a mute that went the
        /// wrong way at the wrong moment.
        func validate(_ value: JSONValue) -> Result<[String: JSONValue], ArgumentFault> {
            // Absent and null both mean "no arguments"; an agent filling in a
            // field it has no value for produces the latter.
            guard !value.isNull else {
                return arguments.contains(where: \.isRequired)
                    ? refuse(missing(from: [:])) : .success([:])
            }
            guard let object = value.objectValue else {
                return refuse("\"arguments\" must be an object")
            }
            let known = Set(arguments.map(\.name))
            for key in object.keys.sorted() where !known.contains(key) {
                return refuse(
                    "\(name) does not take \"\(key)\". It takes: "
                        + (arguments.isEmpty
                            ? "no arguments" : arguments.map(\.name).joined(separator: ", ")))
            }
            for argument in arguments {
                guard let given = object[argument.name], !given.isNull else {
                    if argument.isRequired { return refuse(missing(from: object)) }
                    continue
                }
                switch argument.kind {
                case .boolean:
                    guard given.boolValue != nil else {
                        return refuse("\"\(argument.name)\" must be true or false")
                    }
                case .string:
                    guard let text = given.stringValue else {
                        return refuse("\"\(argument.name)\" must be a string")
                    }
                    // A name of spaces is not a name, and the application would
                    // answer "there is no scene called \"\"", which reads like
                    // the scene list is empty rather than like a bad argument.
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return refuse("\"\(argument.name)\" must not be empty")
                    }
                }
            }
            return .success(object)
        }

        private func refuse(_ reason: String) -> Result<[String: JSONValue], ArgumentFault> {
            .failure(ArgumentFault(reason: reason))
        }

        private func missing(from object: [String: JSONValue]) -> String {
            let absent = arguments.filter { $0.isRequired && (object[$0.name] ?? .null).isNull }
            return "\(name) needs \(absent.map { "\"\($0.name)\"" }.joined(separator: ", "))"
        }
    }

    // MARK: - The vocabulary, as an agent sees it

    /// The three states every switch here has, said the same way each time.
    private static var stateArgument: Argument {
        Argument(
            name: "state", kind: .boolean, isRequired: false,
            description:
                "true to turn it on, false to turn it off. Omit it to toggle, which is what a "
                + "physical button has to do. Prefer true or false: they are idempotent, so "
                + "asking twice is safe, whereas a toggle depends on a state you may not have "
                + "read.")
    }

    private static func switchTool(
        _ name: String, _ description: String,
        _ make: @escaping @Sendable (Bool?) -> RemoteCommand
    ) -> Tool {
        Tool(
            name: name, description: description, arguments: [stateArgument], isReadOnly: false
        ) { arguments in
            .perform(make(arguments["state"]?.boolValue))
        }
    }

    private static func nameArgument(_ kind: String) -> Argument {
        Argument(
            name: "name", kind: .string, isRequired: true,
            description:
                "The name of the \(kind), exactly as yunaudio_list_names gives it. Matched "
                + "without regard to case; an unknown name is refused rather than guessed at.")
    }

    static let tools: [Tool] = [
        Tool(
            name: "yunaudio_status",
            description:
                "Reads what YunAudio is doing right now, as a JSON object. Always present: "
                + "running (whether audio is being routed), busy, muted (the microphone), "
                + "outputMuted, recording, transcribing, inputDecibels and outputDecibels "
                + "(levels in dBFS, where 0 is full scale and -70 is silence), effects (the "
                + "names of the enabled processing stages) and routes (how many source-to-"
                + "destination paths are active). Present when a device is chosen: source, "
                + "sourceUID, destination, destinationUID. Present once routing has started: "
                + "sampleRate, bufferFrames, peak, and loudness in LUFS. Takes no arguments. "
                + "This is one consistent moment rather than several readings, so it is the "
                + "right way to confirm that a change took effect.",
            arguments: [], isReadOnly: true
        ) { _ in .status },

        Tool(
            name: "yunaudio_list_names",
            description:
                "Lists every saved scene and every saved setup, by name, as {\"scenes\": [...], "
                + "\"setups\": [...]}. A scene is a set of mixer and effect settings; a setup is "
                + "a whole-machine arrangement, including which devices are used and what the "
                + "system defaults become. Call this before yunaudio_apply_scene or "
                + "yunaudio_apply_setup rather than guessing a name — the names are the user's "
                + "own and some are translated. Takes no arguments.",
            arguments: [], isReadOnly: true
        ) { _ in .names },

        switchTool(
            "yunaudio_routing",
            "Starts or stops audio routing: the signal actually flowing from the chosen input "
                + "device, through the effect chain, to the chosen output. Nothing is heard, "
                + "recorded or analysed while this is off, so start it before expecting levels "
                + "from yunaudio_status to move. Starting takes over real hardware and can "
                + "change a device's sample rate."
        ) { .routing($0) },

        switchTool(
            "yunaudio_mute",
            "Mutes or unmutes the microphone. This is the input side: muting it stops the far "
                + "end hearing the user and stops the user hearing themselves through "
                + "monitoring, which is what muting a microphone is expected to mean. It does "
                + "not stop routing, and levels after it read silence rather than stopping."
        ) { .mute($0) },

        switchTool(
            "yunaudio_record",
            "Starts or stops recording to a file. Recording captures the routed signal; "
                + "individual stems are captured pre-fader, so they hold what each source "
                + "produced rather than this session's mix decisions. Check \"recording\" in "
                + "yunaudio_status to see whether it actually started — recording needs "
                + "routing to be running."
        ) { .record($0) },

        switchTool(
            "yunaudio_transcribe",
            "Starts or stops live speech transcription of the input. Needs macOS 27 and a "
                + "downloaded language model; on an older system, or before the model is "
                + "there, this reports the feature as unavailable rather than silently doing "
                + "nothing. Check \"transcribing\" in yunaudio_status to see whether it started."
        ) { .transcribe($0) },

        Tool(
            name: "yunaudio_apply_scene",
            description:
                "Applies a saved scene by name — the mixer and effect settings the user stored "
                + "under it. Does not change which devices are in use; use yunaudio_apply_setup "
                + "for that. Returns the name that was applied, or an error naming the scene it "
                + "could not find.",
            arguments: [nameArgument("scene")], isReadOnly: false
        ) { arguments in
            .perform(.preset(arguments["name"]?.stringValue ?? ""))
        },

        Tool(
            name: "yunaudio_apply_setup",
            description:
                "Applies a saved setup by name — a whole-machine arrangement: which device is "
                + "the input, which is the output, and what the system's own default input and "
                + "output become. This changes audio for every application on the machine, not "
                + "just this one. If part of the setup names hardware that is not plugged in, "
                + "the rest is still applied and the answer says what was missing.",
            arguments: [nameArgument("setup")], isReadOnly: false
        ) { arguments in
            .perform(.config(arguments["name"]?.stringValue ?? ""))
        },

        Tool(
            name: "yunaudio_run_script",
            description:
                "Runs a line of JavaScript inside YunAudio, for a sequence that has to happen "
                + "as one step or a decision that depends on the state. The object model is "
                + "`yun`: yun.routing(state), yun.mute(state), yun.record(state), "
                + "yun.transcribe(state) — each taking true, false, or nothing to toggle — "
                + "plus yun.preset(name), yun.config(name), yun.status(), yun.presets(), "
                + "yun.configs() and yun.log(value). Nothing else exists: no filesystem, no "
                + "network, no timers, no require. A script is stopped after two seconds. What "
                + "comes back is whatever it logged, or its last value. Prefer the dedicated "
                + "tools for anything they already cover — they validate their arguments and "
                + "this does not.",
            arguments: [
                Argument(
                    name: "source", kind: .string, isRequired: true,
                    description: "The JavaScript to run, as source.")
            ], isReadOnly: false
        ) { arguments in
            .perform(.script(arguments["source"]?.stringValue ?? ""))
        },
    ]
}

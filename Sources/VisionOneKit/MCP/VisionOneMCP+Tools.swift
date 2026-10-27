import Foundation

extension VisionOneMCP {
    /// What an agent is told when it connects.
    public static let instructions = """
    Vision One records this Mac's screen and edits videos by their transcript. \
    Name a take by its title, its folder name, or "latest". \
    Edits are proposals until kept: they show dashed in Vision One, and keep_changes asks the user before they count. \
    Exports only include kept cuts. \
    start_recording, keep_changes and share_video wait for the user to say yes in Vision One; if they say no, the reply says why. \
    Jobs that take longer than about 40 seconds return a task_id: call wait_for_task with it. \
list_demos and rerecord_demo re-record Autopilot demos (scripted click-throughs of an app).
    """

    // Small schema builders keep the tool list readable and quick to compile.
    static func text(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func choice(_ values: [String], _ description: String? = nil, default value: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string"), "enum": .array(values.map { .string($0) })]
        if let description { schema["description"] = .string(description) }
        if let value { schema["default"] = .string(value) }
        return .object(schema)
    }

    static func flag(_ description: String, default value: Bool = false) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description), "default": .bool(value)])
    }

    static func integer(_ min: Int, _ max: Int, default value: Int) -> JSONValue {
        .object(["type": .string("integer"), "minimum": .number(Double(min)), "maximum": .number(Double(max)),
                 "default": .number(Double(value))])
    }

    static func number(_ description: String, minimum: Double = 0, maximum: Double? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("number"), "description": .string(description),
                                           "minimum": .number(minimum)]
        if let maximum { schema["maximum"] = .number(maximum) }
        return .object(schema)
    }

    static let takeArg = text("The take's title, its folder name, or \"latest\" (the default).")
    static let taskArg = text("The task_id a tool returned, or one from list_tasks.")

    public static let tools: [MCPTool] = [
        // Reading
        MCPTool("list_takes", title: "List takes",
                description: "Lists recordings, newest first. Search matches the title, what it's for, and anything said in it.",
                input: [
                    "search": text("Words to look for. Every word must match."),
                    "filter": choice(["all", "toReview", "notExported", "exported"], "Which takes to show.", default: "all"),
                    "limit": integer(1, 100, default: 20),
                ],
                readOnly: true, idempotent: true),
        MCPTool("get_take", title: "Get a take",
                description: "A take's length, what it's for, transcript status, cuts, clips, exports and tasks.",
                input: ["take": takeArg], readOnly: true, idempotent: true),
        MCPTool("read_transcript", title: "Read a transcript",
                description: "The take's words with times. Words in ~~ ~~ are cut; words in [ ] are proposed cuts waiting for the user.",
                input: [
                    "take": takeArg,
                    "kept_only": flag("Only the words that stay in the video."),
                ],
                readOnly: true, idempotent: true),
        MCPTool("list_tasks", title: "List tasks",
                description: "What Vision One's agents are doing or did: Editor, Clipper, Sharer, recordings and exports.",
                input: [
                    "take": text("Only tasks for this take."),
                    "active_only": flag("Only tasks still running or waiting for the user."),
                    "limit": integer(1, 100, default: 20),
                ],
                readOnly: true, idempotent: true),
        MCPTool("wait_for_task", title: "Wait for a task",
                description: "Waits until a task finishes or needs the user, up to 45 seconds, then says where it's up to.",
                input: [
                    "task_id": taskArg,
                    "seconds": number("How long to wait. 30 if left out.", minimum: 1, maximum: 45),
                ],
                required: ["task_id"], readOnly: true, idempotent: true),
        MCPTool("recording_status", title: "Recording status",
                description: "Whether Vision One is recording, and which take.",
                readOnly: true, idempotent: true),

        // Recording
        MCPTool("start_recording", title: "Start recording",
                description: "Records the screen with the user's last screen, mic and sound choices. Asks the user in Vision One first. Call stop_recording when the demo is done.",
                input: [
                    "for": choice(Purpose.all.map(\.id), "What the video is for."),
                    "title": text("A name for the take."),
                ]),
        MCPTool("stop_recording", title: "Stop recording",
                description: "Stops and saves the take, then transcribes it on this Mac. Waits for the transcript when it's quick."),

        // Editing (proposals)
        MCPTool("clean_up", title: "Clean up",
                description: "Proposes cuts for ums, repeats, long pauses and dead air. Runs on this Mac. Proposals stay dashed until kept.",
                input: ["take": takeArg]),
        MCPTool("cut_to_length", title: "Cut to a length",
                description: "The Editor agent proposes cuts to reach a length, or follows an ask like \"drop the setup\". Proposals stay dashed until kept.",
                input: [
                    "take": takeArg,
                    "seconds": number("Length to aim for, in seconds.", minimum: 5),
                    "ask": text("What to change, in plain words."),
                ]),
        MCPTool("cut_part", title: "Cut a part",
                description: "Proposes cutting one part: a quote from the transcript, or a span in seconds of the original recording.",
                input: [
                    "take": takeArg,
                    "quote": text("Words said in the take, as read_transcript shows them."),
                    "start": number("Start, in seconds of the original recording."),
                    "end": number("End, in seconds of the original recording."),
                ]),
        MCPTool("make_clips", title: "Make clips",
                description: "The Clipper agent finds moments that stand alone, as proposed clips.",
                input: [
                    "take": takeArg,
                    "count": integer(1, 10, default: 3),
                    "format": choice(ClipFormat.allCases.map(\.rawValue), "Shape of the clips.", default: "vertical"),
                ]),
        MCPTool("draft_posts", title: "Draft posts",
                description: "The Sharer agent writes a title, chapters and posts for the edited video, as drafts. Nothing is posted.",
                input: [
                    "take": takeArg,
                    "launch": flag("Also draft a Version One launch."),
                    "product": text("The product's name, for the launch."),
                ]),
        MCPTool("keep_changes", title: "Keep changes",
                description: "Makes a task's proposed cuts and clips count. Asks the user in Vision One first.",
                input: ["task_id": taskArg], required: ["task_id"]),
        MCPTool("undo_changes", title: "Undo changes",
                description: "Takes a task's cuts and clips back out and deletes its drafts.",
                input: ["task_id": taskArg], required: ["task_id"], destructive: true),

        // Files
        MCPTool("write_captions", title: "Write captions",
                description: "Writes captions.srt and captions.vtt for the kept video into the take's folder.",
                input: ["take": takeArg], idempotent: true),
        MCPTool("export_video", title: "Export a video",
                description: "Exports an MP4 with the brand kit, kept cuts only. Presets: original, hd1080, hd720, whatsapp (under 16 MB), vertical, square.",
                input: [
                    "take": takeArg,
                    "preset": choice(ExportPreset.allCases.map(\.rawValue), "Leave out for the one that suits what the take is for."),
                ],
                idempotent: true),
        MCPTool("share_video", title: "Share a video",
                description: "Opens a post on WhatsApp, LinkedIn, X or YouTube with the right export and the Sharer's words. Asks the user every time; the user posts.",
                input: [
                    "take": takeArg,
                    "to": choice(ShareTarget.allCases.map(\.rawValue), "Where to post."),
                ],
                required: ["to"], openWorld: true),
        MCPTool("rename_take", title: "Rename a take",
                description: "Gives a take a title. An empty title goes back to the date.",
                input: ["take": takeArg, "title": text("The new title.")],
                required: ["title"], idempotent: true),

        // Autopilot demos
        MCPTool("list_demos", title: "List demos",
                description: "The Autopilot demos Vision One can record on its own: name, app, steps and roughly how long.",
                input: ["search": text("Words in the demo's name or app.")],
                readOnly: true, idempotent: true),
        MCPTool("rerecord_demo", title: "Re-record a demo",
                description: "Autopilot opens the demo's app, records its window and clicks through the steps. Vision One asks the user first unless they already let these steps run on their own. Returns a task_id; the run takes a while, so call wait_for_task.",
                input: [
                    "demo": text("The demo's name, from list_demos."),
                    "release": text("The release it's for, like v1.4.0."),
                ],
                required: ["demo"]),
    ]
}

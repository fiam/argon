pub(crate) struct BuiltinModule {
    pub(crate) name: &'static str,
    pub(crate) source: &'static str,
}

static BUILTINS: &[BuiltinModule] = &[
    BuiltinModule {
        name: "os",
        source: include_str!("../builtins/os.Sandboxfile"),
    },
    BuiltinModule {
        name: "os/macos",
        source: include_str!("../builtins/os/macos.Sandboxfile"),
    },
    BuiltinModule {
        name: "shell",
        source: include_str!("../builtins/shell.Sandboxfile"),
    },
    BuiltinModule {
        name: "shell/bash",
        source: include_str!("../builtins/shell/bash.Sandboxfile"),
    },
    BuiltinModule {
        name: "shell/fish",
        source: include_str!("../builtins/shell/fish.Sandboxfile"),
    },
    BuiltinModule {
        name: "shell/zsh",
        source: include_str!("../builtins/shell/zsh.Sandboxfile"),
    },
    BuiltinModule {
        name: "agent",
        source: include_str!("../builtins/agent.Sandboxfile"),
    },
    BuiltinModule {
        name: "agent/claude",
        source: include_str!("../builtins/agent/claude.Sandboxfile"),
    },
    BuiltinModule {
        name: "agent/codex",
        source: include_str!("../builtins/agent/codex.Sandboxfile"),
    },
    BuiltinModule {
        name: "agent/gemini",
        source: include_str!("../builtins/agent/gemini.Sandboxfile"),
    },
];

pub(crate) fn names() -> Vec<&'static str> {
    BUILTINS.iter().map(|builtin| builtin.name).collect()
}

pub(crate) fn find(name: &str) -> Option<&'static BuiltinModule> {
    BUILTINS.iter().find(|builtin| builtin.name == name)
}

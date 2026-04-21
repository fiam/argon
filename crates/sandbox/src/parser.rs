use crate::{EnvDefault, ExecDefault, FsAccess, FsDefault, SandboxError};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ParsedProgram {
    pub(crate) statements: Vec<Statement>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Statement {
    pub(crate) line_number: usize,
    pub(crate) raw: String,
    pub(crate) kind: StatementKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StatementKind {
    Version(u32),
    Set { name: String, value: String },
    Use { module: String },
    Warn { message: String },
    Info { message: String },
    EnvDefault { value: EnvDefault },
    EnvAllow { name: String },
    EnvSet { name: String, value: String },
    EnvUnset { name: String },
    FsDefault { value: FsDefault },
    FsAllow { access: FsAccess, value: String },
    ExecDefault { value: ExecDefault },
    ExecAllow { value: String },
    ExecIntercept { command: String, handler: String },
    IfTest { args: Vec<String> },
    Switch { value: String },
    Case { value: String },
    Default,
    Else,
    End,
}

pub(crate) fn parse_program(
    source_name: &str,
    source: &str,
) -> Result<ParsedProgram, SandboxError> {
    let mut statements = Vec::new();
    for (index, raw_line) in source.lines().enumerate() {
        let line_number = index + 1;
        let raw = raw_line.trim().to_string();
        if raw.is_empty() {
            continue;
        }

        let tokens = tokenize_line(raw_line).map_err(|message| SandboxError::Parse {
            input: source_name.to_string(),
            line: line_number,
            message,
        })?;
        if tokens.is_empty() {
            continue;
        }

        let kind = parse_tokens(source_name, line_number, &tokens)?;
        statements.push(Statement {
            line_number,
            raw,
            kind,
        });
    }

    Ok(ParsedProgram { statements })
}

fn parse_error(source_name: &str, line_number: usize, message: impl Into<String>) -> SandboxError {
    SandboxError::Parse {
        input: source_name.to_string(),
        line: line_number,
        message: message.into(),
    }
}

fn parse_tokens(
    source_name: &str,
    line_number: usize,
    tokens: &[String],
) -> Result<StatementKind, SandboxError> {
    let token = |index: usize| tokens.get(index).map(String::as_str);

    match token(0) {
        Some("VERSION") => {
            if tokens.len() != 2 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "VERSION expects exactly one argument",
                ));
            }
            let version = tokens[1].parse::<u32>().map_err(|_| {
                parse_error(
                    source_name,
                    line_number,
                    format!("invalid VERSION value: {}", tokens[1]),
                )
            })?;
            Ok(StatementKind::Version(version))
        }
        Some("SET") => {
            if tokens.len() != 3 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "SET expects a name and a value",
                ));
            }
            Ok(StatementKind::Set {
                name: tokens[1].clone(),
                value: tokens[2].clone(),
            })
        }
        Some("USE") => {
            if tokens.len() != 2 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "USE expects exactly one module name",
                ));
            }
            Ok(StatementKind::Use {
                module: tokens[1].clone(),
            })
        }
        Some("WARN") => {
            if tokens.len() != 2 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "WARN expects exactly one message",
                ));
            }
            Ok(StatementKind::Warn {
                message: tokens[1].clone(),
            })
        }
        Some("INFO") => {
            if tokens.len() != 2 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "INFO expects exactly one message",
                ));
            }
            Ok(StatementKind::Info {
                message: tokens[1].clone(),
            })
        }
        Some("ENV") => parse_env(source_name, line_number, tokens),
        Some("FS") => parse_fs(source_name, line_number, tokens),
        Some("EXEC") => parse_exec(source_name, line_number, tokens),
        Some("IF") => {
            if token(1) != Some("TEST") || tokens.len() < 3 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "IF statements must use `IF TEST ...`",
                ));
            }
            Ok(StatementKind::IfTest {
                args: tokens[2..].to_vec(),
            })
        }
        Some("SWITCH") => {
            if tokens.len() != 2 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "SWITCH expects exactly one value",
                ));
            }
            Ok(StatementKind::Switch {
                value: tokens[1].clone(),
            })
        }
        Some("CASE") => {
            if tokens.len() != 2 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "CASE expects exactly one value",
                ));
            }
            Ok(StatementKind::Case {
                value: tokens[1].clone(),
            })
        }
        Some("DEFAULT") => {
            if tokens.len() != 1 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "DEFAULT does not take any arguments",
                ));
            }
            Ok(StatementKind::Default)
        }
        Some("ELSE") => {
            if tokens.len() != 1 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "ELSE does not take any arguments",
                ));
            }
            Ok(StatementKind::Else)
        }
        Some("END") => {
            if tokens.len() != 1 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "END does not take any arguments",
                ));
            }
            Ok(StatementKind::End)
        }
        Some(other) => Err(parse_error(
            source_name,
            line_number,
            format!("unknown instruction: {other}"),
        )),
        None => Err(parse_error(source_name, line_number, "empty instruction")),
    }
}

fn parse_env(
    source_name: &str,
    line_number: usize,
    tokens: &[String],
) -> Result<StatementKind, SandboxError> {
    match tokens.get(1).map(String::as_str) {
        Some("DEFAULT") => {
            if tokens.len() != 3 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "ENV DEFAULT expects exactly one value",
                ));
            }
            let value = match tokens[2].as_str() {
                "INHERIT" => EnvDefault::Inherit,
                "NONE" => EnvDefault::None,
                other => {
                    return Err(parse_error(
                        source_name,
                        line_number,
                        format!("invalid ENV DEFAULT value: {other}"),
                    ));
                }
            };
            Ok(StatementKind::EnvDefault { value })
        }
        Some("ALLOW") => {
            if tokens.len() != 3 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "ENV ALLOW expects exactly one variable name or pattern",
                ));
            }
            Ok(StatementKind::EnvAllow {
                name: tokens[2].clone(),
            })
        }
        Some("SET") => {
            if tokens.len() != 4 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "ENV SET expects a name and a value",
                ));
            }
            Ok(StatementKind::EnvSet {
                name: tokens[2].clone(),
                value: tokens[3].clone(),
            })
        }
        Some("UNSET") => {
            if tokens.len() != 3 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "ENV UNSET expects exactly one name",
                ));
            }
            Ok(StatementKind::EnvUnset {
                name: tokens[2].clone(),
            })
        }
        Some(other) => Err(parse_error(
            source_name,
            line_number,
            format!("unknown ENV instruction: {other}"),
        )),
        None => Err(parse_error(
            source_name,
            line_number,
            "ENV requires a subcommand",
        )),
    }
}

fn parse_fs(
    source_name: &str,
    line_number: usize,
    tokens: &[String],
) -> Result<StatementKind, SandboxError> {
    match tokens.get(1).map(String::as_str) {
        Some("DEFAULT") => {
            if tokens.len() != 3 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "FS DEFAULT expects exactly one value",
                ));
            }
            let value = match tokens[2].as_str() {
                "NONE" => FsDefault::None,
                "READ" => FsDefault::Read,
                "READWRITE" => FsDefault::ReadWrite,
                other => {
                    return Err(parse_error(
                        source_name,
                        line_number,
                        format!("invalid FS DEFAULT value: {other}"),
                    ));
                }
            };
            Ok(StatementKind::FsDefault { value })
        }
        Some("ALLOW") => {
            if tokens.len() != 4 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "FS ALLOW expects an access mode and a value",
                ));
            }
            let access = match tokens[2].as_str() {
                "READ" => FsAccess::Read,
                "WRITE" => FsAccess::Write,
                other => {
                    return Err(parse_error(
                        source_name,
                        line_number,
                        format!("invalid FS ALLOW access mode: {other}"),
                    ));
                }
            };
            Ok(StatementKind::FsAllow {
                access,
                value: tokens[3].clone(),
            })
        }
        Some(other) => Err(parse_error(
            source_name,
            line_number,
            format!("unknown FS instruction: {other}"),
        )),
        None => Err(parse_error(
            source_name,
            line_number,
            "FS requires a subcommand",
        )),
    }
}

fn parse_exec(
    source_name: &str,
    line_number: usize,
    tokens: &[String],
) -> Result<StatementKind, SandboxError> {
    match tokens.get(1).map(String::as_str) {
        Some("DEFAULT") => {
            if tokens.len() != 3 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "EXEC DEFAULT expects exactly one value",
                ));
            }
            let value = match tokens[2].as_str() {
                "ALLOW" => ExecDefault::Allow,
                "DENY" => ExecDefault::Deny,
                other => {
                    return Err(parse_error(
                        source_name,
                        line_number,
                        format!("invalid EXEC DEFAULT value: {other}"),
                    ));
                }
            };
            Ok(StatementKind::ExecDefault { value })
        }
        Some("ALLOW") => {
            if tokens.len() != 3 {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "EXEC ALLOW expects exactly one value",
                ));
            }
            Ok(StatementKind::ExecAllow {
                value: tokens[2].clone(),
            })
        }
        Some("INTERCEPT") => {
            if tokens.len() != 5 || tokens[3] != "WITH" {
                return Err(parse_error(
                    source_name,
                    line_number,
                    "EXEC INTERCEPT expects `EXEC INTERCEPT <command> WITH <handler>`",
                ));
            }
            Ok(StatementKind::ExecIntercept {
                command: tokens[2].clone(),
                handler: tokens[4].clone(),
            })
        }
        Some(other) => Err(parse_error(
            source_name,
            line_number,
            format!("unknown EXEC instruction: {other}"),
        )),
        None => Err(parse_error(
            source_name,
            line_number,
            "EXEC requires a subcommand",
        )),
    }
}

pub(crate) fn tokenize_line(line: &str) -> Result<Vec<String>, String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut chars = line.chars().peekable();
    let mut quote = None::<char>;

    while let Some(ch) = chars.next() {
        match quote {
            Some(active) => {
                if ch == active {
                    quote = None;
                } else if ch == '\\' && active == '"' {
                    let Some(next) = chars.next() else {
                        return Err("unfinished escape sequence".to_string());
                    };
                    current.push(next);
                } else {
                    current.push(ch);
                }
            }
            None => match ch {
                '#' => break,
                '"' | '\'' => quote = Some(ch),
                ch if ch.is_whitespace() => {
                    if !current.is_empty() {
                        tokens.push(std::mem::take(&mut current));
                    }
                }
                _ => current.push(ch),
            },
        }
    }

    if quote.is_some() {
        return Err("unterminated quoted string".to_string());
    }

    if !current.is_empty() {
        tokens.push(current);
    }

    Ok(tokens)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_if_test_block() {
        let program = parse_program(
            "builtin",
            r#"
                IF TEST -n "$SHELL_HISTORY_FILE"
                FS ALLOW WRITE $SHELL_HISTORY_FILE
                ELSE
                WARN "missing history file"
                END
            "#,
        )
        .expect("program");

        assert_eq!(program.statements.len(), 5);
        assert!(matches!(
            program.statements[0].kind,
            StatementKind::IfTest { .. }
        ));
        assert!(matches!(program.statements[2].kind, StatementKind::Else));
        assert!(matches!(program.statements[4].kind, StatementKind::End));
    }

    #[test]
    fn parse_switch_case_block() {
        let program = parse_program(
            "builtin",
            r#"
                SWITCH "$OS"
                CASE "macos"
                USE os/macos
                DEFAULT
                WARN "unsupported"
                END
            "#,
        )
        .expect("program");

        assert_eq!(program.statements.len(), 6);
        assert!(matches!(
            program.statements[0].kind,
            StatementKind::Switch { .. }
        ));
        assert!(matches!(
            program.statements[1].kind,
            StatementKind::Case { .. }
        ));
        assert!(matches!(program.statements[3].kind, StatementKind::Default));
        assert!(matches!(program.statements[5].kind, StatementKind::End));
    }

    #[test]
    fn parse_info_statement() {
        let program = parse_program("builtin", r#"INFO "hello""#).expect("program");

        assert_eq!(program.statements.len(), 1);
        assert!(matches!(
            program.statements[0].kind,
            StatementKind::Info { .. }
        ));
    }

    #[test]
    fn tokenize_comments_and_quotes() {
        let tokens = tokenize_line(r#"WARN "hello # world" # trailing"#).expect("tokens");
        assert_eq!(tokens, vec!["WARN", "hello # world"]);
    }
}

---
name: writing-agents
description: Use when creating new agents, editing existing agents, or defining specialized subagent roles for the Task tool
---

# Writing Agents

## Overview

**Writing agents IS Test-Driven Development applied to role definitions.**

Agents are specialized subagents invoked via the Task tool. They receive full conversation context and execute autonomously with a defined persona, tools, and behavioral guidelines.

**Core principle:** If you didn't test the agent on representative tasks, you don't know if it performs correctly.

**REQUIRED BACKGROUND:** Understand test-driven-development and writing-skills before using this skill. Same RED-GREEN-REFACTOR cycle applies.

## Agents vs Skills

| Aspect | Agents | Skills |
|--------|--------|--------|
| **Invocation** | Task tool with `subagent_type` | Skill tool with skill name |
| **Context** | Full conversation history | Loaded on-demand |
| **Execution** | Autonomous, multi-turn | Single response guidance |
| **Persona** | Explicit role/identity | Reference documentation |
| **Location** | `.claude/agents/` | `.claude/skills/` |
| **Use for** | Complex, autonomous tasks | Reusable patterns/techniques |

## Agent File Structure

**Agents are PROJECT-LEVEL.** They live in the project's `.claude/agents/` directory, not personal directories.

```
.claude/agents/
  agent-name.md    # Single file with frontmatter + persona
```

**Frontmatter (YAML):**
```yaml
---
name: agent-name
description: Role description. Use for [specific task types].
model: opus  # Optional: opus, sonnet, haiku (defaults to parent)
---
```

**IMPORTANT:** After creating or modifying an agent, prompt the user to restart their Claude Code session. Agents are loaded at session start and won't be available until restart.

## Agent Creation Workflow

Before writing the agent, gather domain knowledge and project context:

### Step 1: Research Domain Best Practices

**Use WebSearch to find domain-specific guidance.** Search for:
- Best practices for [domain] development
- Common [domain] mistakes/anti-patterns
- [Domain] code review checklist
- [Technology] security considerations

**Example searches for Selkie domains:**
```
# Zig systems programming agent
"Zig best practices 2026"
"Zig memory management anti-patterns"
"Zig comptime patterns"
"Zig C interop pitfalls"

# Graphics/rendering agent
"raylib best practices"
"OpenGL rendering performance patterns"
"2D text rendering optimization"

# Markdown/parser agent
"cmark-gfm API usage patterns"
"markdown parser edge cases"
"GFM spec compliance issues"

# Diagram/visualization agent
"graph layout algorithms best practices"
"Sugiyama/dagre layout common issues"
"Mermaid diagram rendering approaches"
```

**Incorporate findings into:**
- Anti-patterns section (domain-specific mistakes)
- Best practices (positive patterns to follow)
- Security considerations (if applicable)

### Step 2: Gather Codebase Context

**Explore the project to make the agent project-specific:**

1. **Read CLAUDE.md and README.md** for project conventions
2. **Identify existing patterns** using Glob/Grep:
   - Directory structure relevant to agent's domain
   - Existing modules, structs, functions the agent will work with
   - Testing patterns and conventions
3. **Check existing agents** in `.claude/agents/` for:
   - Coordination protocols to follow
   - Deferral relationships to establish
   - Naming conventions

**Example exploration:**
```bash
# Find project structure for a layout agent
Glob: "src/layout/**/*.zig"
Grep: "pub const.*= struct"
Read: "CLAUDE.md", "README.md"

# Find existing agent patterns
Glob: ".claude/agents/*.md"
```

### Step 3: Write the Agent

Combine research + codebase context into the agent definition:
- Persona grounded in project specifics
- Anti-patterns from both research AND project history
- Project structure and commands the agent needs
- Coordination with existing agents

### Step 4: Session Restart

After writing the agent file, inform the user:

```
Agent created: .claude/agents/[agent-name].md

**ACTION REQUIRED:** Please restart your Claude Code session for the new agent to be available. Agents are loaded at session start.

To use the agent after restart:
- It will appear in the Task tool's available agents
- Invoke with: Task tool, subagent_type="[agent-name]"
```

## Anatomy of an Effective Agent

### 1. Clear Persona Definition

**The persona is the agent's DNA.** A well-defined persona produces consistent behavior across interactions.

```markdown
You are a [specific role] with expertise in [domains]. You specialize in [specific capabilities] for [context/project].
```

**Good persona:**
```markdown
You are a senior Zig developer with deep expertise in systems programming, C FFI integration, and GPU-accelerated rendering. You specialize in building robust parser and layout systems for the Selkie markdown viewer, which uses cmark-gfm for parsing, raylib for rendering, and native Zig for Mermaid diagram support.
```

**Bad persona:**
```markdown
You are a helpful assistant that can help with code.
```

### 2. Explicit Scope Boundaries

**Define what the agent DOES and DOES NOT handle.** Prevents scope creep and enables deferral to specialists.

```markdown
## CORE COMPETENCIES
- [Domain 1]: Specific capabilities
- [Domain 2]: Specific capabilities

**Not in scope** (defer to [other-agent]):
- [Excluded domain 1]
- [Excluded domain 2]
```

### 3. Anti-Patterns Section

**List specific mistakes to avoid.** More effective than generic guidelines.

```markdown
## Anti-Patterns to Avoid

- **Memory leak prevention** -- always `defer deinit()` immediately after allocation
- **Never use `page_allocator` in tests** -- use `testing.allocator` for leak detection
- **Always check C FFI return values** -- cmark functions return null on failure
```

### 4. Coordination Protocols

**Define how the agent coordinates with others.** Essential for multi-agent workflows.

```markdown
## Coordination with [Other Agent]

**When delegated work:**
1. Acknowledge the task
2. Implement following their requirements
3. Report completion with specific details

**Report format:**
- Issue/task reference
- Changes made (files, functions)
- Testing performed
- Explicit "ready for next step" statement
```

### 5. Project Context

**Provide relevant project structure and conventions.** Enables autonomous operation.

```markdown
## PROJECT CONTEXT

### Project Structure
```
src/
├── parser/        # cmark-gfm integration, AST types
├── layout/        # Document layout engine
├── render/        # raylib drawing code
├── mermaid/       # Mermaid parsers, models, renderers
├── theme/         # Theme definitions and JSON loader
└── viewport/      # Scrolling, input handling
```

### Key Commands
```bash
zig build              # Build
zig build run -- file.md   # Run with markdown file
zig build test         # Run tests
```
```

## Agent Description Best Practices

The description field is critical for Task tool routing. Claude uses it to select the right agent.

**Format:** `[Role statement]. Use for [specific task types].`

**Good descriptions:**
```yaml
# Specific role + clear triggers
description: Senior Zig developer. Use for parser integration, layout algorithms, C FFI with cmark-gfm, memory management, and Zig build system issues.

# Clear scope + deferral
description: Mermaid diagram specialist. Use for diagram parsers, models, layout algorithms, and renderers. Defers to zig-developer for build system issues.

# Domain-specific expertise
description: raylib rendering expert. Use for text rendering, image caching, viewport culling, and GPU draw call optimization.
```

**Bad descriptions:**
```yaml
# Too vague
description: Helps with code

# No trigger conditions
description: A senior developer

# Process summary (causes shortcut behavior)
description: Reviews code by checking style, then logic, then tests
```

## Model Selection

Choose the right model for the task complexity:

| Model | Use When | Cost |
|-------|----------|------|
| **haiku** | Quick, straightforward tasks | Low |
| **sonnet** | Balanced complexity (default) | Medium |
| **opus** | Deep reasoning, architecture decisions | High |

```yaml
# Example: Layout algorithm design needs deep judgment
model: opus

# Example: Simple code formatting check
model: haiku
```

**Omit `model` to inherit from parent conversation.**

## Common Agent Patterns

### Specialist Agent

Focused on a single domain with clear boundaries and deferral rules.

```markdown
You are a [specialist role] focused on [specific domain].

**Your scope:**
- [Capability 1]
- [Capability 2]

**Defer to [other-agent] for:**
- [Out-of-scope area 1]
- [Out-of-scope area 2]
```

### Orchestrator Agent

Coordinates other agents, manages workflow, doesn't do implementation.

```markdown
You orchestrate [workflow type]. You delegate to specialist agents and track progress.

**You manage:**
- Task breakdown and assignment
- Progress tracking
- Integration of results

**You do NOT:**
- Write code directly
- Make implementation decisions
- Deploy without approval
```

### Reviewer Agent

Evaluates work against criteria, provides structured feedback.

```markdown
You review [artifact type] against [criteria].

**Review process:**
1. [Step 1]
2. [Step 2]
3. [Step 3]

**Output format:**
- Status: [PASS/FAIL/NEEDS_CHANGES]
- Issues: [List]
- Recommendations: [List]
```

## Testing Agents

### RED: Baseline Without Agent

Run representative tasks with a generic prompt. Document:
- What mistakes does it make?
- What context does it lack?
- Where does it go wrong?

### GREEN: Write Minimal Agent

Address specific baseline failures:
- Add persona for role consistency
- Add anti-patterns for common mistakes
- Add project context for autonomy

### REFACTOR: Close Loopholes

Test edge cases:
- Does it stay in scope?
- Does it defer correctly?
- Does it follow coordination protocols?

## Agent Creation Checklist

**Research Phase:**
- [ ] WebSearch for "[domain] best practices [current year]"
- [ ] WebSearch for "[domain] anti-patterns" or "[domain] common mistakes"
- [ ] WebSearch for "[technology] security considerations" (if applicable)
- [ ] Document key findings for anti-patterns section

**Context Phase:**
- [ ] Read CLAUDE.md and README.md for project conventions
- [ ] Explore codebase structure relevant to agent's domain
- [ ] Check existing agents in `.claude/agents/` for patterns
- [ ] Identify coordination/deferral relationships needed

**RED Phase:**
- [ ] Identify the specialized task type
- [ ] Test baseline behavior without agent
- [ ] Document specific failures and gaps

**GREEN Phase:**
- [ ] Clear persona with specific expertise AND project context
- [ ] Explicit scope boundaries (does/doesn't)
- [ ] Anti-patterns from BOTH research AND project experience
- [ ] Project structure and commands included
- [ ] Coordination protocols if multi-agent
- [ ] Model selection appropriate for complexity

**REFACTOR Phase:**
- [ ] Test on representative tasks
- [ ] Verify scope boundaries respected
- [ ] Verify deferral works correctly
- [ ] Verify coordination protocols followed

**Quality Checks:**
- [ ] Description under 500 chars, includes triggers
- [ ] Persona is specific, not generic
- [ ] Anti-patterns are actionable, not vague
- [ ] No process summary in description

**Deployment:**
- [ ] Agent file written to `.claude/agents/[name].md`
- [ ] User prompted to restart session

## Anti-Patterns to Avoid

### Generic Persona
```markdown
# BAD: Could be anyone
You are a helpful assistant.

# GOOD: Specific expertise and context
You are a senior Zig developer with expertise in parser design and C FFI integration for the Selkie markdown viewer, which uses cmark-gfm for GFM parsing and raylib-zig for rendering.
```

### Missing Scope Boundaries
```markdown
# BAD: No limits
You can help with anything.

# GOOD: Clear boundaries with deferral
**Not in scope** (defer to mermaid-specialist):
- Mermaid diagram parsing and rendering
- Diagram layout algorithms
- Mermaid model definitions
```

### Vague Anti-Patterns
```markdown
# BAD: Too general
- Write good code
- Follow best practices

# GOOD: Specific and actionable
- **Memory leak prevention** -- always `defer deinit()` after allocation
- **Never skip C FFI null checks** -- cmark functions return null on failure
- **Use `testing.allocator`** in all tests for automatic leak detection
```

### Process in Description
```markdown
# BAD: Claude may follow description instead of reading agent
description: Reviews code by first checking style, then logic, then tests, finally creating report

# GOOD: Just triggers, no process
description: Code quality reviewer. Use after completing features to check against Zig and Selkie standards.
```

## The Bottom Line

**Agents are autonomous specialists.** They need:
1. **Clear identity** - Who they are, what they know
2. **Explicit scope** - What they do and don't do
3. **Actionable guidelines** - Specific anti-patterns, not vague advice
4. **Coordination protocols** - How they work with others

Test your agents on real tasks. A well-defined persona produces consistent, reliable behavior. A vague persona produces unpredictable results.

## References

- [PromptHub: Prompt Engineering for AI Agents](https://www.prompthub.us/blog/prompt-engineering-for-ai-agents)
- [The Agent Architect: 4 Tips for System Prompts](https://theagentarchitect.substack.com/p/4-tips-writing-system-prompts-ai-agents-work)
- [Datablist: 11 Rules for AI Agent Prompts](https://www.datablist.com/how-to/rules-writing-prompts-ai-agents)

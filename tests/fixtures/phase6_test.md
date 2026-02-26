# Phase 6: Mermaid Flowchart Tests

## Basic Flowchart (TD)

```mermaid
graph TD
    A["Start"] --> B{"Decision"}
    B -->|Yes| C["Process"]
    B -->|No| D["End"]
    C --> D
```

## Left-to-Right Direction

```mermaid
graph LR
    A["Input"] --> B["Process"] --> C["Output"]
```

## Multiple Node Shapes

```mermaid
graph TD
    rect["Rectangle"]
    rounded("Rounded")
    diamond{"Diamond"}
    circle(("Circle"))
    stadium(["Stadium"])
    subroutine[["Subroutine"]]
    rect --> rounded --> diamond
    diamond --> circle
    diamond --> stadium
    stadium --> subroutine
```

## Edge Labels and Styles

```mermaid
graph LR
    A --> B
    B -.-> C
    C ==> D
    A -->|solid| D
```

## Subgraphs

```mermaid
graph TD
    subgraph Frontend
        A["React App"] --> B["API Client"]
    end
    subgraph Backend
        C["REST API"] --> D["Database"]
    end
    B --> C
```

## Unsupported Diagram Type

```mermaid
sequenceDiagram
    Alice->>Bob: Hello
    Bob-->>Alice: Hi
```

## Regular Code Block (should still render normally)

```python
def hello():
    print("This is not a mermaid diagram")
```

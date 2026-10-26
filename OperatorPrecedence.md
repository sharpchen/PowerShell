# PowerShell Operator Precedence — Source Analysis and Empirical Verification

Analyzed against PowerShell/PowerShell checkout `1dbabadc0` (`origin/master`).

Source files used:

- `src/System.Management.Automation/engine/parser/token.cs` — `TokenFlags` precedence values and per-token flags
- `src/System.Management.Automation/engine/parser/Parser.cs` — expression, unary, cast, ternary, pipeline, and assignment grammar
- `src/System.Management.Automation/engine/parser/tokenizer.cs` — operator text table (accepted aliases)

## How binary precedence is stored

`TokenTraits.GetBinaryPrecedence()` (`token.cs:1198-1202`) returns the low 4 bits
of `TokenFlags`, masked by `BinaryPrecedenceMask = 0x0000000f`. Higher numeric
value means tighter binding.

`BinaryExpressionRule` (`Parser.cs:6798-6950`) is a shunting-yard parser. The
reduction condition `while (newPrecedence <= precedence)` means equal-precedence
binary operators are left-associative.

## Operators with explicit binary precedence flags

| Source precedence | Operators | Classification |
|---:|---|---|
| `1` (`BinaryPrecedenceLogical`) | `-and`, `-or`, `-xor` | binary |
| `2` (`BinaryPrecedenceBitwise`) | `-band`, `-bor`, `-bxor` | binary |
| `5` (`BinaryPrecedenceComparison`) | `-eq`, `-ieq`, `-ceq`, `-ne`, `-ine`, `-cne`, `-ge`, `-ige`, `-cge`, `-gt`, `-igt`, `-cgt`, `-lt`, `-ilt`, `-clt`, `-le`, `-ile`, `-cle`, `-like`, `-ilike`, `-clike`, `-notlike`, `-inotlike`, `-cnotlike`, `-match`, `-imatch`, `-cmatch`, `-notmatch`, `-inotmatch`, `-cnotmatch`, `-replace`, `-ireplace`, `-creplace`, `-contains`, `-icontains`, `-ccontains`, `-notcontains`, `-inotcontains`, `-cnotcontains`, `-in`, `-iin`, `-cin`, `-notin`, `-inotin`, `-cnotin`, `-split`, `-isplit`, `-csplit`, `-join`, `-is`, `-isnot`, `-as`, `-shl`, `-shr` | binary; `-split`, `-isplit`, `-csplit`, `-join` also unary |
| `7` (`BinaryPrecedenceCoalesce`) | `??` | binary |
| `9` (`BinaryPrecedenceAdd`) | `+`, `-` | dual-form |
| `10` (`BinaryPrecedenceMultiply`) | `*`, `/`, `%` | binary |
| `12` (`BinaryPrecedenceFormat`) | `-f` | binary |
| `13` (`BinaryPrecedenceRange`) | `..` | binary |

`Comma` (`,`) has only `TokenFlags.UnaryOperator` (`token.cs:809`), but
`Parser.cs:ArrayLiteralRule` (`Parser.cs:6975-7021`) also implements infix
array-literal comma. It is therefore dual-form despite having no
`BinaryOperator` flag.

## Dual-form operators

| Operator | Unary behavior | Binary behavior | Different precedence? |
|---|---|---|---|
| `,` | `,$a` creates a one-element array; prefix-unary level | `a,b` creates an array literal; n-ary infix level above all normal binary operators | Yes |
| `+` | unary identity / numeric promotion | additive | Yes |
| `-` | unary negation | subtraction | Yes |
| `-split`, `-isplit`, `-csplit` | prefix split of one operand | comparison-precedence binary split | Yes |
| `-join` | prefix join with default separator | comparison-precedence binary join with separator | Yes |
| `++`, `--` | prefix and postfix unary forms; no binary form | n/a | postfix binds tighter than prefix |

Cast syntax `[<type>]expr` is implemented in `UnaryExpressionRule`
(`Parser.cs:7029-7193`) and sits at prefix-unary precedence. The related binary
type conversion operator is `-as`, not a dual form of cast.

## Full relative precedence (highest to lowest)

| Rank | Operators | Form | Associativity / grouping |
|---:|---|---|---|
| 1 | `.`, `::`, `?.`, `[]`, `?[]`, member method invocation `()`, postfix `++`, postfix `--` | postfix / member / index / invoke / unary postfix | postfix chains processed left-to-right |
| 2 | `[<type>]` cast, unary `,`, prefix `+`, prefix `-`, prefix `++`, prefix `--`, `!`, `-not`, `-bnot`, unary `-split`, unary `-isplit`, unary `-csplit`, unary `-join` | unary prefix / cast | right-nested; prefix operators recursively consume another unary expression |
| 3 | binary `,` | binary / dual-form | n-ary flat array literal; `$a,$b,$c` is one `ArrayLiteralAst`, not `($a,$b),$c` |
| 4 | `..` | binary | left-associative |
| 5 | `-f` | binary | left-associative |
| 6 | `*`, `/`, `%` | binary | left-associative |
| 7 | binary `+`, binary `-` | binary / dual-form | left-associative |
| 8 | `??` | binary | left-associative |
| 9 | all comparison operators listed above, including `-shl` and `-shr` | binary; `-split`/`-join` also unary | left-associative |
| 10 | `-band`, `-bor`, `-bxor` | binary | left-associative |
| 11 | `-and`, `-or`, `-xor` | binary | left-associative |
| 12 | `? :` | ternary | condition is a binary expression; branches recurse through expression parsing |
| 13 | redirection operators, e.g. `>`, `>>`, `2>&1` | command/pipeline-element operator | binds to preceding pipeline element before `\|` |
| 14 | `\|` | pipeline | pipeline elements are sequenced by `\|` |
| 15 | `&&`, `\|\|` | pipeline chain | left-associative |
| 16 | `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `??=` | assignment | right-associative |

### Context-dependent / non-expression operators

- `&` is command invocation when prefixing a command; it is the background
  operator when following a pipeline. Statement/command-level; not ranked here.
- Class inheritance / base-constructor `:` is class syntax, not expression
  precedence.
- The comments at `token.cs:158-162` call `&&` and `||` unimplemented, but this
  checkout parses them in `PipelineChainRule` (`Parser.cs:5773-5988`). The
  comments are stale.

## Empirical verification

Test script: `Test-OperatorPrecedence.ps1`.

```powershell
pwsh -NoProfile -File .\Test-OperatorPrecedence.ps1
```

The script builds the complete ordered infix matrix for 69 operator spellings
(69 × 69 = 4761 cases). For each pair it compares:

```powershell
$a opA $b opB $c
($a opA $b) opB $c
$a opA ($b opB $c)
```

using canonical AST shape. Runtime-sensitive special cases are available with
`-IncludeRuntime`; the full runtime binary matrix with `-IncludeRuntimeMatrix`;
CSV export with `-CsvPath`.

### Current results

```text
=== Binary parse mismatches ===
<none>
=== Special-level parse mismatches ===
<none>
```

Run log: `precedence-run.txt`.

### Representative runtime evidence

| Test | Unparenthesized / expected-side result | Other grouping | Conclusion |
|---|---:|---:|---|
| `-$a + $b` with `$a='3'; $b=5` | `2` | `-($a + $b)` => `-35` | prefix `-` > binary `+` |
| `[int]$a + $b` with `$a='2.9'; $b=.5` | `3.5` | `[int]($a + $b)` => cast error | cast > additive |
| `-$a.b` with `$a.b=3` | `-3` | `(-$a).b` => error | postfix member > prefix unary |
| `-$a++` with `$a=3` | `-3` | `(-$a)++` => error | postfix `++` > prefix unary |
| `$a,$b + $c` | `1,2,3` | `$a,($b + $c)` => `1,5` | binary comma > additive |
| `-split $a -eq $b` | `'a'` | `-split ($a -eq $b)` => `'False'` | unary `-split` > comparison |
| `-join $a -eq $b` | `$true` | `-join ($a -eq $b)` => empty string | unary `-join` > comparison |
| `$a + $b ? $c : $a` | `3` | `$a + ($b ? $c : $a)` => `4` | additive > ternary |
| `$a -and $b ? $c : $a` | `'A'` | `$a -and ($b ? $c : $a)` => `$true` | logical > ternary |
| `$a = $b \| Out-String` | `$null` | `($a = $b) \| Out-String` => string | pipe > assignment |
| `$a = $b && $c` | `$null` | `($a = $b) && $c` => array | `&&` > assignment |
| `$a = $b = $c` | `$null` | `($a = $b) = $c` => error | assignment is right-associative |

Runtime log: `precedence-runtime.txt`.

## Source vs. empirical disagreements

None found in the 4761-pair binary matrix or the special unary/cast/ternary/
pipeline/assignment tests.

One modeling nuance: repeated comma is n-ary, not left-associative binary.
`$a,$b,$c` parses as a single flat `ArrayLiteralAst` with three elements, not
as `($a,$b),$c`. The script models this explicitly and does not treat it as a
disagreement.

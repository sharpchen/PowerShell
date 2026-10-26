<#
.SYNOPSIS
    Empirically checks PowerShell operator precedence by comparing an unparenthesized
    expression with the two possible parenthesized groupings.

.DESCRIPTION
    The binary matrix uses the PowerShell parser (not documentation) and compares the
    canonical AST shape of:

        $a OP_A $b OP_B $c

    with:

        ($a OP_A $b) OP_B $c
        $a OP_A ($b OP_B $c)

    For equal binary precedence, the expected winner is the left-associated grouping.
    Repeated commas are the exception: PowerShell builds one flat n-ary
    ArrayLiteralAst, not nested binary comma operations.
    The script also checks representative prefix-unary, cast, array-comma, ternary,
    pipeline-chain, and assignment cases.

.EXAMPLE
    ./Test-OperatorPrecedence.ps1

.EXAMPLE
    ./Test-OperatorPrecedence.ps1 -IncludeRuntime -ShowMatches

.EXAMPLE
    ./Test-OperatorPrecedence.ps1 -IncludeRuntimeMatrix -CsvPath precedence.csv
#>

[CmdletBinding()]
param(
    [switch] $IncludeRuntime,
    [switch] $IncludeRuntimeMatrix,
    [switch] $ShowMatches,
    [string] $CsvPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-Precedence {
    param([string] $Operator)

    # Values are the exact BinaryPrecedence* values in token.cs.
    switch ($Operator) {
        '-and' { return 1 }
        '-or'  { return 1 }
        '-xor' { return 1 }

        '-band' { return 2 }
        '-bor'  { return 2 }
        '-bxor' { return 2 }

        { $_ -in @(
            '-eq', '-ieq', '-ceq',
            '-ne', '-ine', '-cne',
            '-ge', '-ige', '-cge',
            '-gt', '-igt', '-cgt',
            '-lt', '-ilt', '-clt',
            '-le', '-ile', '-cle',
            '-like', '-ilike', '-clike',
            '-notlike', '-inotlike', '-cnotlike',
            '-match', '-imatch', '-cmatch',
            '-notmatch', '-inotmatch', '-cnotmatch',
            '-replace', '-ireplace', '-creplace',
            '-contains', '-icontains', '-ccontains',
            '-notcontains', '-inotcontains', '-cnotcontains',
            '-in', '-iin', '-cin',
            '-notin', '-inotin', '-cnotin',
            '-split', '-isplit', '-csplit',
            '-join',
            '-is', '-isnot', '-as',
            '-shl', '-shr'
        ) } { return 5 }

        '??' { return 7 }
        '+'  { return 9 }
        '-'  { return 9 }
        '*'  { return 10 }
        '/'  { return 10 }
        '%'  { return 10 }
        '-f' { return 12 }
        '..' { return 13 }

        # The comma is not TokenFlags.BinaryOperator, but ArrayLiteralRule gives it
        # the highest infix-operand position; see Parser.cs ArrayLiteralRule.
        ',' { return 14 }

        default { throw "No source precedence is defined for operator '$Operator'." }
    }
}

function Get-ParsedStatement {
    param([string] $Text)

    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Text, [ref] $null, [ref] $parseErrors)

    if ($parseErrors.Count -gt 0) {
        return [pscustomobject] @{
            Ast    = $null
            Errors = $parseErrors
        }
    }

    return [pscustomobject] @{
        Ast    = $ast.EndBlock.Statements[0]
        Errors = $parseErrors
    }
}

function Convert-AstToCanonicalString {
    param($Ast)

    if ($null -eq $Ast) {
        return '<null>'
    }

    if ($Ast -is [System.Management.Automation.Language.BinaryExpressionAst]) {
        return '(BIN {0} {1} {2})' -f
            (Convert-AstToCanonicalString $Ast.Left),
            $Ast.Operator,
            (Convert-AstToCanonicalString $Ast.Right)
    }

    if ($Ast -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        return '(ASSIGN {0} {1} {2})' -f
            (Convert-AstToCanonicalString $Ast.Left),
            $Ast.Operator,
            (Convert-AstToCanonicalString $Ast.Right)
    }

    if ($Ast -is [System.Management.Automation.Language.PipelineChainAst]) {
        return '(CHAIN {0} {1} {2})' -f
            (Convert-AstToCanonicalString $Ast.LhsPipelineChain),
            $Ast.Operator,
            (Convert-AstToCanonicalString $Ast.RhsPipeline)
    }

    if ($Ast -is [System.Management.Automation.Language.PipelineAst]) {
        # Parentheses and assignment RHS can introduce a pipeline wrapper around a
        # single expression. This wrapper is not semantically relevant here.
        if ($Ast.PipelineElements.Count -eq 1 -and
            $Ast.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
            return Convert-AstToCanonicalString $Ast.PipelineElements[0].Expression
        }

        return '(PIPE {0})' -f (($Ast.PipelineElements |
            ForEach-Object { Convert-AstToCanonicalString $_ }) -join ' | ')
    }

    if ($Ast -is [System.Management.Automation.Language.CommandExpressionAst]) {
        return Convert-AstToCanonicalString $Ast.Expression
    }

    if ($Ast -is [System.Management.Automation.Language.TernaryExpressionAst]) {
        return '(TERNARY {0} ? {1} : {2})' -f
            (Convert-AstToCanonicalString $Ast.Condition),
            (Convert-AstToCanonicalString $Ast.IfTrue),
            (Convert-AstToCanonicalString $Ast.IfFalse)
    }

    if ($Ast -is [System.Management.Automation.Language.ConvertExpressionAst]) {
        return '(CAST {0} {1})' -f
            $Ast.Type.TypeName.FullName,
            (Convert-AstToCanonicalString $Ast.Child)
    }

    if ($Ast -is [System.Management.Automation.Language.UnaryExpressionAst]) {
        return '(UNARY {0} {1})' -f
            $Ast.TokenKind,
            (Convert-AstToCanonicalString $Ast.Child)
    }

    if ($Ast -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        return '(ARRAY {0})' -f (($Ast.Elements |
            ForEach-Object { Convert-AstToCanonicalString $_ }) -join ', ')
    }

    if ($Ast -is [System.Management.Automation.Language.IndexExpressionAst]) {
        return '(INDEX {0} [{1}])' -f
            (Convert-AstToCanonicalString $Ast.Target),
            (Convert-AstToCanonicalString $Ast.Index)
    }

    if ($Ast -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        return '(INVOKE {0}.{1}({2}))' -f
            (Convert-AstToCanonicalString $Ast.Expression),
            (Convert-AstToCanonicalString $Ast.Member),
            (($Ast.Arguments | ForEach-Object { Convert-AstToCanonicalString $_ }) -join ', ')
    }

    if ($Ast -is [System.Management.Automation.Language.MemberExpressionAst]) {
        return '(MEMBER {0}.{1})' -f
            (Convert-AstToCanonicalString $Ast.Expression),
            (Convert-AstToCanonicalString $Ast.Member)
    }

    if ($Ast -is [System.Management.Automation.Language.VariableExpressionAst]) {
        if ($Ast.Splatted) {
            return '@' + $Ast.VariablePath.UserPath
        }
        return '$' + $Ast.VariablePath.UserPath
    }

    if ($Ast -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        if ($null -eq $Ast.Value) { return '<null>' }
        return '{0}:{1}' -f $Ast.Value.GetType().FullName, $Ast.Value
    }

    if ($Ast -is [System.Management.Automation.Language.TypeExpressionAst]) {
        return '[{0}]' -f $Ast.TypeName.FullName
    }

    if ($Ast -is [System.Management.Automation.Language.ParenExpressionAst]) {
        return Convert-AstToCanonicalString $Ast.Pipeline
    }

    # Use the type name only. Including source extent would make equivalent
    # parenthesized ASTs look different.
    return '<{0}>' -f $Ast.GetType().Name
}

function Get-CanonicalAst {
    param([string] $Text)

    $parsed = Get-ParsedStatement $Text
    if ($parsed.Errors.Count -gt 0) {
        return '<parse-error>'
    }
    return Convert-AstToCanonicalString $parsed.Ast
}

function Convert-ResultToSignature {
    param($Value)

    if ($null -eq $Value) { return '<null>' }
    if ($Value -is [System.Array]) {
        return 'array[{0}]<{1}>' -f $Value.Count, (($Value |
            ForEach-Object { Convert-ResultToSignature $_ }) -join ', ')
    }
    return '{0}:{1}' -f $Value.GetType().FullName, $Value
}

function Invoke-TestExpression {
    param(
        [string] $Text,
        [hashtable] $Values
    )

    try {
        foreach ($entry in $Values.GetEnumerator()) {
            Set-Variable -Name $entry.Key -Value $entry.Value
        }

        $result = Invoke-Expression -Command $Text
        return Convert-ResultToSignature $result
    }
    catch {
        return 'ERROR:' + $_.FullyQualifiedErrorId
    }
}

# Every surface text with a binary precedence flag, plus aliases. The comma is
# tested separately because its precedence is implemented by ArrayLiteralRule.
$binaryOperators = @(
    '-and', '-or', '-xor',
    '-band', '-bor', '-bxor',
    '-eq', '-ieq', '-ceq',
    '-ne', '-ine', '-cne',
    '-ge', '-ige', '-cge',
    '-gt', '-igt', '-cgt',
    '-lt', '-ilt', '-clt',
    '-le', '-ile', '-cle',
    '-like', '-ilike', '-clike',
    '-notlike', '-inotlike', '-cnotlike',
    '-match', '-imatch', '-cmatch',
    '-notmatch', '-inotmatch', '-cnotmatch',
    '-replace', '-ireplace', '-creplace',
    '-contains', '-icontains', '-ccontains',
    '-notcontains', '-inotcontains', '-cnotcontains',
    '-in', '-iin', '-cin',
    '-notin', '-inotin', '-cnotin',
    '-split', '-isplit', '-csplit',
    '-join',
    '-is', '-isnot', '-as',
    '-shl', '-shr',
    '??',
    '+', '-',
    '*', '/', '%',
    '-f', '..',
    ','
)

$binaryResults = New-Object 'System.Collections.Generic.List[object]'
for ($i = 0; $i -lt $binaryOperators.Count; $i++) {
    for ($j = 0; $j -lt $binaryOperators.Count; $j++) {
        $opA = $binaryOperators[$i]
        $opB = $binaryOperators[$j]
        $precA = Get-Precedence $opA
        $precB = Get-Precedence $opB

        if ($opA -eq ',' -and $opB -eq ',') {
            $expected = 'Flat' # repeated comma builds one n-ary ArrayLiteralAst
        }
        elseif ($precA -gt $precB) { $expected = 'Left' }
        elseif ($precA -lt $precB) { $expected = 'Right' }
        else { $expected = 'Left' } # BinaryExpressionRule is left-associative.

        $noParens = '$a ' + $opA + ' $b ' + $opB + ' $c'
        $left = '($a ' + $opA + ' $b) ' + $opB + ' $c'
        $right = '$a ' + $opA + ' ($b ' + $opB + ' $c)'

        $noParensAst = Get-CanonicalAst $noParens
        $leftAst = Get-CanonicalAst $left
        $rightAst = Get-CanonicalAst $right

        $observed =
            if ($noParensAst -eq $leftAst -and $noParensAst -ne $rightAst) { 'Left' }
            elseif ($noParensAst -eq $rightAst -and $noParensAst -ne $leftAst) { 'Right' }
            elseif ($leftAst -eq $rightAst) { 'Indistinguishable' }
            else { 'Neither' }

        if ($opA -eq ',' -and $opB -eq ',' -and
            $noParensAst -eq '(ARRAY $a, $b, $c)') {
            $observed = 'Flat'
        }

        $row = [pscustomobject] @{
            OpA            = $opA
            OpB            = $opB
            SourcePrecedenceA = $precA
            SourcePrecedenceB = $precB
            Expected       = $expected
            Observed       = $observed
            Match          = ($observed -eq $expected)
            NoParensAst    = $noParensAst
            LeftAst        = $leftAst
            RightAst       = $rightAst
            Source         = $noParens
        }

        if ($IncludeRuntimeMatrix) {
            $values = @{ a = 7; b = 3; c = 2 }
            $row | Add-Member -NotePropertyName RuntimeNoParens `
                -NotePropertyValue (Invoke-TestExpression $noParens $values)
            $row | Add-Member -NotePropertyName RuntimeLeft `
                -NotePropertyValue (Invoke-TestExpression $left $values)
            $row | Add-Member -NotePropertyName RuntimeRight `
                -NotePropertyValue (Invoke-TestExpression $right $values)
            $row | Add-Member -NotePropertyName RuntimeSensitive `
                -NotePropertyValue (
                    $row.RuntimeNoParens -ne $row.RuntimeLeft -or
                    $row.RuntimeNoParens -ne $row.RuntimeRight
                )
        }

        $binaryResults.Add($row)
    }
}

# Representative tests for grammar levels that do not fit the all-infix matrix.
$specialTests = @(
    @{
        Name = 'postfix member access beats prefix unary'
        Source = '-$a.b'
        Left = '(-$a).b'
        Right = '-($a.b)'
        Expected = 'Right'
        Values = @{ a = [pscustomobject]@{ b = 3 } }
    },
    @{
        Name = 'postfix increment beats prefix unary'
        Source = '-$a++'
        Left = '(-$a)++'
        Right = '-($a++)'
        Expected = 'Right'
        Values = @{ a = 3 }
    },
    @{
        Name = 'cast is prefix-unary level and beats additive'
        Source = '[int]$a + $b'
        Left = '([int]$a) + $b'
        Right = '[int]($a + $b)'
        Expected = 'Left'
        Values = @{ a = '2.9'; b = 0.5 }
    },
    @{
        Name = 'prefix unary beats additive'
        Source = '-$a + $b'
        Left = '(-$a) + $b'
        Right = '-($a + $b)'
        Expected = 'Left'
        Values = @{ a = '3'; b = 5 }
    },
    @{
        Name = 'infix comma beats additive'
        Source = '$a,$b + $c'
        Left = '($a,$b) + $c'
        Right = '$a,($b + $c)'
        Expected = 'Left'
        Values = @{ a = 1; b = 2; c = 3 }
    },
    @{
        Name = 'infix comma beats range'
        Source = '$a..$b,$c'
        Left = '($a..$b),$c'
        Right = '$a..($b,$c)'
        Expected = 'Right'
        Values = @{ a = 1; b = 3; c = 9 }
    },
    @{
        Name = 'unary comma is at unary level'
        Source = ',$a + $b'
        Left = '(,$a) + $b'
        Right = ',($a + $b)'
        Expected = 'Left'
        Values = @{ a = 2; b = 3 }
    },
    @{
        Name = 'unary split beats comparison'
        Source = '-split $a -eq $b'
        Left = '(-split $a) -eq $b'
        Right = '-split ($a -eq $b)'
        Expected = 'Left'
        Values = @{ a = 'a b'; b = 'a' }
    },
    @{
        Name = 'unary join beats comparison'
        Source = '-join $a -eq $b'
        Left = '(-join $a) -eq $b'
        Right = '-join ($a -eq $b)'
        Expected = 'Left'
        Values = @{ a = @('x', 'y'); b = 'xy' }
    },
    @{
        Name = 'logical is below ternary'
        Source = '$a -and $b ? $c : $a'
        Left = '($a -and $b) ? $c : $a'
        Right = '$a -and ($b ? $c : $a)'
        Expected = 'Left'
        Values = @{ a = 'A'; b = $false; c = $false }
    },
    @{
        Name = 'additive is above ternary'
        Source = '$a + $b ? $c : $a'
        Left = '($a + $b) ? $c : $a'
        Right = '$a + ($b ? $c : $a)'
        Expected = 'Left'
        Values = @{ a = 1; b = 2; c = 3 }
    },
    @{
        Name = 'assignment is right-associative'
        Source = '$a = $b = $c'
        Left = '($a = $b) = $c'
        Right = '$a = ($b = $c)'
        Expected = 'Right'
        Values = @{ a = $null; b = $null; c = 9 }
    },
    @{
        Name = 'assignment is below pipe'
        Source = '$a = $b | Out-String'
        Left = '($a = $b) | Out-String'
        Right = '$a = ($b | Out-String)'
        Expected = 'Right'
        Values = @{ a = $null; b = 3 }
    },
    @{
        Name = 'assignment is below pipeline chain'
        Source = '$a = $b && $c'
        Left = '($a = $b) && $c'
        Right = '$a = ($b && $c)'
        Expected = 'Right'
        Values = @{ a = $null; b = $true; c = $false }
    }
)

$specialResults = foreach ($test in $specialTests) {
    $noParensAst = Get-CanonicalAst $test.Source
    $leftAst = Get-CanonicalAst $test.Left
    $rightAst = Get-CanonicalAst $test.Right

    $observed =
        if ($noParensAst -eq $leftAst -and $noParensAst -ne $rightAst) { 'Left' }
        elseif ($noParensAst -eq $rightAst -and $noParensAst -ne $leftAst) { 'Right' }
        elseif ($leftAst -eq $rightAst) { 'Indistinguishable' }
        else { 'Neither' }

    $row = [pscustomobject] @{
        Test        = $test.Name
        Expected    = $test.Expected
        Observed    = $observed
        Match       = ($observed -eq $test.Expected)
        NoParensAst = $noParensAst
        LeftAst     = $leftAst
        RightAst    = $rightAst
        Source      = $test.Source
    }

    if ($IncludeRuntime -or $IncludeRuntimeMatrix) {
        $row | Add-Member -NotePropertyName RuntimeNoParens `
            -NotePropertyValue (Invoke-TestExpression $test.Source $test.Values)
        $row | Add-Member -NotePropertyName RuntimeLeft `
            -NotePropertyValue (Invoke-TestExpression $test.Left $test.Values)
        $row | Add-Member -NotePropertyName RuntimeRight `
            -NotePropertyValue (Invoke-TestExpression $test.Right $test.Values)
    }

    $row
}

$disagreements = @($binaryResults | Where-Object { -not $_.Match }) +
                 @($specialResults | Where-Object { -not $_.Match })

if ($ShowMatches) {
    $binaryResults
    $specialResults
}
else {
    '=== Binary parse mismatches ==='
    if ($disagreements.Count -eq 0) { '<none>' } else { $disagreements }

    '=== Special-level parse mismatches ==='
    $specialDisagreements = @($specialResults | Where-Object { -not $_.Match })
    if ($specialDisagreements.Count -eq 0) { '<none>' } else { $specialDisagreements }

    '=== Equal-precedence left-associativity spot checks ==='
    $binaryResults | Where-Object {
        $_.OpA -in @('-and', '-or', '-xor') -and $_.OpB -in @('-and', '-or', '-xor')
    } | Select-Object -First 9 OpA, OpB, Expected, Observed, Match

    if ($IncludeRuntime -or $IncludeRuntimeMatrix) {
        '=== Special runtime results ==='
        $specialResults | Select-Object Test, Expected, Observed, Match,
            RuntimeNoParens, RuntimeLeft, RuntimeRight
    }
}

if ($CsvPath) {
    $binaryResults | Export-Csv -Path $CsvPath -NoTypeInformation
    $specialResults | Export-Csv -Path ($CsvPath -replace '\.csv$') '-special.csv' -NoTypeInformation
}

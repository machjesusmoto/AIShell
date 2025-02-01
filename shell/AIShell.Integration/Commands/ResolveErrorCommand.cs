using System.Collections;
using System.Text;
using System.Management.Automation;
using System.Management.Automation.Host;
using Microsoft.PowerShell.Commands;
using AIShell.Abstraction;

namespace AIShell.Integration.Commands;

[Alias("fixit")]
[Cmdlet(VerbsDiagnostic.Resolve, "Error")]
public class ResolveErrorCommand : PSCmdlet
{
    [Parameter]
    [ValidateNotNullOrEmpty]
    public string Agent { get; set; }

    [Parameter]
    public SwitchParameter IncludeOutputFromClipboard { get; set; }

    protected override void EndProcessing()
    {
        bool questionMarkValue = (bool)GetVariableValue("?");
        if (questionMarkValue)
        {
            WriteWarning("No error to resolve. The last command execution was successful.");
            return;
        }

        object value = GetVariableValue("LASTEXITCODE");
        int lastExitCode = value is null ? 0 : (int)value;

        using var pwsh = PowerShell.Create(RunspaceMode.CurrentRunspace);
        var results = pwsh
            .AddCommand("Get-History")
            .AddParameter("Count", 1)
            .Invoke<HistoryInfo>();

        if (results.Count is 0)
        {
            WriteWarning("No error to resolve. No command line has been executed yet.");
            return;
        }

        string query = null, context = null;
        HistoryInfo lastHistory = results[0];
        Channel channel = Channel.Singleton;
        string commandLine = lastHistory.CommandLine;

        if (TryGetLastError(lastHistory, out ErrorRecord lastError))
        {
            query = ErrorFeedback.CreateQueryForError(commandLine, lastError, channel);
        }
        else if (lastExitCode is 0)
        {
            // Cannot find the ErrorRecord associated with the last command, and no native command failure, so we don't know why '$?' was set to False.
            ErrorRecord error = new(
                new NotSupportedException($"Failed to detect the actual error even though '$?' is 'False'. No 'ErrorRecord' can be found that is associated with the last command line '{commandLine}' and no executable failure was found."),
                errorId: "FailedToDetectActualError",
                ErrorCategory.ObjectNotFound,
                targetObject: null);
            ThrowTerminatingError(error);
        }
        else
        {
            // '$? == False' but no 'ErrorRecord' can be found that is associated with the last command line,
            // and '$LASTEXITCODE' is non-zero, which indicates the last failed command is a native command.
            query = $"""
                Running the command line `{commandLine}` in PowerShell v{channel.PSVersion} failed.
                Please try to explain the failure and suggest the right fix.
                Output of the command line can be found in the context information below.
                """;

            context = ScrapeScreenForNativeCommandOutput(commandLine);
            if (context is null)
            {
                if (UseClipboardForCommandOutput())
                {
                    IncludeOutputFromClipboard = true;
                }
                else
                {
                    ThrowTerminatingError(new(
                        new NotSupportedException($"The output content is needed for suggestions on native executable failures."),
                        errorId: "OutputNeededForNativeCommand",
                        ErrorCategory.InvalidData,
                        targetObject: null
                    ));
                }
            }
        }

        if (context is null && IncludeOutputFromClipboard)
        {
            pwsh.Commands.Clear();
            var r = pwsh
                .AddCommand("Get-Clipboard")
                .AddParameter("Raw")
                .Invoke<string>();

            context = r?.Count > 0 ? r[0] : null;
        }

        channel.PostQuery(new PostQueryMessage(query, context, Agent));
    }

    private bool UseClipboardForCommandOutput()
    {
        if (IncludeOutputFromClipboard)
        {
            return true;
        }

        string query = "The last failed command is a native command that did not produce an ErrorRecord object.\nPlease \x1b[93mcopy its output and then press 'y'\x1b[0m to allow using the output as context information.";
        return ShouldContinue(query, caption: "Include output from the clipboard");
    }

    private bool TryGetLastError(HistoryInfo lastHistory, out ErrorRecord lastError)
    {
        lastError = null;
        ArrayList errors = (ArrayList)GetVariableValue("Error");
        if (errors.Count == 0)
        {
            return false;
        }

        lastError = errors[0] as ErrorRecord;
        if (lastError is null && errors[0] is RuntimeException rtEx)
        {
            lastError = rtEx.ErrorRecord;
        }

        if (lastError?.InvocationInfo is null || lastError.InvocationInfo.HistoryId != lastHistory.Id)
        {
            return false;
        }

        return true;
    }

    private string ScrapeScreenForNativeCommandOutput(string lastCommandLine)
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        try
        {
            PSHostRawUserInterface rawUI = Host.UI.RawUI;
            Coordinates start = new(0, 0), end = rawUI.CursorPosition;

            string currentCommandLine = MyInvocation.Line;
            end.X = rawUI.BufferSize.Width - 1;

            BufferCell[,] content = rawUI.GetBufferContents(new Rectangle(start, end));
            StringBuilder line = new(), buffer = new();

            bool collect = false;
            int rows = content.GetLength(0);
            int columns = content.GetLength(1);

            for (int row = 0; row < rows; row++)
            {
                line.Clear();
                for (int column = 0; column < columns; column++)
                {
                    line.Append(content[row, column].Character);
                }

                string lineStr = line.ToString().TrimEnd();
                if (!collect && IsStartOfCommand(lineStr, columns, lastCommandLine))
                {
                    collect = true;
                    buffer.Append(lineStr);
                    continue;
                }

                if (collect)
                {
                    // The current command line is just `Resolve-Error` or `fixit`, which should be on the same line
                    // and thus there is no need to check for the span-to-the-next-line case.
                    if (lineStr.EndsWith(currentCommandLine, StringComparison.Ordinal))
                    {
                        break;
                    }

                    buffer.Append('\n').Append(lineStr);
                }
            }

            return buffer.Length is 0 ? null : buffer.ToString();
        }
        catch
        {
            return null;
        }

        static bool IsStartOfCommand(string lineStr, int columns, string commandLine)
        {
            if (lineStr.EndsWith(commandLine, StringComparison.Ordinal))
            {
                return true;
            }

            // Handle the case where the command line is too long and spans to the next line on screen,
            // like az, gcloud, and aws CLI commands which are usually long with many parameters.
            if (columns - lineStr.Length > 3 || commandLine.Length < 20)
            {
                // The line on screen unlikely spanned to the next line in this case.
                return false;
            }

            // We check if the prefix of the command line is the suffix of the current line on screen.
            ReadOnlySpan<char> lineStrSpan = lineStr.AsSpan();
            ReadOnlySpan<char> cmdLineSpan = commandLine.AsSpan();

            // We assume the first 20 chars of the command line should be in the current line on screen.
            // This assumption is not perfect but practically good enough.
            int index = lineStrSpan.IndexOf(cmdLineSpan[..20], StringComparison.Ordinal);
            if (index >= 0 && cmdLineSpan.StartsWith(lineStrSpan[index..], StringComparison.Ordinal))
            {
                return true;
            }

            return false;
        }
    }
}

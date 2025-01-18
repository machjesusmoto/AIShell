using System.Runtime.InteropServices;
using System.Security;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using System.ClientModel.Primitives;

namespace AIShell.OpenAI.Agent;

/// <summary>
/// Static type that contains all utility methods.
/// </summary>
internal static class Utils
{
    internal const string ApimAuthorizationHeader = "Ocp-Apim-Subscription-Key";
    internal const string ApimGatewayDomain = ".azure-api.net";
    internal const string AzureOpenAIDomain = ".openai.azure.com";

    internal static readonly string OS;

    static Utils()
    {
        string rid = RuntimeInformation.RuntimeIdentifier;
        int index = rid.IndexOf('-');
        OS = index is -1 ? rid : rid[..index];
    }

    internal static string ConvertFromSecureString(SecureString secureString)
    {
        if (secureString is null || secureString.Length is 0)
        {
            return null;
        }

        nint ptr = IntPtr.Zero;

        try
        {
            ptr = Marshal.SecureStringToBSTR(secureString);
            return Marshal.PtrToStringBSTR(ptr);
        }
        finally
        {
            Marshal.ZeroFreeBSTR(ptr);
        }
    }

    internal static SecureString ConvertToSecureString(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return null;
        }

        var ss = new SecureString();
        foreach (char c in text)
        {
            ss.AppendChar(c);
        }

        return ss;
    }

    internal static bool IsEqualTo(this SecureString ss1, SecureString ss2)
    {
        if (ss1.Length != ss2.Length)
        {
            return false;
        }

        if (ss1.Length is 0)
        {
            return true;
        }

        string plain1 = ConvertFromSecureString(ss1);
        string plain2 = ConvertFromSecureString(ss2);
        return string.Equals(plain1, plain2, StringComparison.Ordinal);
    }
}

/// <summary>
/// <see cref="SecureString"/> converter for JSON serailization/de-serailization.
/// </summary>
internal class SecureStringJsonConverter : JsonConverter<SecureString>
{
    public override SecureString Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        string payload = reader.GetString();
        return Utils.ConvertToSecureString(payload);
    }

    public override void Write(Utf8JsonWriter writer, SecureString value, JsonSerializerOptions options)
    {
        string payload = Utils.ConvertFromSecureString(value);
        writer.WriteStringValue(payload);
    }
}

/// <summary>
/// The contract resolver for a GPT instance.
/// </summary>
internal class GPTContractResolver : DefaultJsonTypeInfoResolver
{
    private readonly bool _ignoreKey;
    internal GPTContractResolver(bool ignoreKey)
    {
        // Allow the key to be ignored during de-serailization.
        _ignoreKey = ignoreKey;
    }

    public override JsonTypeInfo GetTypeInfo(Type type, JsonSerializerOptions options)
    {
        JsonTypeInfo typeInfo = base.GetTypeInfo(type, options);

        if (_ignoreKey && typeInfo.Type == typeof(GPT))
        {
            int index = 0;
            for (; index < typeInfo.Properties.Count; index++)
            {
                if (typeInfo.Properties[index].Name is nameof(GPT.Key))
                {
                    break;
                }
            }

            typeInfo.Properties.RemoveAt(index);
        }

        return typeInfo;
    }
}

/// <summary>
/// Initializes a new instance of the <see cref="ChatRetryPolicy"/> class.
/// </summary>
/// <param name="maxRetries">The maximum number of retries to attempt.</param>
/// <param name="delayStrategy">The delay to use for computing the interval between retry attempts.</param>
internal sealed class ChatRetryPolicy(int maxRetries = 2) : ClientRetryPolicy(maxRetries)
{
    private const string RetryAfterHeaderName = "Retry-After";
    private const string RetryAfterMsHeaderName = "retry-after-ms";
    private const string XRetryAfterMsHeaderName = "x-ms-retry-after-ms";

    protected override bool ShouldRetry(PipelineMessage message, Exception exception) => ShouldRetryImpl(message, exception);
    protected override ValueTask<bool> ShouldRetryAsync(PipelineMessage message, Exception exception) => new(ShouldRetryImpl(message, exception));

    private bool ShouldRetryImpl(PipelineMessage message, Exception exception)
    {
        bool result = base.ShouldRetry(message, exception);

        if (result && message.Response is not null)
        {
            TimeSpan? retryAfter = GetRetryAfterHeaderValue(message.Response.Headers);
            if (retryAfter > TimeSpan.FromSeconds(5))
            {
                // Do not retry if the required interval is longer than 5 seconds.
                return false;
            }
        }

        return result;
    }

    private static TimeSpan? GetRetryAfterHeaderValue(PipelineResponseHeaders headers)
    {
        if (headers.TryGetValue(RetryAfterMsHeaderName, out var retryAfterValue) ||
            headers.TryGetValue(XRetryAfterMsHeaderName, out retryAfterValue))
        {
            if (int.TryParse(retryAfterValue, out var delayInMS))
            {
                return TimeSpan.FromMilliseconds(delayInMS);
            }
        }

        if (headers.TryGetValue(RetryAfterHeaderName, out retryAfterValue))
        {
            if (int.TryParse(retryAfterValue, out var delayInSec))
            {
                return TimeSpan.FromSeconds(delayInSec);
            }

            if (DateTimeOffset.TryParse(retryAfterValue, out DateTimeOffset delayTime))
            {
                return delayTime - DateTimeOffset.Now;
            }
        }

        return default;
    }
}

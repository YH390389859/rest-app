using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace Rest.App.Views;

/// <summary>false → 可见。用来「有壁纸时隐藏渐变底」这类互补显示。</summary>
public sealed class InverseBoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        => value is true ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>
/// 枚举 ↔ RadioButton 的 IsChecked，ConverterParameter 写枚举名。
/// 三选一的「休息结束后的行为」用它，比 ComboBox 更贴近 macOS 的 radioGroup。
/// </summary>
public sealed class EnumToBoolConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is null || parameter is not string name) return false;
        return string.Equals(value.ToString(), name, StringComparison.Ordinal);
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        // 只有被选中时才写回，取消选中由另一个 RadioButton 的选中事件覆盖
        if (value is true && parameter is string name && Enum.TryParse(targetType, name, out var parsed))
        {
            return parsed;
        }
        return Binding.DoNothing;
    }
}

/// <summary>把 true 变成「已授权」这类文案用的小工具。</summary>
public sealed class BoolToTextConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var parts = (parameter as string ?? "是|否").Split('|');
        var isTrue = value is true;
        return parts.Length >= 2 ? (isTrue ? parts[0] : parts[1]) : (isTrue ? "是" : "否");
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

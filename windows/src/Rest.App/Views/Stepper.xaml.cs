using System.Windows;
using System.Windows.Controls;

namespace Rest.App.Views;

/// <summary>
/// 数值步进器。macOS 版用 SwiftUI 的 <c>Stepper</c>，WPF 没有对应控件，
/// 这里用「− 数值 +」三个元素拼一个，同时把数值和文案分开（文案支持后缀单位）。
/// </summary>
public partial class Stepper : UserControl
{
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(Stepper),
        new FrameworkPropertyMetadata(0.0,
            FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, OnValueChanged));

    public static readonly DependencyProperty MinimumProperty = DependencyProperty.Register(
        nameof(Minimum), typeof(double), typeof(Stepper), new PropertyMetadata(0.0, OnValueChanged));

    public static readonly DependencyProperty MaximumProperty = DependencyProperty.Register(
        nameof(Maximum), typeof(double), typeof(Stepper), new PropertyMetadata(100.0, OnValueChanged));

    public static readonly DependencyProperty StepProperty = DependencyProperty.Register(
        nameof(Step), typeof(double), typeof(Stepper), new PropertyMetadata(1.0));

    public static readonly DependencyProperty SuffixProperty = DependencyProperty.Register(
        nameof(Suffix), typeof(string), typeof(Stepper), new PropertyMetadata(string.Empty, OnValueChanged));

    public Stepper()
    {
        InitializeComponent();
        UpdateDisplay();
    }

    public double Value
    {
        get => (double)GetValue(ValueProperty);
        set => SetValue(ValueProperty, value);
    }

    public double Minimum
    {
        get => (double)GetValue(MinimumProperty);
        set => SetValue(MinimumProperty, value);
    }

    public double Maximum
    {
        get => (double)GetValue(MaximumProperty);
        set => SetValue(MaximumProperty, value);
    }

    public double Step
    {
        get => (double)GetValue(StepProperty);
        set => SetValue(StepProperty, value);
    }

    public string Suffix
    {
        get => (string)GetValue(SuffixProperty);
        set => SetValue(SuffixProperty, value);
    }

    private static void OnValueChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        => ((Stepper)d).UpdateDisplay();

    private void UpdateDisplay()
    {
        if (ValueText is null) return;

        var rounded = Rest.Core.RestSettings.Round(Value);
        var number = Math.Abs(rounded - Math.Round(rounded)) < 0.001
            ? ((int)Math.Round(rounded)).ToString()
            : rounded.ToString("0.#");

        ValueText.Text = string.IsNullOrEmpty(Suffix) ? number : $"{number} {Suffix}";
    }

    private void OnMinusClick(object sender, RoutedEventArgs e) => Apply(-Step);

    private void OnPlusClick(object sender, RoutedEventArgs e) => Apply(Step);

    private void Apply(double delta)
    {
        var next = Math.Clamp(Value + delta, Minimum, Maximum);
        if (Math.Abs(next - Value) < 0.0001) return;
        Value = next;
    }
}

using System.Windows;
using System.Windows.Media;

namespace Rest.App.Views;

/// <summary>
/// 细线环形进度条（对应 SwiftUI 里 `Circle().trim(from:to:)` 那段）。
///
/// 为什么自己画而不是用两个 Ellipse + StrokeDashArray：虚线方案的起点在右侧、
/// 还要手算 dash 比例，进度接近 100% 时会有明显接缝；直接画圆弧最省事也最准。
/// </summary>
public sealed class ProgressRing : FrameworkElement
{
    public static readonly DependencyProperty ProgressProperty = DependencyProperty.Register(
        nameof(Progress), typeof(double), typeof(ProgressRing),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty ThicknessProperty = DependencyProperty.Register(
        nameof(Thickness), typeof(double), typeof(ProgressRing),
        new FrameworkPropertyMetadata(5.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty TrackBrushProperty = DependencyProperty.Register(
        nameof(TrackBrush), typeof(Brush), typeof(ProgressRing),
        new FrameworkPropertyMetadata(new SolidColorBrush(Color.FromArgb(33, 255, 255, 255)),
            FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty ProgressBrushProperty = DependencyProperty.Register(
        nameof(ProgressBrush), typeof(Brush), typeof(ProgressRing),
        new FrameworkPropertyMetadata(new SolidColorBrush(Color.FromArgb(235, 255, 255, 255)),
            FrameworkPropertyMetadataOptions.AffectsRender));

    /// <summary>0 到 1。</summary>
    public double Progress
    {
        get => (double)GetValue(ProgressProperty);
        set => SetValue(ProgressProperty, value);
    }

    public double Thickness
    {
        get => (double)GetValue(ThicknessProperty);
        set => SetValue(ThicknessProperty, value);
    }

    public Brush TrackBrush
    {
        get => (Brush)GetValue(TrackBrushProperty);
        set => SetValue(TrackBrushProperty, value);
    }

    public Brush ProgressBrush
    {
        get => (Brush)GetValue(ProgressBrushProperty);
        set => SetValue(ProgressBrushProperty, value);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var size = Math.Min(ActualWidth, ActualHeight);
        if (size <= 0) return;

        var thickness = Thickness;
        var radius = (size - thickness) / 2;
        if (radius <= 0) return;

        var center = new Point(ActualWidth / 2, ActualHeight / 2);

        // 底圈
        dc.DrawEllipse(null, new Pen(TrackBrush, thickness), center, radius, radius);

        var progress = Math.Clamp(Progress, 0, 1);
        if (progress <= 0.0001) return;

        if (progress >= 0.9999)
        {
            dc.DrawEllipse(null, new Pen(ProgressBrush, thickness), center, radius, radius);
            return;
        }

        // 12 点方向起画，顺时针
        var start = PointOnCircle(center, radius, -90);
        var end = PointOnCircle(center, radius, -90 + 360 * progress);
        var isLargeArc = progress > 0.5;

        var figure = new PathFigure { StartPoint = start, IsClosed = false, IsFilled = false };
        figure.Segments.Add(new ArcSegment(end, new Size(radius, radius), 0, isLargeArc,
            SweepDirection.Clockwise, isStroked: true));

        var geometry = new StreamGeometry();
        using (var ctx = geometry.Open())
        {
            ctx.BeginFigure(figure.StartPoint, isFilled: false, isClosed: false);
            ctx.ArcTo(end, new Size(radius, radius), 0, isLargeArc, SweepDirection.Clockwise,
                isStroked: true, isSmoothJoin: false);
        }
        geometry.Freeze();

        var pen = new Pen(ProgressBrush, thickness)
        {
            StartLineCap = PenLineCap.Round,
            EndLineCap = PenLineCap.Round,
        };
        dc.DrawGeometry(null, pen, geometry);
    }

    private static Point PointOnCircle(Point center, double radius, double angleDegrees)
    {
        var radians = angleDegrees * Math.PI / 180.0;
        return new Point(center.X + radius * Math.Cos(radians), center.Y + radius * Math.Sin(radians));
    }
}

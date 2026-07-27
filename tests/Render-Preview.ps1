[CmdletBinding()]
param([string]$OutputPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot 'artifacts\token-rader-preview.png'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[Windows.Media.RenderOptions]::ProcessRenderMode = [Windows.Interop.RenderMode]::SoftwareOnly
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$paths = Get-TokenRaderPaths -ProjectRoot $projectRoot
$prices = Get-TokenRaderPrices -PricingPath $paths.PricingPath
$session = [pscustomobject]@{
    ShortId = 'demo5c84'
    DisplayName = '07-14 10:30   demo5c84   680 KB'
    FilePath = 'synthetic-preview.jsonl'
}
$project = [pscustomobject]@{
    ProjectName = 'Demo Project'
    ProjectPath = 'C:\demo\Demo Project'
    DisplayName = 'Demo Project  ·  1 个日志'
}
$model = 'gpt-5.6-sol'
$usage = [pscustomobject]@{
    Cached = [Int64]2480000
    Uncached = [Int64]320000
    Input = [Int64]2800000
    Output = [Int64]42000
    Total = [Int64]2842000
    CacheHitRate = [double]88.5714286
}
$cost = Get-TokenRaderCost -Usage $usage -Model $model -PricingDocument $prices -Scope task

[xml]$xaml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'MainWindow.xaml')
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.Width = 1280
$window.Height = 840
$window.WindowStartupLocation = 'Manual'
$window.Left = 20
$window.Top = 20
$window.ShowInTaskbar = $false

$window.FindName('AccountNameText').Text = 'demo@example.local'
$window.FindName('AccountIdText').Text = 'acct_demo…000001'
$window.FindName('PlanText').Text = '计划快照：team'
$window.FindName('AccountHintText').Text = '预览图使用合成数据，不含真实账号或日志内容。'
$window.FindName('IntervalStatusText').Text = '已完成'
$window.FindName('IntervalTimeText').Text = '10:00:00 — 10:25:00 · 共 25 分 0 秒'
$window.FindName('StartMeasureButton').IsEnabled = $true
$window.FindName('StopMeasureButton').IsEnabled = $false
$window.FindName('ViewIntervalButton').IsEnabled = $true
$window.FindName('FiveHourUsageText').Text = '25%'
$window.FindName('FiveHourProgress').Value = 25
$window.FindName('FiveHourResetText').Text = '重置 07-14 15:00'
$window.FindName('FiveHourDollarText').Text = '总额≈$20.00 · 已用≈$5.00 · 剩余≈$15.00'
$window.FindName('WeeklyUsageText').Text = '44%'
$window.FindName('WeeklyProgress').Value = 44
$window.FindName('WeeklyResetText').Text = '重置 07-20 10:00'
$window.FindName('WeeklyDollarText').Text = '总额≈$50.00 · 已用≈$22.00 · 剩余≈$28.00'
$window.FindName('QuotaEstimateHintText').Text = '按本次 API 等价成本与额度增量反推：5 小时 +2%，周 +1%。'
$window.FindName('SessionCountText').Text = '1 个合成日志'
$window.FindName('ProjectComboBox').ItemsSource = @($project)
$window.FindName('ProjectComboBox').SelectedIndex = 0
$window.FindName('SessionListBox').ItemsSource = @($session)
$window.FindName('SessionListBox').SelectedIndex = 0
$window.FindName('SelectedSessionText').Text = '全部项目 · 指定时间段消耗'
$window.FindName('UpdatedText').Text = '10:00:00 → 10:25:00 · 25 分 0 秒 · 1 个活跃会话'
$window.FindName('ScopeBadgeText').Text = '全部项目时间段'
$window.FindName('ModelMetricText').Text = $model
$window.FindName('CachedMetricText').Text = Format-TokenRaderNumber $usage.Cached
$window.FindName('UncachedMetricText').Text = Format-TokenRaderNumber $usage.Uncached
$window.FindName('OutputMetricText').Text = Format-TokenRaderNumber $usage.Output
$window.FindName('TotalMetricText').Text = Format-TokenRaderNumber $usage.Total
$window.FindName('HitRateMetricText').Text = ('{0:0.0}%' -f $usage.CacheHitRate)
$window.FindName('HitRateProgress').Value = $usage.CacheHitRate
$window.FindName('PricingVerifiedText').Text = 'USD / 1M tokens · 官方页面核对于 ' + $prices.verifiedAt
if ($cost.Known) {
    $window.FindName('UsdCostText').Text = Format-TokenRaderUsd $cost.TotalCost
    $window.FindName('CostBreakdownText').Text = ('未缓存 {0} · 缓存 {1} · 输出 {2}' -f (Format-TokenRaderUsd $cost.InputCost), (Format-TokenRaderUsd $cost.CachedCost), (Format-TokenRaderUsd $cost.OutputCost))
    $window.FindName('InputPriceText').Text = '$' + ([double]$cost.Price.input).ToString('0.###')
    $window.FindName('CachedPriceText').Text = '$' + ([double]$cost.Price.cachedInput).ToString('0.###')
    $window.FindName('OutputPriceText').Text = '$' + ([double]$cost.Price.output).ToString('0.###')
}
$window.FindName('PricingDataGrid').ItemsSource = @($prices.models | ForEach-Object {
    [pscustomobject]@{
        Model = $_.displayName
        Input = '$' + ([double]$_.input).ToString('0.###')
        Cached = '$' + ([double]$_.cachedInput).ToString('0.###')
        Output = '$' + ([double]$_.output).ToString('0.###')
    }
})
$window.FindName('StatusText').Text = '可视化验证预览 · SYNTHETIC DATA'

$directory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$window.Show()
$window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Loaded)
$window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
Start-Sleep -Milliseconds 350
$window.UpdateLayout()
$window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
$bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap(
    [int][Math]::Ceiling($window.ActualWidth),
    [int][Math]::Ceiling($window.ActualHeight),
    96, 96,
    [Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($window)
$encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$fileStream = [IO.File]::Open($OutputPath, [IO.FileMode]::Create)
try { $encoder.Save($fileStream) } finally { $fileStream.Dispose() }
$window.Close()
Write-Output $OutputPath

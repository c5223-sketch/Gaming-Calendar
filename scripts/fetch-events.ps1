# Fetches in-game event schedules and writes data/events.json + calendar.ics.
# Runs on Windows PowerShell 5.1 and PowerShell 7 (GitHub Actions).
# Keep this file ASCII-only: all Japanese text lives in data/games.json
# (regexes below use \uXXXX escapes for the same reason).
param([switch]$ShowSkipped)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding $false
$inv = [System.Globalization.CultureInfo]::InvariantCulture
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

function Read-Text($path) { [System.IO.File]::ReadAllText($path, $utf8) }
function Write-Text($path, $text) { [System.IO.File]::WriteAllText($path, $text, $utf8) }

function Get-Page($url) {
  $wc = New-Object System.Net.WebClient
  $wc.Encoding = [System.Text.Encoding]::UTF8
  $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (gaming-calendar; personal event reminder)')
  try { return $wc.DownloadString($url) } finally { $wc.Dispose() }
}
function Get-Json($url) { return (Get-Page $url | ConvertFrom-Json) }

function Clean-Title($s) {
  if (-not $s) { return '' }
  $t = [regex]::Replace([string]$s, '<[^>]+>', ' ')
  $t = [System.Net.WebUtility]::HtmlDecode($t)
  return ([regex]::Replace($t, '\s+', ' ')).Trim()
}

function Get-ShortHash($s) {
  $md5 = [System.Security.Cryptography.MD5]::Create()
  try { return (-join ($md5.ComputeHash($utf8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 10) }
  finally { $md5.Dispose() }
}

function New-Utc($year, $month, $day, $hour, $minute, $tzHours) {
  # Hours like 24:00 or 27:59 appear on Japanese game sites; let AddHours roll them over.
  $d = (New-Object datetime($year, $month, $day, 0, 0, 0)).AddHours($hour).AddMinutes($minute)
  return (New-Object System.DateTimeOffset($d, [timespan]::FromHours($tzHours))).UtcDateTime
}

# ---------------- HoYoverse in-game announcements ----------------
function Get-HoyoverseEvents($game) {
  $res = Get-Json $game.source.url
  if ($res.retcode -ne 0) { throw "retcode $($res.retcode): $($res.message)" }
  $tz = [double]$res.data.timezone

  # Some of these endpoints are served by backends in different regions that each
  # format times in their own local zone while still reporting the same "timezone".
  # The Asia backend (the zone we assume) is the furthest ahead, so sample a few
  # times and keep the latest wall-clock value seen for each announcement.
  $latest = @{}
  $samples = @($res)
  for ($n = 1; $n -lt [int]$game.source.samples; $n++) {
    Start-Sleep -Milliseconds 250
    try { $samples += Get-Json "$($game.source.url)&_=$n" } catch { }
  }
  foreach ($sample in $samples) {
    $rows = @()
    foreach ($group in @($sample.data.list)) { $rows += @($group.list) }
    foreach ($group in @($sample.data.pic_list)) { foreach ($sub in @($group.type_list)) { $rows += @($sub.list) } }
    foreach ($a in $rows) {
      if (-not $a -or -not $a.start_time) { continue }
      $id = [string]$a.ann_id
      # "yyyy-MM-dd HH:mm:ss" sorts correctly as an ordinal string.
      if (-not $latest.ContainsKey($id) -or [string]::CompareOrdinal($a.start_time, $latest[$id].start) -gt 0) { $latest[$id] = @{ start = $a.start_time; end = $a.end_time } }
    }
  }

  # Announcement bodies tell us whether the event pays out premium currency.
  $bodies = @{}
  try {
    $content = Get-Json ($game.source.url -replace 'getAnnList', 'getAnnContent')
    foreach ($c in @($content.data.list) + @($content.data.pic_list)) { if ($c) { $bodies[[string]$c.ann_id] = [string]$c.content } }
  } catch { Write-Warning "$($game.id): announcement bodies unavailable ($($_.Exception.Message))" }

  $raw = @()
  foreach ($group in @($res.data.list)) { $raw += @($group.list) }
  foreach ($group in @($res.data.pic_list)) {
    foreach ($sub in @($group.type_list)) { $raw += @($sub.list) }
  }
  $out = @()
  foreach ($a in $raw) {
    if (-not $a -or -not $a.end_time -or -not $a.start_time) { continue }
    $img = $a.banner
    if (-not $img) { $img = $a.img }
    $s = [datetime]::ParseExact($latest[[string]$a.ann_id].start, 'yyyy-MM-dd HH:mm:ss', $inv)
    $e = [datetime]::ParseExact($latest[[string]$a.ann_id].end, 'yyyy-MM-dd HH:mm:ss', $inv)
    $out += [pscustomobject]@{
      key   = [string]$a.ann_id
      title = Clean-Title $a.title
      start = (New-Object System.DateTimeOffset($s, [timespan]::FromHours($tz))).UtcDateTime
      end   = (New-Object System.DateTimeOffset($e, [timespan]::FromHours($tz))).UtcDateTime
      image = [string]$img
      url   = ''
      text  = Clean-Title $bodies[[string]$a.ann_id]
    }
  }
  return $out
}

# ---------------- Generic "find date ranges in a web page" ----------------
# Matches e.g.  2026<nen>11<gatsu>7<nichi>(Sat)12:00 ~ 11<gatsu>25<nichi>(Wed)11:59   and   11/01(Sun)00:00 ~ 11/30(Mon)23:59
$ymd = '(?:(\d{4})[\u5E74/])?(\d{1,2})[\u6708/](\d{1,2})\u65E5?'
$weekday = '\s*[\(\uFF08][^\)\uFF09]{1,3}[\)\uFF09]'
$hm = '(\d{1,2})[:\uFF1A](\d{2})'
# Start time may be "after maintenance" instead of a clock time.
$startTime = '(?:' + $hm + '|\u30E1\u30F3\u30C6\u30CA\u30F3\u30B9\u5F8C)'
$sep = '\s*(?:[\uFF5E\u301C~-]|\u304B\u3089)\s*'
$strictRx = New-Object regex ($ymd + $weekday + '\s*' + $startTime + $sep + $ymd + $weekday + '\s*' + $hm)
# Loose form: weekday optional ("11/16 12:00 ~ 12/21 11:59"). Only for sites that write ranges that way.
$looseRx = New-Object regex ($ymd + '(?:' + $weekday + ')?\s*' + $startTime + $sep + $ymd + '(?:' + $weekday + ')?\s*' + $hm)
$periodRx = $strictRx
$junkLabelRx = New-Object regex '^[\u2192\u203B\u25CE\u30FB]|\u3002$|\u66F4\u65B0|^\[|\u3053\u3061\u3089'
$genericLabelRx = New-Object regex '^[\u3010\[\u300C]?.{0,8}(\u671F\u9593|\u65E5\u6642|\u6982\u8981)[\u3011\]\u300D]?(\(.{1,8}\))?[\u2460-\u2469]?$'
$headingMark = [char]1
$trimChars = @([char]0x25BC, [char]0x25A0, [char]0x25C6, [char]0xFF1C, [char]0xFF1E, [char]0x226A, [char]0x226B, [char]0xFF1A, [char]0x25CF, [char]0x30FB, ':', ' ')
function Test-BadLabel($label) {
  return ($label.Length -lt 3 -or $label.Length -gt 70 -or $junkLabelRx.IsMatch($label) -or $genericLabelRx.IsMatch($label))
}

function Get-PageLines($html) {
  $t = [regex]::Replace($html, '(?s)<(script|style|noscript)\b.*?</\1>', '')
  # Mark headings with a leading "#" control marker so section titles can be found later.
  $t = [regex]::Replace($t, '<h[1-6]\b[^>]*>', "`n$headingMark")
  $t = [regex]::Replace($t, '<[^>]+>', "`n")
  $t = [System.Net.WebUtility]::HtmlDecode($t)
  $lines = @($t -split "`n" | ForEach-Object { ([regex]::Replace($_, '[ \t\r\u00A0\u3000]+', ' ')).Trim() } | Where-Object { $_ })
  # A heading whose text sits inside a nested tag leaves the marker alone on its line: move it to the next line.
  $out = New-Object System.Collections.Generic.List[string]
  $pending = $false
  foreach ($l in $lines) {
    if ($l -eq "$headingMark") { $pending = $true; continue }
    if ($pending -and -not $l.StartsWith("$headingMark")) { $l = "$headingMark$l" }
    $pending = $false
    $out.Add($l)
  }
  return , $out.ToArray()
}
function Remove-Mark($s) { return ([string]$s).TrimStart($headingMark).Trim() }

# $baseDate supplies the year when the page omits it (picks the year closest to $baseDate).
function Get-PagePeriods($lines, $pageTitle, $baseDate, $tzHours) {
  $out = @()
  $seen = @{}
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $m = $periodRx.Match($lines[$i])
    if (-not $m.Success) { continue }
    $sm = [int]$m.Groups[2].Value; $sd = [int]$m.Groups[3].Value
    $em = [int]$m.Groups[7].Value; $ed = [int]$m.Groups[8].Value
    try {
      if ($m.Groups[1].Success) { $sy = [int]$m.Groups[1].Value }
      else {
        $sy = $baseDate.Year
        $best = [double]::MaxValue
        foreach ($y in ($baseDate.Year - 1), $baseDate.Year, ($baseDate.Year + 1)) {
          $gap = [math]::Abs(((New-Object datetime($y, $sm, $sd)) - $baseDate).TotalDays)
          if ($gap -lt $best) { $best = $gap; $sy = $y }
        }
      }
      # No clock time means "after maintenance": assume late afternoon.
      $sh = if ($m.Groups[4].Success) { [int]$m.Groups[4].Value } else { 16 }
      $smin = if ($m.Groups[5].Success) { [int]$m.Groups[5].Value } else { 0 }
      $start = New-Utc $sy $sm $sd $sh $smin $tzHours
      $ey = if ($m.Groups[6].Success) { [int]$m.Groups[6].Value } else { $sy }
      $end = New-Utc $ey $em $ed ([int]$m.Groups[9].Value) ([int]$m.Groups[10].Value) $tzHours
      if (-not $m.Groups[6].Success -and $end -lt $start) { $end = New-Utc ($ey + 1) $em $ed ([int]$m.Groups[9].Value) ([int]$m.Groups[10].Value) $tzHours }
    } catch { continue }
    if ($end -le $start) { continue }

    # Label = nearest preceding line that is not itself a date range.
    $j = $i - 1
    while ($j -ge 0 -and $periodRx.IsMatch($lines[$j])) { $j-- }
    $label = if ($j -ge 0) { (Remove-Mark $lines[$j]).Trim($trimChars) } else { '' }
    $prefix = $lines[$i].Substring(0, $m.Index)
    $mark = [regex]::Match($prefix, '[\u2460-\u2469]').Value
    $sectionStart = $j
    if (Test-BadLabel $label) {
      # Generic label such as "Period": fall back to the section heading above it, then to the page title.
      $label = $pageTitle
      for ($k = $j - 1; $k -ge [math]::Max(0, $j - 40); $k--) {
        if (-not $lines[$k].StartsWith("$headingMark")) { continue }
        $cand = (Remove-Mark $lines[$k]).Trim($trimChars)
        if (-not (Test-BadLabel $cand)) { $label = $cand; $sectionStart = $k }
        break
      }
    }
    # A short section label alone ("Login bonus") is hard to place, so lead with the article title.
    $title = if ($label -ne $pageTitle -and $label.Length -le 14 -and $pageTitle) { "$pageTitle" + [char]0xFF5C + "$label$mark" } else { $label + $mark }

    $key ="$title|$($start.Ticks)|$($end.Ticks)"
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true

    # Text around the range, used to detect currency rewards.
    $from = [math]::Max(0, [math]::Min($j - 4, $sectionStart))
    $to = [math]::Min($lines.Count - 1, $i + 14)
    for ($k = $i + 1; $k -le $to; $k++) { if ($periodRx.IsMatch($lines[$k])) { $to = $k - 1; break } }
    $out += [pscustomobject]@{ title = $title; label = $label; start = $start; end = $end; text = ($lines[$from..$to] -join ' ') }
  }
  return $out
}

function Convert-PageToEvents($html, $url, $pageTitle, $baseDate, $image, $bodyRx) {
  if ($bodyRx) {
    $bm = [regex]::Match($html, $bodyRx)
    if ($bm.Success) { $html = $bm.Value }
  }
  $out = @()
  foreach ($p in @(Get-PagePeriods (Get-PageLines $html) $pageTitle $baseDate 9) | Select-Object -First 14) {
    $out += [pscustomobject]@{
      key = Get-ShortHash "$url|$($p.title)|$($p.start.Ticks)"
      title = $p.title; label = $p.label; start = $p.start; end = $p.end; image = $image; url = $url; text = $p.text
    }
  }
  return $out
}

# ---------------- Monster Strike official news ----------------
function Get-MonstEvents($game) {
  $src = $game.source
  $today = [datetime]::UtcNow.AddHours(9).Date
  $pages = [ordered]@{}
  foreach ($list in $src.lists) {
    $html = Get-Page ($src.base + $list)
    foreach ($m in [regex]::Matches($html, 'href="(/news/(\d{8})[^"]*\.html)" class="news-item__link" data-tracking="[^,]*,[^,]*,([^"]*)"')) {
      $date = [datetime]::ParseExact($m.Groups[2].Value, 'yyyyMMdd', $inv)
      if (($today - $date).TotalDays -gt $src.maxAgeDays) { continue }
      if (-not $pages.Contains($m.Groups[1].Value)) { $pages[$m.Groups[1].Value] = @{ date = $date; title = Clean-Title $m.Groups[3].Value } }
    }
    Start-Sleep -Milliseconds 300
  }
  $out = @()
  foreach ($path in @($pages.Keys) | Select-Object -First $src.maxPages) {
    $url = $src.base + $path
    try { $html = Get-Page $url } catch { Write-Warning "monst: $path skipped ($($_.Exception.Message))"; continue }
    $img = [regex]::Match($html, '<meta property="og:image" content="([^"]+)"').Groups[1].Value
    $out += @(Convert-PageToEvents $html $url $pages[$path].title $pages[$path].date $img '(?s)<article.*?</article>')
    Start-Sleep -Milliseconds 300
  }
  return $out
}

# ---------------- Puzzle & Dragons official site ----------------
function Get-PadEvents($game) {
  $src = $game.source
  $top = Get-Json ($src.base + $src.index)
  $pages = [ordered]@{}
  foreach ($it in @($top.latest) + @($top.slider)) {
    if (-not $it -or -not $it.link -or $it.link -notmatch '^/member/' -or $it.link -match $src.skip) { continue }
    if ($pages.Contains($it.link)) { continue }
    $date = [datetime]::UtcNow.AddHours(9).Date
    if ($it.update) { try { $date = [datetime]::ParseExact($it.update, 'yyyy.MM.dd', $inv) } catch { } }
    $pages[$it.link] = @{ date = $date; title = Clean-Title $it.alt; image = if ($it.bnr) { $src.base + ($it.bnr -replace '\?.*$', '') } else { '' } }
  }
  $out = @()
  foreach ($path in $pages.Keys) {
    $url = $src.base + $path
    try { $html = Get-Page $url } catch { Write-Warning "pad: $path skipped ($($_.Exception.Message))"; continue }
    $out += @(Convert-PageToEvents $html $url $pages[$path].title $pages[$path].date $pages[$path].image $null)
    Start-Sleep -Milliseconds 300
  }
  return $out
}

# ---------------- Generic official-news source ----------------
# Reads a news list (HTML links or a JSON API), then scans each article for date ranges.
function Get-PathValue($obj, $path) {
  foreach ($p in ("$path" -split '\.')) { if ($null -eq $obj) { return $null }; $obj = $obj.$p }
  return $obj
}
function Convert-AnyDate($v, $fallback) {
  $s = "$v"
  if ($s -match '^\d{12,13}$') { return (New-Object datetime(1970, 1, 1)).AddMilliseconds([double]$s).AddHours(9).Date }
  if ($s -match '^(\d{4})\D(\d{1,2})\D(\d{1,2})') { return New-Object datetime([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) }
  return $fallback
}
function Get-ArticleEvents($game) {
  $src = $game.source
  $today = [datetime]::UtcNow.AddHours(9).Date
  $maxAge = if ($src.maxAgeDays) { $src.maxAgeDays } else { 45 }
  $maxPages = if ($src.maxPages) { $src.maxPages } else { 25 }
  $entries = [ordered]@{}
  foreach ($listUrl in @($src.listUrls)) {
    if ($src.rows) {
      foreach ($row in @(Get-PathValue (Get-Json $listUrl) $src.rows)) {
        if (-not $row) { continue }
        $id = [string]$row.($src.id)
        $url = "$($src.url)".Replace('{id}', $id)
        $key = "$id"
        if ($entries.Contains($key)) { continue }
        $entries[$key] = @{
          url = $url; title = Clean-Title $row.($src.title); date = Convert-AnyDate $row.($src.date) $today
          html = if ($src.content) { [string]$row.($src.content) } else { $null }
          detail = if ($src.detailUrl) { "$($src.detailUrl)".Replace('{id}', $id) } else { $null }
          image = if ($src.image) { [string]$row.($src.image) } else { '' }
        }
      }
    } else {
      $html = Get-Page $listUrl
      foreach ($m in [regex]::Matches($html, $src.linkPattern)) {
        $url = $m.Groups['url'].Value
        if ($url.StartsWith('/')) { $url = $src.base + $url }
        if ($entries.Contains($url)) { continue }
        $entries[$url] = @{ url = $url; title = Clean-Title $m.Groups['title'].Value; date = Convert-AnyDate $m.Groups['date'].Value $today; html = $null; detail = $null; image = '' }
      }
    }
    Start-Sleep -Milliseconds 300
  }
  $script:periodRx = if ($src.loose) { $looseRx } else { $strictRx }
  $out = @()
  try {
    $n = 0
    foreach ($e in $entries.Values) {
      if (($today - $e.date).TotalDays -gt $maxAge) { continue }
      if (++$n -gt $maxPages) { break }
      $html = $e.html
      $body = $src.bodyPattern
      try {
        if ($e.detail) { $html = [string](Get-PathValue (Get-Json $e.detail) $src.detailPath); Start-Sleep -Milliseconds 300 }
        elseif ($null -eq $html) {
          $html = Get-Page $e.url
          Start-Sleep -Milliseconds 300
          if (-not $e.title) {
            $t = [regex]::Match($html, '<meta property="og:title" content="([^"]+)"').Groups[1].Value
            if (-not $t) { $t = [regex]::Match($html, '(?s)<title[^>]*>(.*?)</title>').Groups[1].Value }
            $e.title = Clean-Title $t
          }
          if (-not $e.image) { $e.image = [regex]::Match($html, '<meta property="og:image" content="([^"]+)"').Groups[1].Value }
          if (-not $body) { $body = '(?s)<(article|main)\b.*</\1>' }
        }
      } catch { Write-Warning "$($game.id): $($e.url) skipped ($($_.Exception.Message))"; continue }
      if ($src.titleTrim) { $e.title = ([regex]::Replace($e.title, $src.titleTrim, '')).Trim() }
      if ($e.image -notmatch '^https://') { $e.image = '' }
      $out += @(Convert-PageToEvents $html $e.url $e.title $e.date $e.image $body)
    }
  } finally { $script:periodRx = $strictRx }
  return $out
}

# ---------------- Project SEKAI (community-maintained master data mirror) ----------------
function Get-SekaiEvents($game) {
  $src = $game.source
  $epoch = New-Object datetime(1970, 1, 1)
  $out = @()
  foreach ($set in @(@{ file = 'events.json'; end = 'aggregateAt'; cat = 'event'; reward = $true }, @{ file = 'gachas.json'; end = 'endAt'; cat = 'gacha'; reward = $false })) {
    foreach ($row in @(Get-Json ($src.base + $set.file))) {
      if (-not $row.startAt -or -not $row.($set.end)) { continue }
      $start = $epoch.AddMilliseconds([double]$row.startAt)
      $end = $epoch.AddMilliseconds([double]$row.($set.end))
      if ($end -le [datetime]::UtcNow -or ($end - $start).TotalDays -gt 70 -or $row.name -match $src.skip) { continue }
      $out += [pscustomobject]@{
        key = "$($set.cat)-$($row.id)"; title = Clean-Title $row.name; start = $start; end = $end
        image = ''; url = ''; text = ''; cat = $set.cat; reward = $set.reward
      }
    }
  }
  return $out
}

# ---------------- Rule-based recurring content (e.g. monthly resets) ----------------
function Get-RecurringEvents($game, $now) {
  $out = @()
  foreach ($r in @($game.recurring)) {
    if (-not $r) { continue }
    $local = $now.AddHours($r.tz)
    $start = New-Utc $local.Year $local.Month $r.day $r.hour 0 $r.tz
    if ($start -gt $now) { $start = New-Utc $local.AddMonths(-1).Year $local.AddMonths(-1).Month $r.day $r.hour 0 $r.tz }
    $next = $start.AddHours($r.tz).AddMonths(1)
    $end = New-Utc $next.Year $next.Month $r.day $r.hour 0 $r.tz
    $out += [pscustomobject]@{
      key = "$($r.key)-$($start.AddHours($r.tz).ToString('yyyyMM'))"
      title = $r.title; start = $start; end = $end; image = ''; url = ''; text = ''; cat = $r.cat; reward = $true
    }
  }
  return $out
}

# ---------------- main ----------------
$config = Read-Text (Join-Path $root 'data/games.json') | ConvertFrom-Json
$outPath = Join-Path $root 'data/events.json'
$previous = @()
if (Test-Path $outPath) { $previous = @((Read-Text $outPath | ConvertFrom-Json).events) }

$now = [datetime]::UtcNow
$events = @()
$failed = @()

foreach ($game in $config.games) {
  $exclude = if ($game.exclude) { $game.exclude } else { $config.defaults.exclude }
  $maxDays = if ($game.maxDays) { $game.maxDays } else { $config.defaults.maxDays }
  $rules = @($game.rules) + @($config.defaults.rules) | Where-Object { $_ }
  $recurring = @(Get-RecurringEvents $game $now)
  try {
    switch ($game.source.type) {
      'hoyoverse' { $items = @(Get-HoyoverseEvents $game) }
      'monst' { $items = @(Get-MonstEvents $game) }
      'pad' { $items = @(Get-PadEvents $game) }
      'articles' { $items = @(Get-ArticleEvents $game) }
      'sekai' { $items = @(Get-SekaiEvents $game) }
      default { throw "unknown source type '$($game.source.type)'" }
    }
  } catch {
    Write-Warning "$($game.id): fetch failed, keeping previous data ($($_.Exception.Message))"
    $failed += $game.id
    $events += @($previous | Where-Object { $_.game -eq $game.id })
    continue
  }
  $seen = @{}
  $kept = 0
  foreach ($it in $recurring + $items) {
    $isRule = [bool]$it.cat
    $skip = $null
    # The same event is often announced on several pages: one entry per title + period.
    $same = "$($it.title)|$($it.start.Ticks)|$($it.end.Ticks)"
    if ($seen.ContainsKey($it.key) -or $seen.ContainsKey($same)) { $skip = 'duplicate' }
    elseif (-not $it.title) { $skip = 'no title' }
    elseif ($it.end -le $now) { $skip = 'ended' }
    elseif (-not $isRule -and ($it.end - $it.start).TotalDays -gt $maxDays) { $skip = 'too long' }
    elseif (-not $isRule -and $it.title -match $exclude) { $skip = 'excluded' }
    elseif (-not $isRule -and $game.source.futureDays -and $it.start -gt $now.AddDays($game.source.futureDays)) { $skip = 'too far ahead' }
    if ($skip) {
      if ($ShowSkipped) { Write-Host "  skip [$skip] $($game.id) $($it.key)" }
      continue
    }
    $seen[$it.key] = $true
    $seen[$same] = $true
    $kept++
    $startIso = $it.start.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
    $endIso = $it.end.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
    if ($game.source.samples) {
      # Second guard for the region mix-up above: if every sample came from a
      # non-Asia backend, times land exactly 6/7/12/13 hours early. Trust the stored value then.
      $old = $previous | Where-Object { $_.id -eq "$($game.id)-$($it.key)" } | Select-Object -First 1
      if ($old) {
        $oldStart = [datetime]::ParseExact($old.start, 'yyyy-MM-ddTHH:mm:ssZ', $inv, [System.Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal')
        if (@(6, 7, 12, 13) -contains ($oldStart - $it.start).TotalHours) { $startIso = $old.start; $endIso = $old.end }
      }
    }
    $cat = $it.cat
    if (-not $cat) {
      $cat = $config.defaults.fallbackCategory
      # Classify by the section label first; the article title is only context
      # ("Collab event | Starter pack" is a pack, not an event).
      $matched = $false
      foreach ($text in @($it.label, $it.title)) {
        if (-not $text -or $matched) { continue }
        foreach ($r in $rules) { if ($text -match $r.pattern) { $cat = $r.cat; $matched = $true; break } }
      }
    }
    # "reward" = worth doing for premium currency: endgame content always, others when the text mentions it.
    $reward = [bool]$it.reward
    if (-not $reward -and $cat -ne 'gacha' -and $cat -ne 'shop') {
      $reward = ($cat -eq 'endgame') -or ($game.currency -and ("$($it.title) $($it.text)" -match $game.currency))
    }
    $events += [pscustomobject]@{
      id     = "$($game.id)-$($it.key)"
      game   = $game.id
      title  = $it.title
      cat    = $cat
      reward = [bool]$reward
      start  = $startIso
      end    = $endIso
      image  = $it.image
      url    = $it.url
    }
  }
  Write-Host "$($game.id): $kept events (of $($items.Count + $recurring.Count) candidates)"
}

$events = @($events | Sort-Object end, id)
$games = @($config.games | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; color = $_.color; currency = $_.currency } })
$doc = [pscustomobject]@{
  updatedAt  = $now.ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
  failed     = $failed
  categories = @($config.categories)
  games      = $games
  events     = $events
}
Write-Text $outPath (ConvertTo-Json -InputObject $doc -Depth 6)

# ---- calendar.ics (deadline markers; subscribe to it from Google Calendar) ----
function Escape-Ics($s) {
  return ([string]$s).Replace('\', '\\').Replace(';', '\;').Replace(',', '\,').Replace("`n", '\n')
}
function Fold-Ics($line) {
  # RFC 5545: lines are at most 75 octets; never split inside a UTF-8 sequence.
  $sb = New-Object System.Text.StringBuilder
  $count = 0
  $i = 0
  while ($i -lt $line.Length) {
    $len = if ([char]::IsHighSurrogate($line[$i]) -and $i + 1 -lt $line.Length) { 2 } else { 1 }
    $piece = $line.Substring($i, $len)
    $bytes = $utf8.GetByteCount($piece)
    if ($count + $bytes -gt 73) { [void]$sb.Append("`r`n "); $count = 1 }
    [void]$sb.Append($piece)
    $count += $bytes
    $i += $len
  }
  return $sb.ToString()
}

# The calendar feed carries what the app shows by default: default-on categories only.
$defaultCats = @{}
foreach ($c in $config.categories) { if ($c.defaultOn) { $defaultCats[$c.id] = $true } }
$nameById = @{}
foreach ($g in $config.games) { $nameById[$g.id] = $g.name }
$stamp = $now.ToString('yyyyMMddTHHmmssZ', $inv)
$lines = @(
  'BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//gaming-calendar//JA', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
  ('X-WR-CALNAME:' + (Escape-Ics $config.ics.name))
)
$icsCount = 0
foreach ($e in $events) {
  if (-not $defaultCats.ContainsKey($e.cat)) { continue }
  $icsCount++
  $end = [datetime]::ParseExact($e.end, 'yyyy-MM-ddTHH:mm:ssZ', $inv, [System.Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal')
  $summary = $config.ics.summaryFormat.Replace('{game}', [string]$nameById[$e.game]).Replace('{title}', $e.title)
  $lines += @(
    'BEGIN:VEVENT',
    "UID:$($e.id)@gaming-calendar",
    "DTSTAMP:$stamp",
    ('DTSTART:' + $end.AddMinutes(-30).ToString('yyyyMMddTHHmmssZ', $inv)),
    ('DTEND:' + $end.ToString('yyyyMMddTHHmmssZ', $inv)),
    ('SUMMARY:' + (Escape-Ics $summary))
  )
  if ($e.url) { $lines += ('URL:' + $e.url) }
  $lines += @('TRANSP:TRANSPARENT', 'END:VEVENT')
}
$lines += 'END:VCALENDAR'
Write-Text (Join-Path $root 'calendar.ics') ((($lines | ForEach-Object { Fold-Ics $_ }) -join "`r`n") + "`r`n")

Write-Host "wrote $($events.Count) events -> data/events.json ($icsCount in calendar.ics)"
if ($failed.Count -gt 0 -and $failed.Count -eq @($config.games).Count) { exit 1 }

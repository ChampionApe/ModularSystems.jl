# Detached runs

Anything past a few minutes — a solver benchmark, a sweep over model sizes, a long doctest build — is
launched as a **detached** job that writes to `logs/`, not held open inside a chat session. A session
that is closed, times out or is interrupted takes an attached run with it, and there is then no record
of what the run had reached.

## The pattern (Windows / PowerShell)

Write a small `.ps1` under `logs/`, named after the run, and launch it detached. The script is the
record of what was run: keep it, do not overwrite it for the next run.

```powershell
$repo = 'C:\Users\sxj477\Documents\GitHub\ModularSystems.jl'
$log  = "$repo\logs\benchmark.log"
Set-Location $repo
# One sentence: what this run is, at what settings, and which TODO item it closes.
Add-Content -Encoding UTF8 $log ("START " + (Get-Date))
cmd /c "julia --project=. logs\runBenchmark.jl > `"$repo\logs\benchmarkRun.log`" 2>&1"
Add-Content -Encoding UTF8 $log ("exit $LASTEXITCODE " + (Get-Date))
```

Launch it with `Start-Process powershell -ArgumentList '-File', 'logs\runBenchmark.ps1'` (or the
harness's own detached-run mechanism), then poll the log — do not sit in a blocking wait.

## Why it is shaped like that

- **`cmd /c "… > file 2>&1"` rather than PowerShell's `*>`.** PowerShell writes redirected output as
  UTF-16, which every downstream reader gets wrong.
- **`Add-Content` for the START/exit markers.** The exit code is the first thing you want when you
  come back, and it is not in the run's own output.
- **`--project=.` inside the script, not inherited.** A detached process does not carry the session's
  environment; without it the run silently uses the global environment and measures a different set
  of package versions than the one being tested.
- **Do not hold the log open while it runs.** A `tail -F`-style follower on Windows can block the
  script's own `Add-Content` and stall the run.
- **One script and one log per run, named after it.** Overwriting `run.log` destroys the evidence for
  the question you will ask tomorrow.

## Julia-specific

The first minutes of a long Julia run are precompilation, not work. Warm the environment once
(`julia --project=. -e "using ModularSystems"`) before timing anything, and say in the script whether
the reported time includes compilation — a benchmark that does not say is a benchmark nobody can
compare against.

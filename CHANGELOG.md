# Changelog

## 1.0.0 (unreleased)

First version: bar widget with project list, start and pause, inline editing with time input (`2h22m`, `+2h22m`, `-90m`, `0`), delete with confirmation, keyboard control, automatic pause on lock and suspend, heartbeat for power loss, configurable data file, read-only protection for unreadable data files. Settings behind a gear in the panel (`s`): pause on lock/suspend, which resumes the project afterwards if it was running, and a colored or neutral timer in the bar. The panel grows with the longest name up to the Omarchy panel width; longer names wrap. The data file uses the keys `version`, `last` and `projects` (`name`, `ms`, `since`); a file with any other field is opened read-only.

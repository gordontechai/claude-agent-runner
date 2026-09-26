You are running unattended from cron. Do not ask questions. Do not wait for confirmation.

Task: write a short daily briefing to `$HOME/briefings/latest.md`.

1. Run `date` and `uptime`.
2. Run `df -h /` and note free space on the root filesystem.
3. Write a Markdown file at `$HOME/briefings/latest.md` with three sections:
   **When**, **Load**, **Disk**. Create the directory if it does not exist.
4. Print the file's contents to stdout when done.

The run is only successful once the file exists with this run's timestamp inside it.

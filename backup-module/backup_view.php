<?php
    /*
     All Emoncms code is released under the GNU Affero General Public License.
     See COPYRIGHT.txt and LICENSE.txt.

        ---------------------------------------------------------------------
        Emoncms - open source energy visualisation
        Part of the OpenEnergyMonitor project:
        http://openenergymonitor.org

        ---------------------------------------------------------------------
        Backup module interface.

        Two tabs, matching the two things a user actually does:

          Backup   ongoing protection. Is my data safe, where does it go, and
                   what can I do about it right now.
          Restore  recovery, from any of the three sources this module reads:
                   the backup drive, an uploaded archive, or an old emonSD card.

        Styling follows Lib/api_explorer_view.php: a scoped set of CSS custom
        properties rather than Bootstrap 2 classes, with light values as the
        default so the page sits in the normal Emoncms chrome.

        Translated strings used from Javascript are collected into the T map
        below and emitted with json_encode. Writing tr() straight into a JS
        string literal breaks as soon as a translation contains an apostrophe.
    */

    global $path;
    @exec('ps ax | grep service-runner.py | grep -v grep', $servicerunnerproc);
    $servicerunner_running = !empty($servicerunnerproc);

    $archive_filename = "emoncms-backup-".gethostname()."-".date("Y-m-d").".tar.gz";
    $archive_ready = file_exists($parsed_ini['backup_location']."/".$archive_filename)
                     && !file_exists("/tmp/backuplock");

    $T = array(
        "checking"        => tr("Checking"),
        "not_set_up"      => tr("No automatic backup set up"),
        "not_set_up_d"    => tr("Your data is not being copied anywhere. Choose a drive below."),
        "not_connected"   => tr("Backup drive not connected"),
        "nothing_at"      => tr("Nothing is mounted at"),
        "resumes"         => tr("Backups resume when it is reconnected."),
        "ready_no_backup" => tr("Drive ready, no backup taken yet"),
        "run_first"       => tr("Run the first backup now, or wait for the daily run."),
        "last_failed"     => tr("The last backup failed"),
        "finished"        => tr("Finished"),
        "see_log"         => tr("See the log below."),
        "out_of_date"     => tr("Backup is out of date"),
        "falling_behind"  => tr("Backup is falling behind"),
        "backed_up"       => tr("Your data is backed up"),
        "last_backup"     => tr("Last backup"),
        "written"         => tr("written"),
        "next"            => tr("next"),
        "timer_off"       => tr("the daily timer is not enabled"),
        "not_scheduled"   => tr("Backups are not running automatically"),
        "not_scheduled_d" => tr("The daily timer is not enabled, so this will not happen again on its own."),
        "just_now"        => tr("just now"),
        "minutes_ago"     => tr("minutes ago"),
        "hours_ago"       => tr("hours ago"),
        "days_ago"        => tr("days ago"),
        "usb"             => tr("USB"),
        "network"         => tr("Network"),
        "disk"            => tr("Disk"),
        "use_drive_q"     => tr("Use this drive for Emoncms backups?"),
        "use_this_drive"  => tr("Use this drive"),
        "use_again"       => tr("Use again"),
        "preparing"       => tr("Preparing drive"),
        "backup"          => tr("Backup"),
        "verify"          => tr("Verify and repair"),
        "building"        => tr("Building archive"),
        "importing_sd"    => tr("Importing from SD card"),
        "restoring"       => tr("Restoring"),
    );

    load_js("Lib/js/vue.global.prod-3.5.22.min.js");
?>
<style>
.backup-page {
    --bg-card: #fff;
    --bg-subtle: #fafafa;
    --border-card: #e0e0e0;
    --text-primary: #222;
    --text-body: #444;
    --text-muted: #777;
    --accent: #2a8fc7;
    --accent-bg: rgba(42, 143, 199, 0.10);
    --ok: #4a9d4a;
    --ok-bg: rgba(74, 157, 74, 0.12);
    --warn: #c8860d;
    --warn-bg: rgba(200, 134, 13, 0.12);
    --danger: #c0392b;
    --danger-bg: rgba(192, 57, 43, 0.10);

    max-width: 1000px;
    margin: 0 auto;
    padding: 4px 0 64px 0;
    color: var(--text-body);
    font-size: 14px;
    line-height: 21px;
}

.backup-page [v-cloak] { display: none; }
.backup-page h2 { font-size: 24px; line-height: 32px; color: var(--text-primary); margin: 0; }
.backup-page h3 { font-size: 17px; line-height: 26px; color: var(--text-primary); margin: 0 0 4px 0; }
.backup-page h4 { font-size: 14px; line-height: 22px; color: var(--text-primary); margin: 0 0 8px 0; font-weight: 600; }
.backup-page p { margin: 0 0 10px 0; }
.backup-page .muted { color: var(--text-muted); }
.backup-page .mono { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 13px; }

.bk-tabs { display: flex; gap: 4px; border-bottom: 1px solid var(--border-card); margin: 16px 0 24px 0; }
.bk-tab {
    padding: 10px 18px; cursor: pointer; border: none; background: none;
    color: var(--text-muted); font-size: 15px; border-bottom: 2px solid transparent;
    margin-bottom: -1px;
}
.bk-tab:hover { color: var(--text-primary); }
.bk-tab.active { color: var(--accent); border-bottom-color: var(--accent); font-weight: 600; }

.bk-card {
    background-color: var(--bg-card);
    border: 1px solid var(--border-card);
    border-radius: 10px;
    padding: 20px;
    margin-bottom: 16px;
}

/* Status hero: the one thing this page has to answer at a glance */
.bk-hero { display: flex; align-items: flex-start; gap: 16px; padding: 22px 24px; border-radius: 10px; border: 1px solid; margin-bottom: 20px; }
.bk-hero .dot { width: 12px; height: 12px; border-radius: 50%; flex-shrink: 0; margin-top: 7px; }
.bk-hero .headline { font-size: 19px; line-height: 28px; font-weight: 600; color: var(--text-primary); }
.bk-hero .detail { font-size: 14px; margin-top: 2px; }
.bk-hero.ok        { background-color: var(--ok-bg);     border-color: rgba(74,157,74,0.35); }
.bk-hero.ok .dot   { background-color: var(--ok); }
.bk-hero.warn      { background-color: var(--warn-bg);   border-color: rgba(200,134,13,0.35); }
.bk-hero.warn .dot { background-color: var(--warn); }
.bk-hero.danger      { background-color: var(--danger-bg); border-color: rgba(192,57,43,0.35); }
.bk-hero.danger .dot { background-color: var(--danger); }
.bk-hero.idle        { background-color: var(--bg-subtle); border-color: var(--border-card); }
.bk-hero.idle .dot   { background-color: var(--text-muted); }

.bk-badge {
    display: inline-block; padding: 2px 8px; border-radius: 5px;
    font-size: 12px; line-height: 18px; font-weight: 600;
    background-color: var(--accent-bg); color: var(--accent);
}
.bk-badge.grey { background-color: #eee; color: var(--text-muted); }
.bk-badge.ok { background-color: var(--ok-bg); color: var(--ok); }

.bk-rows { display: flex; flex-direction: column; }
.bk-row { display: flex; gap: 16px; padding: 9px 0; border-bottom: 1px solid var(--border-card); }
.bk-row:last-child { border-bottom: none; }
.bk-row .k { width: 210px; flex-shrink: 0; color: var(--text-muted); }
.bk-row .v { color: var(--text-body); min-width: 0; word-break: break-word; }

/* What this destination can give you, beyond the incremental sync */
.bk-caps { display: flex; flex-direction: column; gap: 7px; margin: 4px 0 0 0; }
.bk-cap { display: flex; align-items: baseline; gap: 9px; }
.bk-cap .mark { width: 14px; flex-shrink: 0; font-weight: 700; }
.bk-cap.yes .mark { color: var(--ok); }
.bk-cap.no .mark { color: var(--text-muted); }
.bk-cap.no { color: var(--text-muted); }

.bk-bar { height: 8px; border-radius: 4px; background-color: #eaeaea; overflow: hidden; margin: 10px 0 6px 0; }
.bk-bar > div { height: 100%; background-color: var(--accent); }

.bk-actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
.bk-btn {
    display: inline-flex; align-items: center; gap: 7px;
    border: 1px solid var(--border-card); border-radius: 8px;
    background-color: var(--bg-card); color: var(--text-body);
    padding: 9px 16px; cursor: pointer; font-size: 14px; text-decoration: none;
}
.bk-btn:hover:not(:disabled) { background-color: var(--bg-subtle); color: var(--text-primary); text-decoration: none; }
.bk-btn:disabled { opacity: 0.45; cursor: not-allowed; }
.bk-btn.primary { background-color: var(--accent); border-color: var(--accent); color: #fff; }
.bk-btn.primary:hover:not(:disabled) { background-color: #2481b5; color: #fff; }
.bk-btn.danger { background-color: var(--danger); border-color: var(--danger); color: #fff; }
.bk-btn.danger:hover:not(:disabled) { background-color: #a93226; color: #fff; }
.bk-btn.small { padding: 5px 11px; font-size: 13px; }

.bk-table { width: 100%; border-collapse: collapse; }
.bk-table th {
    text-align: left; font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em;
    color: var(--text-muted); font-weight: 600; padding: 0 10px 8px 0; border-bottom: 1px solid var(--border-card);
}
.bk-table td { padding: 9px 10px 9px 0; border-bottom: 1px solid var(--border-card); vertical-align: middle; }
.bk-table tr:last-child td { border-bottom: none; }

.bk-log {
    background-color: #1e1e1e; color: #ddd; border-radius: 8px; padding: 14px 16px;
    font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12.5px; line-height: 19px;
    max-height: 340px; overflow: auto; white-space: pre-wrap; word-break: break-word; margin: 0;
}

.bk-disclosure > summary {
    cursor: pointer; color: var(--accent); font-size: 14px; padding: 6px 0; list-style: none;
}
.bk-disclosure > summary::-webkit-details-marker { display: none; }
.bk-disclosure > summary::before { content: "\25B8  "; }
.bk-disclosure[open] > summary::before { content: "\25BE  "; }
.bk-disclosure > div { padding: 6px 0 4px 16px; }

.bk-warning {
    border-left: 3px solid var(--danger); background-color: var(--danger-bg);
    padding: 12px 16px; border-radius: 0 8px 8px 0; margin-bottom: 16px;
}
.bk-note {
    border-left: 3px solid var(--accent); background-color: var(--accent-bg);
    padding: 12px 16px; border-radius: 0 8px 8px 0; margin-bottom: 16px;
}
.bk-check { display: flex; align-items: flex-start; gap: 9px; margin: 10px 0; cursor: pointer; }
.bk-check input { margin: 4px 0 0 0; flex-shrink: 0; }

@media (max-width: 700px) {
    .bk-row { flex-direction: column; gap: 2px; }
    .bk-row .k { width: auto; }
}
</style>

<div class="backup-page" id="backup-app" v-cloak>

    <?php if (!$servicerunner_running) { ?>
    <div class="bk-warning">
        <b><?php echo tr("service-runner is not running"); ?></b> &mdash;
        <?php echo tr("nothing on this page can run until it is."); ?>
        <a href="https://github.com/emoncms/emoncms/blob/master/scripts/services/install-service-runner-update.md"><?php echo tr("Installation instructions"); ?></a>
    </div>
    <?php } ?>

    <div class="bk-tabs">
        <button class="bk-tab" :class="{active: tab=='backup'}" @click="show('backup')"><?php echo tr("Backup"); ?></button>
        <button class="bk-tab" :class="{active: tab=='restore'}" @click="show('restore')"><?php echo tr("Restore"); ?></button>
    </div>

    <!-- ============================== BACKUP ============================== -->
    <div v-if="tab=='backup'">

        <div class="bk-hero" :class="hero.level">
            <div class="dot"></div>
            <div>
                <div class="headline">{{ hero.headline }}</div>
                <div class="detail muted">{{ hero.detail }}</div>
            </div>
        </div>

        <!-- No destination, or it is not connected: offer the drives found -->
        <div class="bk-card" v-if="status.configured === false || (status.configured && !status.available)">
            <h3 v-if="!status.configured"><?php echo tr("Choose where backups are kept"); ?></h3>
            <h3 v-else><?php echo tr("Backup drive not available"); ?></h3>

            <p class="muted" v-if="status.configured">
                <?php echo tr("Nothing is mounted at"); ?> <span class="mono">{{ status.path }}</span>.
                <?php echo tr("Reconnect it, or choose a different drive."); ?>
            </p>
            <p class="muted" v-else>
                <?php echo tr("Emoncms keeps a copy of your data on an attached drive. Mount a USB drive or network share, then choose it below."); ?>
            </p>

            <table class="bk-table" v-if="drives.length">
                <thead><tr>
                    <th><?php echo tr("Mounted at"); ?></th>
                    <th><?php echo tr("Type"); ?></th>
                    <th><?php echo tr("Free"); ?></th>
                    <th></th>
                </tr></thead>
                <tbody>
                    <tr v-for="d in drives" :key="d.mountpoint">
                        <td>
                            <span class="mono">{{ d.mountpoint }}</span><br>
                            <span class="muted mono">{{ d.source }}</span>
                        </td>
                        <td>
                            <span class="bk-badge" :class="{grey: d.kind=='fixed'}">{{ kind_label(d) }}</span>
                            <span class="muted mono"> {{ d.fstype }}</span>
                        </td>
                        <td>{{ gb(d.free_mb) }}</td>
                        <td style="text-align:right">
                            <button class="bk-btn small primary" :disabled="busy" @click="pick(d)">
                                {{ d.initialised ? T.use_again : T.use_this_drive }}
                            </button>
                        </td>
                    </tr>
                </tbody>
            </table>
            <p class="muted" v-else><?php echo tr("No drives found. Mount a USB drive or network share first. Add it to /etc/fstab so it is mounted again after a reboot."); ?></p>
        </div>

        <!-- The destination in use, and what it can do -->
        <div class="bk-card" v-if="status.available">
            <div style="display:flex; justify-content:space-between; align-items:flex-start; gap:16px; flex-wrap:wrap">
                <div style="min-width:0">
                    <h3><?php echo tr("Backup destination"); ?></h3>
                    <div class="mono">{{ status.path }}</div>
                    <div class="muted mono" v-if="status.drive">{{ status.drive.source }} &middot; {{ status.drive.fstype }}</div>
                </div>
                <button class="bk-btn small" :disabled="busy" @click="change_drive = !change_drive"><?php echo tr("Change drive"); ?></button>
            </div>

            <div v-if="status.total_mb > 0">
                <div class="bk-bar"><div :style="{width: used_percent + '%'}"></div></div>
                <div class="muted">
                    {{ gb(status.total_mb - status.free_mb) }} <?php echo tr("used of"); ?> {{ gb(status.total_mb) }}
                    &middot; {{ gb(status.free_mb) }} <?php echo tr("free"); ?>
                </div>
            </div>

            <h4 style="margin-top:18px"><?php echo tr("What this drive can do"); ?></h4>
            <div class="bk-caps">
                <div class="bk-cap yes">
                    <span class="mark">&check;</span>
                    <span><b><?php echo tr("Only new data is copied"); ?></b> &mdash;
                    <?php echo tr("just the new readings each day, usually a few MB rather than all of your data."); ?></span>
                </div>
                <div class="bk-cap" :class="caps.compressed ? 'yes' : 'no'">
                    <span class="mark" v-if="caps.compressed">&check;</span><span class="mark" v-else>&ndash;</span>
                    <span v-if="caps.compressed"><b><?php echo tr("Compressed"); ?></b> &mdash;
                        <?php echo tr("the drive compresses as it writes. Feed data is typically about 80% smaller."); ?></span>
                    <span v-else><b><?php echo tr("Not compressed"); ?></b> &mdash;
                        <?php echo tr("feed files are copied as they are. Compressing them here would mean rewriting each one in full every day, which is exactly what this backup avoids. A btrfs drive mounted with compress=zstd compresses them as it writes instead."); ?></span>
                </div>
                <div class="bk-cap" :class="caps.snapshots ? 'yes' : 'no'">
                    <span class="mark" v-if="caps.snapshots">&check;</span><span class="mark" v-else>&ndash;</span>
                    <span v-if="caps.snapshots"><b><?php echo tr("Dated copies of everything"); ?></b> &mdash;
                        <?php echo tr("this drive can keep dated copies of the feed data as well as the database."); ?></span>
                    <span v-else><b><?php echo tr("Dated copies of the database only"); ?></b> &mdash;
                        <?php echo tr("feed data is kept at its latest state, so a problem that goes unnoticed for a while cannot be undone. A btrfs drive would add this."); ?></span>
                </div>
            </div>

            <div v-if="change_drive" style="margin-top:18px; border-top:1px solid var(--border-card); padding-top:16px">
                <h4><?php echo tr("Change to another drive"); ?></h4>
                <table class="bk-table" v-if="drives.length">
                    <tbody>
                        <tr v-for="d in drives" :key="d.mountpoint">
                            <td><span class="mono">{{ d.mountpoint }}</span></td>
                            <td><span class="bk-badge" :class="{grey: d.kind=='fixed'}">{{ kind_label(d) }}</span></td>
                            <td>{{ gb(d.free_mb) }}</td>
                            <td style="text-align:right">
                                <button class="bk-btn small" :disabled="busy" @click="pick(d)"><?php echo tr("Use this drive"); ?></button>
                            </td>
                        </tr>
                    </tbody>
                </table>
                <p class="muted" v-else><?php echo tr("No other drives found."); ?></p>
            </div>
        </div>

        <!-- Last run -->
        <div class="bk-card" v-if="status.available && status.status">
            <h3><?php echo tr("Last backup"); ?></h3>
            <div class="bk-rows">
                <div class="bk-row"><div class="k"><?php echo tr("Finished"); ?></div><div class="v">{{ local_time(status.status.last_run) }} <span class="muted">({{ ago(status.status.last_run) }})</span></div></div>
                <div class="bk-row"><div class="k"><?php echo tr("Mode"); ?></div><div class="v">{{ status.status.mode }}<span v-if="status.status.dry_run"> (<?php echo tr("dry run"); ?>)</span></div></div>
                <div class="bk-row"><div class="k"><?php echo tr("Took"); ?></div><div class="v">{{ duration(status.status.duration_seconds) }}</div></div>
                <div class="bk-row"><div class="k"><?php echo tr("Written"); ?></div><div class="v">{{ bytes(status.status.bytes_written) }}</div></div>
                <div class="bk-row" v-if="status.status.files_repaired || status.status.files_realigned">
                    <div class="k"><?php echo tr("Files repaired / realigned"); ?></div>
                    <div class="v">{{ status.status.files_repaired }} / {{ status.status.files_realigned }}</div>
                </div>
                <div class="bk-row" v-if="status.status.orphans">
                    <div class="k"><?php echo tr("Orphaned files"); ?></div>
                    <div class="v">{{ status.status.orphans }} <span class="muted"><?php echo tr("on the backup but no longer in Emoncms"); ?></span></div>
                </div>
            </div>
        </div>

        <!-- Run now -->
        <div class="bk-card" v-if="status.available">
            <h3><?php echo tr("Run now"); ?></h3>
            <p class="muted"><?php echo tr("Backups run each day on their own. Use these to run one now."); ?></p>
            <div class="bk-actions">
                <button class="bk-btn primary" :disabled="busy" @click="run('drivebackup','drivebackuplog')"><?php echo tr("Back up now"); ?></button>
                <button class="bk-btn" :disabled="busy" @click="run('drivebackupverify','drivebackupverifylog')"><?php echo tr("Verify and repair"); ?></button>
            </div>
            <details class="bk-disclosure" style="margin-top:12px">
                <summary><?php echo tr("When should I verify?"); ?></summary>
                <div><?php echo tr("The daily backup only adds new readings to the end of each file, so it cannot spot a file that was changed in place without changing size. Verify checks every file and repairs any difference. It runs weekly on its own, so this is only for running it early."); ?></div>
            </details>
        </div>

        <!-- Restore points -->
        <div class="bk-card" v-if="status.available">
            <h3><?php echo tr("Restore points"); ?></h3>
            <p class="muted"><?php echo tr("Dated copies of the Emoncms database kept on the drive. Feed data is kept at its latest state, not per date."); ?></p>
            <table class="bk-table" v-if="status.sql && status.sql.length">
                <thead><tr>
                    <th><?php echo tr("Taken"); ?></th>
                    <th><?php echo tr("Kept as"); ?></th>
                    <th><?php echo tr("Size"); ?></th>
                </tr></thead>
                <tbody>
                    <tr v-for="s in status.sql" :key="s.period + s.name">
                        <td class="mono">{{ snapshot_date(s.name) }}</td>
                        <td><span class="bk-badge" :class="{grey: s.period=='daily'}">{{ s.period }}</span></td>
                        <td>{{ s.size_mb }} MB</td>
                    </tr>
                </tbody>
            </table>
            <p class="muted" v-else><?php echo tr("No restore points yet."); ?></p>
        </div>

        <!-- Portable archive, formerly the Export Archive tab -->
        <div class="bk-card">
            <h3><?php echo tr("Download a portable copy"); ?></h3>
            <p class="muted"><?php echo tr("A single compressed archive of everything, to keep off site or move to another emonPi / emonBase. It rewrites all of your data each time, so use it now and then rather than daily."); ?></p>
            <div class="bk-actions">
                <button class="bk-btn" :disabled="busy" @click="run('start','exportlog')"><?php echo tr("Build archive"); ?></button>
                <?php if ($archive_ready) { ?>
                <a class="bk-btn" href="<?php echo $path; ?>backup/download"><?php echo tr("Download"); ?>&nbsp;<span class="mono"><?php echo $archive_filename; ?></span></a>
                <?php } ?>
            </div>
            <?php if (!$archive_ready) { ?>
            <p class="muted" style="margin-top:10px"><i><?php echo tr("Once the archive is built, refresh the page to see the download link."); ?></i></p>
            <?php } ?>
        </div>

        <details class="bk-disclosure bk-card">
            <summary><?php echo tr("How the daily backup works"); ?></summary>
            <div>
                <p><?php echo tr("Emoncms adds each new reading to the end of a feed file. From one day to the next the only new data is at the end, so the backup copies just that rather than the whole file."); ?></p>
                <p><?php echo tr("On a system with 83 feeds and 738 MB of data that is about 2 MB a day, against roughly 1.5 GB for a full archive. It is quicker, it uses far less network bandwidth, and it is much kinder to a USB flash drive."); ?></p>
                <p><?php echo tr("The Emoncms database is small, so a fresh compressed copy is saved every run. The last seven days and the last four weeks are kept."); ?></p>
            </div>
        </details>
    </div>

    <!-- ============================== RESTORE ============================== -->
    <div v-if="tab=='restore'">

        <div class="bk-warning">
            <b><?php echo tr("Restoring replaces all Emoncms data on this system."); ?></b>
            <?php echo tr("Inputs, feeds, dashboards and feed data are all replaced by the copy you restore from."); ?>
        </div>

        <p class="muted"><?php echo tr("Choose where to restore from."); ?></p>

        <div class="bk-card">
            <div style="display:flex; justify-content:space-between; align-items:flex-start; gap:16px; flex-wrap:wrap">
                <div>
                    <h3><?php echo tr("From the backup drive"); ?></h3>
                    <p class="muted" style="margin:0"><?php echo tr("The copy kept up to date by the daily backup."); ?></p>
                </div>
                <span class="bk-badge ok" v-if="status.available"><?php echo tr("Connected"); ?></span>
                <span class="bk-badge grey" v-else><?php echo tr("Not connected"); ?></span>
            </div>

            <div v-if="status.available && status.sql && status.sql.length" style="margin-top:16px">
                <div class="bk-rows">
                    <div class="bk-row">
                        <div class="k"><?php echo tr("Restore point"); ?></div>
                        <div class="v">
                            <select v-model="restore_sql" style="width:auto; max-width:100%">
                                <option v-for="s in status.sql" :key="s.period + s.name" :value="s.name">
                                    {{ snapshot_date(s.name) }} &middot; {{ s.period }} &middot; {{ s.size_mb }} MB
                                </option>
                            </select>
                        </div>
                    </div>
                    <div class="bk-row">
                        <div class="k"><?php echo tr("Feed data"); ?></div>
                        <div class="v muted"><?php echo tr("restored to the state of the last backup, whichever restore point you choose"); ?></div>
                    </div>
                </div>

                <label class="bk-check">
                    <input type="checkbox" v-model="restore_delete">
                    <span><?php echo tr("Also delete feed files that are not in the backup, so this system matches it exactly"); ?></span>
                </label>
                <label class="bk-check">
                    <input type="checkbox" v-model="restore_confirm">
                    <span><b><?php echo tr("I understand this overwrites all Emoncms data on this system"); ?></b></span>
                </label>

                <p class="muted"><?php echo tr("The current database is saved first, so a restore started by mistake can be undone. Feed data is overwritten in place and cannot be recovered this way."); ?></p>

                <div class="bk-actions">
                    <button class="bk-btn danger" :disabled="!restore_confirm || busy" @click="do_restore()"><?php echo tr("Restore from drive"); ?></button>
                </div>
            </div>
            <p class="muted" style="margin-top:12px" v-else-if="status.available"><?php echo tr("No restore points on the drive yet."); ?></p>
            <p class="muted" style="margin-top:12px" v-else><?php echo tr("Connect the backup drive to restore from it."); ?></p>
        </div>

        <div class="bk-card">
            <h3><?php echo tr("From an archive file"); ?></h3>
            <p class="muted"><?php echo tr("Upload a"); ?> <span class="mono">.tar.gz</span>
                <?php echo tr("archive downloaded from this or another Emoncms."); ?></p>
            <form action="<?php echo $path; ?>backup/upload" method="post" enctype="multipart/form-data">
                <input type="file" name="file" id="file" accept=".gz">
                <div class="bk-actions" style="margin-top:12px">
                    <input class="bk-btn danger" type="submit" name="submit" value="<?php echo tr("Upload and restore"); ?>">
                </div>
            </form>
            <details class="bk-disclosure" style="margin-top:10px">
                <summary><?php echo tr("The upload fails for large archives"); ?></summary>
                <div><?php echo tr("Browsers and PHP limit the upload size. For a large archive, copy it onto the machine and run"); ?>
                    <span class="mono">./emoncms-import.sh</span>,
                    <a href="http://github.com/emoncms/backup"><?php echo tr("see the module readme"); ?></a>.
                </div>
            </details>
        </div>

        <div class="bk-card">
            <h3><?php echo tr("From an old emonSD card"); ?></h3>
            <p class="muted"><?php echo tr("Put the old emonPi or emonBase SD card in a USB card reader and plug it in. The data is read straight from the card, with no need to export an archive first."); ?></p>
            <p class="muted"><i><?php echo tr("Note: Update Emoncms and EmonHub to the latest version before importing."); ?></i></p>
            <label class="bk-check">
                <input type="checkbox" v-model="sd_confirm">
                <span><b><?php echo tr("I understand this overwrites all Emoncms data on this system"); ?></b></span>
            </label>
            <div class="bk-actions">
                <button class="bk-btn danger" :disabled="!sd_confirm || busy" @click="run('usbimport','usbimportlog')"><?php echo tr("Import from SD card"); ?></button>
            </div>
        </div>

        <div class="bk-note" v-if="restore_started">
            <?php echo tr("When the restore is complete, log out then log in using the restored account details."); ?>
        </div>
    </div>

    <!-- Shared activity log -->
    <div class="bk-card" v-if="log_text !== ''">
        <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px">
            <h3 style="margin:0">{{ log_title }}</h3>
            <span class="bk-badge" v-if="busy"><?php echo tr("running"); ?></span>
        </div>
        <pre class="bk-log" ref="log">{{ log_text }}</pre>
    </div>
</div>

<script>
var backup_path = <?php echo json_encode($path); ?>;

Vue.createApp({
    data() { return {
        T: <?php echo json_encode($T); ?>,
        tab: (location.hash === "#restore" ? "restore" : "backup"),
        status: {configured: null, available: false, sql: [], free_mb: 0, total_mb: 0, path: ""},
        drives: [],
        change_drive: false,
        busy: false,
        log_text: "",
        log_title: "",
        log_action: "",
        log_timer: false,
        log_last: "",
        log_stall: 0,
        restore_sql: "",
        restore_delete: false,
        restore_confirm: false,
        restore_started: false,
        sd_confirm: false,
        now: Math.floor(Date.now()/1000)
    }; },

    computed: {
        // What this destination adds on top of the incremental sync every
        // destination gets. It comes from the filesystem, not from the scripts.
        caps: function() {
            var d = this.status.drive;
            return {compressed: !!(d && d.compressed), snapshots: !!(d && d.snapshots)};
        },

        used_percent: function() {
            if (!this.status.total_mb) return 0;
            return Math.min(100, Math.round((this.status.total_mb - this.status.free_mb) / this.status.total_mb * 100));
        },

        // The one question this page exists to answer
        hero: function() {
            var s = this.status, T = this.T;
            if (s.configured === null) return {level: "idle", headline: T.checking, detail: ""};
            if (!s.configured) return {level: "idle", headline: T.not_set_up, detail: T.not_set_up_d};

            var next = "";
            var unscheduled = (s.schedule && s.schedule.scheduled === false);
            if (s.schedule && s.schedule.scheduled && s.schedule.next_run) {
                next = " · " + T.next + " " + this.local_time_ts(s.schedule.next_run);
            }

            if (!s.available) return {
                level: "warn", headline: T.not_connected,
                detail: T.nothing_at + " " + s.path + ". " + T.resumes
            };
            if (!s.status) return {
                level: "warn", headline: T.ready_no_backup,
                detail: T.run_first + (unscheduled ? " · " + T.timer_off : next)
            };
            if (s.status.errors) return {
                level: "danger", headline: T.last_failed,
                detail: T.finished + " " + this.ago(s.status.last_run) + ". " + T.see_log
            };

            var age_days = (this.now - this.epoch(s.status.last_run)) / 86400;
            var detail = T.last_backup + " " + this.ago(s.status.last_run) +
                         " · " + this.bytes(s.status.bytes_written) + " " + T.written + next;

            if (age_days > 7) return {level: "danger", headline: T.out_of_date, detail: detail};
            if (age_days > 2) return {level: "warn", headline: T.falling_behind, detail: detail};

            // A backup taken by hand is not protection. Only say the data is
            // safe if it will also happen again without anyone doing anything.
            if (unscheduled) return {level: "warn", headline: T.not_scheduled, detail: T.not_scheduled_d + " " + detail};

            return {level: "ok", headline: T.backed_up, detail: detail};
        }
    },

    methods: {
        show: function(tab) { this.tab = tab; location.hash = tab; },

        gb: function(mb) {
            if (!mb) return "0 GB";
            if (mb < 1024) return mb + " MB";
            return (Math.round(mb / 1024 * 10) / 10) + " GB";
        },

        bytes: function(b) {
            if (b === undefined || b === null) return "-";
            var u = ["B","kB","MB","GB","TB"], i = 0;
            while (b >= 1024 && i < u.length - 1) { b = b / 1024; i++; }
            return (i === 0 ? b : b.toFixed(1)) + " " + u[i];
        },

        duration: function(s) {
            if (s === undefined) return "-";
            if (s < 60) return s + " s";
            if (s < 3600) return Math.floor(s/60) + " min " + (s%60) + " s";
            return Math.floor(s/3600) + " h " + Math.floor((s%3600)/60) + " min";
        },

        epoch: function(iso) { var d = new Date(iso); return isNaN(d.getTime()) ? 0 : Math.floor(d.getTime()/1000); },
        local_time: function(iso) { var d = new Date(iso); return isNaN(d.getTime()) ? iso : d.toLocaleString(); },
        local_time_ts: function(ts) { return new Date(ts * 1000).toLocaleString(); },

        ago: function(iso) {
            var t = this.epoch(iso);
            if (!t) return iso;
            var s = this.now - t;
            if (s < 90) return this.T.just_now;
            if (s < 5400) return Math.round(s/60) + " " + this.T.minutes_ago;
            if (s < 172800) return Math.round(s/3600) + " " + this.T.hours_ago;
            return Math.round(s/86400) + " " + this.T.days_ago;
        },

        kind_label: function(d) {
            if (d.kind == "removable") return this.T.usb;
            if (d.kind == "network") return this.T.network;
            return this.T.disk;
        },

        // Snapshot filenames end in the ISO date: emoncms-<host>-YYYY-MM-DD.sql.gz
        snapshot_date: function(name) {
            var m = /(\d{4}-\d{2}-\d{2})\.sql\.gz$/.exec(name);
            return m ? m[1] : name;
        },

        refresh: function() {
            var self = this;
            self.now = Math.floor(Date.now()/1000);
            $.ajax({url: backup_path + "backup/drivebackupstatus", dataType: "json", success: function(s) {
                self.status = s;
                if (s.sql && s.sql.length && self.restore_sql === "") self.restore_sql = s.sql[0].name;
            }});
            $.ajax({url: backup_path + "backup/drivediscover", dataType: "json", success: function(d) {
                self.drives = d;
            }});
        },

        pick: function(drive) {
            if (!confirm(this.T.use_drive_q + "\n\n" + drive.mountpoint)) return;
            this.change_drive = false;
            this.start("drivesetpath?mountpoint=" + encodeURIComponent(drive.mountpoint),
                       "drivebackuplog", this.T.preparing);
        },

        run: function(action, log_action) {
            var titles = {
                drivebackup: this.T.backup,
                drivebackupverify: this.T.verify,
                start: this.T.building,
                usbimport: this.T.importing_sd
            };
            if (action == "usbimport") this.restore_started = true;
            this.start(action, log_action, titles[action] || action);
        },

        do_restore: function() {
            if (!this.restore_confirm) return;
            var url = "driverestore?sql=" + encodeURIComponent(this.restore_sql);
            if (this.restore_delete) url += "&delete=1";
            this.restore_confirm = false;
            this.restore_started = true;
            this.start(url, "driverestorelog", this.T.restoring);
        },

        start: function(action, log_action, title) {
            var self = this;
            self.busy = true;
            self.log_action = log_action;
            self.log_title = title;
            self.log_text = "...";
            self.log_last = "";
            self.log_stall = 0;
            $.ajax({url: backup_path + "backup/" + action, dataType: "text", success: function(result) {
                self.log_text = result;
                clearInterval(self.log_timer);
                self.log_timer = setInterval(self.poll_log, 1000);
            }});
        },

        // Completion markers printed by the scripts. Amend there if changed here.
        is_finished: function(text) {
            var done = [
                "=== Emoncms drive backup complete! ===",
                "=== Emoncms drive backup completed with ERRORS! ===",
                "=== Emoncms drive backup skipped ===",
                "=== Emoncms drive backup ready ===",
                "=== Emoncms drive restore complete! ===",
                "=== Emoncms drive restore completed with ERRORS! ===",
                "=== Emoncms drive restore cancelled ===",
                "=== Emoncms export complete! ===",
                "=== Emoncms export completed with ERRORS! ===",
                "=== Emoncms import complete! ==="
            ];
            for (var i = 0; i < done.length; i++) {
                if (text.indexOf(done[i]) != -1) return true;
            }
            return false;
        },

        poll_log: function() {
            var self = this;
            $.ajax({url: backup_path + "backup/" + self.log_action, dataType: "text", success: function(result) {
                if (result == "backup module requires admin access") { location.replace("/"); return; }
                self.log_text = result;
                self.$nextTick(function() {
                    var el = self.$refs.log;
                    if (el) el.scrollTop = el.scrollHeight;
                });
                if (self.is_finished(result)) {
                    clearInterval(self.log_timer);
                    self.busy = false;
                    self.refresh();
                    // The archive download link is rendered server side, so the
                    // page has to come back to pick it up
                    if (self.log_action == "exportlog") location.reload();
                    return;
                }

                // Give up on a log that has stopped growing. Without this a run
                // killed part way through leaves the page polling for ever.
                if (result === self.log_last) {
                    self.log_stall++;
                    if (self.log_stall > 300) {
                        clearInterval(self.log_timer);
                        self.busy = false;
                    }
                } else {
                    self.log_last = result;
                    self.log_stall = 0;
                }
            }});
        },

        // A run started before this page was loaded is still worth showing.
        // busy is deliberately not set: a log left behind by a run that was
        // interrupted, by a reboot say, would otherwise disable every button
        // for as long as the page stayed open. Starting a second run while one
        // is genuinely in progress is refused by the scripts' own lock.
        resume: function(log_action, title) {
            var self = this;
            $.ajax({url: backup_path + "backup/" + log_action, dataType: "text", success: function(r) {
                if (!r || self.busy || self.log_text !== "" || self.is_finished(r)) return;
                self.log_action = log_action;
                self.log_title = title;
                self.log_text = r;
                self.log_last = r;
                clearInterval(self.log_timer);
                self.log_timer = setInterval(self.poll_log, 1000);
            }});
        }
    },

    mounted: function() {
        this.refresh();
        this.resume("driverestorelog", this.T.restoring);
        this.resume("importlog", this.T.restoring);
        this.resume("drivebackuplog", this.T.backup);

        // Keep the relative times honest without asking the server for them
        setInterval(function() { this.now = Math.floor(Date.now()/1000); }.bind(this), 30000);

        window.addEventListener("hashchange", function() {
            this.tab = (location.hash === "#restore" ? "restore" : "backup");
        }.bind(this));
    }
}).mount("#backup-app");
</script>

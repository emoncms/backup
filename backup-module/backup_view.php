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

        Styling follows Modules/graph: the shared .card classes from
        Theme/css/card.css on a whitesmoke page, Bootstrap buttons, and the
        theme's own colour tokens rather than a palette of its own.

        Translated strings used from Javascript are collected into the T map
        below and emitted with json_encode. Writing tr() straight into a JS
        string literal breaks as soon as a translation contains an apostrophe.
    */

    global $path;
    @exec('ps ax | grep service-runner.py | grep -v grep', $servicerunnerproc);
    $servicerunner_running = !empty($servicerunnerproc);

    $archive_filename = "emoncms-backup-".preg_replace('/[^a-zA-Z0-9\-]/', '-', gethostname())."-".date("Y-m-d").".tar.gz";
    $archive_ready = file_exists($parsed_ini['backup_location']."/".$archive_filename)
                     && !file_exists("/tmp/backuplock");

    $T = array(
        "checking"        => tr("Checking"),
        "not_set_up"      => tr("No automatic backup set up"),
        "not_set_up_d"    => tr("Your data is not being copied anywhere. Choose a drive below."),
        "not_connected"   => tr("Backup drive not connected"),
        "not_responding"  => tr("Backup drive is not responding"),
        "not_responding_d"=> tr("It is still mounted but will not answer. This normally means it was unplugged and plugged back in. Unplug it and plug it back in again, or remount it, and then run a backup to check."),
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
        "show_log"        => tr("Show log"),
        "hide_log"        => tr("Hide log"),
        "ran_ok"          => tr("Complete"),
        "ran_failed"      => tr("Failed"),
        "ran_skipped"     => tr("Nothing to do"),
        "not_started"     => tr("Not started"),
        "not_started_log" => tr("No log: the script was never started. The previous run's log has been left as it was."),
        "schedule_on"     => tr("Turning on daily backup"),
        "schedule_off"    => tr("Turning off daily backup"),
        "free_suffix"     => tr("free"),
        "no_filesystem"   => tr("no filesystem"),
        "no_media"        => tr("card reader, no card inserted"),
        "scan"            => tr("Scan for drives"),
        "scanning"        => tr("Scanning"),
        "setting_up"      => tr("Setting up drive"),
        "formatting"      => tr("Formatting drive"),
    );

    load_js("Lib/js/vue.global.prod-3.5.22.min.js");
?>
<style>
/* The backup pages follow Modules/graph: a whitesmoke page holding white cards
   from Theme/css/card.css, Bootstrap buttons and a blue accent. Colours come
   from the theme tokens, so only the status palette is defined here. */
body { background-color: var(--bg-body); }
.content-container { max-width: 1000px; }

.backup-page {
    --ok:            #468847;
    --ok-bg:         #dff0d8;
    --ok-border:     #d6e9c6;
    --warn:          #c09853;
    --warn-bg:       #fcf8e3;
    --warn-border:   #fbeed5;
    --danger:        #b94a48;
    --danger-bg:     #f2dede;
    --danger-border: #eed3d7;

    padding: 1rem 0 3rem 0;
    color: var(--text-body);
}

.backup-page [v-cloak] { display: none; }
.backup-page p { margin: 0 0 0.6rem 0; }
.backup-page p:last-child { margin-bottom: 0; }
.backup-page .muted { color: var(--text-secondary); }
.backup-page .mono { font-family: var(--font-mono); font-size: var(--font-sm); }

/* Card headers here label a section, they do not collapse it */
.backup-page .card-header { cursor: default; }
.backup-page .card-header:hover { background-color: var(--bg-card-header); }
.backup-page .card-header.is-toggle { cursor: pointer; }
.backup-page .card-header.is-toggle:hover { background-color: var(--bg-card-header-hover); }
.backup-page .card-header .bk-toggle { font-size: var(--font-2xs); color: var(--accent); white-space: nowrap; }
.backup-page .card-header .btn { margin-left: auto; }
.backup-page .card-body { padding: 1rem; }

/* Sub-heading within a card body */
.backup-page .bk-subhead {
    margin: 1.2rem 0 0.6rem 0;
    font-size: var(--font-2xs);
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-secondary);
}
.backup-page .bk-subhead:first-child { margin-top: 0; }

/* Names a group of cards. The page does two different jobs, an ongoing backup
   to a drive and a portable copy to take away, and saying so is what keeps them
   from reading as one long list. */
.backup-page .bk-section {
    margin: 1.8rem 0 0.6rem 0;
    font-size: var(--font-2xs);
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--text-secondary);
}
.backup-page .bk-section:first-child { margin-top: 0.4rem; }

/* Spacing for blocks that follow something else inside a card body */
.backup-page .bk-rows-spaced { margin-top: 0.9rem; }
.backup-page .bk-actions-spaced { margin-top: 1rem; }
.backup-page .bk-disclosure-spaced { margin-top: 1rem; }
.backup-page .bk-hint { margin-top: 0.6rem; font-style: italic; }
.backup-page .bk-notice ul { margin: 0.2rem 0 0.5rem 1.2rem; }
.backup-page .bk-notice li { line-height: 1.5; }
.backup-page .bk-disclosure .bk-caps { margin-top: 0.4rem; }

/* ==========================================================================
   SECTION SWITCHER — as graph's .graph-section-switcher
   ========================================================================== */
.bk-switcher { display: flex; justify-content: flex-start; margin-bottom: 1rem; }
.bk-switcher .btn-group { display: inline-flex; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.08); }
.bk-switcher .btn { padding-inline: 1.4rem; }
.bk-switcher .btn.active {
    background: var(--accent);
    border-color: var(--accent);
    color: #fff;
    box-shadow: none;
    text-shadow: none;
}

/* ==========================================================================
   STATUS BANNER — the one thing the page has to answer at a glance
   ========================================================================== */
.bk-hero {
    display: flex;
    align-items: flex-start;
    gap: 0.8rem;
    padding: 0.9rem 1rem;
    margin-bottom: 0.5rem;
    border: 1px solid var(--border);
    border-left-width: 4px;
    border-radius: var(--radius-card);
    background-color: var(--bg-card);
}
.bk-hero .dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; margin-top: 6px; }
.bk-hero .headline { font-size: var(--font-subheading); font-weight: 600; color: var(--text-primary); }
.bk-hero .detail { font-size: var(--font-sm); margin-top: 2px; }
.bk-hero.ok       { background-color: var(--ok-bg);     border-color: var(--ok-border);     border-left-color: var(--ok); }
.bk-hero.ok .dot  { background-color: var(--ok); }
.bk-hero.warn     { background-color: var(--warn-bg);   border-color: var(--warn-border);   border-left-color: var(--warn); }
.bk-hero.warn .dot{ background-color: var(--warn); }
.bk-hero.danger      { background-color: var(--danger-bg); border-color: var(--danger-border); border-left-color: var(--danger); }
.bk-hero.danger .dot { background-color: var(--danger); }
.bk-hero.idle        { border-left-color: var(--border-strong); }
.bk-hero.idle .dot   { background-color: var(--text-muted); }

/* ==========================================================================
   BADGES, KEY/VALUE ROWS, CAPABILITIES, DISK BAR
   ========================================================================== */
.bk-badge {
    display: inline-block;
    padding: 1px 8px;
    border-radius: 0.75rem;
    font-size: var(--font-2xs);
    color: var(--accent);
    background-color: var(--accent-bg);
    border: 1px solid var(--accent-border);
}
.bk-badge.grey { color: var(--text-secondary); background-color: var(--bg-badge); border-color: var(--border-strong); }
.bk-badge.ok   { color: var(--ok); background-color: var(--ok-bg); border-color: var(--ok-border); }
.bk-badge.danger { color: var(--danger); background-color: var(--danger-bg); border-color: var(--danger-border); }

.bk-rows { display: flex; flex-direction: column; }
.bk-row { display: flex; gap: 1rem; padding: 0.45rem 0; border-bottom: 1px solid var(--border); }
.bk-row:last-child { border-bottom: none; }
.bk-row .k { width: 210px; flex-shrink: 0; color: var(--text-secondary); }
.bk-row .v { color: var(--text-body); min-width: 0; word-break: break-word; }

.bk-caps { display: flex; flex-direction: column; gap: 0.45rem; }
.bk-cap { display: flex; align-items: baseline; gap: 0.55rem; }
.bk-cap .mark { width: 14px; flex-shrink: 0; font-weight: 700; }
.bk-cap.yes .mark { color: var(--ok); }
.bk-cap.no .mark { color: var(--text-muted); }
.bk-cap.no { color: var(--text-secondary); }

.bk-bar {
    height: 8px;
    border-radius: 4px;
    background-color: var(--bg-badge);
    border: 1px solid var(--border);
    overflow: hidden;
    margin: 0.6rem 0 0.4rem 0;
}
.bk-bar > div { height: 100%; background-color: var(--accent); }

.bk-actions { display: flex; gap: 0.5rem; flex-wrap: wrap; align-items: center; }
.bk-actions .btn { margin: 0; }

/* ==========================================================================
   TABLES — card.css styles these. Columns size to their content, and the row
   rule it draws is a light-on-dark one that leaves nothing behind here.
   ========================================================================== */
.backup-page .card table { table-layout: auto; border-top: 1px solid var(--border); }
.backup-page .card table td { border-bottom: 1px solid var(--border); }
.backup-page .card table tr:last-child td { border-bottom: none; }
.backup-page .card table td.right,
.backup-page .card table th.right { text-align: right; }
.backup-page .card table .btn { margin: 0; }

/* ==========================================================================
   LOG, DISCLOSURES AND NOTICES
   ========================================================================== */
.bk-log {
    margin: 0;
    padding: 0.7rem 0.9rem;
    border: 1px solid var(--border);
    border-radius: var(--radius-control);
    background-color: var(--bg-badge);
    color: var(--text-body);
    font-family: var(--font-mono);
    font-size: var(--font-xs);
    line-height: 19px;
    max-height: 340px;
    overflow: auto;
    white-space: pre-wrap;
    word-break: break-word;
}

.bk-disclosure > summary {
    cursor: pointer;
    color: var(--accent);
    font-size: var(--font-sm);
    padding: 0.3rem 0;
    list-style: none;
}
.bk-disclosure > summary::-webkit-details-marker { display: none; }
.bk-disclosure > summary::before { content: "\25B8  "; }
.bk-disclosure[open] > summary::before { content: "\25BE  "; }
.bk-disclosure > div { padding: 0.3rem 0 0.2rem 1rem; color: var(--text-secondary); }

.bk-notice {
    padding: 0.7rem 1rem;
    margin-bottom: 0.5rem;
    border: 1px solid var(--border);
    border-left: 3px solid var(--accent);
    border-radius: var(--radius-card);
    background-color: var(--accent-bg);
    font-size: var(--font-sm);
}
.bk-notice.danger {
    border-color: var(--danger-border);
    border-left-color: var(--danger);
    background-color: var(--danger-bg);
    color: var(--danger);
}

.bk-check { display: flex; align-items: flex-start; gap: 0.5rem; margin: 0.6rem 0; cursor: pointer; }
.bk-check input { margin: 3px 0 0 0; flex-shrink: 0; }
.backup-page input[type="checkbox"] { accent-color: var(--accent); }
.backup-page select { margin-bottom: 0; }

@media (max-width: 700px) {
    .bk-row { flex-direction: column; gap: 2px; }
    .bk-row .k { width: auto; }
}
</style>

<div class="backup-page" id="backup-app" v-cloak>

    <div class="bk-switcher">
        <div class="btn-group">
            <button class="btn" :class="{active: tab=='backup'}" @click="show('backup')"><?php echo tr("Backup"); ?></button>
            <button class="btn" :class="{active: tab=='restore'}" @click="show('restore')"><?php echo tr("Restore"); ?></button>
        </div>
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

        <div class="bk-section"><?php echo tr("Automatic backup"); ?></div>

        <!-- The drive backup, all of it.
             Where the copy goes, when it last ran, when it runs next and what
             can be done to it are one subject, so they are one card rather than
             four. The explanations sit with what they explain. -->
        <div class="card" v-if="status.available">
            <div class="card-header">
                <span class="card-accent"></span>
                <span class="card-name"><?php echo tr("Backup drive"); ?></span>
                <button class="btn btn-small" :disabled="busy" @click="change_drive = !change_drive"><?php echo tr("Change drive"); ?></button>
            </div>
            <div class="card-body">
                <div class="mono">{{ status.path }}</div>
                <div class="muted mono" v-if="status.drive">{{ status.drive.source }} &middot; {{ status.drive.fstype }}</div>

                <div v-if="status.total_mb > 0">
                    <div class="bk-bar"><div :style="{width: used_percent + '%'}"></div></div>
                    <div class="muted">
                        {{ gb(status.total_mb - status.free_mb) }} <?php echo tr("used of"); ?> {{ gb(status.total_mb) }}
                        &middot; {{ gb(status.free_mb) }} <?php echo tr("free"); ?>
                    </div>
                </div>

                <div class="bk-rows bk-rows-spaced">
                    <div class="bk-row">
                        <div class="k"><?php echo tr("Last backup"); ?></div>
                        <div class="v" v-if="status.status">{{ local_time(status.status.last_run) }}
                            <span class="muted">({{ ago(status.status.last_run) }})</span></div>
                        <div class="v muted" v-else><?php echo tr("none yet"); ?></div>
                    </div>
                    <div class="bk-row" v-if="status.status">
                        <div class="k"><?php echo tr("Written"); ?></div>
                        <div class="v">{{ bytes(status.status.bytes_written) }}
                            <span class="muted"><?php echo tr("in"); ?> {{ duration(status.status.duration_seconds) }}</span></div>
                    </div>
                    <div class="bk-row" v-if="status.status && (status.status.files_repaired || status.status.files_realigned)">
                        <div class="k"><?php echo tr("Files repaired"); ?></div>
                        <div class="v">{{ status.status.files_repaired }}
                            <span class="muted">/ {{ status.status.files_realigned }} <?php echo tr("realigned"); ?></span></div>
                    </div>
                    <div class="bk-row" v-if="status.status && status.status.orphans">
                        <div class="k"><?php echo tr("Orphaned files"); ?></div>
                        <div class="v">{{ status.status.orphans }}
                            <span class="muted"><?php echo tr("on the drive, no longer in Emoncms"); ?></span></div>
                    </div>
                    <div class="bk-row" v-if="status.schedule && status.schedule.scheduled !== null">
                        <div class="k"><?php echo tr("Next backup"); ?></div>
                        <div class="v" v-if="status.schedule.scheduled && status.schedule.next_run">{{ local_time_ts(status.schedule.next_run) }}</div>
                        <div class="v" v-else-if="status.schedule.scheduled"><?php echo tr("daily"); ?></div>
                        <div class="v muted" v-else><?php echo tr("not scheduled, so this only happens when you press the button"); ?></div>
                    </div>
                </div>

                <div class="bk-actions bk-actions-spaced">
                    <button class="btn btn-primary" :disabled="busy" @click="run('drivebackup','drivebackuplog')"><?php echo tr("Back up now"); ?></button>
                    <button class="btn" :disabled="busy" @click="run('drivebackupverify','drivebackupverifylog')"><?php echo tr("Verify and repair"); ?></button>
                    <button class="btn btn-primary" v-if="status.schedule && status.schedule.scheduled === false"
                            :disabled="busy" @click="set_schedule(true)"><?php echo tr("Turn on daily backup"); ?></button>
                    <button class="btn" v-if="status.schedule && status.schedule.scheduled === true"
                            :disabled="busy" @click="set_schedule(false)"><?php echo tr("Turn off daily backup"); ?></button>
                </div>

                <details class="bk-disclosure bk-disclosure-spaced">
                    <summary><?php echo tr("How the daily backup works"); ?></summary>
                    <div>
                        <p><?php echo tr("Emoncms adds each reading to the end of a feed file, so the backup copies only what was added. That is a few MB a day rather than all of your data."); ?></p>
                        <p><?php echo tr("The database is small, so a fresh copy is saved every run. Seven days and four weeks are kept."); ?></p>
                    </div>
                </details>
                <details class="bk-disclosure">
                    <summary><?php echo tr("When should I verify?"); ?></summary>
                    <div><p><?php echo tr("The daily run only adds to the end of each file, so it cannot see a file that changed in place. Verify checks every file and repairs any difference. It runs weekly on its own, so this is only for running it early."); ?></p></div>
                </details>
                <details class="bk-disclosure">
                    <summary><?php echo tr("What this drive can do"); ?></summary>
                    <div class="bk-caps">
                        <div class="bk-cap yes">
                            <span class="mark">&check;</span>
                            <span><b><?php echo tr("Only new data is copied"); ?></b> &mdash;
                            <?php echo tr("a few MB a day, not all of your data."); ?></span>
                        </div>
                        <div class="bk-cap" :class="caps.compressed ? 'yes' : 'no'">
                            <span class="mark" v-if="caps.compressed">&check;</span><span class="mark" v-else>&ndash;</span>
                            <span v-if="caps.compressed"><b><?php echo tr("Compressed"); ?></b> &mdash;
                                <?php echo tr("the drive compresses as it writes. Feed data is about 80% smaller."); ?></span>
                            <span v-else><b><?php echo tr("Not compressed"); ?></b> &mdash;
                                <?php echo tr("files are copied as they are. A btrfs drive mounted with compress=zstd would compress them."); ?></span>
                        </div>
                        <div class="bk-cap" :class="caps.snapshots ? 'yes' : 'no'">
                            <span class="mark" v-if="caps.snapshots">&check;</span><span class="mark" v-else>&ndash;</span>
                            <span v-if="caps.snapshots"><b><?php echo tr("Dated copies of everything"); ?></b> &mdash;
                                <?php echo tr("feed data as well as the database."); ?></span>
                            <span v-else><b><?php echo tr("Dated copies of the database only"); ?></b> &mdash;
                                <?php echo tr("feed data is kept at its latest state. A btrfs drive would add this."); ?></span>
                        </div>
                    </div>
                </details>
            </div>
        </div>

        <!-- Choosing a drive.
             One list, because it is one question. Drives that are mounted and
             ready sit alongside drives that are plugged in and still need
             setting up, and each row offers whatever that drive needs next.
             Shown when there is nothing working, and when Change drive is
             pressed, rather than existing twice. -->
        <div class="card" v-if="!status.available || change_drive">
            <div class="card-header">
                <span class="card-accent"></span>
                <span class="card-name" v-if="change_drive"><?php echo tr("Change backup drive"); ?></span>
                <span class="card-name" v-else-if="!status.configured"><?php echo tr("Set up a backup drive"); ?></span>
                <span class="card-name" v-else-if="status.unresponsive"><?php echo tr("Backup drive is not responding"); ?></span>
                <span class="card-name" v-else><?php echo tr("Backup drive not available"); ?></span>
                <button class="btn btn-small" :disabled="busy || scanning" @click="scan()">{{ scanning ? T.scanning : T.scan }}</button>
            </div>
            <div class="card-body">
                <p class="muted" v-if="status.unresponsive && !change_drive">
                    <span class="mono">{{ status.path }}</span>
                    <?php echo tr("is mounted but every read and write to it fails. Unplug the drive and plug it back in, then run a backup to check."); ?>
                </p>
                <p class="muted" v-else-if="status.configured && !change_drive">
                    <?php echo tr("Nothing is mounted at"); ?> <span class="mono">{{ status.path }}</span>.
                    <?php echo tr("Reconnect it, or pick another drive."); ?>
                </p>
                <p class="muted" v-else>
                    <?php echo tr("Emoncms keeps a copy of your data on an attached drive. Plug in a USB drive and pick it below."); ?>
                </p>
                <p class="muted" v-if="!choices.length">
                    <?php echo tr("No drives found. Plug one in, then press Scan for drives."); ?>
                </p>
                <p class="muted" v-if="choices_needing_setup">
                    <?php echo tr("A drive that is not set up yet will be mounted, added to /etc/fstab so it comes back after a reboot, and used from then on."); ?>
                    <?php echo tr("Any drive can instead be erased and formatted as btrfs, which compresses feed data, checks every block it reads back and can keep dated copies of the backup."); ?>
                </p>
            </div>

            <table v-if="choices.length">
                <thead><tr>
                    <th><?php echo tr("Drive"); ?></th>
                    <th><?php echo tr("Type"); ?></th>
                    <th><?php echo tr("Space"); ?></th>
                    <th class="right"></th>
                </tr></thead>
                <tbody>
                    <template v-for="c in choices" :key="c.key">
                    <tr>
                        <td>{{ c.name }}<br><span class="muted mono">{{ c.detail }}</span></td>
                        <td><span class="bk-badge" :class="{grey: c.kind != 'removable'}">{{ kind_label(c) }}</span></td>
                        <td>{{ c.space }}</td>
                        <td class="right">
                            <button class="btn btn-small btn-primary" v-if="c.mounted"
                                    :disabled="busy" @click="pick(c.drive)">
                                {{ c.drive.initialised ? T.use_again : T.use_this_drive }}
                            </button>
                            <span class="muted" v-else-if="c.device.state == 'nomedia'"><?php echo tr("Insert a card, then scan again"); ?></span>
                            <template v-else-if="c.device.state != 'nofilesystem'">
                                <button class="btn btn-small btn-primary"
                                        :disabled="busy" @click="ask_setup(c.device, 'mount')"><?php echo tr("Set up this drive"); ?></button>
                                <button class="btn btn-small"
                                        :disabled="busy" @click="ask_setup(c.device, 'format')"><?php echo tr("Erase and format"); ?></button>
                            </template>
                            <button class="btn btn-small btn-danger" v-else
                                    :disabled="busy" @click="ask_setup(c.device, 'format')"><?php echo tr("Format and set up"); ?></button>
                        </td>
                    </tr>

                    <!-- Confirmation. It says what will be done, rather than
                         asking a yes/no question about the word "mount" -->
                    <tr v-if="!c.mounted && confirm_id == c.device.id">
                        <td colspan="4">
                            <div v-if="confirm_mode == 'mount'">
                                <div class="bk-notice">
                                    <p><b><?php echo tr("Set this drive up for backups?"); ?></b></p>
                                    <ul>
                                        <li v-if="c.device.state == 'infstab'"><?php echo tr("mount it where /etc/fstab already puts it"); ?></li>
                                        <li v-else><?php echo tr("mount it at"); ?> <span class="mono">/media/emoncms-backup</span></li>
                                        <li v-if="c.device.state != 'infstab'"><?php echo tr("add it to"); ?> <span class="mono">/etc/fstab</span>,
                                            <?php echo tr("so it comes back after a reboot"); ?></li>
                                        <li><?php echo tr("use it for backups from now on"); ?></li>
                                    </ul>
                                    <p class="muted"><?php echo tr("Nothing on the drive is erased. The current /etc/fstab is saved first, and put back if the drive will not mount."); ?></p>
                                </div>
                                <div class="bk-actions">
                                    <button class="btn" @click="cancel_setup()"><?php echo tr("Cancel"); ?></button>
                                    <button class="btn btn-primary" :disabled="busy" @click="do_mount(c.device)"><?php echo tr("Mount and use this drive"); ?></button>
                                </div>
                            </div>

                            <div v-else>
                                <div class="bk-notice danger">
                                    <p><b><?php echo tr("This erases the whole drive."); ?></b></p>
                                    <p>{{ c.device.model || c.name }} (<span class="mono">{{ c.device.disk }}</span>, {{ gb(c.device.disk_size_mb) }})
                                       <span v-if="c.device.disk_contents"><?php echo tr("currently holds:"); ?> <span class="mono">{{ c.device.disk_contents }}</span>.</span>
                                       <span v-else><?php echo tr("has no filesystem on it."); ?></span></p>
                                    <p><?php echo tr("Setting it up writes a new partition table and a btrfs filesystem, destroying everything already there, every partition included. This cannot be undone."); ?></p>
                                    <p v-if="looks_like_backup(c.device)"><b><?php echo tr("This looks like an existing Emoncms backup drive."); ?></b>
                                       <?php echo tr("The backup on it will be lost. To carry on using it as it is, choose Set up this drive instead."); ?></p>
                                    <p><?php echo tr("Check this is the drive you mean. Emoncms will not offer a drive the system runs from, but it cannot tell whether this one holds something you want."); ?></p>
                                </div>
                                <p class="muted"><?php echo tr("btrfs compresses feed data as it is written, checks every block it reads back so damage on the drive is detected, and can keep dated copies of the backup."); ?></p>
                                <p><?php echo tr("Type ERASE to confirm:"); ?></p>
                                <input type="text" v-model="erase_text" placeholder="ERASE">
                                <div class="bk-actions">
                                    <button class="btn" @click="cancel_setup()"><?php echo tr("Cancel"); ?></button>
                                    <button class="btn btn-danger" :disabled="busy || erase_text != 'ERASE'"
                                            @click="do_format_mount(c.device)"><?php echo tr("Erase, format and use this drive"); ?></button>
                                </div>
                            </div>
                        </td>
                    </tr>
                    </template>
                </tbody>
            </table>
        </div>

        <!-- What can actually be recovered, which is the proof the backup works -->
        <div class="card" v-if="status.available">
            <div class="card-header">
                <span class="card-accent"></span>
                <span class="card-name"><?php echo tr("Restore points"); ?></span>
            </div>
            <div class="card-body">
                <p class="muted"><?php echo tr("Dated copies of the database kept on the drive. Feed data is kept at its latest state, not per date."); ?></p>
                <p class="muted" v-if="!(status.sql && status.sql.length)"><?php echo tr("None yet."); ?></p>
            </div>
            <table v-if="status.sql && status.sql.length">
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
        </div>

        <!-- A different job from the drive backup, so it is kept apart from it
             rather than sitting in the middle of it -->
        <div class="bk-section"><?php echo tr("Portable copy"); ?></div>

        <div class="card">
            <div class="card-header">
                <span class="card-accent"></span>
                <span class="card-name"><?php echo tr("Download a portable copy"); ?></span>
            </div>
            <div class="card-body">
                <p class="muted"><?php echo tr("One compressed file holding everything, to keep off site or move to another emonPi or emonBase. It rewrites all of your data each time, so use it now and then rather than daily."); ?></p>
                <div class="bk-actions">
                    <button class="btn" :disabled="busy" @click="run('start','exportlog')"><?php echo tr("Build archive"); ?></button>
                    <a class="btn" v-if="archive_ready" href="<?php echo $path; ?>backup/download"><?php echo tr("Download"); ?>&nbsp;<span class="mono">{{ archive_filename }}</span></a>
                </div>
                <p class="muted bk-hint" v-if="!archive_ready"><?php echo tr("The download link appears here once the archive is built."); ?></p>
            </div>
        </div>
    </div>

    <!-- ============================== RESTORE ============================== -->
    <div v-if="tab=='restore'">

        <div class="bk-notice danger">
            <b><?php echo tr("Restoring replaces all Emoncms data on this system."); ?></b>
            <?php echo tr("Inputs, feeds, dashboards and feed data are all replaced by the copy you restore from."); ?>
        </div>

        <p class="muted"><?php echo tr("Choose where to restore from."); ?></p>

        <div class="card">
            <div class="card-header">
                <span class="card-accent"></span>
                <span class="card-name"><?php echo tr("From the backup drive"); ?></span>
                <span class="bk-badge ok" v-if="status.available"><?php echo tr("Connected"); ?></span>
                <span class="bk-badge grey" v-else><?php echo tr("Not connected"); ?></span>
            </div>
            <div class="card-body">
                <p class="muted"><?php echo tr("The copy kept up to date by the daily backup."); ?></p>

                <div v-if="status.available && status.sql && status.sql.length">
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
                        <button class="btn btn-danger" :disabled="!restore_confirm || busy" @click="do_restore()"><?php echo tr("Restore from drive"); ?></button>
                    </div>
                </div>
                <p class="muted" v-else-if="status.available"><?php echo tr("No restore points on the drive yet."); ?></p>
                <p class="muted" v-else><?php echo tr("Connect the backup drive to restore from it."); ?></p>
            </div>
        </div>

        <div class="card">
            <div class="card-header">
                <span class="card-accent"></span>
                <span class="card-name"><?php echo tr("From an archive file"); ?></span>
            </div>
            <div class="card-body">
                <p class="muted"><?php echo tr("Upload a"); ?> <span class="mono">.tar.gz</span>
                    <?php echo tr("archive downloaded from this or another Emoncms."); ?></p>
                <form action="<?php echo $path; ?>backup/upload" method="post" enctype="multipart/form-data">
                    <input type="file" name="file" id="file" accept=".gz">
                    <div class="bk-actions" style="margin-top:0.6rem">
                        <input class="btn btn-danger" type="submit" name="submit" value="<?php echo tr("Upload and restore"); ?>">
                    </div>
                </form>
                <details class="bk-disclosure" style="margin-top:0.6rem">
                    <summary><?php echo tr("The upload fails for large archives"); ?></summary>
                    <div><?php echo tr("Browsers and PHP limit the upload size. For a large archive, copy it onto the machine and run"); ?>
                        <span class="mono">./emoncms-import.sh</span>,
                        <a href="http://github.com/emoncms/backup"><?php echo tr("see the module readme"); ?></a>.
                    </div>
                </details>
            </div>
        </div>

        <div class="card">
            <div class="card-header">
                <span class="card-accent"></span>
                <span class="card-name"><?php echo tr("From an old emonSD card"); ?></span>
            </div>
            <div class="card-body">
                <p class="muted"><?php echo tr("Put the old emonPi or emonBase SD card in a USB card reader and plug it in. The data is read straight from the card, with no need to export an archive first."); ?></p>
                <p class="muted"><i><?php echo tr("Note: Update Emoncms and EmonHub to the latest version before importing."); ?></i></p>
                <label class="bk-check">
                    <input type="checkbox" v-model="sd_confirm">
                    <span><b><?php echo tr("I understand this overwrites all Emoncms data on this system"); ?></b></span>
                </label>
                <div class="bk-actions">
                    <button class="btn btn-danger" :disabled="!sd_confirm || busy" @click="run('usbimport','usbimportlog')"><?php echo tr("Import from SD card"); ?></button>
                </div>
            </div>
        </div>

        <div class="bk-notice" v-if="restore_started">
            <?php echo tr("When the restore is complete, log out then log in using the restored account details."); ?>
        </div>
    </div>

    <!-- Shared activity log -->
    <div class="card" v-if="log_text !== ''">
        <div class="card-header is-toggle" @click="show_log = !show_log">
            <span class="card-accent"></span>
            <span class="card-name">{{ log_title }}</span>
            <span class="bk-badge" v-if="busy"><?php echo tr("running"); ?></span>
            <!-- Whether the run worked. The log ends in a line that says so, but
                 that is the one line nobody scrolls down to read. -->
            <span class="bk-badge ok" v-else-if="log_result == 'ok'">&check; {{ T.ran_ok }}</span>
            <span class="bk-badge danger" v-else-if="log_result == 'error'">{{ T.ran_failed }}</span>
            <span class="bk-badge grey" v-else-if="log_result == 'skipped'">{{ T.ran_skipped }}</span>
            <span class="bk-badge danger" v-else-if="log_result == 'notstarted'">{{ T.not_started }}</span>
            <span class="bk-toggle">{{ show_log ? "\u25BE " + T.hide_log : "\u25B8 " + T.show_log }}</span>
        </div>
        <div class="card-body" v-show="show_log">
            <div class="bk-notice danger" v-if="log_result == 'notstarted'">
                <b><?php echo tr("service-runner did not start this action."); ?></b>
                <?php echo tr("It only runs actions on its whitelist, and the backup drive actions were added to Emoncms core recently. Update Emoncms, then restart service-runner:"); ?>
                <span class="mono">sudo systemctl restart service-runner</span>
            </div>
            <pre class="bk-log" ref="log">{{ log_text }}</pre>
        </div>
    </div>

    <?php if (!$servicerunner_running) { ?>
    <div class="bk-notice danger">
        <b><?php echo tr("service-runner is not running"); ?></b> &mdash;
        <?php echo tr("nothing on this page can run until it is."); ?>
        <a href="https://github.com/emoncms/emoncms/blob/master/scripts/services/install-service-runner-update.md"><?php echo tr("Installation instructions"); ?></a>
    </div>
    <?php } ?>
</div>

<script>
var backup_path = <?php echo json_encode($path); ?>;

Vue.createApp({
    data() { return {
        T: <?php echo json_encode($T); ?>,
        tab: (location.hash === "#restore" ? "restore" : "backup"),
        status: {configured: null, available: false, unresponsive: false, sql: [], free_mb: 0, total_mb: 0, path: ""},
        drives: [],
        // Drives that are plugged in but not mounted, from a scan
        devices: [],
        scanned: false,
        scanning: false,
        confirm_id: "",
        // "mount" to use a drive as it is, "format" to erase it first
        confirm_mode: "mount",
        erase_text: "",
        change_drive: false,
        busy: false,
        log_text: "",
        log_title: "",
        // "", ok, error or skipped, from the completion marker in the log
        log_result: "",
        show_log: true,
        archive_ready: <?php echo $archive_ready ? "true" : "false"; ?>,
        archive_filename: <?php echo json_encode($archive_filename); ?>,
        log_action: "",
        log_timer: false,
        log_last: "",
        log_stall: 0,
        // The log as it was before the current action was requested, until
        // the log changes. null once the script has visibly started.
        log_before: null,
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

        // Every drive that could be picked, as one list.
        //
        // Drives that are already mounted and drives that are plugged in and not
        // set up are the same question to whoever is looking at the page, so
        // they are one table with a different action per row, rather than two
        // tables that have to be read as a pair.
        choices: function() {
            var self = this, list = [];

            this.drives.forEach(function(d) {
                list.push({
                    key: "m:" + d.mountpoint,
                    mounted: true,
                    drive: d,
                    name: d.mountpoint,
                    detail: d.source + " \u00b7 " + d.fstype,
                    kind: d.kind,
                    space: self.gb(d.free_mb) + " " + self.T.free_suffix
                });
            });

            this.devices.forEach(function(d) {
                var empty = (d.state == "nomedia");
                list.push({
                    key: "d:" + d.id,
                    mounted: false,
                    device: d,
                    name: self.device_name(d),
                    detail: d.device + " \u00b7 " + (empty ? self.T.no_media : (d.fstype ? d.fstype : self.T.no_filesystem)),
                    kind: d.kind,
                    space: empty ? "\u2013" : self.gb(d.size_mb)
                });
            });

            return list;
        },

        // Whether to explain what setting a drive up will do
        choices_needing_setup: function() {
            return this.choices.some(function(c) { return !c.mounted && c.device.state != "nomedia"; });
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

            // Mounted, present, and failing every access. Worth its own message:
            // "reconnect the drive" is the wrong advice, and it is the advice the
            // absent case gives.
            if (s.unresponsive) return {
                level: "danger", headline: T.not_responding, detail: T.not_responding_d
            };
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
                // Nothing is configured, so a drive is almost certainly plugged
                // in waiting to be found. Look without making the user ask.
                if (s.configured === false && !self.scanned && !self.scanning) self.scan();
            }});
            $.ajax({url: backup_path + "backup/drivediscover", dataType: "json", success: function(d) {
                self.drives = d;
            }});
            // Only once the list is on screen, so that it stays honest after a
            // drive has been set up or unplugged. Until then it waits to be asked.
            if (self.scanned) self.scan();
        },

        // Look for drives that are plugged in but not mounted
        scan: function() {
            var self = this;
            self.scanning = true;
            $.ajax({url: backup_path + "backup/drivedevices", dataType: "json",
                success: function(d) { self.devices = d; },
                complete: function() {
                    self.scanning = false;
                    self.scanned = true;
                    // A drive that has just been set up is gone from the list,
                    // so an open confirmation no longer refers to anything
                    self.cancel_setup();
                }});
        },

        // What to call a drive. Its own label if it has one, otherwise the model
        // reported by the hardware, so it can be told apart from another drive.
        device_name: function(d) {
            if (d.label) return d.label;
            if (d.model) return d.model;
            return d.device;
        },

        // Open the confirmation for a drive, or close it if the same one is
        // pressed again. mode is "mount" or "format".
        ask_setup: function(d, mode) {
            var same = (this.confirm_id == d.id && this.confirm_mode == mode);
            this.confirm_id = same ? "" : d.id;
            this.confirm_mode = mode;
            this.erase_text = "";
        },

        cancel_setup: function() { this.confirm_id = ""; this.erase_text = ""; },

        // Whether a drive about to be erased was probably set up by this
        // module before. Only the label can be seen without mounting it.
        looks_like_backup: function(d) {
            var text = (d.label || "") + " " + (d.disk_contents || "");
            return /emoncms-backup/i.test(text);
        },

        do_mount: function(d) {
            this.cancel_setup();
            this.start("drivemount?id=" + encodeURIComponent(d.id),
                       "drivebackuplog", this.T.setting_up);
        },

        do_format_mount: function(d) {
            if (this.erase_text !== "ERASE") return;
            this.cancel_setup();
            this.start("driveformatmount?id=" + encodeURIComponent(d.id) + "&confirm=ERASE",
                       "drivebackuplog", this.T.formatting);
        },

        set_schedule: function(on) {
            this.start("driveschedule?enable=" + (on ? "1" : "0"),
                       "drivebackuplog", on ? this.T.schedule_on : this.T.schedule_off);
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
            self.show_log = true;
            self.log_action = log_action;
            self.log_title = title;
            self.log_text = "...";
            self.log_last = "";
            self.log_stall = 0;
            self.log_result = "";
            self.log_before = null;
            // The log file is only rewritten once service-runner actually
            // starts the script. Remember what it holds now, so that a log
            // left by an earlier run is not mistaken for the result of this
            // one when service-runner rejects the action and nothing runs.
            $.ajax({url: backup_path + "backup/" + log_action, dataType: "text",
                complete: function(xhr) {
                    self.log_before = (xhr.status == 200) ? xhr.responseText : "";
                    $.ajax({url: backup_path + "backup/" + action, dataType: "text", success: function(result) {
                        self.log_text = result;
                        clearInterval(self.log_timer);
                        self.log_timer = setInterval(self.poll_log, 1000);
                    }});
                }});
        },

        // Completion markers printed by the scripts. Amend there if changed here.
        is_finished: function(text) {
            var done = [
                "=== Emoncms drive backup complete! ===",
                "=== Emoncms drive backup completed with ERRORS! ===",
                "=== Emoncms drive backup skipped ===",
                "=== Emoncms drive backup ready ===",
                "=== Emoncms drive backup schedule updated ===",
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

        // What the completion marker says about a finished run. Only meaningful
        // once is_finished() is true.
        outcome: function(text) {
            if (text.indexOf("with ERRORS!") != -1) return "error";
            if (text.indexOf("skipped ===") != -1 || text.indexOf("cancelled ===") != -1) return "skipped";
            return "ok";
        },

        poll_log: function() {
            var self = this;
            $.ajax({url: backup_path + "backup/" + self.log_action, dataType: "text", success: function(result) {
                if (result == "backup module requires admin access") { location.replace("/"); return; }

                // Still the log from before this action was requested, so the
                // script has not started. service-runner starts a script within
                // a second or so of it being queued; if the log has not changed
                // after 15 seconds it has rejected the action, which it does
                // silently when the action is missing from its whitelist.
                if (self.log_before !== null) {
                    if (result === self.log_before) {
                        self.log_stall++;
                        if (self.log_stall > 15) {
                            clearInterval(self.log_timer);
                            self.busy = false;
                            self.log_result = "notstarted";
                            self.log_text = self.T.not_started_log;
                        }
                        return;
                    }
                    self.log_before = null;
                    self.log_stall = 0;
                }

                self.log_text = result;
                self.$nextTick(function() {
                    var el = self.$refs.log;
                    if (el) el.scrollTop = el.scrollHeight;
                });
                if (self.is_finished(result)) {
                    clearInterval(self.log_timer);
                    self.busy = false;
                    self.log_result = self.outcome(result);
                    self.refresh();
                    // The download link is offered from state rather than by
                    // reloading the page, so the log stays up for review
                    if (self.log_action == "exportlog" &&
                        result.indexOf("=== Emoncms export complete! ===") != -1) {
                        self.archive_ready = true;
                    }
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

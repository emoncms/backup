<?php
    global $path;    
    @exec('ps ax | grep service-runner.py | grep -v grep', $servicerunnerproc);
?>

<style>
.nav-tabs > li > a {
    color: #999!important;
}
.nav-tabs > li.active > a {
    color: #333!important;
}
.nav-tabs > li > a:hover {
    color: #333!important;
}
</style>



<ul class="nav nav-tabs mb-0 mt-3" id="backup-tabs">
    <li class="active"><a href="#view-import-usb"><?php echo tr("Import USB"); ?></a></li>
    <li><a href="#view-import-archive"><?php echo tr("Import Archive"); ?></a></li>
    <li><a href="#view-export"><?php echo tr("Export Archive"); ?></a></li>
    <li><a href="#view-drive-backup"><?php echo tr("Drive Backup"); ?></a></li>
</ul>
    
<div class="tab-content">
    <div class="tab-pane active" id="view-import-usb">
        <h3><?php echo tr("Import from USB drive"); ?></h3>
        <p><?php echo tr("Import emoncms account data from old emonSD card mounted as a USB drive."); ?></p>
        <p><?php echo tr("Place your old emonPi or emonBase SD card in a USB SD card reader and plug into one of the raspberry pi USB ports.<br>This importer will then find and import all emoncms account data without the need to export and import an archive."); ?></p>
        <span style="color:red;font-weight:bold;">
          <?php echo tr("CAUTION ALL EMONCMS ACCOUNT DATA WILL BE OVERWRITTEN BY THE IMPORTED DATA"); ?>
        </span><br><br>
        <p><i><?php echo tr("Note: Before import update to latest version of Emoncms & EmonHub."); ?></i></p>
        <button id="usb-import" class="btn btn-danger"><?php echo tr('Import from USB drive'); ?></button>
        <br><br>
        <pre id="usb-import-log-bound" class="log"><div id="usb-import-log"></div></pre>
        <br>
        <p><i><?php echo tr("Refresh page if log window does not update."); ?></i></p>
        <p><i><?php echo tr("After import is complete logout then login using the new imported account login details."); ?></i></p>
    </div>
    <div class="tab-pane" id="view-import-archive">
        <h3><?php echo tr("Import from Archive"); ?></h3>
        <p><?php echo tr("Import an emoncms backup archive."); ?></p>
        <span style="color:red;font-weight:bold;">
            <?php echo tr("CAUTION ALL EMONCMS ACCOUNT DATA WILL BE OVERWRITTEN BY THE IMPORTED DATA"); ?>
        </span><br><br>
        <p><i><?php echo tr("Note: Before import update to latest version of Emoncms & EmonHub."); ?></i></p>
        <form action="<?php echo $path; ?>backup/upload" method="post" enctype="multipart/form-data">
        <input type="file" name="file" id="file"><br><br>
        <input class="btn btn-danger" type="submit" name="submit" value="<?php echo tr("Import Backup"); ?>">
        </form>
        <br><br>
        <p><i>
            <?php echo tr("Note: If browser upload fails for large backup files"); ?> 
            <a href="http://github.com/emoncms/backup"><?php echo tr("follow manual import instructions."); ?></a>
        </i></p>
        <pre id="import-log-bound" class="log"><div id="import-log"></div></pre>
        <br>
        <p><i><?php echo tr("Refresh page if log window does not update."); ?></i></p>
        <p><i><?php echo tr("After import is complete logout then login using the new imported account login details."); ?></i></p>
    </div>
    <div class="tab-pane" id="view-export">
        <h3><?php echo tr("Export"); ?></h3>
        <p><?php echo tr("Export a compressed archive containing:"); ?></p>
        <ul>
        <li><?php echo tr("Emoncms MYSQL database"); ?></li>
        <li><?php echo tr("PHPFina data files"); ?></li>
        <li><?php echo tr("PHPTimeSeries data files"); ?></li>
        <li><?php echo tr("EmonHub Config"); ?></li>
        </ul>
        <p><?php echo tr("These files contain all Emoncms data including:"); ?></p>
        <ul>
        <li><?php echo tr("Input processes"); ?></li>
        <li><?php echo tr("Feed data"); ?></li>
        <li><?php echo tr("Dashboards"); ?></li>
        <li><?php echo tr("EmonHub Config"); ?></li>
        </ul>
        <p><?php echo tr("The compressed archive can be used to migrate data to another emonPi / emonBase."); ?></p>
        <button id="emonpi-backup" class="btn btn-info"><?php echo tr('Create backup'); ?></button>
        <br><br>
        <pre id="export-log-bound" class="log"><div id="export-log"></div></pre>
        <?php
        $backup_filename="emoncms-backup-".gethostname()."-".date("Y-m-d").".tar.gz";
        if (file_exists($parsed_ini['backup_location']."/".$backup_filename) && !file_exists("/tmp/backuplock")) {
            echo '<br><br><b>'.tr("Right Click > Download:");
            echo '</b><br><a href="'.$path.'backup/download">'.$backup_filename.'</a>';
        }
        ?>
        <br><br>
        <p><?php echo tr("Once export is complete refresh page to see download link."); ?></p>
        <p><i><?php echo tr("Note: Export can take a long time; please be patient."); ?></i></p>
    </div>
    <div class="tab-pane" id="view-drive-backup">
        <h3><?php echo tr("Backup to a drive"); ?></h3>
        <p><?php echo tr("Keeps a mirror of your Emoncms data on an attached drive, a USB disk or a NAS share, writing only what has changed since the last run."); ?></p>
        <p><?php echo tr("Feed data is stored in append only files, so a daily backup only has to write the new readings at the end of each one. This is typically a few megabytes rather than the several gigabytes a full archive export would rewrite every time, which matters for speed, for network bandwidth, and for the life of a USB flash drive."); ?></p>

        <div id="drive-backup-unconfigured" style="display:none">
            <div class="alert">
                <b><?php echo tr("No backup drive selected yet."); ?></b>
                <?php echo tr("Choose one of the drives found below, or set"); ?> <code>drive_backup_path</code>
                <?php echo tr("in the backup module"); ?> <code>config.cfg</code>.
            </div>
        </div>

        <div id="drive-picker">
            <h4><?php echo tr("Available drives"); ?></h4>
            <table class="table table-condensed">
                <thead><tr>
                    <th><?php echo tr("Mounted at"); ?></th>
                    <th><?php echo tr("Device"); ?></th>
                    <th style="width:90px"><?php echo tr("Type"); ?></th>
                    <th style="width:100px"><?php echo tr("Free"); ?></th>
                    <th style="width:150px"></th>
                </tr></thead>
                <tbody id="drive-picker-list"></tbody>
            </table>
            <p><i><?php echo tr("Only mounted drives that are not part of the system are listed. Mount your USB drive or network share first, adding it to /etc/fstab so that it is mounted again after a reboot."); ?></i></p>
        </div>

        <div id="drive-backup-unavailable" style="display:none">
            <div class="alert alert-error">
                <b><?php echo tr("Backup drive not available."); ?></b>
                <?php echo tr("The drive does not appear to be mounted at"); ?>
                <code><span id="drive-backup-unavailable-path"></span></code>.
                <?php echo tr("Scheduled backups are skipped while it is unplugged and will catch up when it is reconnected."); ?>
            </div>
        </div>

        <div id="drive-backup-available" style="display:none">
            <div id="drive-backup-result"></div>
            <table class="table table-condensed">
                <tbody>
                    <tr><td style="width:220px"><?php echo tr("Destination"); ?></td><td><code id="drive-backup-path"></code></td></tr>
                    <tr><td><?php echo tr("Last run"); ?></td><td id="drive-backup-lastrun"></td></tr>
                    <tr><td><?php echo tr("Mode"); ?></td><td id="drive-backup-mode"></td></tr>
                    <tr><td><?php echo tr("Duration"); ?></td><td id="drive-backup-duration"></td></tr>
                    <tr><td><?php echo tr("Written last run"); ?></td><td id="drive-backup-written"></td></tr>
                    <tr><td><?php echo tr("Files repaired / realigned"); ?></td><td id="drive-backup-repaired"></td></tr>
                    <tr><td><?php echo tr("Orphaned files"); ?></td><td id="drive-backup-orphans"></td></tr>
                    <tr><td><?php echo tr("Drive space free"); ?></td><td id="drive-backup-space"></td></tr>
                </tbody>
            </table>

            <h4><?php echo tr("Database snapshots"); ?></h4>
            <table class="table table-condensed">
                <thead><tr>
                    <th><?php echo tr("Snapshot"); ?></th>
                    <th style="width:100px"><?php echo tr("Retained"); ?></th>
                    <th style="width:100px"><?php echo tr("Size"); ?></th>
                </tr></thead>
                <tbody id="drive-backup-sql"></tbody>
            </table>
        </div>

        <button id="drive-backup-run" class="btn btn-info"><?php echo tr('Back up now'); ?></button>
        <button id="drive-backup-verify" class="btn"><?php echo tr('Verify and repair'); ?></button>
        <br><br>
        <p><i><?php echo tr("Verify reads every file on both sides and repairs any difference. Run it occasionally; the daily backup cannot detect a file that was rewritten in place without changing size."); ?></i></p>
        <pre id="drive-backup-log-bound" class="log"><div id="drive-backup-log"></div></pre>
        <br>
        <p><i><?php echo tr("The first run copies all of your data and can take a long time. Later runs only append what is new."); ?></i></p>

        <div id="drive-restore-section" style="display:none">
            <hr>
            <h3><?php echo tr("Restore from the backup drive"); ?></h3>
            <p><?php echo tr("Copies the feed data back from the drive and imports one of the saved database snapshots."); ?></p>
            <span style="color:red;font-weight:bold;">
                <?php echo tr("CAUTION ALL EMONCMS ACCOUNT DATA WILL BE OVERWRITTEN BY THE RESTORED DATA"); ?>
            </span><br><br>
            <p><?php echo tr("The current database is saved to the backup folder first, so a restore started by mistake can be undone. Feed data is overwritten in place and cannot be recovered this way."); ?></p>
            <p><i><?php echo tr("Emoncms settings are not restored, they belong to the system the backup was taken from."); ?></i></p>

            <label for="drive-restore-sql"><?php echo tr("Database snapshot to restore"); ?></label>
            <select id="drive-restore-sql" style="width:auto"></select>
            <br>
            <label class="checkbox">
                <input type="checkbox" id="drive-restore-delete">
                <?php echo tr("Also delete feed files that are not in the backup, making this system an exact copy of it"); ?>
            </label>
            <label class="checkbox">
                <input type="checkbox" id="drive-restore-confirm">
                <b><?php echo tr("I understand this will overwrite all Emoncms data on this system"); ?></b>
            </label>
            <br>
            <button id="drive-restore-run" class="btn btn-danger" disabled><?php echo tr('Restore from the backup drive'); ?></button>
            <br><br>
            <pre id="drive-restore-log-bound" class="log"><div id="drive-restore-log"></div></pre>
            <br>
            <p><i><?php echo tr("Refresh page if log window does not update."); ?></i></p>
            <p><i><?php echo tr("After restore is complete logout then login using the restored account login details."); ?></i></p>
        </div>
    </div>
</div>

<script>
    $(function () {
        // trigger tab open on click (adding hash to location)
        $('#backup-tabs a').click(function (e) {
            e.preventDefault();
            var href = $(e.target).attr('href');
            selectTab(href.replace('view-',''));
            // show tab
            $(this).tab('show');
            // change hash
            location.hash = href.replace('view-','');
        })
        // pre-select tab on load
        // @todo: fix slight delay from ajax calls
        selectTab();

        // on hash change
        $(window).on('hashchange', function(event) {
            selectTab(location.hash);
        })
        /**
         * loop through all tabs and highlight one if given [hash] is a match
         */
        function selectTab(hash) {
            hash = hash || location.hash;

            $.each($('#backup-tabs a'), function(i,elem) {
                var $tab = $(elem);
                if($tab.attr('href') == hash.replace('#','#view-')) {
                    $tab.tab('show');
                }
            });
        }
})
</script>

  <?php
    if (empty($servicerunnerproc)) {
        echo "<div class='alert alert-error'><b>".tr("Warning:");
        echo "</b> ".tr("service-runner is not running and is required. To install service-runner see");
        echo " <a href='https://github.com/emoncms/emoncms/blob/master/scripts/services/install-service-runner-update.md'>";
        echo tr("service-runner installation")."</a></div>";
    }
  ?>

<script>
export_log_update();
import_log_update();
var export_updater = false;
var import_updater = false;
var usb_import_updater = false;
export_updater = setInterval(export_log_update,1000);
import_updater = setInterval(import_log_update,1000);
usb_import_updater = setInterval(usb_import_log_update,1000);

$("#emonpi-backup").click(function() {
  $.ajax({ url: path+"backup/start", async: true, dataType: "text", success: function(result) {
      $("#export-log").text(result);
      clearInterval(export_updater);
      export_updater = setInterval(export_log_update,1000);
    }
  });
});

$("#usb-import").click(function() {
  $.ajax({ url: path+"backup/usbimport", async: true, dataType: "text", success: function(result) {
      $("#usb-import-log").text(result);
      clearInterval(usb_import_updater);
      usb_import_updater = setInterval(usb_import_log_update,1000);
    }
  });
});

function export_log_update() {
  $.ajax({ url: path+"backup/exportlog", async: true, dataType: "text", success: function(result)
    {
      $("#export-log").text(result);
      document.getElementById("export-log-bound").scrollTop = document.getElementById("export-log-bound").scrollHeight

      if (result.indexOf("=== Emoncms export complete! ===")!=-1 || result.indexOf("=== Emoncms export completed with ERRORS! ===")!=-1) {
          clearInterval(export_updater);
      }
    }
  });
}

function import_log_update() {
  $.ajax({ url: path+"backup/importlog", async: true, dataType: "text", success: function(result)
    {
      if (result=="backup module requires admin access") location.replace("/");
      $("#import-log").text(result);
      document.getElementById("import-log-bound").scrollTop = document.getElementById("import-log-bound").scrollHeight

      if (result.indexOf("=== Emoncms import complete! ===")!=-1) {
          clearInterval(import_updater);
      }
    }
  });
}

function usb_import_log_update() {
  $.ajax({ url: path+"backup/usbimportlog", async: true, dataType: "text", success: function(result)
    {
      if (result=="backup module requires admin access") location.replace("/");
      $("#usb-import-log").text(result);
      document.getElementById("usb-import-log-bound").scrollTop = document.getElementById("usb-import-log-bound").scrollHeight

      if (result.indexOf("=== Emoncms import complete! ===")!=-1) {
          clearInterval(usb_import_updater);
      }
    }
  });
}

// ---------------------------------------------------------------------------
// Write efficient USB drive backup
//
// Unlike the log windows above this only polls while a run is in progress,
// the status panel is loaded once on page load and refreshed when a run ends.
// ---------------------------------------------------------------------------
var drive_backup_updater = false;
var drive_backup_log_action = "drivebackuplog";

drive_backup_status_update();
drive_picker_update();

// Drives that could hold a backup. The list comes from drive-backup.sh --discover,
// and selecting one is the only way the interface can set the destination.
function drive_picker_update() {
  $.ajax({ url: path+"backup/drivediscover", async: true, dataType: "json", success: function(drives) {
      var rows = "";
      for (var i=0; i<drives.length; i++) {
        var d = drives[i];
        var mp = $("<div>").text(d.mountpoint).html();
        var label = d.initialised
          ? <?php echo json_encode(tr("Already prepared")); ?>
          : <?php echo json_encode(tr("Use this drive")); ?>;
        rows += "<tr><td><code>"+mp+"</code></td>"
              + "<td>"+$("<div>").text(d.source).html()+"</td>"
              + "<td>"+d.kind+" / "+$("<div>").text(d.fstype).html()+"</td>"
              + "<td>"+Math.round(d.free_mb/1024*10)/10+" GB</td>"
              + "<td><button class=\"btn btn-small drive-pick\" data-mountpoint=\""+mp+"\">"+label+"</button></td></tr>";
      }
      if (rows === "") rows = '<tr><td colspan="5">' + <?php echo json_encode(tr("No suitable drives found. Mount a USB drive or network share first.")); ?> + '</td></tr>';
      $("#drive-picker-list").html(rows);
    }
  });
}

$(document).on("click", ".drive-pick", function() {
  var mountpoint = $(this).data("mountpoint");
  if (!confirm(<?php echo json_encode(tr("Use this drive for Emoncms backups?")); ?> + "\n\n" + mountpoint)) return;
  $(".drive-pick").prop("disabled", true);
  drive_backup_log_action = "drivebackuplog";
  $.ajax({ url: path+"backup/drivesetpath?mountpoint="+encodeURIComponent(mountpoint),
    async: true, dataType: "text", success: function(result) {
      $("#drive-backup-log").text(result);
      clearInterval(drive_backup_updater);
      drive_backup_updater = setInterval(drive_backup_log_update, 1000);
    }
  });
});

function drive_backup_human_bytes(bytes) {
  if (bytes === undefined || bytes === null) return "-";
  var units = ["B","kB","MB","GB","TB"];
  var i = 0;
  while (bytes >= 1024 && i < units.length-1) { bytes = bytes/1024; i++; }
  return (i === 0 ? bytes : bytes.toFixed(1)) + " " + units[i];
}

function drive_backup_status_update() {
  $.ajax({ url: path+"backup/drivebackupstatus", async: true, dataType: "json", success: function(s) {
      $("#drive-backup-unconfigured").hide();
      $("#drive-backup-unavailable").hide();
      $("#drive-backup-available").hide();

      if (!s.configured) {
        $("#drive-backup-unconfigured").show();
        $("#drive-backup-run, #drive-backup-verify").prop("disabled", true);
        return;
      }
      $("#drive-backup-run, #drive-backup-verify").prop("disabled", false);

      if (!s.available) {
        $("#drive-backup-unavailable-path").text(s.path);
        $("#drive-backup-unavailable").show();
        return;
      }

      $("#drive-backup-available").show();
      $("#drive-backup-path").text(s.path);
      $("#drive-backup-space").text(s.free_mb + " MB / " + s.total_mb + " MB");

      if (s.status) {
        var st = s.status;
        // last_run is written as UTC, show it in the browser's local time
        var d = new Date(st.last_run);
        $("#drive-backup-lastrun").text(isNaN(d.getTime()) ? st.last_run : d.toLocaleString());
        $("#drive-backup-mode").text(st.mode + (st.dry_run ? " (dry run)" : ""));
        $("#drive-backup-duration").text(st.duration_seconds + " s");
        $("#drive-backup-written").text(drive_backup_human_bytes(st.bytes_written));
        $("#drive-backup-repaired").text(st.files_repaired + " / " + st.files_realigned);
        $("#drive-backup-orphans").text(st.orphans);

        if (st.errors) {
          $("#drive-backup-result").html('<div class="alert alert-error"><b>' + <?php echo json_encode(tr("The last backup finished with errors.")); ?> + '</b> ' + <?php echo json_encode(tr("See the log below.")); ?> + '</div>');
        } else {
          $("#drive-backup-result").html('<div class="alert alert-success"><b>' + <?php echo json_encode(tr("Last backup completed successfully.")); ?> + '</b></div>');
        }
      } else {
        $("#drive-backup-lastrun").text(<?php echo json_encode(tr("Never")); ?>);
        $("#drive-backup-result").html('<div class="alert">' + <?php echo json_encode(tr("The drive is ready but no backup has run yet.")); ?> + '</div>');
      }

      var rows = "";
      var options = "";
      for (var i=0; i<s.sql.length; i++) {
        var name = $("<div>").text(s.sql[i].name).html();
        rows += "<tr><td>"+name+"</td><td>"+s.sql[i].period+"</td><td>"+s.sql[i].size_mb+" MB</td></tr>";
        options += "<option value=\""+name+"\">"+name+" ("+s.sql[i].period+")</option>";
      }
      if (rows === "") rows = '<tr><td colspan="3">' + <?php echo json_encode(tr("No database snapshots yet")); ?> + '</td></tr>';
      $("#drive-backup-sql").html(rows);

      // Restore is only offered when there is actually a snapshot to restore from
      $("#drive-restore-sql").html(options);
      if (s.sql.length > 0) {
        $("#drive-restore-section").show();
      } else {
        $("#drive-restore-section").hide();
      }
    }
  });
}

function drive_backup_start(action, log_action) {
  drive_backup_log_action = log_action;
  $("#drive-backup-run, #drive-backup-verify").prop("disabled", true);
  $.ajax({ url: path+"backup/"+action, async: true, dataType: "text", success: function(result) {
      $("#drive-backup-log").text(result);
      clearInterval(drive_backup_updater);
      drive_backup_updater = setInterval(drive_backup_log_update, 1000);
    }
  });
}

$("#drive-backup-run").click(function() { drive_backup_start("drivebackup", "drivebackuplog"); });
$("#drive-backup-verify").click(function() { drive_backup_start("drivebackupverify", "drivebackupverifylog"); });

function drive_backup_log_update() {
  $.ajax({ url: path+"backup/"+drive_backup_log_action, async: true, dataType: "text", success: function(result)
    {
      if (result=="backup module requires admin access") location.replace("/");
      $("#drive-backup-log").text(result);
      document.getElementById("drive-backup-log-bound").scrollTop = document.getElementById("drive-backup-log-bound").scrollHeight

      // These strings are printed by drive-backup.sh, amend there if changed here
      if (result.indexOf("=== Emoncms drive backup ready ===")!=-1 ||
          result.indexOf("=== Emoncms drive backup complete! ===")!=-1 ||
          result.indexOf("=== Emoncms drive backup completed with ERRORS! ===")!=-1 ||
          result.indexOf("=== Emoncms drive backup skipped ===")!=-1) {
          clearInterval(drive_backup_updater);
          $("#drive-backup-run, #drive-backup-verify").prop("disabled", false);
          $(".drive-pick").prop("disabled", false);
          drive_backup_status_update();
          drive_picker_update();
      }
    }
  });
}

// ---------------------------------------------------------------------------
// Restore from the USB drive. This overwrites all Emoncms data, so the button
// stays disabled until the confirmation box is ticked.
// ---------------------------------------------------------------------------
var drive_restore_updater = false;

$("#drive-restore-confirm").change(function() {
  $("#drive-restore-run").prop("disabled", !$(this).is(":checked"));
});

$("#drive-restore-run").click(function() {
  if (!$("#drive-restore-confirm").is(":checked")) return;

  var url = path+"backup/driverestore?sql="+encodeURIComponent($("#drive-restore-sql").val());
  if ($("#drive-restore-delete").is(":checked")) url += "&delete=1";

  $("#drive-restore-run").prop("disabled", true);
  $("#drive-restore-confirm").prop("checked", false);
  $.ajax({ url: url, async: true, dataType: "text", success: function(result) {
      $("#drive-restore-log").text(result);
      clearInterval(drive_restore_updater);
      drive_restore_updater = setInterval(drive_restore_log_update, 1000);
    }
  });
});

function drive_restore_log_update() {
  $.ajax({ url: path+"backup/driverestorelog", async: true, dataType: "text", success: function(result)
    {
      if (result=="backup module requires admin access") location.replace("/");
      $("#drive-restore-log").text(result);
      document.getElementById("drive-restore-log-bound").scrollTop = document.getElementById("drive-restore-log-bound").scrollHeight

      // These strings are printed by drive-restore.sh, amend there if changed here
      if (result.indexOf("=== Emoncms drive restore complete! ===")!=-1 ||
          result.indexOf("=== Emoncms drive restore completed with ERRORS! ===")!=-1 ||
          result.indexOf("=== Emoncms drive restore cancelled ===")!=-1) {
          clearInterval(drive_restore_updater);
          drive_backup_status_update();
      }
    }
  });
}

</script>

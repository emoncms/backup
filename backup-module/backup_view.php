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
.emonpi-backup-type {
    display: none;
}
#current-schedule {
    white-space: pre-line;
}
</style>



<ul class="nav nav-tabs mb-0 mt-3" id="backup-tabs">
    <li class="active"><a href="#view-import-usb">Import USB</a></li>
    <li><a href="#view-import-archive">Import Archive</a></li>
    <li><a href="#view-export">Export</a></li>
</ul>
    
<div class="tab-content">
    <div class="tab-pane active" id="view-import-usb">
        <h3>Import from USB drive</h3>
        <p>Import emoncms account data from old emonSD card mounted as a USB drive.</p>
        <p>Place your old emonPi or emonBase SD card in a USB SD card reader and plug into one of the raspberry pi USB ports.<br>This importer will then find and import all emoncms account data without the need to export and import an archive.</p>
        <span style="color:red;font-weight:bold;">CAUTION ALL EMONCMS ACCOUNT DATA WILL BE OVERWRITTEN BY THE IMPORTED DATA</span><br><br>
        <p><i>Note: Before import update to latest version of Emoncms & emonHub.</i></p>
        <button id="usb-import" class="btn btn-danger"><?php echo _('Import from USB drive'); ?></button>
        <br><br>
        <pre id="usb-import-log-bound" class="log"><div id="usb-import-log"></div></pre>
        <br>
        <p><i>Refresh page if log window does not update.</i></p>
        <p><i>After import is complete logout then login using the new imported account login details.</i></p>
    </div>
    <div class="tab-pane" id="view-import-archive">
        <h3>Import from Archive</h3>
        <p>Import an emoncms backup archive.</p>
        <span style="color:red;font-weight:bold;">CAUTION ALL EMONCMS ACCOUNT DATA WILL BE OVERWRITTEN BY THE IMPORTED DATA</span><br><br>
        <p><i>Note: Before import update to latest version of Emoncms & emonHub.</i></p>
        <form action="<?php echo $path; ?>backup/upload" method="post" enctype="multipart/form-data">
        <input type="file" name="file" id="file"><br><br>
        <input class="btn btn-danger" type="submit" name="submit" value="Import Backup">
        </form>
        <br><br>
        <p><i>Note: If browser upload fails for large backup files <a href="http://github.com/emoncms/backup">follow manual import instructions.</a></i></p>
        <pre id="import-log-bound" class="log"><div id="import-log"></div></pre>
        <br>
        <p><i>Refresh page if log window does not update.</i></p>
        <p><i>After import is complete logout then login using the new imported account login details.</i></p>
    </div>
    <div class="tab-pane" id="view-export">
        <h3>Export</h3>
        <p>Export a compressed archive containing:</p>
        <ul>
        <li>Emoncms MYSQL database</li>
        <li>PHPFina data files</li>
        <li>PHPTimeSeries data files</li>
        <li>EmonHub Config</li>
        </ul>
        <p>These files contain all Emoncms data including:</p>
        <ul>
        <li>Input processes</li>
        <li>Feed data</li>
        <li>Dashboards</li>
        <li>EmonHub Config</li>
        </ul>
        <p>The compressed archive can be used to migrate data to another emonPi / emonBase.</p>
        <select id="emonpi-backup-type">
            <?php foreach ($backup_types AS $k => $v) : ?>
            <option value="<?php echo $k; ?>"><?php echo $v; ?></option>
            <?php endforeach; ?>
        </select>
        <br>
        <div class="emonpi-backup-type emonpi-backup-type-nfs">
            <label for="emonpi-backup-location">Backup location (x.x.x.x:/path/to/share)</label>
            <input id="emonpi-backup-location" type="text" value="">
            <br>
        </div>
        <div class="emonpi-backup-type emonpi-backup-type-drive">
            <label for="emonpi-backup-device">Backup device</label>
            <select id="emonpi-backup-device">
                <option>None</option>
                <?php foreach ($block_devices AS $block_device) : ?>
                <?php     if ($block_device['type'] == 'part') : ?>
                <option <?php echo ($block_device['mountpoint'] != '' ? "disabled=disabled" : ""); ?> value="<?php echo $block_device['path']; ?>"><?php echo $block_device['path']; ?></option>
                <?php     endif; ?>
                <?php endforeach; ?>
            </select>
            <br>
        </div>
        <h4>Current Schedule Script</h4>
        <span id="current-schedule"></span>
        <br><br>
        <button id="emonpi-backup" class="btn btn-info"><?php echo _('Create backup'); ?></button>
        <button id="emonpi-backup-schedule" class="btn btn-success"><?php echo _('Create backup schedule'); ?></button>
        <button id="emonpi-backup-unschedule" class="btn btn-danger"><?php echo _('Delete backup schedule'); ?></button>
        <br><br>
        <pre id="export-log-bound" class="log"><div id="export-log"></div></pre>
        <?php
        $backup_filename="emoncms-backup-".date("Y-m-d").".tar.gz";
        if (file_exists($parsed_ini['backup_location']."/".$backup_filename) && !file_exists("/tmp/backuplock")) {
            echo '<br><br><b>Right Click > Download:</b><br><a href="'.$path.'backup/download">'.$backup_filename.'</a>';
        }
        ?>
        <br><br>
        <p>Once export is complete refresh page to see download link.</p>
        <p><i>Note: Export can take a long some time, please be patient.</i></p>
    </div>
</div>

<script>
    $(function () {
	$('#emonpi-backup-type').change(function(e) {
            updateForm(this.value);
	});
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
	/**
         * change the visible form fields
	 */
	function updateForm(backupType) {
            jQuery('.emonpi-backup-type').hide();
            jQuery('.emonpi-backup-type-'+backupType).show();
        }
    })
</script>

  <?php
    if (empty($servicerunnerproc)) {
        echo "<div class='alert alert-error'><b>Warning:</b> service-runner is not running and is required. To install service-runner see <a href='https://github.com/emoncms/emoncms/blob/master/scripts/services/install-service-runner-update.md'>service-runner installation</a></div>";
    }
  ?>

<script>
schedule_update();
export_log_update();
import_log_update();
var export_updater = false;
var import_updater = false;
var usb_import_updater = false;
export_updater = setInterval(export_log_update,1000);
import_updater = setInterval(import_log_update,1000);
usb_import_updater = setInterval(usb_import_log_update,1000);

function getEmonpiBackupData() {
  var backupType = $('#emonpi-backup-type option:selected').val();
  var backupLocation = 'NONE';
  switch (backupType) {
    case 'nfs':
      backupLocation = $('#emonpi-backup-location').val();
      break;
    case 'drive':
      backupLocation = $('#emonpi-backup-device option:selected').val();
      break;
  }
  return { backupType: backupType, backupLocation: backupLocation };
}

$("#emonpi-backup").click(function() {
  var backupData = getEmonpiBackupData();
  $.ajax({ url: path+"backup/start", async: true, dataType: "text", data: backupData, success: function(result) {
      $("#export-log").html(result);
      clearInterval(export_updater);
      export_updater = setInterval(export_log_update,1000);
    }
  });
});

$('#emonpi-backup-schedule').click(function() {
  var backupData = getEmonpiBackupData();
  $.ajax({ url: path+"backup/schedule", async: true, dataType: "text", data: backupData, success: function(result) {
      schedule_update();
    }
  });
});

$('#emonpi-backup-unschedule').click(function() {
  var backupData = getEmonpiBackupData();
  $.ajax({ url: path+"backup/unschedule", async: true, dataType: "text", data: backupData, success: function(result) {
      schedule_update();
    }
  });
});

$("#usb-import").click(function() {
  $.ajax({ url: path+"backup/usbimport", async: true, dataType: "text", success: function(result) {
      $("#usb-import-log").html(result);
      clearInterval(usb_import_updater);
      usb_import_updater = setInterval(usb_import_log_update,1000);
    }
  });
});

function schedule_update() {
  $.ajax({ url: path+"backup/schedulefile", async: true, dataType: "text", success: function(result)
    {
      $("#current-schedule").html(result);
    }
  });
}

function export_log_update() {
  $.ajax({ url: path+"backup/exportlog", async: true, dataType: "text", success: function(result)
    {
      $("#export-log").html(result);
      document.getElementById("export-log-bound").scrollTop = document.getElementById("export-log-bound").scrollHeight

      if (result.indexOf("=== Emoncms export complete! ===")!=-1) {
          clearInterval(export_updater);
      }
    }
  });
}

function import_log_update() {
  $.ajax({ url: path+"backup/importlog", async: true, dataType: "text", success: function(result)
    {
      if (result=="backup module requires admin access") location.replace("/");
      $("#import-log").html(result);
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
      $("#usb-import-log").html(result);
      document.getElementById("usb-import-log-bound").scrollTop = document.getElementById("usb-import-log-bound").scrollHeight

      if (result.indexOf("=== Emoncms import complete! ===")!=-1) {
          clearInterval(usb_import_updater);
      }
    }
  });
}


</script>

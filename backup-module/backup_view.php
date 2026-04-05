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
        $backup_filepath=$parsed_ini['backup_location']."/".$backup_filename;
        if (file_exists($backup_filepath) && !file_exists("/tmp/backuplock")) {
            $size = filesize($backup_filepath);
            echo '<br><br><b>'.tr("Right Click > Download:");
            echo '</b><br><a href="'.$path.'backup/download">'.$backup_filename.'</a>';
            if ($size !== false) {
                // TODO: This isn't RTL friendly, need to parameterise number in message
                echo " (" . ( $size/1024/1024 ) . tr(" MB") . ")";
            }
        }
        ?>
        <br><br>
        <p><?php echo tr("Once export is complete refresh page to see download link."); ?></p>
        <p><i><?php echo tr("Note: Export can take a long time; please be patient."); ?></i></p>
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
      $("#export-log").html(result);
      clearInterval(export_updater);
      export_updater = setInterval(export_log_update,1000);
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

function export_log_update() {
  $.ajax({ url: path+"backup/exportlog", async: true, dataType: "text", success: function(result)
    {
      $("#export-log").html(result);
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

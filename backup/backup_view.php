<?php
    global $path;
?>

<style>
pre {
    width:80%;
    height:300px;


    margin:0px;
    padding:0px;
    font-size:16px;
    color:#fff;
    background-color:#300a24;
    overflow: scroll;
    overflow-x: hidden;

    font-size:16px;
}
#export-log {
    padding-left:20px;
    padding-top:20px;
}
#import-log {
    padding-left:20px;
    padding-top:20px;
}
</style>

<br>
<h2>Backup</h2>
<table class="table">
<tr>
    <td>
        <h3>Export</h3>
        <p>Export a compressed archive containing the emoncms mysql database, phpfina, phptimeseries data files, emonhub.conf and emoncms.conf. This can be used to migrate data to another emonpi or emonbase. Refresh page to see archive download link once export is complete.</p>

        <pre id="export-log-bound"><div id="export-log"></div></pre>
    </td>
    <td class="buttons"><br>
        <button id="emonpi-backup" class="btn btn-info"><?php echo _('Create backup'); ?></button>
        <?php
        $backup_filename="emoncms-backup-".date("Y-m-d").".tar.gz";
        if (file_exists("/home/pi/data/$backup_filename") && !file_exists("/tmp/backuplock"))
        {
            echo '<br><br><b>Download ready:</b><br><a href="'.$path.'backup/download">Download Backup</a>';
        }
        ?>
    </td>
</tr>

<tr>
    <td>
        <h3>Import</h3>
        <p>Import an emoncms backup archive containing the emoncms mysql database, phpfina, phptimeseries data files, emonhub.conf and emoncms.conf.</p>
        <p>Before import ensure latest version of Emoncms & emonHub.</p>
	<p><b>*CAUTION ALL EMONCMS ACCOUNT DATA WILL BE OVERWRITTEN BY THE IMPORTETD DATA*</b></p>
	<p>Note: If browser upload fails for large backup files <a href="http://github.com/emoncms/backup">follow manual import instructions.</a> </p>
        <pre id="import-log-bound"><div id="import-log"></div></pre>
        <p>After import is complete logout then login using the imported account login details</p>
    </td>
    <td>
        <form action="<?php echo $path; ?>backup/upload" method="post" enctype="multipart/form-data">
        <input type="file" name="file" id="file"><br><br>
        <input class="btn btn-info" type="submit" name="submit" value="Import Backup">
        </form>
    </td>
</tr>

</table>

<script>

var path = "<?php echo $path; ?>";

export_log_update();
import_log_update();
var export_updater = false;
var import_updater = false;
export_updater = setInterval(export_log_update,1000);
import_updater = setInterval(import_log_update,1000);

$("#emonpi-backup").click(function() {
  $.ajax({ url: path+"backup/start", async: true, dataType: "text", success: function(result) {
      $("#export-log").html(result);
      export_updater = setInterval(export_log_update,1000);
    }
  });
});

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
      $("#import-log").html(result);
      document.getElementById("import-log-bound").scrollTop = document.getElementById("import-log-bound").scrollHeight


      if (result.indexOf("=== Emoncms import complete! ===")!=-1) {
          clearInterval(import_updater);
      }
    }
  });
}
</script>

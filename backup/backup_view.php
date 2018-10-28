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
<hr>
<table class="table">
<tr>
  <h3>Export</h3>
  <p>Export a compressed archive containing:</p>
  <ul>
    <li>Emoncms MYSQL database</li>
    <li>PHPFINA data files</li>
    <li>PHPTIMESERIES data files</li>
    <li>EmonHub Config</li>
    <li>Emoncms Config</li>
  </ul>
  <p>These files contain all Emoncms data including:</p>
  <ul>
    <li>Input processes</li>
    <li>Feed data</li>
    <li>Dashboards</li>
    <li>EmonHub Config</li>
  </ul>
  <p>The compressed archive can be used to migrate data to another emonPi / emonBase.</p>
  <button id="emonpi-backup" class="btn btn-info"><?php echo _('Create backup'); ?></button>
  <br><br>
  <pre id="export-log-bound"><div id="export-log"></div></pre>
  <?php
  $backup_filename="emoncms-backup-".date("Y-m-d").".tar.gz";
  if (file_exists("/home/pi/data/$backup_filename") && !file_exists("/tmp/backuplock"))
  {
      echo '<br><br><b>Right Click > Download:</b><br><a href="'.$path.'backup/download">'.$backup_filename.'</a>';
  }
  ?>
  <br><br>
  <p>Once export is complete refresh page to see download link.</p>
  
  <p><i>Note: Export can take a long some time, please be patient.</i></p>
  
</tr>
<hr>
<tr>
  <h3>Import</h3>
  <p>Import an emoncms backup archive.</p>
  <span style="color:red;font-weight:bold;">CAUTION ALL EMONCMS ACCOUNT DATA WILL BE OVERWRITTEN BY THE IMPORTED DATA</span><br><br>
  <p><i>Note: Before import update to latest version of Emoncms & emonHub.</i></p>
  <form action="<?php echo $path; ?>backup/upload" method="post" enctype="multipart/form-data">
    <input type="file" name="file" id="file"><br><br>
    <input class="btn btn-danger" type="submit" name="submit" value="Import Backup">
  </form>
  <br><br>
  <p><i>Note: If browser upload fails for large backup files <a href="http://github.com/emoncms/backup">follow manual import instructions.</a></i></p>
  <pre id="import-log-bound"><div id="import-log"></div></pre>
  <br>
  <p><i>Refresh page if log window does not update.</i></p>
  <p><i>After import is complete logout then login using the new imported account login details.</i></p>
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

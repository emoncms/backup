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
#console-out {
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
        <p>Create a compressed archive containing the emoncms mysql database, phpfina, phptimeseries data files, emonhub.conf and emoncms.conf. This can be used to migrate data to another emonpi or emonbase. Depending on your data size it may take a while to prepare the backup file. Once ready a link will appear here from which the backup can then be downloaded. Refresh the page to see the link.</p>
        
        <pre id="log"><div id="console-out"></div></pre>
    </td>
    <td class="buttons"><br>
        <button id="emonpi-backup" class="btn btn-info"><?php echo _('Create backup'); ?></button>
        <?php 
        if (file_exists("/home/pi/data/backup.tar.gz") && !file_exists("/tmp/backuplock")) {
            echo '<br><br><b>Download ready:</b><br><a href="'.$path.'backup/download">backup.tar.gz</a>';
        }
        ?>
    </td>
</tr>

<tr>
    <td>
        <h3>Import</h3>
        <p>Import an emoncms backup archive containing the emoncms mysql database, phpfina, phptimeseries data files, emonhub.conf and emoncms.conf.</p>
        <div id="emonpi-backup-reply" style="display:none"></div>
    </td>
    <td>
        <form action="<?php echo $path; ?>backup/upload" method="post" enctype="multipart/form-data">
        <input type="hidden" name="MAX_FILE_SIZE" value="20971520" />
        <input type="file" name="file" id="file"><br><br>
        <input class="btn btn-info" type="submit" name="submit" value="Import Backup">
        </form>
    </td>
</tr>

</table>

<script>

var path = "<?php echo $path; ?>";

logupdate();
var updater = false;


$("#emonpi-backup").click(function() {
  $.ajax({ url: path+"backup/start", async: true, dataType: "text", success: function(result) {
      $("#console-out").html(result);
      updater = setInterval(logupdate,1000);
    }
  });
});

function logupdate() {
  $.ajax({ url: path+"backup/log", async: true, dataType: "text", success: function(result)
    {
      $("#console-out").html(result);
      document.getElementById("log").scrollTop = document.getElementById("log").scrollHeight 
        
      if (result.indexOf("Starting RPI")!=-1) {
          clearInterval(updater);
      }
    }
  });
}
</script>

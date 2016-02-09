<?php
    /*
     All Emoncms code is released under the GNU Affero General Public License.
     See COPYRIGHT.txt and LICENSE.txt.

        ---------------------------------------------------------------------
        Emoncms - open source energy visualisation
        Part of the OpenEnergyMonitor project:
        http://openenergymonitor.org
    */

    // no direct access
    defined('EMONCMS_EXEC') or die('Restricted access');

function backup_controller()
{
    global $route, $session, $path;
    $result = false;

    $export_flag = "/tmp/emoncms-flag-export";
    $export_script = "/home/pi/backup/emoncms-export.sh";
    $export_logfile = "/home/pi/data/emoncms-export.log";

    $import_flag = "/tmp/emoncms-flag-import";
    $import_script = "/home/pi/backup/emoncms-import.sh";
    $import_logfile = "/home/pi/data/emoncms-import.log";

    // This module is only to be ran by the admin user
    if (!$session['write'] && !$session['admin']) return array('content'=>false);

    if ($route->format == 'html' && $route->action == "") {
        $result = view("Modules/backup/backup_view.php",array());
    }

    if ($route->action == 'start') {
        $route->format = "text";
        $fh = @fopen($export_flag,"w");
        if (!$fh) {
            $result = "ERROR: Can't write the flag $export_flag.";
        } else {
            fwrite($fh,"$export_script>$export_logfile");
            $result = "Backup flag set";
        }
        @fclose($fh);
    }

    if ($route->action == 'exportlog') {
        $route->format = "text";
        ob_start();
        passthru("cat $export_logfile");
        $result = trim(ob_get_clean());
    }

    if ($route->action == 'importlog') {
        $route->format = "text";
        ob_start();
        passthru("cat $import_logfile");
        $result = trim(ob_get_clean());
    }

    if ($route->action == "download") {
        header("Content-type: application/zip");
        $backup_filename="emoncms-backup-".date("Y-m-d")."tar.gz";
        header("Content-Disposition: attachment; filename=$filename"); 
        header("Pragma: no-cache");
        header("Expires: 0");
        readfile("/home/pi/data/$backup_filename");
        exit;
    }

    if ($route->action == "upload") {
        // These need to be set in php.ini
        // ini_set('upload_max_filesize', '200M');
        // ini_set('post_max_size', '200M');
        $target_path = "/home/pi/data/uploads/";
        $target_path = $target_path . basename( $_FILES['file']['name']);

        if (move_uploaded_file($_FILES['file']['tmp_name'], $target_path)) {

            $fh = @fopen($import_flag,"w");
            if (!$fh) {
                $result = "ERROR: Can't write the flag $import_flag.";
            } else {
                fwrite($fh,"$import_script>$import_logfile");
                $result = "Backup flag set";
            }
            @fclose($fh);

            header('Location: '.$path.'backup');
        } else {
            $result = "There was an error uploading the file, please try again!";
        }
    }

    return array('content'=>$result);
}

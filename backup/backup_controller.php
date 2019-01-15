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
    global $route, $session, $path, $redis, $homedir;
    $result = false;

    // This module is only to be ran by the admin user
    if (!$session['write'] && !$session['admin']) return array('content'=>false);
    
    if (!file_exists("$homedir/backup/config.cfg")) return "missing backup config.cfg";
    
    $parsed_ini = parse_ini_file("$homedir/backup/config.cfg", true);

    $export_flag = "/tmp/emoncms-flag-export";
    $export_script = $parsed_ini['backup_script_location']."/emoncms-export.sh";
    $export_logfile = $parsed_ini['backup_location']."/emoncms-export.log";

    $import_flag = "/tmp/emoncms-flag-import";
    $import_script = $parsed_ini['backup_script_location']."/emoncms-import.sh";
    $import_logfile = $parsed_ini['backup_location']."/emoncms-import.log";

    if ($route->format == 'html' && $route->action == "") {
        $result = view("Modules/backup/backup_view.php",array());
    }

    if ($route->action == 'start') {
        $route->format = "text";
        
        $redis->rpush("service-runner","$export_script $export_flag>$export_logfile");
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
        $backup_filename="emoncms-backup-".date("Y-m-d").".tar.gz";
        header("Content-Disposition: attachment; filename=$backup_filename");
        header("Pragma: no-cache");
        header("Expires: 0");
        readfile($parsed_ini['backup_location']."/".$backup_filename);
        exit;
    }

    if ($route->action == "upload") {
        // These need to be set in php.ini
        // ini_set('upload_max_filesize', '200M');
        // ini_set('post_max_size', '200M');
        $uploadOk = 1;
        $target_path = $parsed_ini['backup_location']."/uploads/";
        $target_path = $target_path . basename( $_FILES['file']['name']);
        
        $imageFileType = pathinfo($target_path,PATHINFO_EXTENSION);
        
        // Allow certain file formats
        if($imageFileType != "gz")
        {
            $result="Sorry, only .tar.gz files are allowed.";
            $uploadOk = 0;
        }

        if ((move_uploaded_file($_FILES['file']['tmp_name'], $target_path)) && ($uploadOk == 1)) {

            $redis->rpush("service-runner","$import_script $import_flag>$import_logfile");
            header('Location: '.$path.'backup');
        } else {
            $result = "Sorry, there was an error uploading the file";
        }
    }

    return array('content'=>$result);
}

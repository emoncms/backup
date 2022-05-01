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
    global $route, $session, $path, $redis, $linked_modules_dir, $settings;
    $result = false;
    // This module is only to be ran by the admin user
    if (!$session['write'] && !$session['admin']) {
        $route->format = "html";
        return "<br><div class='alert alert-error'><b>Error:</b> backup module requires admin access</div>";
    }
    if (file_exists("$linked_modules_dir/backup/config.cfg")) {
        $ini_string = file_get_contents("$linked_modules_dir/backup/config.cfg");
        // Strip out comments from ini file
        $ini_string_lines = explode("\n",$ini_string);
        $tmp = array();
        for ($i=0; $i<count($ini_string_lines); $i++) {
            if (isset($ini_string_lines[$i][0]) && $ini_string_lines[$i][0]!="#") $tmp[] = $ini_string_lines[$i];
        }
        $ini_string_lines = $tmp;
    
        $parsed_ini = parse_ini_string(implode("\n",$ini_string_lines), true);
    } else {
        return "<br><div class='alert alert-error'><b>Error:</b> missing backup config.cfg</div>";
    }
    
    $schedule_file = "/etc/cron.daily/emoncms-export";

    $export_flag = "/tmp/emoncms-flag-export";
    $export_script = $parsed_ini['backup_script_location']."/emoncms-export.sh";
    $export_logfile = $settings['log']['location']."/exportbackup.log";
    $backup_type = preg_replace('/[^\w]/','',get('backupType'));
    $backup_location = preg_replace('/[^\w\-:\/.]/','',get('backupLocation'));

    $import_flag = "/tmp/emoncms-flag-import";
    $import_script = $parsed_ini['backup_script_location']."/emoncms-import.sh";
    $import_logfile = $settings['log']['location']."/importbackup.log";

    $usb_import_flag = "/tmp/emoncms-flag-usb-import";
    $usb_import_script = $parsed_ini['backup_script_location']."/usb-import.sh";
    $usb_import_logfile = $settings['log']['location']."/usbimport.log";

    if ($route->format == 'html' && $route->action == "") {
        @exec('lsblk --raw --paths --noheadings --output PATH,TYPE,MOUNTPOINT', $blockdevices);
        $backup_types = [
            'local' => 'Local backup',
            'drive' => 'Backup to specified drive',
            'nfs'   => 'Backup to NFS location'
        ];
        $block_devices = [];
        foreach ($blockdevices AS $blockdevice) {
            $parts = explode(' ', $blockdevice);
            $block_devices[] = [
                "path"       => count($parts) >= 1 ? $parts[0] : '',
                "type"       => count($parts) >= 2 ? $parts[1] : '',
                "mountpoint" => count($parts) >= 3 ? $parts[2] : ''
            ];
        }
        
        $result = view("Modules/backup/backup_view.php",array("parsed_ini"=>$parsed_ini,'backup_types'=>$backup_types,'block_devices'=>$block_devices));
    }

    if ($route->action == 'start') {
        $route->format = "text";
        $redis->rpush("service-runner","$export_script $backup_type $backup_location $export_flag>$export_logfile");
    }

    if ($route->action == 'schedule') {
        $schedule_data = "#!/bin/bash\n$export_script $backup_type $backup_location $export_flag $> $export_logfile";
        $route->format = "text";
        file_put_contents($schedule_file, $schedule_data);
    }

    if ($route->action == 'unschedule') {
        $schedule_data = "#!/bin/bash\n# no cron task defined";
        $route->format = "text";
        file_put_contents($schedule_file, $schedule_data);
    }

    if ($route->action == 'schedulefile') {
        $route->format = "text";
        if (file_exists($schedule_file)) {
            ob_start();
            passthru("cat $schedule_file");
            $result = trim(ob_get_clean());
        } else {
            $result = "";
        }
    }

    if ($route->action == 'exportlog') {
        $route->format = "text";
        if (file_exists($export_logfile)) {
            ob_start();
            passthru("cat $export_logfile");
            $result = trim(ob_get_clean());
        } else {
            $result = "";
        }
    }

    if ($route->action == 'importlog') {
        $route->format = "text";
        if (file_exists($import_logfile)) {
            ob_start();
            passthru("cat $import_logfile");
            $result = trim(ob_get_clean());
        } else {
            $result = "";
        }
    }

    if ($route->action == 'usbimportlog') {
        $route->format = "text";
        if (file_exists($usb_import_logfile)) {
            ob_start();
            passthru("cat $usb_import_logfile");
            $result = trim(ob_get_clean());
        } else {
            $result = "";
        }
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
            header('Location: '.$path.'backup#import');
        } else {
            return "<br><div class='alert alert-error'><b>Error:</b> Import archive not selected</div>";
        }
    }
    
    if ($route->action == "usbimport") {
        $route->format = "text";
        $result = "Starting USB import";
        $redis->rpush("service-runner","$usb_import_script $usb_import_flag>$usb_import_logfile");
    }

    return array('content'=>$result);
}
